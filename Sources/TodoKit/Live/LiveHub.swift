import Fluent
import Vapor

/// Environment-driven limits. Read once; tests may override via `app.liveSettings`.
struct LiveSettings: Sendable {
    /// How often a replica checks the token while at least one connection waits (one query set for all waiters).
    var pollInterval: TimeInterval = 1.5
    var maxWaitSeconds: Int = 25
    var defaultWaitSeconds: Int = 25
    var maxWaitersPerAccount: Int = 8
    var maxWaitersPerReplica: Int = 500
    /// Waiters are woken at least this often to re-validate the session (revocation ends the connection).
    var sessionRecheckSeconds: TimeInterval = 10
    var clientPollSeconds: Int = 5
    var enabled: Bool = true

    static func fromEnvironment() -> LiveSettings {
        var s = LiveSettings()
        func int(_ k: String) -> Int? { Environment.get(k).flatMap { Int($0) } }
        if let v = int("LIVE_POLL_MS"), v >= 100 { s.pollInterval = Double(v) / 1000 }
        if let v = int("LIVE_WAIT_MAX_SECONDS"), v >= 1 { s.maxWaitSeconds = min(v, 120); s.defaultWaitSeconds = min(25, s.maxWaitSeconds) }
        if let v = int("LIVE_MAX_WAITERS_PER_ACCOUNT"), v >= 1 { s.maxWaitersPerAccount = v }
        if let v = int("LIVE_MAX_WAITERS_PER_REPLICA"), v >= 1 { s.maxWaitersPerReplica = v }
        if let v = int("LIVE_CLIENT_POLL_SECONDS"), v >= 1 { s.clientPollSeconds = v }
        if Environment.get("LIVE_REFRESH_ENABLED") == "false" { s.enabled = false }
        return s
    }
}

/// Per-replica registry of long-poll waiters. Replicas are never coupled: each one only compares the database
/// token (the same `sync_counter` + `live_events` every replica writes to) with what its own waiters know.
actor LiveHub {
    enum Wake: Sendable {
        case changed(String)   // new token
        case recheck           // time to re-validate the session / deadline reached
        case shutdown
    }
    enum Registration { case ok, accountLimit, replicaLimit }

    private struct Waiter {
        let user: UUID
        let since: String
        let continuation: CheckedContinuation<Wake, Never>
    }

    private let app: Application
    private var waiters: [UUID: Waiter] = [:]
    private var poller: Task<Void, Never>?
    private var closed = false
    private var polls = 0

    init(app: Application) { self.app = app }

    var waiterCount: Int { waiters.count }

    /// Waits until the token differs from `since`, `seconds` passed (recheck), or the replica shuts down.
    func wait(user: UUID, since: String, seconds: TimeInterval, settings: LiveSettings) async -> (Registration, Wake?) {
        if closed { return (.ok, .shutdown) }
        if waiters.count >= settings.maxWaitersPerReplica { return (.replicaLimit, nil) }
        if waiters.values.filter({ $0.user == user }).count >= settings.maxWaitersPerAccount { return (.accountLimit, nil) }
        let id = UUID()
        startPoller(settings)
        let wake = await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Wake, Never>) in
                waiters[id] = Waiter(user: user, since: since, continuation: c)
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    await self?.resume(id, .recheck)
                }
            }
        } onCancel: { Task { await self.resume(id, .recheck) } }
        return (.ok, wake)
    }

    private func resume(_ id: UUID, _ wake: Wake) {
        guard let w = waiters.removeValue(forKey: id) else { return }
        w.continuation.resume(returning: wake)
    }

    private func startPoller(_ settings: LiveSettings) {
        guard poller == nil else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(settings.pollInterval * 1_000_000_000))
                guard let self else { return }
                if await !self.tick() { return }
            }
        }
    }

    /// Returns false when there is nothing left to watch (poller ends; restarted by the next waiter).
    private func tick() async -> Bool {
        if waiters.isEmpty || closed { poller = nil; return false }
        polls += 1
        do {
            let now = try await LiveToken.current(on: app.db).token
            for (id, w) in waiters where w.since != now { resume(id, .changed(now)) }
            if polls % 400 == 0 { try? await LiveToken.trim(on: app.db) }
        } catch {
            // Never fail waiters because of a transient database error; they fall back to their deadline.
            app.logger.warning("live hub: token check failed")
        }
        if waiters.isEmpty { poller = nil; return false }
        return true
    }

    func shutdown() {
        closed = true
        poller?.cancel(); poller = nil
        for id in Array(waiters.keys) { resume(id, .shutdown) }
    }
}

final class LiveHubLifecycle: LifecycleHandler, @unchecked Sendable {
    let hub: LiveHub
    init(_ hub: LiveHub) { self.hub = hub }
    func shutdown(_ application: Application) {
        let hub = self.hub
        Task { await hub.shutdown() }
    }
}

extension Application {
    private struct LiveSettingsKey: StorageKey { typealias Value = LiveSettings }
    private struct LiveHubKey: StorageKey { typealias Value = LiveHub }

    var liveSettings: LiveSettings {
        get { storage[LiveSettingsKey.self] ?? LiveSettings.fromEnvironment() }
        set { storage[LiveSettingsKey.self] = newValue }
    }

    var liveHub: LiveHub {
        if let hub = storage[LiveHubKey.self] { return hub }
        let hub = LiveHub(app: self)
        storage[LiveHubKey.self] = hub
        lifecycle.use(LiveHubLifecycle(hub))
        return hub
    }
}
