import Fluent
import Vapor

/// Opaque, lossless (createdAt, id) cursor. The date travels as the exact bit pattern of its Double so that no
/// rounding (the activity feed's problem) can skip or repeat an event at a page boundary.
struct FeedCursor: Equatable {
    let date: Date
    let id: UUID

    var encoded: String { String(date.timeIntervalSinceReferenceDate.bitPattern, radix: 16) + "_" + id.uuidString }

    init(date: Date, id: UUID) { self.date = date; self.id = id }
    init(_ raw: String) throws {
        let parts = raw.split(separator: "_", maxSplits: 1).map(String.init)
        guard parts.count == 2, let bits = UInt64(parts[0], radix: 16), let id = UUID(uuidString: parts[1]) else {
            throw Abort(.badRequest, reason: "invalid_cursor")
        }
        let seconds = Double(bitPattern: bits)
        guard seconds.isFinite else { throw Abort(.badRequest, reason: "invalid_cursor") }
        self.date = Date(timeIntervalSinceReferenceDate: seconds); self.id = id
    }

    /// Total order: newest first, ties by id string (descending). `true` = `a` comes before `b`.
    static func precedes(_ a: (Date, UUID), _ b: (Date, UUID)) -> Bool {
        a.0 != b.0 ? a.0 > b.0 : a.1.uuidString > b.1.uuidString
    }
}

struct FeedService: Sendable {
    let user: User
    let db: any Database
    var allowedProjects: Set<UUID>? = nil

    static let maxNeedsYou = 10
    static let managementKinds = [
        "progress.posted", "build.added", "task.status_changed", "review.accepted", "review.changes_requested",
        "question.answered", "comment.created", "agent.claimed", "agent.submit", "agent.stop", "agent.fail",
        "agent.accept", "agent.request_changes",
    ]
    static let classicKinds = ["comment.created", "task.status_changed"]

    func feed(projectID: UUID?, mode rawMode: String?, cursor rawCursor: String?, limit rawLimit: Int?) async throws -> FeedResponse {
        let mode = rawMode ?? "all"
        guard ["all", "classic", "management"].contains(mode) else { throw Abort(.badRequest, reason: "invalid_mode") }
        let limit = rawLimit ?? 30
        guard (1...100).contains(limit) else { throw Abort(.badRequest, reason: "invalid_limit") }
        let cursor = try rawCursor.map(FeedCursor.init)
        let now = Date()
        let scope = try await CommandCenterScope.resolve(user: user, db: db, projectID: projectID, includeSubprojects: true, allowed: allowedProjects)
        var needs: [FeedNeedsYouDTO] = []
        var total = 0
        if cursor == nil {
            let all = try await needsYou(scope: scope, classic: mode == "classic", now: now)
            total = all.count
            needs = Array(all.prefix(Self.maxNeedsYou))
        }
        let (posts, next) = try await posts(scope: scope, kinds: mode == "classic" ? Self.classicKinds : Self.managementKinds, cursor: cursor, limit: limit)
        return FeedResponse(generatedAt: now, mode: mode, projectID: projectID, needsYou: needs, needsYouTotal: total, posts: posts, nextCursor: next)
    }

    // MARK: Needs you

    private func roles(_ scope: CommandCenterScope) async throws -> [UUID: ProjectRole] {
        var result: [UUID: ProjectRole] = [:]
        let access = SharingAccess(user: user, db: db)
        for (id, project) in scope.projects { if let role = try await access.visibility(project).role { result[id] = role } }
        return result
    }

    private func chunks<T>(_ values: [T], _ size: Int = 200) -> [[T]] {
        stride(from: 0, to: values.count, by: size).map { Array(values[$0..<min($0 + size, values.count)]) }
    }

    private func needsYou(scope: CommandCenterScope, classic: Bool, now: Date) async throws -> [FeedNeedsYouDTO] {
        let ids = scope.projectIDs
        guard !ids.isEmpty else { return [] }
        let roles = try await roles(scope)
        let userID = try user.requireID()
        func name(_ id: UUID) -> String { scope.projects[id]?.name ?? "" }
        var ranked: [(rank: Int, sort: Date, item: FeedNeedsYouDTO)] = []

        if !classic {
            for chunk in chunks(ids) {
                // Open questions. The answer rules only forbid an integration answering its own question, which a person never is.
                let questions = try await TaskQuestion.query(on: db)
                    .join(TodoTask.self, on: \TaskQuestion.$taskID == \TodoTask.$id)
                    .filter(TodoTask.self, \.$projectID ~~ chunk).filter(TaskQuestion.self, \.$state == "open").all()
                for q in questions {
                    let task = try q.joined(TodoTask.self)
                    guard (roles[task.projectID]?.rank ?? -1) >= ProjectRole.comment.rank else { continue }
                    let qid = try q.requireID()
                    let actions: [FeedActionDTO] = q.options.isEmpty
                        ? [FeedActionDTO(key: "answer", label: "Antworten", method: "POST", path: "/v1/questions/\(qid)/answer", body: nil, requiresInput: true, inputField: "answer")]
                        : q.options.map { FeedActionDTO(key: "answer", label: $0, method: "POST", path: "/v1/questions/\(qid)/answer", body: FeedActionBody(answer: $0), requiresInput: false, inputField: nil) }
                    ranked.append((q.blocking ? 0 : 1, q.createdAt ?? now, FeedNeedsYouDTO(
                        id: "question:\(qid)", kind: "question", projectID: task.projectID, projectName: name(task.projectID), taskID: try task.requireID(),
                        taskTitle: task.title, taskVersion: task.version, title: q.prompt, detail: nil, options: q.options, blocking: q.blocking,
                        questionID: qid, reviewID: nil, dueAt: nil, actor: FeedActorDTO(type: q.askedByType, id: q.askedByID, name: q.askedByLabel),
                        createdAt: q.createdAt, actions: actions)))
                }
                // Pending reviews the user may decide.
                let reviews = try await TaskReview.query(on: db)
                    .join(TodoTask.self, on: \TaskReview.$taskID == \TodoTask.$id)
                    .filter(TodoTask.self, \.$projectID ~~ chunk).filter(TaskReview.self, \.$state == "pending").all()
                for r in reviews {
                    let task = try r.joined(TodoTask.self)
                    guard (roles[task.projectID]?.rank ?? -1) >= ProjectRole.edit.rank,
                        r.reviewerID == nil || r.reviewerID == userID else { continue }
                    let rid = try r.requireID(), tid = try task.requireID()
                    let path = "/v1/tasks/\(tid)/review/decision"
                    ranked.append((2, r.createdAt ?? now, FeedNeedsYouDTO(
                        id: "review:\(rid)", kind: "review", projectID: task.projectID, projectName: name(task.projectID), taskID: tid,
                        taskTitle: task.title, taskVersion: task.version, title: r.summary, detail: nil, options: [], blocking: false,
                        questionID: nil, reviewID: rid, dueAt: nil, actor: FeedActorDTO(type: r.requestedByType, id: r.requestedByID, name: r.requestedByLabel),
                        createdAt: r.createdAt, actions: [
                            FeedActionDTO(key: "accept", label: "Annehmen", method: "POST", path: path, body: FeedActionBody(decision: "accept"), requiresInput: false, inputField: nil),
                            FeedActionDTO(key: "request_changes", label: "Änderungen anfordern", method: "POST", path: path, body: FeedActionBody(decision: "request_changes"), requiresInput: true, inputField: "note"),
                        ])))
                }
                // Blocked tasks with the reason.
                let blocked = try await TaskWorkflow.query(on: db)
                    .join(TodoTask.self, on: \TaskWorkflow.$id == \TodoTask.$id)
                    .filter(TodoTask.self, \.$projectID ~~ chunk).filter(TodoTask.self, \.$status != "done")
                    .filter(TaskWorkflow.self, \.$blockedReason != .null).all()
                for wf in blocked {
                    let task = try wf.joined(TodoTask.self)
                    guard (roles[task.projectID]?.rank ?? -1) >= ProjectRole.edit.rank, let reason = wf.blockedReason, !reason.isEmpty else { continue }
                    ranked.append((3, task.updatedAt ?? now, FeedNeedsYouDTO(
                        id: "blocked:\(try task.requireID())", kind: "blocked", projectID: task.projectID, projectName: name(task.projectID),
                        taskID: try task.requireID(), taskTitle: task.title, taskVersion: task.version, title: task.title, detail: reason, options: [],
                        blocking: true, questionID: nil, reviewID: nil, dueAt: nil, actor: nil, createdAt: task.updatedAt, actions: [])))
                }
            }
        }
        // Due within 24 hours or overdue: open tasks the user created (there are no assignees yet).
        let horizon = now.addingTimeInterval(86_400)
        for chunk in chunks(ids) {
            let planned = try await TaskPlanning.query(on: db)
                .join(TodoTask.self, on: \TaskPlanning.$id == \TodoTask.$id)
                .filter(TodoTask.self, \.$projectID ~~ chunk).filter(TodoTask.self, \.$status != "done")
                .filter(TodoTask.self, \.$ownerID == userID).filter(TaskPlanning.self, \.$dueAt != .null)
                .filter(TaskPlanning.self, \.$dueAt <= horizon).all()
            for p in planned {
                let task = try p.joined(TodoTask.self)
                guard (roles[task.projectID]?.rank ?? -1) >= ProjectRole.read.rank, let due = p.dueAt else { continue }
                let canEdit = (roles[task.projectID]?.rank ?? -1) >= ProjectRole.edit.rank
                let tid = try task.requireID()
                ranked.append((due < now ? 4 : 5, due, FeedNeedsYouDTO(
                    id: "due:\(tid)", kind: due < now ? "overdue" : "due", projectID: task.projectID, projectName: name(task.projectID), taskID: tid,
                    taskTitle: task.title, taskVersion: task.version, title: task.title, detail: nil, options: [], blocking: false, questionID: nil,
                    reviewID: nil, dueAt: due, actor: nil, createdAt: task.createdAt,
                    actions: canEdit ? [FeedActionDTO(key: "complete", label: "Erledigt", method: "PATCH", path: "/v1/tasks/\(tid)",
                        body: FeedActionBody(status: "done", version: task.version), requiresInput: false, inputField: nil)] : [])))
            }
        }
        return ranked.sorted { ($0.rank, $0.sort, $0.item.id) < ($1.rank, $1.sort, $1.item.id) }.map(\.item)
    }

    // MARK: Posts

    /// Events newest first, strictly after `cursor`, in the total order of `FeedCursor.precedes`. The database only
    /// narrows by time (with one second of tolerance); the exact boundary and the tie order are decided here, on the
    /// loaded values, so DB collation and timestamp precision cannot move an event across a page boundary.
    private func events(projectIDs: [UUID], kinds: [String], cursor: FeedCursor?, want: Int) async throws -> (rows: [ActivityEvent], exhausted: Bool) {
        var n = max(want * 2, 40)
        while true {
            var query = ActivityEvent.query(on: db)
                .join(TodoTask.self, on: \ActivityEvent.$taskID == \TodoTask.$id)
                .filter(TodoTask.self, \.$projectID ~~ projectIDs).filter(ActivityEvent.self, \.$kind ~~ kinds)
            if let cursor { query = query.filter(ActivityEvent.self, \.$createdAt <= cursor.date.addingTimeInterval(1)) }
            var raw = try await query.sort(ActivityEvent.self, \.$createdAt, .descending).sort(ActivityEvent.self, \.$id, .descending).limit(n).all()
            let exhausted = raw.count < n
            if !exhausted, let edge = raw.last?.createdAt {
                // The last timestamp group may be cut off; only complete groups are trustworthy.
                raw.removeAll { $0.createdAt == edge }
            }
            var rows = raw.filter { e in
                guard let at = e.createdAt, let id = e.id else { return false }
                guard let cursor else { return true }
                return FeedCursor.precedes((cursor.date, cursor.id), (at, id)) && !(at == cursor.date && id == cursor.id)
            }
            rows.sort { FeedCursor.precedes(($0.createdAt!, $0.id!), ($1.createdAt!, $1.id!)) }
            if rows.count >= want || exhausted || n >= 4000 { return (rows, exhausted) }
            n *= 2
        }
    }

    private func posts(scope: CommandCenterScope, kinds: [String], cursor start: FeedCursor?, limit: Int) async throws -> ([FeedPostDTO], String?) {
        let ids = scope.projectIDs
        guard !ids.isEmpty else { return ([], nil) }
        var cursor = start
        var out: [FeedPostDTO] = []
        for _ in 0..<5 {
            let (rows, exhausted) = try await events(projectIDs: ids, kinds: kinds, cursor: cursor, want: limit)
            let taken = Array(rows.prefix(limit))
            let more = rows.count > limit || !exhausted
            if let last = taken.last { cursor = FeedCursor(date: last.createdAt!, id: last.id!) }
            out += try await build(taken, scope: scope)
            if taken.isEmpty || !more { return (out, nil) }
            if out.count >= limit { return (out, cursor?.encoded) }
        }
        return (out, cursor?.encoded)
    }

    private func build(_ events: [ActivityEvent], scope: CommandCenterScope) async throws -> [FeedPostDTO] {
        guard !events.isEmpty else { return [] }
        func subjects(_ kinds: [String]) -> [UUID] { events.filter { kinds.contains($0.kind) }.compactMap(\.subjectID) }
        let tasks = Dictionary(uniqueKeysWithValues: try await TodoTask.query(on: db).filter(\.$id ~~ Array(Set(events.map(\.taskID)))).all().map { ($0.id!, $0) })
        let notes = Dictionary(uniqueKeysWithValues: try await TaskProgressNote.query(on: db).filter(\.$id ~~ subjects(["progress.posted"])).all().map { ($0.id!, $0) })
        let comments = Dictionary(uniqueKeysWithValues: try await TaskComment.query(on: db).filter(\.$id ~~ subjects(["comment.created"])).all().map { ($0.id!, $0) })
        let reviews = Dictionary(uniqueKeysWithValues: try await TaskReview.query(on: db).filter(\.$id ~~ subjects(["review.accepted", "review.changes_requested"])).all().map { ($0.id!, $0) })
        let answeredIDs = subjects(["question.answered"])
        let questions = Dictionary(uniqueKeysWithValues: try await TaskQuestion.query(on: db).filter(\.$id ~~ answeredIDs).all().map { ($0.id!, $0) })
        let artifacts = Dictionary(uniqueKeysWithValues: try await BuildArtifact.query(on: db).filter(\.$id ~~ subjects(["build.added"])).all().map { ($0.id!, $0) })
        let attachments = Dictionary(uniqueKeysWithValues: try await Attachment.query(on: db).filter(\.$id ~~ artifacts.values.map(\.attachmentID)).all().map { ($0.id!, $0) })
        let names = try await displayNames(events.filter { $0.actorType == .person }.map(\.actorID), on: db)

        var result: [FeedPostDTO] = []
        var buildIndex: [String: Int] = [:]  // taskID|buildID -> index in result
        for e in events {
            guard let task = tasks[e.taskID], let eventID = e.id else { continue }
            var actorName: String? = e.actorType == .person ? names[e.actorID] : nil
            var kind = "", state: String?, text: String?, detail: String?, percent: Int?
            var images: [FeedImageDTO] = []
            switch e.kind {
            case "progress.posted":
                guard let n = e.subjectID.flatMap({ notes[$0] }) else { continue }
                kind = "progress"; text = n.note; percent = n.percent; actorName = n.actorLabel ?? actorName
            case "build.added":
                guard let artifact = e.subjectID.flatMap({ artifacts[$0] }) else { continue }
                kind = "build"; text = artifact.label ?? artifact.buildID
                if let a = attachments[artifact.attachmentID], a.mediaType.hasPrefix("image/") {
                    images = [FeedImageDTO(attachmentID: artifact.attachmentID, buildArtifactID: artifact.id, filename: a.filename, mediaType: a.mediaType,
                        previewURL: "/v1/attachments/\(artifact.attachmentID.uuidString)/preview", buildID: artifact.buildID, label: artifact.label, platform: artifact.platform)]
                }
                // Several screenshots of one build on one task become one post (within this page).
                let key = "\(e.taskID)|\(artifact.buildID)"
                if let at = buildIndex[key] {
                    let existing = result[at]
                    result[at] = FeedPostDTO(id: existing.id, kind: existing.kind, event: existing.event, state: existing.state, projectID: existing.projectID,
                        projectName: existing.projectName, taskID: existing.taskID, taskTitle: existing.taskTitle, actor: existing.actor, text: existing.text,
                        detail: existing.detail, percent: nil, images: existing.images + images, createdAt: existing.createdAt)
                    continue
                }
                buildIndex[key] = result.count
            case "task.status_changed":
                guard task.status == "done" else { continue }
                kind = "done"
            case "review.accepted", "review.changes_requested":
                guard let r = e.subjectID.flatMap({ reviews[$0] }) else { continue }
                kind = "review"; state = e.kind == "review.accepted" ? "accepted" : "changes_requested"
                text = r.decisionNote ?? r.summary
            case "question.answered":
                guard let q = e.subjectID.flatMap({ questions[$0] }) else { continue }
                kind = "question"; text = q.prompt; detail = q.answer
            case "comment.created":
                guard let c = e.subjectID.flatMap({ comments[$0] }) else { continue }
                kind = "comment"; text = String(c.body.prefix(600))
            case "agent.claimed": kind = "agent_run"; state = "started"
            case "agent.submit": kind = "agent_run"; state = "finished"
            case "agent.stop": kind = "agent_run"; state = "stopped"
            case "agent.fail": kind = "agent_run"; state = "failed"
            case "agent.accept": kind = "review"; state = "accepted"
            case "agent.request_changes": kind = "review"; state = "changes_requested"
            default: continue
            }
            result.append(FeedPostDTO(id: eventID, kind: kind, event: e.kind, state: state, projectID: task.projectID,
                projectName: scope.projects[task.projectID]?.name ?? "", taskID: e.taskID, taskTitle: task.title,
                actor: FeedActorDTO(type: e.actorType, id: e.actorID, name: actorName), text: text, detail: detail, percent: percent,
                images: images, createdAt: e.createdAt))
        }
        return result
    }
}
