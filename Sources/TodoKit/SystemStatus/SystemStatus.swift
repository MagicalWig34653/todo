import Fluent
import Vapor

/// Latest situation report (traffic lights for quota, Codex, disk) pushed by a watcher on the owner's Mac.
/// One row per (user, source); a new report replaces the old one. Known fields are validated, the rest is kept as is.
final class SystemStatus: Model, @unchecked Sendable {
    static let schema = "system_status"
    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userID: UUID
    @Field(key: "source") var source: String
    /// Label of the reporting runner device, for display only.
    @OptionalField(key: "label") var label: String?
    @Field(key: "reported_at") var reportedAt: Date
    @Field(key: "payload") var payload: [String: JSONValue]
    init() {}
    init(userID: UUID, source: String, label: String?, reportedAt: Date, payload: [String: JSONValue]) {
        self.userID = userID; self.source = source; self.label = label; self.reportedAt = reportedAt; self.payload = payload
    }
}

struct CreateSystemStatus: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(SystemStatus.schema).id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("source", .string, .required)
            .field("label", .string)
            .field("reported_at", .datetime, .required)
            .field("payload", .json, .required)
            .unique(on: "user_id", "source").create()
    }
    func revert(on db: any Database) async throws { try await db.schema(SystemStatus.schema).delete() }
}

func configureSystemStatus(_ app: Application) {
    app.migrations.add(CreateSystemStatus())
}

struct SystemStatusItem: Content {
    let source: String
    let label: String?
    let reportedAt: Date
    let status: JSONValue
}

struct SystemStatusResponse: Content {
    let items: [SystemStatusItem]
    /// Server clock: clients compute the age of a report against it (no trust in the device clock).
    let now: Date
}

enum SystemStatusService {
    static let maxSources = 10
    static let maxBytes = 16_384
    static let ampel: Set<String> = ["gruen", "gelb", "rot"]

    static func validSource(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 64 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.:".contains($0)) }
    }

    /// Known fields are typed; unknown fields pass through. Throws 400 `invalid_status` / `invalid_<field>`.
    static func validate(_ body: JSONValue) throws {
        guard case .object(let o) = body, !o.isEmpty else { throw Abort(.badRequest, reason: "invalid_status") }
        guard (try? JSONEncoder().encode(body).count) ?? Int.max <= maxBytes else { throw Abort(.badRequest, reason: "status_too_large") }
        func number(_ v: JSONValue?) -> Bool { if case .number = v { return true }; return false }
        func optional(_ key: String, _ ok: (JSONValue) -> Bool) throws {
            if let v = o[key], !v.isNull, !ok(v) { throw Abort(.badRequest, reason: "invalid_\(key)") }
        }
        func isAmpel(_ v: JSONValue) -> Bool { if case .string(let s) = v { return ampel.contains(s) }; return false }
        func isDate(_ v: JSONValue) -> Bool { if case .string(let s) = v { return parseDate(s) != nil }; return false }
        try optional("claude_ampel", isAmpel)
        try optional("platte_ampel", isAmpel)
        try optional("zeit", isDate)
        try optional("claude_frei_fuer_brain") { number($0) }
        try optional("platte_frei_gb") { number($0) }
        try optional("claude_nutzbare_konten") { v in
            if case .array(let a) = v { return a.count <= 50 && a.allSatisfy { number($0) } }; return false
        }
        try optional("codex") { v in
            guard case .object(let c) = v else { return false }
            for k in ["verbraucht_pct", "erlaubt_bis_jetzt_pct", "ziel_pct"] where c[k] != nil && !c[k]!.isNull && !number(c[k]) { return false }
            if let r = c["reset"], !r.isNull, !isDate(r) { return false }
            if let f = c["freigabe"], !f.isNull { guard case .bool = f else { return false } }
            return true
        }
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    static func report(userID: UUID, source: String, label: String?, body: JSONValue, on db: any Database) async throws -> SystemStatusItem {
        try validate(body)
        guard case .object(let payload) = body else { throw Abort(.badRequest, reason: "invalid_status") }
        guard validSource(source) else { throw Abort(.badRequest, reason: "invalid_source") }
        let now = Date()
        let row: SystemStatus
        if let existing = try await SystemStatus.query(on: db).filter(\.$userID == userID).filter(\.$source == source).first() {
            existing.payload = payload; existing.reportedAt = now; if let label { existing.label = label }
            try await existing.save(on: db); row = existing
        } else {
            guard try await SystemStatus.query(on: db).filter(\.$userID == userID).count() < maxSources else {
                throw Abort(.conflict, reason: "too_many_sources")
            }
            row = SystemStatus(userID: userID, source: source, label: label, reportedAt: now, payload: payload)
            try await row.save(on: db)
        }
        return SystemStatusItem(source: row.source, label: row.label, reportedAt: row.reportedAt, status: .object(row.payload))
    }

    static func read(userID: UUID, on db: any Database) async throws -> SystemStatusResponse {
        let rows = try await SystemStatus.query(on: db).filter(\.$userID == userID).sort(\.$source).all()
        return SystemStatusResponse(items: rows.map { SystemStatusItem(source: $0.source, label: $0.label, reportedAt: $0.reportedAt, status: .object($0.payload)) }, now: Date())
    }
}

struct SystemStatusController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let r = routes.grouped("v1", "system-status")
        r.put(use: put)
        r.get(use: get)
    }

    /// A paired runner device token (the watcher on the Mac) or a normal session may report; reading needs a session.
    @Sendable func put(_ req: Request) async throws -> SystemStatusItem {
        let source = req.query[String.self, at: "source"] ?? "default"
        let body = try req.content.decode(JSONValue.self)
        if let token = req.headers.bearerAuthorization?.token,
           let device = try await RunnerDevice.query(on: req.db).filter(\.$tokenHash == AuthSupport.hash(token)).first() {
            guard device.revokedAt == nil, let owner = try await User.find(device.ownerID, on: req.db), !owner.isLocked else { throw Abort(.unauthorized) }
            return try await SystemStatusService.report(userID: device.ownerID, source: source, label: device.label, body: body, on: req.db)
        }
        let user = try await req.requireUser()
        return try await SystemStatusService.report(userID: user.requireID(), source: source, label: nil, body: body, on: req.db)
    }

    @Sendable func get(_ req: Request) async throws -> SystemStatusResponse {
        try await SystemStatusService.read(userID: req.requireUser().requireID(), on: req.db)
    }
}
