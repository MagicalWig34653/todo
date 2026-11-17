import Fluent
import Vapor

/// ADR 0033: account switch "Automatische Starts erlauben" (default off), one row per person.
final class AutoStartAccount: Model, @unchecked Sendable {
    static let schema = "account_auto_start"
    @ID(custom: "id", generatedBy: .user) var id: UUID?
    @Field(key: "allowed") var allowed: Bool
    @Field(key: "updated_at") var updatedAt: Date
    init() {}
    init(userID: UUID, allowed: Bool, updatedAt: Date) { id = userID; self.allowed = allowed; self.updatedAt = updatedAt }
}

struct AutoStartRequest: Content {
    var version: Int
    var enabled: Bool
    /// Chooses the runner device when the project has several usable bindings.
    var deviceID: UUID?
}

struct AutoStartAccountRequest: Content { var allowed: Bool }
struct AutoStartAccountResponse: Content { var allowed: Bool; var updatedAt: Date? }

/// Where the origin of an agent release comes from. `scheduler` is only reachable through an MCP connection (the guard).
enum ReleaseOrigin: String { case manual, scheduler }

extension Request {
    /// Person session only (cookie or session bearer). A valid OAuth access token or runner device token gets 403
    /// `session_required` instead of 401: the credential is known but must never decide this.
    func requirePersonSession() async throws -> User {
        do { return try await requireUser() }
        catch let error as Abort where error.status == .unauthorized && error.reason != "account_disabled" {
            if let raw = headers.bearerAuthorization?.token {
                let hash = AuthSupport.hash(raw)
                let oauth = try await OAuthSecret.query(on: db).filter(\.$hash == hash).filter(\.$kind == "access").first()
                let device = try await RunnerDevice.query(on: db).filter(\.$tokenHash == hash).first()
                if oauth != nil || device != nil { throw Abort(.forbidden, reason: "session_required") }
            }
            throw error
        }
    }
}

enum AutoStartService {
    /// Catch-up threshold: a start later than this after `plannedAt` counts as catch-up in the audit.
    static let catchupSeconds: TimeInterval = 5 * 60

    // MARK: Account switch

    static func accountAllowed(userID: UUID, on db: any Database) async throws -> Bool {
        try await AutoStartAccount.find(userID, on: db)?.allowed ?? false
    }

    static func account(userID: UUID, on db: any Database) async throws -> AutoStartAccountResponse {
        let row = try await AutoStartAccount.find(userID, on: db)
        return AutoStartAccountResponse(allowed: row?.allowed ?? false, updatedAt: row?.updatedAt)
    }

    static func setAccount(userID: UUID, allowed: Bool, on database: any Database) async throws -> AutoStartAccountResponse {
        try await database.transaction { db in
            try await lockRow(table: User.schema, id: userID, on: db)
            let row = try await AutoStartAccount.find(userID, on: db) ?? AutoStartAccount(userID: userID, allowed: false, updatedAt: Date())
            row.allowed = allowed; row.updatedAt = Date()
            try await row.save(on: db)
            return AutoStartAccountResponse(allowed: allowed, updatedAt: row.updatedAt)
        }
    }

    // MARK: Bindings

    /// The person's live devices bound to the project; `deviceID` narrows the choice. Same rule for `start_agent_job`.
    static func usableBinding(projectID: UUID, deviceID: UUID?, user: User, on db: any Database) async throws -> ProjectRunnerBinding {
        var candidates: [ProjectRunnerBinding] = []
        for binding in try await ProjectRunnerBinding.query(on: db).filter(\.$projectID == projectID).sort(\.$id).all() {
            if let deviceID, binding.deviceID != deviceID { continue }
            guard let device = try await RunnerDevice.find(binding.deviceID, on: db), device.ownerID == user.id,
                  device.revokedAt == nil, device.tokenHash != nil else { continue }
            candidates.append(binding)
        }
        guard !candidates.isEmpty else { throw Abort(.conflict, reason: "no_binding") }
        guard candidates.count == 1, let binding = candidates.first else { throw Abort(.conflict, reason: "device_required") }
        return binding
    }

    // MARK: Per-card permission

    /// `PUT /v1/tasks/{id}/auto-start`. Owner only; the caller authenticated a person session.
    static func set(taskID: UUID, request: AutoStartRequest, user: User, on database: any Database) async throws -> PlanningTaskDTO {
        try await database.transaction { db in
            let service = PlanningService(user: user, db: db)
            try await service.lock()
            try await lockRow(table: TodoTask.schema, id: taskID, on: db)
            let task = try await service.task(taskID, role: .read)
            _ = try await ProjectAccess(user: user, db: db).startAgent(in: task.projectID)
            guard task.version == request.version else { throw Abort(.conflict, reason: "version_conflict") }
            let planning = try await TaskPlanning.find(taskID, on: db) ?? TaskPlanning(taskID: taskID)
            if request.enabled {
                guard task.status != "done" else { throw Abort(.conflict, reason: "task_done") }
                guard planning.plannedAt != nil else { throw Abort(.conflict, reason: "planned_start_required") }
                guard !planning.plannedAllDay else { throw Abort(.conflict, reason: "all_day_not_allowed") }
                _ = try await usableBinding(projectID: task.projectID, deviceID: request.deviceID, user: user, on: db)
            }
            if planning.autoStart != request.enabled {
                planning.autoStart = request.enabled
                try await planning.save(on: db)
                // The version bump saves the task row and thereby emits the sync upsert (clients and live refresh).
                task.version += 1
                try await task.save(on: db)
                try await appendActivity(taskID: taskID, actorType: .person, actorID: user.requireID(),
                    kind: request.enabled ? "agent.auto_start_enabled" : "agent.auto_start_disabled", subjectID: nil, on: db)
            }
            return try PlanningTaskDTO(task, planning)
        }
    }

    /// Caller holds the task row lock. Clears the permission and records `agent.auto_start_revoked` for the actor.
    /// Does not save `planning` when `save` is false (the caller saves it with its own change).
    static func revoke(_ planning: TaskPlanning, taskID: UUID, actorType: ActivityActorType, actorID: UUID, save: Bool = true, on db: any Database) async throws {
        guard planning.autoStart else { return }
        planning.autoStart = false
        if save { try await planning.save(on: db) }
        try await appendActivity(taskID: taskID, actorType: actorType, actorID: actorID, kind: "agent.auto_start_revoked", subjectID: nil, on: db)
    }

    /// Title, description or project change revokes, no matter who did it. Caller holds the task row lock.
    static func contentChanged(taskID: UUID, actorType: ActivityActorType, actorID: UUID, on db: any Database) async throws {
        guard let planning = try await TaskPlanning.find(taskID, on: db) else { return }
        try await revoke(planning, taskID: taskID, actorType: actorType, actorID: actorID, on: db)
    }

    /// Schedule change on an already modified `planning` (not yet saved). A moved start or a switch to all-day always
    /// revokes; a changed duration revokes unless the project owner changed it in person (not through a connection).
    static func scheduleChanged(_ planning: TaskPlanning, taskID: UUID, projectID: UUID, before: (start: Date?, minutes: Int?, allDay: Bool),
                                user: User, integrationGrant: UUID?, on db: any Database) async throws {
        guard planning.autoStart else { return }
        let startChanged = planning.plannedAt != before.start
        let becameAllDay = planning.plannedAllDay && !before.allDay
        let minutesChanged = planning.plannedMinutes != before.minutes
        var revokes = startChanged || becameAllDay
        if !revokes, minutesChanged {
            let owner = try await isOwner(user, projectID: projectID, on: db)
            revokes = integrationGrant != nil || !owner
        }
        guard revokes else { return }
        try await revoke(planning, taskID: taskID, actorType: integrationGrant == nil ? .person : .integration,
                         actorID: try integrationGrant ?? user.requireID(), save: false, on: db)
    }

    static func isOwner(_ user: User, projectID: UUID, on db: any Database) async throws -> Bool {
        do { _ = try await ProjectAccess(user: user, db: db).startAgent(in: projectID); return true }
        catch let error as Abort where error.status == .forbidden || error.status == .notFound { return false }
    }
}
