import Fluent
import SQLKit
import Vapor

/// Locking and anonymizing accounts instead of deleting them (user decision 1.11.2026, docs/VERWALTUNG.md).
///
/// Disable: login and every connection stop working at once (sessions, OAuth grants, runner devices, open agent
/// jobs, push devices, recovery codes, open invitations). Reversible by an admin.
/// Anonymize: irreversible. The name becomes a placeholder, username, password, passkeys, recovery, e-mail and push
/// data are removed. Projects, tasks and comments stay and keep pointing at the (now anonymous) account.
struct AddAccountLock: AsyncMigration {
    func prepare(on db: any Database) async throws {
        // One ALTER per column: SQLite cannot add several columns in one statement.
        try await db.schema(User.schema).field("disabled_at", .datetime).update()
        try await db.schema(User.schema).field("disabled_by", .uuid).update()
        try await db.schema(User.schema).field("anonymized_at", .datetime).update()
    }
    func revert(on db: any Database) async throws {
        try await db.schema(User.schema).deleteField("anonymized_at").update()
        try await db.schema(User.schema).deleteField("disabled_by").update()
        try await db.schema(User.schema).deleteField("disabled_at").update()
    }
}

enum AccountLock {
    /// Shown instead of the name everywhere once an account is anonymized.
    static let placeholderName = "Ehemaliges Mitglied"
    static let confirmation = "ANONYMIZE"
    static let openJobStates = ["queued", "claimed", "running", "waiting_for_answer"]

    enum Action { case disable, enable, anonymize }

    /// `allowSelf`: the self-service route may lock the caller's own account; the admin route may not.
    /// The last remaining active administrator can never be locked (409 last_admin_required).
    @discardableResult
    static func apply(_ action: Action, userID: UUID, actor: User, allowSelf: Bool, on database: any Database) async throws -> User {
        try await database.transaction { db in
            if let sql = db as? any SQLDatabase, sql.dialect.name != "sqlite" {
                _ = try await sql.raw("SELECT id FROM users WHERE is_admin = 1 FOR UPDATE").all()
            }
            try await lockRow(table: User.schema, id: userID, on: db)
            guard let user = try await User.find(userID, on: db) else { throw Abort(.notFound) }
            let now = Date()
            if action != .enable, !allowSelf, user.id == actor.id {
                throw SettingsProblem(code: "cannot_lock_self", key: nil, message: "Du kannst dein eigenes Konto hier nicht sperren. Nutze dafür die Einstellungen unter Daten & Datenschutz.")
            }
            switch action {
            case .enable:
                if user.anonymizedAt != nil {
                    throw SettingsProblem(code: "account_anonymized", key: nil, message: "Ein anonymisiertes Konto kann nicht wieder entsperrt werden.")
                }
                guard user.disabledAt != nil else { return user }
                user.disabledAt = nil; user.disabledBy = nil
                try await user.save(on: db)
                try await audit(db, actor: actor, userID: userID, detail: "enabled")
            case .disable, .anonymize:
                if user.anonymizedAt != nil { return user }
                if action == .disable, user.disabledAt != nil { return user }
                if user.isAdmin, user.disabledAt == nil,
                   try await User.query(on: db).filter(\.$isAdmin == true).filter(\.$disabledAt == nil).count() <= 1 {
                    throw SettingsProblem(code: "last_admin_required", key: nil, message: "Das Konto des letzten Administrators kann nicht gesperrt werden.")
                }
                if user.disabledAt == nil { user.disabledAt = now; user.disabledBy = actor.id }
                try await revokeConnections(of: userID, now: now, on: db)
                if action == .anonymize { try await wipe(user, now: now, on: db) }
                try await user.save(on: db)
                try await audit(db, actor: actor, userID: userID, detail: action == .anonymize ? "anonymized" : "disabled")
            }
            return user
        }
    }

    private static func audit(_ db: any Database, actor: User, userID: UUID, detail: String) async throws {
        let e = ServerSettingAudit()
        e.settingKey = "admin.account"; e.action = "account"; e.actorID = actor.id; e.actorName = actor.displayName
        e.detail = "\(detail):\(userID.uuidString.lowercased())"
        try await e.save(on: db)
    }

    /// Everything that lets the account (or a program acting for it) act on the server.
    private static func revokeConnections(of uid: UUID, now: Date, on db: any Database) async throws {
        try await UserSession.query(on: db).filter(\.$user.$id == uid).delete()
        try await AuthChallenge.query(on: db).filter(\.$userID == uid).delete()
        try await RecoveryGrant.query(on: db).filter(\.$userID == uid).delete()
        try await Invitation.query(on: db).filter(\.$createdBy == uid).filter(\.$usedAt == nil).delete()
        for grant in try await OAuthGrant.query(on: db).filter(\.$userID == uid).filter(\.$revoked == false).all() {
            grant.revoked = true
            try await grant.save(on: db)
        }
        for device in try await PushDevice.query(on: db).filter(\.$userID == uid).filter(\.$revokedAt == nil).all() {
            device.revokedAt = now
            try await device.save(on: db)
        }
        // Runner devices: revoked like a manual revoke; open jobs of the account or on its devices are cancelled
        // and their runs fenced (a local process can only be told later).
        let devices = try await RunnerDevice.query(on: db).filter(\.$ownerID == uid).all()
        for device in devices where device.revokedAt == nil {
            device.revokedAt = now
            try await device.save(on: db)
        }
        let deviceIDs = try devices.map { try $0.requireID() }
        var bindingIDs: [UUID] = []
        if !deviceIDs.isEmpty {
            bindingIDs = try await ProjectRunnerBinding.query(on: db).filter(\.$deviceID ~~ deviceIDs).all().map { try $0.requireID() }
        }
        var jobs = try await AgentJob.query(on: db).filter(\.$state ~~ openJobStates).filter(\.$requestedBy == uid).all()
        if !bindingIDs.isEmpty {
            jobs += try await AgentJob.query(on: db).filter(\.$state ~~ openJobStates).filter(\.$bindingID ~~ bindingIDs).all()
        }
        var seen = Set<UUID>()
        for job in jobs {
            let jobID = try job.requireID()
            guard seen.insert(jobID).inserted else { continue }
            job.state = "cancelled"
            try await WorkflowMirror.runnerWithdrawn(jobID: jobID, on: db)
            for run in try await AgentRun.query(on: db).filter(\.$jobID == jobID).filter(\.$endedAt == nil).all() {
                run.generation += 1; run.leaseUntil = now
                try await run.save(on: db)
            }
            try await job.save(on: db)
            try await AgentService.event(job, kind: "account_disabled", on: db)
        }
        // Runs of the account's devices that belong to jobs of other people: fence them as well.
        if !deviceIDs.isEmpty {
            for run in try await AgentRun.query(on: db).filter(\.$deviceID ~~ deviceIDs).filter(\.$endedAt == nil).all() {
                run.generation += 1; run.leaseUntil = now
                try await run.save(on: db)
            }
        }
    }

    /// Irreversible part of anonymizing.
    private static func wipe(_ user: User, now: Date, on db: any Database) async throws {
        let uid = try user.requireID()
        user.displayName = placeholderName
        user.username = nil
        user.passwordHash = nil
        user.isAdmin = false
        user.anonymizedAt = now
        try await PasskeyCredential.query(on: db).filter(\.$user.$id == uid).delete()
        try await UserEmail.query(on: db).filter(\.$userID == uid).delete()
        try await EmailVerification.query(on: db).filter(\.$userID == uid).delete()
        try await MailOutbox.query(on: db).filter(\.$userID == uid).delete()
        try await PushDevice.query(on: db).filter(\.$userID == uid).delete()
        try await PushPrefs.query(on: db).filter(\.$userID == uid).delete()
        try await PushOutbox.query(on: db).filter(\.$userID == uid).delete()
        let deviceIDs = try await RunnerDevice.query(on: db).filter(\.$ownerID == uid).all().map { try $0.requireID() }
        if !deviceIDs.isEmpty {
            try await RunnerPairing.query(on: db).filter(\.$deviceID ~~ deviceIDs).delete()
            for device in try await RunnerDevice.query(on: db).filter(\.$id ~~ deviceIDs).all() {
                device.tokenHash = nil
                try await device.save(on: db)
            }
        }
        try await ServerSettingAudit.query(on: db).filter(\.$actorID == uid).set(\.$actorName, to: placeholderName).update()
    }
}

// MARK: - Routes

struct AccountLockController: RouteCollection {
    /// Export size limit; larger accounts get 413 with a hint (no silent truncation).
    static let maxExportBytes = 20 * 1024 * 1024

    struct ConfirmBody: Content { let confirm: String }

    func boot(routes: any RoutesBuilder) throws {
        let admin = routes.grouped("v1", "admin").grouped(SettingsProblemMiddleware())
        admin.post("users", ":id", "disable") { try await self.admin($0, .disable) }
        admin.post("users", ":id", "enable") { try await self.admin($0, .enable) }
        admin.post("users", ":id", "anonymize") { try await self.admin($0, .anonymize) }
        let me = routes.grouped("v1", "me").grouped(SettingsProblemMiddleware())
        me.post("anonymize", use: anonymizeSelf)
        me.get("export", use: export)
    }

    @Sendable private func admin(_ req: Request, _ action: AccountLock.Action) async throws -> AdminUserDTO {
        let actor = try await req.requireAdmin()
        guard let id = req.parameters.get("id", as: UUID.self) else { throw Abort(.badRequest) }
        return try AdminUserDTO(try await AccountLock.apply(action, userID: id, actor: actor, allowSelf: false, on: req.db))
    }

    /// Any person may lock and anonymize their own account after an explicit confirmation (never the last admin).
    @Sendable func anonymizeSelf(_ req: Request) async throws -> Response {
        let user = try await req.requireUser()
        guard (try? req.content.decode(ConfirmBody.self))?.confirm == AccountLock.confirmation else {
            throw SettingsProblem(code: "confirmation_required", key: nil, message: "Bitte bestätige das Anonymisieren ausdrücklich.")
        }
        try await AccountLock.apply(.anonymize, userID: try user.requireID(), actor: user, allowSelf: true, on: req.db)
        let response = Response(status: .noContent)
        response.cookies[AuthSupport.cookieName] = HTTPCookies.Value(
            string: "", expires: Date(timeIntervalSince1970: 0), maxAge: 0, path: "/",
            isSecure: req.application.settings.secureCookies, isHTTPOnly: true, sameSite: .strict)
        return response
    }

    // MARK: Export

    struct ExportAccount: Content {
        let id: UUID, displayName: String, username: String?, isAdmin: Bool, createdAt: Date?, email: String?
    }
    struct ExportProject: Content {
        let id: UUID, parentID: UUID?, name: String, description: String?, color: String?, createdAt: Date?, updatedAt: Date?
    }
    struct ExportTask: Content {
        let id: UUID, projectID: UUID, title: String, description: String, status: String, createdAt: Date?, updatedAt: Date?
    }
    struct ExportComment: Content {
        let id: UUID, taskID: UUID?, projectID: UUID?, body: String
    }
    struct ExportLabel: Content { let id: UUID, name: String }
    struct ExportDocument: Content {
        let exportedAt: Date
        let account: ExportAccount
        let projects: [ExportProject]
        let tasks: [ExportTask]
        let comments: [ExportComment]
        let labels: [ExportLabel]
    }

    /// Own data only: the account, projects and tasks it owns, comments it wrote and its labels. No secrets
    /// (no password hash, passkeys, tokens, push tokens).
    @Sendable func export(_ req: Request) async throws -> Response {
        let user = try await req.requireUser()
        let uid = try user.requireID()
        let db = req.db
        let email = try await UserEmail.query(on: db).filter(\.$userID == uid).first()?.email
        let projects = try await Project.query(on: db).filter(\.$ownerID == uid).sort(\.$createdAt).sort(\.$id).all().map {
            ExportProject(id: try $0.requireID(), parentID: $0.parentID, name: $0.name, description: $0.details, color: $0.color,
                          createdAt: $0.createdAt, updatedAt: $0.updatedAt)
        }
        let tasks = try await TodoTask.query(on: db).filter(\.$ownerID == uid).sort(\.$createdAt).sort(\.$id).all().map {
            ExportTask(id: try $0.requireID(), projectID: $0.projectID, title: $0.title, description: $0.details, status: $0.status,
                       createdAt: $0.createdAt, updatedAt: $0.updatedAt)
        }
        var comments = try await TaskComment.query(on: db).filter(\.$authorID == uid).sort(\.$id).all().map {
            ExportComment(id: try $0.requireID(), taskID: $0.taskID, projectID: nil, body: $0.body)
        }
        comments += try await ProjectComment.query(on: db).filter(\.$authorID == uid).sort(\.$id).all().map {
            ExportComment(id: try $0.requireID(), taskID: nil, projectID: $0.projectID, body: $0.body)
        }
        let labels = try await DiscoveryLabel.query(on: db).filter(\.$ownerID == uid).sort(\.$name).all().map {
            ExportLabel(id: try $0.requireID(), name: $0.name)
        }
        let document = ExportDocument(
            exportedAt: Date(),
            account: ExportAccount(id: uid, displayName: user.displayName, username: user.username, isAdmin: user.isAdmin,
                                   createdAt: user.createdAt, email: email),
            projects: projects, tasks: tasks, comments: comments, labels: labels)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= Self.maxExportBytes else {
            throw Abort(.payloadTooLarge, reason: "export_too_large")
        }
        var headers = HTTPHeaders()
        headers.contentType = .json
        headers.replaceOrAdd(name: .contentDisposition, value: "attachment; filename=\"todolino-export.json\"")
        headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        return Response(status: .ok, headers: headers, body: .init(data: data))
    }
}
