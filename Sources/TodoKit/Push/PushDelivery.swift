import Fluent
import Vapor

/// A notification ready for the wire (content depends on the device locale and the account's content setting).
struct PushMessage: Equatable, Sendable {
    var title: String
    var body: String
    var kind: String
    var taskID: UUID?
    var projectID: UUID?
    var subjectID: UUID?
    var badge: Int?
    var threadID: String?
    var category: String
    var priority: Int
    var ttl: TimeInterval

    func payload() throws -> Data {
        var aps: [String: Any] = ["alert": ["title": title, "body": body], "sound": "default", "mutable-content": 1, "category": category]
        if let badge { aps["badge"] = badge }
        if let threadID { aps["thread-id"] = threadID }
        // Deep-link fields for the app (userInfo): identifiers only.
        var root: [String: Any] = ["aps": aps, "kind": kind]
        if let taskID { root["taskID"] = taskID.uuidString }
        if let projectID { root["projectID"] = projectID.uuidString }
        if let subjectID { root["subjectID"] = subjectID.uuidString }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
}

enum PushContent {
    static func clip(_ s: String, _ n: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        return t.count <= n ? t : String(t.prefix(n - 1)) + "…"
    }

    static func isGerman(_ locale: String?) -> Bool { (locale ?? "de").lowercased().hasPrefix("de") }

    /// Text for the notification. Without `showContent` it is generic: task titles and prompts reach Apple's
    /// servers and the lock screen only when the account opted in (ADR 0021).
    static func message(for event: PushEvent, category: String, task: TodoTask, detail: String?, showContent: Bool,
                        locale: String?, badge: Int?) -> PushMessage {
        let de = isGerman(locale)
        let title: String, body: String, cat: String, priority: Int, ttl: TimeInterval
        let name = clip(task.title, 80)
        switch event.kind {
        case "reminder":
            (cat, priority, ttl) = ("TODO_REMINDER", 10, 12 * 3600)
            title = showContent ? name : (de ? "Erinnerung" : "Reminder")
            body = showContent ? (de ? "Erinnerung" : "Reminder") : (de ? "Eine Aufgabe ist fällig." : "A task is due.")
        case "question":
            (cat, priority, ttl) = ("TODO_QUESTION", 10, 24 * 3600)
            title = showContent ? (de ? "Rückfrage: " : "Question: ") + name : (de ? "Rückfrage vom Agenten" : "Question from the agent")
            body = showContent ? clip(detail ?? "", 160) : (de ? "Eine Aufgabe wartet auf deine Antwort." : "A task is waiting for your answer.")
        case "review":
            (cat, priority, ttl) = ("TODO_REVIEW", 10, 24 * 3600)
            title = showContent ? "Review: " + name : (de ? "Review bereit" : "Review ready")
            body = showContent ? clip(detail ?? "", 160) : (de ? "Ein Ergebnis wartet auf deine Prüfung." : "A result is waiting for your review.")
        default:
            (cat, priority, ttl) = ("TODO_COMMENT", 5, 12 * 3600)
            title = showContent ? (de ? "Kommentar: " : "Comment: ") + name : (de ? "Neuer Kommentar" : "New comment")
            body = showContent ? (de ? "Neuer Kommentar" : "New comment") : (de ? "Zu einer Aufgabe gibt es einen neuen Kommentar." : "A task has a new comment.")
        }
        return PushMessage(title: title, body: body.isEmpty ? title : body, kind: event.kind, taskID: event.taskID,
                           projectID: event.projectID, subjectID: event.subjectID, badge: badge,
                           threadID: event.projectID.uuidString, category: cat, priority: priority, ttl: ttl)
    }

    static func testMessage(locale: String?) -> PushMessage {
        let de = isGerman(locale)
        return PushMessage(title: "Todolino", body: de ? "Testbenachrichtigung: Push funktioniert." : "Test notification: push works.",
                           kind: "test", taskID: nil, projectID: nil, subjectID: nil, badge: nil, threadID: nil,
                           category: "TODO_TEST", priority: 5, ttl: 300)
    }
}

/// Sends one outbox row. Rights and object state are checked again here (not only at enqueue time): a revoked
/// share, a deleted task, an answered question or a decided review turns the row into `skipped`.
struct PushDelivery: Sendable {
    static let maxAttempts = 6

    struct Result: Equatable, Sendable {
        var state: String
        var error: String?
        var retryAfter: TimeInterval?
        var revoked = 0
        var delivered = 0
    }

    let db: any Database
    let sender: APNsSender

    static func backoff(attempt: Int) -> TimeInterval { min(3600, 30 * pow(2, Double(max(0, attempt - 1)))) }

    static func requiredRole(_ kind: String) -> ProjectRole {
        switch kind {
        case "question": return .comment
        case "review": return .edit
        default: return .read
        }
    }

    /// nil when the event must no longer be delivered.
    func resolve(_ event: PushEvent, user: User) async throws -> (task: TodoTask, detail: String?)? {
        guard let task = try? await ProjectAccess(user: user, db: db).task(event.taskID, role: Self.requiredRole(event.kind)),
              task.projectID == event.projectID || event.kind == "reminder" else { return nil }
        switch event.kind {
        case "reminder":
            guard task.status != "done", let p = try await TaskPlanning.find(event.taskID, on: db),
                  p.reminders.contains(where: { Int($0.timeIntervalSince1970.rounded(.down)) == event.at }) else { return nil }
            return (task, nil)
        case "question":
            guard let id = event.subjectID, let q = try await TaskQuestion.find(id, on: db), q.state == "open" else { return nil }
            return (task, q.prompt)
        case "review":
            guard let id = event.subjectID, let r = try await TaskReview.find(id, on: db), r.state == "pending" else { return nil }
            return (task, r.summary)
        case "comment":
            return (task, nil)
        default:
            return nil
        }
    }

    func badge(for user: User) async -> Int? {
        let service = WorkflowService(user: user, db: db)
        guard let q = try? await service.questions(projectID: nil, taskID: nil, state: "open", limit: 100),
              let r = try? await service.reviews(projectID: nil, state: "pending", limit: 100) else { return nil }
        return q.count + r.count
    }

    func deliver(_ row: PushOutbox) async throws -> Result {
        guard let user = try await User.find(row.userID, on: db) else { return Result(state: "skipped", error: "account_gone") }
        let prefs = try await PushService.prefs(of: row.userID, on: db)
        guard prefs.categories[row.category] == true else { return Result(state: "skipped", error: "category_disabled") }
        guard let data = row.payload.data(using: .utf8), let event = try? JSONDecoder().decode(PushEvent.self, from: data) else {
            return Result(state: "failed", error: "invalid_payload")
        }
        guard let (task, detail) = try await resolve(event, user: user) else { return Result(state: "skipped", error: "no_longer_relevant") }
        let devices = try await PushDevice.query(on: db).filter(\.$userID == row.userID).filter(\.$revokedAt == nil).sort(\.$id).all()
        guard !devices.isEmpty else { return Result(state: "skipped", error: "no_device") }
        let badge = prefs.badge ? await badge(for: user) : nil
        var result = Result(state: "sent")
        var retry: String?, permanent: String?
        for device in devices {
            let message = PushContent.message(for: event, category: row.category, task: task, detail: detail,
                                              showContent: prefs.showContent, locale: device.locale, badge: badge)
            let outcome = await sender.send(to: device, payload: try message.payload(), priority: message.priority,
                                            ttl: message.ttl, collapseKey: row.dedupeKey)
            switch outcome {
            case .delivered: result.delivered += 1
            case .revoke:
                device.revokedAt = Date(); try await device.save(on: db); result.revoked += 1
            case .retry(let why): retry = why
            case .permanent(let why): permanent = why
            }
        }
        if let retry, row.attempts + 1 < Self.maxAttempts {
            return Result(state: "pending", error: retry, retryAfter: Self.backoff(attempt: row.attempts + 1), revoked: result.revoked, delivered: result.delivered)
        }
        if let why = retry ?? permanent, result.delivered == 0 { result.state = "failed"; result.error = why }
        else if result.delivered == 0 { result.state = "skipped"; result.error = "all_devices_revoked" }
        return result
    }
}
