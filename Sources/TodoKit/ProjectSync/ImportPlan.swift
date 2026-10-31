import Fluent
import Vapor

// MARK: - Request / result

struct PlanItem: Content {
    /// Stable key chosen by the caller (for example `phase-2/login`); unique inside the project.
    let externalKey: String
    let title: String
    let description: String?
    /// `open` (default) or `done`. Import only advances open -> done; it never reopens a task.
    let status: String?
    let blockedReason: String?
    let criteria: [String]?
    /// New open tasks land in "Backlog" instead of "Bereit".
    let backlog: Bool?
    /// Subtasks (one level). An item with children becomes a feature.
    let children: [PlanItem]?
}

struct ImportPlanRequest: Content {
    let items: [PlanItem]
    let applyWorkflowColumns: Bool?
    let dryRun: Bool?
}

struct ImportedItem: Content {
    let externalKey: String
    let taskID: UUID
    let title: String
    let parentKey: String?
    /// `created` | `updated` | `unchanged`
    let outcome: String
    /// What changed on an `updated` item (title, description, status, blocked, parent, kind, criteria:+n).
    let changes: [String]
}

struct ImportPlanResult: Content {
    let projectID: UUID
    let dryRun: Bool
    let created: Int
    let updated: Int
    let unchanged: Int
    let columnsCreated: Bool
    let items: [ImportedItem]
}

enum ImportPlanLimits {
    static let maxItems = 300
    static let maxCriteriaPerItem = 50
    static let maxDescription = 10_000
    static let maxKey = 200
}

// MARK: - Service

/// Idempotent bulk upsert of features/tasks/subtasks/criteria, matched by external key. One transaction; nothing is
/// deleted, reopened or unticked (the board is the source of truth for progress).
extension ProjectSyncService {
    private struct Flat {
        let item: PlanItem
        let key: String
        let title: String
        let description: String?
        let status: String
        let blocked: String?
        let criteria: [String]
        let parentKey: String?
        let hasChildren: Bool
    }

    private struct DryRunRollback: Error { let result: ImportPlanResult }

    static func cleanKey(_ raw: String) throws -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.count <= ImportPlanLimits.maxKey,
              !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Abort(.badRequest, reason: "invalid_external_key")
        }
        return key
    }

    private func flatten(_ items: [PlanItem]) throws -> [Flat] {
        var result: [Flat] = []
        var seen = Set<String>()
        func add(_ item: PlanItem, parent: String?, depth: Int) throws {
            let key = try Self.cleanKey(item.externalKey)
            guard seen.insert(key).inserted else { throw Abort(.badRequest, reason: "duplicate_external_key") }
            let title = try PlanningOperations.cleanName(item.title, reason: "invalid_title")
            var description: String?
            if let d = item.description {
                let value = d.trimmingCharacters(in: .whitespacesAndNewlines)
                guard value.count <= ImportPlanLimits.maxDescription else { throw Abort(.badRequest, reason: "invalid_description") }
                description = value
            }
            let status = item.status ?? "open"
            guard ["open", "done"].contains(status) else { throw Abort(.badRequest, reason: "invalid_status") }
            var blocked: String?
            if let b = item.blockedReason?.trimmingCharacters(in: .whitespacesAndNewlines), !b.isEmpty {
                guard b.count <= 1000 else { throw Abort(.badRequest, reason: "invalid_blocked_reason") }
                blocked = b
            }
            var criteria: [String] = []
            for raw in item.criteria ?? [] {
                let text = try WorkflowService.text(raw, max: 2000, reason: "invalid_criterion")
                if !criteria.contains(text) { criteria.append(text) }
            }
            guard criteria.count <= ImportPlanLimits.maxCriteriaPerItem else { throw Abort(.badRequest, reason: "too_many_criteria") }
            let children = item.children ?? []
            if !children.isEmpty, depth >= 1 { throw Abort(.badRequest, reason: "plan_too_deep") }
            result.append(Flat(item: item, key: key, title: title, description: description, status: status, blocked: blocked,
                               criteria: criteria, parentKey: parent, hasChildren: !children.isEmpty))
            guard result.count <= ImportPlanLimits.maxItems else { throw Abort(.badRequest, reason: "too_many_items") }
            for child in children { try add(child, parent: key, depth: depth + 1) }
        }
        for item in items { try add(item, parent: nil, depth: 0) }
        guard !result.isEmpty else { throw Abort(.badRequest, reason: "empty_plan") }
        return result
    }

    func importPlan(_ projectID: UUID, _ request: ImportPlanRequest, actor: WorkflowActor) async throws -> ImportPlanResult {
        let flat = try flatten(request.items)
        let dryRun = request.dryRun ?? false
        let applyColumns = request.applyWorkflowColumns ?? false
        let user = self.user, allowed = allowedProjects
        do {
            return try await db.transaction { tx in
                try await lockSharingGraph(on: tx)
                try await lockRow(table: Project.schema, id: projectID, on: tx)
                if let allowed, !allowed.contains(projectID) { throw Abort(.notFound) }
                _ = try await ProjectAccess(user: user, db: tx).project(projectID, role: .edit)
                let result = try await Self.apply(flat, projectID: projectID, applyColumns: applyColumns, dryRun: dryRun, user: user, actor: actor, on: tx)
                if dryRun { throw DryRunRollback(result: result) }
                return result
            }
        } catch let rollback as DryRunRollback {
            return rollback.result
        }
    }

    private static func apply(_ flat: [Flat], projectID: UUID, applyColumns: Bool, dryRun: Bool, user: User, actor: WorkflowActor,
                              on tx: any Database) async throws -> ImportPlanResult {
        var columnsCreated = false
        let columns = ColumnService(user: user, db: tx)
        if applyColumns, try await columns.columns(of: projectID).isEmpty {
            _ = try await columns.applyTemplate(projectID, source: "agent_workflow")
            columnsCreated = true
        }
        let keys = flat.map(\.key)
        var keyRows: [String: TaskExternalKey] = [:]
        var index = 0
        while index < keys.count {
            let chunk = Array(keys[index..<min(index + 400, keys.count)])
            index += 400
            for row in try await TaskExternalKey.query(on: tx).filter(\.$projectID == projectID).filter(\.$externalKey ~~ chunk).all() {
                keyRows[row.externalKey] = row
            }
        }
        var tasks: [String: TodoTask] = [:]
        for (key, row) in keyRows {
            // A task moved to another project keeps its key row; it no longer counts here.
            if let task = try await TodoTask.find(row.taskID, on: tx), task.projectID == projectID { tasks[key] = task }
        }
        var items: [ImportedItem] = []
        var taskByKey = tasks
        for entry in flat {
            var changes: [String] = []
            var created = false
            let task: TodoTask
            if let existing = tasks[entry.key] {
                task = existing
                var dirty = false
                if existing.title != entry.title { existing.title = entry.title; changes.append("title"); dirty = true }
                if let d = entry.description, existing.details != d { existing.details = d; changes.append("description"); dirty = true }
                if entry.status == "done", existing.status != "done" {
                    try await WorkflowService.applyStatus(existing, "done", actor: actor, on: tx); changes.append("status"); dirty = true
                }
                if dirty { existing.version += 1; try await existing.save(on: tx) }
            } else {
                task = TodoTask(ownerID: try user.requireID(), projectID: projectID, title: entry.title, details: entry.description ?? "")
                task.id = UUID()
                if entry.status == "done" {
                    task.status = "done"
                    try await ColumnService.reconcile(task, on: tx)
                } else {
                    try await WorkflowService.place(task, role: entry.item.backlog == true ? .backlog : .ready, on: tx)
                }
                try await task.save(on: tx)
                try await appendActivity(taskID: task.requireID(), actorType: actor.type, actorID: actor.id, kind: "task.created", subjectID: nil, on: tx)
                try await TaskExternalKey(taskID: task.requireID(), projectID: projectID, externalKey: entry.key).save(on: tx)
                created = true
            }
            let taskID = try task.requireID()
            taskByKey[entry.key] = task

            // Workflow: kind, parent, blocked reason.
            let existingWorkflow = try await TaskWorkflow.find(taskID, on: tx)
            let wf = existingWorkflow ?? TaskWorkflow(taskID: taskID)
            var wfDirty = existingWorkflow == nil && (entry.hasChildren || entry.parentKey != nil || entry.blocked != nil)
            if entry.hasChildren, wf.kind != "feature" {
                if wf.parentTaskID != nil { throw Abort(.unprocessableEntity, reason: "subtask_depth_exceeded") }
                wf.kind = "feature"; wfDirty = true; if !created { changes.append("kind") }
            }
            if let parentKey = entry.parentKey, let parent = taskByKey[parentKey] {
                let parentID = try parent.requireID()
                if wf.parentTaskID != parentID {
                    if let parentWorkflow = try await TaskWorkflow.find(parentID, on: tx), parentWorkflow.parentTaskID != nil {
                        throw Abort(.unprocessableEntity, reason: "subtask_depth_exceeded")
                    }
                    if try await TaskWorkflow.query(on: tx).filter(\.$parentTaskID == taskID).count() > 0 {
                        throw Abort(.unprocessableEntity, reason: "subtask_depth_exceeded")
                    }
                    wf.parentTaskID = parentID; wfDirty = true; if !created { changes.append("parent") }
                }
            }
            if let blocked = entry.blocked, wf.blockedReason != blocked {
                wf.blockedReason = blocked; wfDirty = true; if !created { changes.append("blocked") }
                try await appendActivity(taskID: taskID, actorType: actor.type, actorID: actor.id, kind: "task.blocked", subjectID: nil, on: tx)
            }
            if wfDirty { try await wf.save(on: tx) }

            // Criteria: add the missing ones by exact text; never remove or untick.
            if !entry.criteria.isEmpty {
                let have = Set(try await AcceptanceCriterion.query(on: tx).filter(\.$taskID == taskID).all().map(\.text))
                var added = 0
                for text in entry.criteria where !have.contains(text) {
                    let c = AcceptanceCriterion(taskID: taskID, text: text)
                    try await c.save(on: tx)
                    try await appendActivity(taskID: taskID, actorType: actor.type, actorID: actor.id, kind: "criterion.created", subjectID: c.id, on: tx)
                    added += 1
                }
                if added > 0, !created { changes.append("criteria:+\(added)") }
            }
            items.append(ImportedItem(externalKey: entry.key, taskID: taskID, title: task.title, parentKey: entry.parentKey,
                outcome: created ? "created" : (changes.isEmpty ? "unchanged" : "updated"), changes: changes))
        }
        return ImportPlanResult(projectID: projectID, dryRun: dryRun,
            created: items.filter { $0.outcome == "created" }.count, updated: items.filter { $0.outcome == "updated" }.count,
            unchanged: items.filter { $0.outcome == "unchanged" }.count, columnsCreated: columnsCreated, items: items)
    }

    /// Mapping external key -> task for a project (to resume work after an import).
    func planKeys(_ projectID: UUID) async throws -> [JSONValue] {
        _ = try await project(projectID)
        var result: [JSONValue] = []
        for row in try await TaskExternalKey.query(on: db).filter(\.$projectID == projectID).sort(\.$externalKey).all() {
            guard let task = try await TodoTask.find(row.taskID, on: db), task.projectID == projectID else { continue }
            let parent = try await TaskWorkflow.find(row.taskID, on: db)?.parentTaskID
            result.append(.object(["externalKey": .string(row.externalKey), "taskID": .string(row.taskID.uuidString),
                "title": .string(task.title), "status": .string(task.status), "parentTaskID": parent.map { .string($0.uuidString) } ?? .null]))
        }
        return result
    }
}
