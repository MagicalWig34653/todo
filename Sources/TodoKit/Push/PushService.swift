import Crypto
import Fluent
import Vapor

/// Device registration and per-account settings.
struct PushService: Sendable {
    static let maxActiveDevices = 20
    let user: User
    let db: any Database
    let settings: APNsConfig

    // MARK: Devices

    static func normalizedToken(_ raw: String) throws -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard t.range(of: "^[0-9a-f]{32,200}$", options: .regularExpression) != nil else { throw Abort(.badRequest, reason: "invalid_token") }
        return t
    }

    static func hash(_ token: String) -> String { SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined() }

    /// Idempotent per token: registering a known token refreshes it (and re-activates it); a token that moves to
    /// another account (new sign-in on the same device) is reassigned, so the previous account stops receiving it.
    func register(_ body: RegisterPushDeviceRequest) async throws -> (device: PushDevice, created: Bool) {
        let token = try Self.normalizedToken(body.token)
        guard ["ios", "macos"].contains(body.platform) else { throw Abort(.badRequest, reason: "invalid_platform") }
        let env = body.environment ?? settings.environment.rawValue
        guard APNsEnvironment(rawValue: env) != nil else { throw Abort(.badRequest, reason: "invalid_environment") }
        let bundle = body.bundleId.trimmingCharacters(in: .whitespaces)
        guard bundle.range(of: "^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil, bundle.count <= 155 else {
            throw Abort(.badRequest, reason: "invalid_bundle_id")
        }
        if settings.enabled, !settings.topics.contains(bundle) { throw Abort(.badRequest, reason: "invalid_bundle_id") }
        let version = try Self.short(body.appVersion, max: 40, reason: "invalid_app_version")
        let locale = try Self.short(body.locale, max: 35, reason: "invalid_locale")
        let userID = try user.requireID(), now = Date(), digest = Self.hash(token)
        let existing = try await PushDevice.query(on: db).filter(\.$tokenHash == digest).first()
        let device = existing ?? PushDevice()
        let created = existing == nil
        device.userID = userID; device.platform = body.platform; device.token = token; device.tokenHash = digest
        device.environment = env; device.bundleID = bundle; device.appVersion = version; device.locale = locale
        device.lastSeenAt = now; device.revokedAt = nil
        do { try await device.save(on: db) } catch {
            // Concurrent first registration of the same token: the unique hash made the second insert fail.
            guard created, let winner = try await PushDevice.query(on: db).filter(\.$tokenHash == digest).first() else { throw error }
            winner.userID = userID; winner.lastSeenAt = now; winner.revokedAt = nil
            try await winner.save(on: db)
            return (winner, false)
        }
        try await enforceLimit(keeping: try device.requireID())
        return (device, created)
    }

    private static func short(_ raw: String?, max: Int, reason: String) throws -> String? {
        guard let raw else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count <= max, !t.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Abort(.badRequest, reason: reason) }
        return t.isEmpty ? nil : t
    }

    /// At most `maxActiveDevices` per account: the least recently seen devices are revoked (stale tokens of
    /// reinstalled apps would otherwise block new registrations).
    private func enforceLimit(keeping id: UUID) async throws {
        let active = try await PushDevice.query(on: db).filter(\.$userID == user.requireID()).filter(\.$revokedAt == nil)
            .sort(\.$lastSeenAt, .descending).sort(\.$id).all()
        guard active.count > Self.maxActiveDevices else { return }
        for old in active.dropFirst(Self.maxActiveDevices) where old.id != id {
            old.revokedAt = Date(); try await old.save(on: db)
        }
    }

    func devices() async throws -> [PushDevice] {
        try await PushDevice.query(on: db).filter(\.$userID == user.requireID()).filter(\.$revokedAt == nil)
            .sort(\.$createdAt).sort(\.$id).all()
    }

    func revoke(_ id: UUID) async throws {
        guard let d = try await PushDevice.find(id, on: db), d.userID == (try user.requireID()), d.revokedAt == nil else { throw Abort(.notFound) }
        d.revokedAt = Date(); try await d.save(on: db)
    }

    // MARK: Preferences

    static func dto(_ row: PushPrefs?) -> PushPrefsDTO {
        var cats = PushCategory.defaults
        for (k, v) in row?.categories ?? [:] where cats[k] != nil { cats[k] = v }
        return PushPrefsDTO(categories: cats, showContent: row?.showContent ?? false, badge: row?.badge ?? true)
    }

    static func prefs(of userID: UUID, on db: any Database) async throws -> PushPrefsDTO {
        dto(try await PushPrefs.query(on: db).filter(\.$userID == userID).first())
    }

    func prefs() async throws -> PushPrefsDTO { try await Self.prefs(of: user.requireID(), on: db) }

    func update(_ body: UpdatePushPrefsRequest) async throws -> PushPrefsDTO {
        let userID = try user.requireID()
        for key in (body.categories ?? [:]).keys where PushCategory.defaults[key] == nil { throw Abort(.badRequest, reason: "invalid_category") }
        let row = try await PushPrefs.query(on: db).filter(\.$userID == userID).first() ?? {
            let r = PushPrefs(); r.userID = userID; r.categories = [:]; r.showContent = false; r.badge = true; return r
        }()
        for (k, v) in body.categories ?? [:] { row.categories[k] = v }
        if let s = body.showContent { row.showContent = s }
        if let b = body.badge { row.badge = b }
        do { try await row.save(on: db) } catch {
            // Two first writes at once: the unique user_id rejected one; apply onto the winner.
            guard row.$id.value == nil, let winner = try await PushPrefs.query(on: db).filter(\.$userID == userID).first() else { throw error }
            for (k, v) in body.categories ?? [:] { winner.categories[k] = v }
            if let s = body.showContent { winner.showContent = s }
            if let b = body.badge { winner.badge = b }
            try await winner.save(on: db)
            return Self.dto(winner)
        }
        return Self.dto(row)
    }
}

struct PushController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let v1 = routes.grouped("v1")
        v1.post("push", "devices", use: register)
        v1.get("push", "devices", use: list)
        v1.delete("push", "devices", ":id", use: revoke)
        v1.get("me", "push-prefs", use: getPrefs)
        v1.post("me", "push-prefs", use: setPrefs)
        v1.put("me", "push-prefs", use: setPrefs)
    }

    private func service(_ req: Request) async throws -> PushService {
        PushService(user: try await req.requireUser(), db: req.db, settings: req.application.settings.apns)
    }

    @Sendable func register(_ req: Request) async throws -> Response {
        let service = try await service(req)
        let (device, created) = try await service.register(req.content.decode(RegisterPushDeviceRequest.self))
        return try await PushDeviceDTO(device).encodeResponse(status: created ? .created : .ok, for: req)
    }
    @Sendable func list(_ req: Request) async throws -> [PushDeviceDTO] {
        try await service(req).devices().map(PushDeviceDTO.init)
    }
    @Sendable func revoke(_ req: Request) async throws -> HTTPStatus {
        guard let id = req.parameters.get("id", as: UUID.self) else { throw Abort(.badRequest) }
        try await service(req).revoke(id)
        return .noContent
    }
    @Sendable func getPrefs(_ req: Request) async throws -> PushPrefsDTO { try await service(req).prefs() }
    @Sendable func setPrefs(_ req: Request) async throws -> PushPrefsDTO {
        try await service(req).update(req.content.decode(UpdatePushPrefsRequest.self))
    }
}
