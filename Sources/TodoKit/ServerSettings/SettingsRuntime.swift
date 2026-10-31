import Fluent
import Foundation
import Vapor

/// Lock-protected mutable value. Hot-reloaded configuration is read by request handlers and replaced by the
/// settings runtime from a background task, so plain `Application.storage` access would be a data race.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

private let boxCreation = NSLock()

extension Application {
    /// Returns the box for `key`, creating it with `initial` on first use (creation is serialised process-wide).
    func lockedBox<K: StorageKey, V>(_ key: K.Type, _ initial: @autoclosure () -> V) -> Locked<V> where K.Value == Locked<V> {
        boxCreation.lock(); defer { boxCreation.unlock() }
        if let box = storage[key] { return box }
        let box = Locked(initial())
        storage[key] = box
        return box
    }
}

/// Stored settings of one process: loads rows, resolves env > database > default, and applies changes at runtime.
/// Replicas have no direct channel to each other: each one polls `(setting_key, version)` every few seconds.
final class SettingsRuntime: LifecycleHandler, @unchecked Sendable {
    struct Key: StorageKey { typealias Value = SettingsRuntime }

    let app: Application
    let env: @Sendable (String) -> String?
    let keyRing: SettingsKeyRing
    let pollInterval: TimeInterval
    private let state = Locked<State>(State())
    private var task: Task<Void, Never>?
    private let taskLock = NSLock()

    struct State {
        var signature = ""
        var lastError: String?
        var lastRefresh: Date?
    }

    init(app: Application, env: @escaping @Sendable (String) -> String? = { Environment.get($0) },
         keyRing: SettingsKeyRing, pollInterval: TimeInterval = 10) {
        self.app = app; self.env = env; self.keyRing = keyRing; self.pollInterval = pollInterval
    }

    var lastError: String? { state.value.lastError }

    // MARK: Loading

    struct Loaded {
        var rows: [ServerSetting]
        var values: [String: String]
        var unreadable: Set<String>
    }

    func load(on db: any Database) async throws -> Loaded {
        let rows = try await ServerSetting.query(on: db).all()
        var values: [String: String] = [:]
        var unreadable: Set<String> = []
        for r in rows {
            guard let v = r.value, SettingsRegistry.byKey[r.settingKey] != nil else { continue }
            if r.secret {
                do { values[r.settingKey] = try keyRing.open(v, keyID: r.keyID, settingKey: r.settingKey) }
                catch { unreadable.insert(r.settingKey) }
            } else {
                values[r.settingKey] = v
            }
        }
        return Loaded(rows: rows, values: values, unreadable: unreadable)
    }

    static func signature(_ rows: [ServerSetting]) -> String {
        rows.map { "\($0.settingKey):\($0.version)" }.sorted().joined(separator: ",")
    }

    /// Resolution as seen by the admin API: environment + stored rows (decrypted).
    func resolve(_ loaded: Loaded) throws -> SettingValues {
        try SettingsResolver.resolve(env: env, stored: loaded.values)
    }

    // MARK: Applying

    /// Startup: merge stored values into `app.settings`. Invalid stored values never prevent startup
    /// (falls back to the environment alone); an invalid environment still does, as before.
    func bootstrap() async throws {
        var base = try AppSettings.baseFromEnvironment(get: env)
        let envOnly = try SettingsResolver.resolve(env: env, stored: [:])
        var loaded: Loaded?
        if let l = try? await load(on: app.db) { loaded = l }
        var merged = base
        do {
            let values = try SettingsResolver.resolve(env: env, stored: loaded?.values ?? [:])
            try merged.applyHot(values, strict: true)
            merged.applyStartup(values)
            app.settings = merged
            app.liveSettings = values.liveSettings()
            app.identitySettings = values.identitySettings()
            state.value.signature = Self.signature(loaded?.rows ?? [])
        } catch {
            app.logger.error("stored settings are invalid, starting with the environment only: \(error)")
            state.value.lastError = "\(error)"
            try base.applyHot(envOnly); base.applyStartup(envOnly)
            app.settings = base
            app.liveSettings = envOnly.liveSettings()
            app.identitySettings = envOnly.identitySettings()
        }
    }

    /// Re-reads the rows and applies hot settings when something changed (or `force`). Returns whether it applied.
    @discardableResult
    func refresh(force: Bool = false) async -> Bool {
        do {
            let loaded = try await load(on: app.db)
            let sig = Self.signature(loaded.rows)
            guard force || sig != state.value.signature else { return false }
            let values = try resolve(loaded)
            let before = app.settings
            var next = before
            try next.applyHot(values, strict: true)
            // Build the new transports first: a failure leaves the running configuration untouched.
            let mailTransport = next.mail != before.mail ? (next.mail.enabled ? try SMTPClient(config: next.mail) : nil) : app.mailTransport
            let sender = next.apns != before.apns ? (next.apns.enabled ? try APNsSender(config: next.apns, transport: VaporAPNsTransport(client: app.client)) : nil) : app.apnsSender
            app.settings = next
            app.mailTransport = mailTransport
            app.apnsSender = sender
            app.liveSettings = values.liveSettings()
            app.identitySettings = values.identitySettings()
            state.value.signature = sig
            state.value.lastError = nil
            state.value.lastRefresh = Date()
            app.logger.info("server settings applied (\(loaded.rows.count) stored)")
            return true
        } catch {
            // Keep the last working configuration; remember the problem (never the values).
            state.value.lastError = "\(error)"
            app.logger.warning("server settings not applied: \(type(of: error))")
            return false
        }
    }

    // MARK: Lifecycle

    func didBoot(_ application: Application) throws {
        guard CleanupScheduler.isServing(arguments: application.environment.arguments) else { return }
        start()
    }

    func start() {
        taskLock.lock(); defer { taskLock.unlock() }
        guard task == nil else { return }
        let period = pollInterval
        task = Task.detached { [self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(period * Double.random(in: 0.9...1.1) * 1_000_000_000))
                if Task.isCancelled { break }
                await refresh()
            }
        }
    }

    func shutdown(_ application: Application) {
        taskLock.lock(); let t = task; task = nil; taskLock.unlock()
        t?.cancel()
    }
}

extension Application {
    var settingsRuntime: SettingsRuntime? {
        get { storage[SettingsRuntime.Key.self] }
        set { storage[SettingsRuntime.Key.self] = newValue }
    }

    /// Runtime for tests and the API: created on demand from the process environment.
    func requireSettingsRuntime() throws -> SettingsRuntime {
        if let r = settingsRuntime { return r }
        let r = SettingsRuntime(app: self, keyRing: try .fromEnvironment(get: { Environment.get($0) }))
        settingsRuntime = r
        return r
    }

    /// Rebuilds the SMTP transport from `settings.mail`.
    func reconfigureMail() throws {
        let cfg = settings.mail
        mailTransport = cfg.enabled ? try SMTPClient(config: cfg) : nil
    }

    /// Rebuilds the APNs sender from `settings.apns`.
    func reconfigurePush() throws {
        let cfg = settings.apns
        apnsSender = cfg.enabled ? try APNsSender(config: cfg, transport: VaporAPNsTransport(client: client)) : nil
    }
}
