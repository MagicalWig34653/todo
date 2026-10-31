import Fluent
import XCTVapor
@testable import TodoKit

/// ADR 0020: task.planning and label mutations/entities in the sync feed (SQLite only).
final class SyncPlanningLabelTests: XCTestCase {
    private func account(_ t: TestApp) async throws -> (id: String, token: String) {
        let user = User(displayName: "Test", isAdmin: false)
        try await user.save(on: t.app.db)
        let token = AuthSupport.randomToken()
        try await UserSession(userID: user.requireID(), tokenHash: AuthSupport.hash(token),
            expiresAt: Date().addingTimeInterval(3600)).save(on: t.app.db)
        return (try user.requireID().uuidString, token)
    }

    private func mutate(_ t: TestApp, _ token: String, _ type: String, id: String, mutationID: String = UUID().uuidString,
        _ fields: [String: Any] = [:]) async throws -> (status: HTTPStatus, body: [String: Any]?, replay: Bool) {
        var body: [String: Any] = ["mutationID": mutationID, "type": type, "id": id]
        body.merge(fields) { $1 }
        let r = try await t.json(.POST, "/v1/sync/mutations", body, token: token)
        return (r.status, r.body, false)
    }

    private func feed(_ t: TestApp, _ token: String, _ cursor: String = "c0") async throws -> [[String: Any]] {
        let r = try await t.json(.GET, "/v1/sync/changes?cursor=\(cursor)&limit=500", token: token)
        XCTAssertEqual(r.status, .ok)
        return r.body?["changes"] as? [[String: Any]] ?? []
    }

    private func labelEntries(_ t: TestApp, _ token: String, upsertOnly: Bool = false) async throws -> [[String: Any]] {
        try await feed(t, token).filter { $0["entityType"] as? String == "label" && (!upsertOnly || $0["kind"] as? String == "upsert") }
    }

    private func head(_ t: TestApp, _ token: String) async throws -> String {
        let r = try await t.json(.GET, "/v1/sync/changes?cursor=c0&limit=500", token: token)
        return r.body?["cursor"] as? String ?? "c0"
    }

    private func setup(_ t: TestApp, _ token: String) async throws -> (project: String, task: String) {
        let pid = UUID().uuidString, tid = UUID().uuidString
        _ = try await mutate(t, token, "project.create", id: pid, ["name": "P"])
        _ = try await mutate(t, token, "task.create", id: tid, ["projectID": pid, "title": "T"])
        return (pid, tid)
    }

    func testTaskPlanningSuccessConflictIdempotencyAndFeed() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let owner = try await account(t)
        let (_, tid) = try await setup(t, owner.token)
        let cursor = try await head(t, owner.token)

        // Feed task upserts always carry planning (defaults).
        let initial = try await feed(t, owner.token)
        let initialTask = try XCTUnwrap(initial.first { $0["entityType"] as? String == "task" })
        XCTAssertEqual((initialTask["planning"] as? [String: Any])?["priority"] as? Int, 0)

        let mid = UUID().uuidString
        let fields: [String: Any] = [
            "version": 1, "dueAt": "2030-01-02T10:00:00Z", "plannedAt": "2030-01-01T08:00:00Z", "priority": 3,
            "recurrence": ["frequency": "weekly", "interval": 1, "timeZone": "Europe/Berlin"],
            "reminders": ["2030-01-02T09:00:00Z"]]
        let r = try await mutate(t, owner.token, "task.planning", id: tid, mutationID: mid, fields)
        XCTAssertEqual(r.status, .ok, "\(String(describing: r.body))")
        XCTAssertEqual((r.body?["task"] as? [String: Any])?["version"] as? Int, 2)
        XCTAssertEqual((r.body?["planning"] as? [String: Any])?["priority"] as? Int, 3)

        // Same mutationID: replayed, no second version bump.
        let again = try await mutate(t, owner.token, "task.planning", id: tid, mutationID: mid, fields)
        XCTAssertEqual(again.status, .ok)
        XCTAssertEqual((again.body?["task"] as? [String: Any])?["version"] as? Int, 2)
        XCTAssertEqual(try XCTUnwrap(r.body?["cursor"] as? String), try XCTUnwrap(again.body?["cursor"] as? String))

        // Stale version: 409; REST sees the same data.
        let stale = try await mutate(t, owner.token, "task.planning", id: tid, fields.merging(["priority": 1]) { $1 })
        XCTAssertEqual(stale.status, .conflict)
        let rest = try await t.json(.GET, "/v1/planning/tasks/\(tid)", token: owner.token)
        XCTAssertEqual(rest.body?["priority"] as? Int, 3)
        // A stale task.update now conflicts as well (the planning change bumped the version).
        let upd = try await mutate(t, owner.token, "task.update", id: tid, ["version": 1, "title": "X"])
        XCTAssertEqual(upd.status, .conflict)

        // Feed after the cursor: exactly one task upsert with the new planning.
        let changed = try await feed(t, owner.token, cursor)
        let tasks = changed.filter { $0["entityType"] as? String == "task" }
        XCTAssertEqual(tasks.count, 1)
        let planning = try XCTUnwrap(tasks[0]["planning"] as? [String: Any])
        XCTAssertEqual(planning["priority"] as? Int, 3)
        XCTAssertEqual((planning["recurrence"] as? [String: Any])?["frequency"] as? String, "weekly")
        XCTAssertEqual((planning["reminders"] as? [Any])?.count, 1)

        // Full replacement: omitted fields clear. Invalid input: 400.
        let clear = try await mutate(t, owner.token, "task.planning", id: tid, ["version": 2])
        XCTAssertEqual(clear.status, .ok)
        XCTAssertEqual((clear.body?["planning"] as? [String: Any])?["priority"] as? Int, 0)
        XCTAssertNil((clear.body?["planning"] as? [String: Any])?["dueAt"])
        let bad = try await mutate(t, owner.token, "task.planning", id: tid, ["version": 3, "priority": 9])
        XCTAssertEqual(bad.status, .badRequest)
        let missing = try await mutate(t, owner.token, "task.planning", id: tid, ["priority": 1])
        XCTAssertEqual(missing.status, .badRequest)

        // A REST planning change (no version) also reaches the feed.
        let before = try await head(t, owner.token)
        let put = try await t.json(.PUT, "/v1/planning/tasks/\(tid)", ["priority": 2, "reminders": []], token: owner.token)
        XCTAssertEqual(put.status, .ok)
        let viaRest = try await feed(t, owner.token, before)
        XCTAssertEqual((viaRest.first { $0["entityType"] as? String == "task" }?["planning"] as? [String: Any])?["priority"] as? Int, 2)
    }

    func testTaskPlanningRights() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let owner = try await account(t), reader = try await account(t), stranger = try await account(t)
        let (pid, tid) = try await setup(t, owner.token)
        let grant = try await t.json(.PUT, "/v1/projects/\(pid)/grants",
            ["principalType": "person", "principalID": reader.id, "role": "read"], token: owner.token)
        XCTAssertTrue((200..<300).contains(Int(grant.status.code)))
        let denied = try await mutate(t, reader.token, "task.planning", id: tid, ["version": 1, "priority": 1])
        XCTAssertEqual(denied.status, .forbidden)
        let hidden = try await mutate(t, stranger.token, "task.planning", id: tid, ["version": 1, "priority": 1])
        XCTAssertEqual(hidden.status, .notFound)
        // The reader still sees planning in the feed.
        let readerFeed = try await feed(t, reader.token)
        XCTAssertNotNil(readerFeed.first { $0["entityType"] as? String == "task" }?["planning"])
    }

    func testLabelLifecycleIdempotencyConflictAndFeed() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let owner = try await account(t)
        let (_, tid) = try await setup(t, owner.token)
        let cursor = try await head(t, owner.token)
        let lid = UUID().uuidString, mid = UUID().uuidString

        var r = try await mutate(t, owner.token, "label.create", id: lid, mutationID: mid, ["name": "  Home "])
        XCTAssertEqual(r.status, .created, "\(String(describing: r.body))")
        XCTAssertEqual((r.body?["label"] as? [String: Any])?["name"] as? String, "Home")
        let replay = try await mutate(t, owner.token, "label.create", id: lid, mutationID: mid, ["name": "  Home "])
        XCTAssertEqual(replay.status, .created)
        // Another mutationID for the same ID: id_exists.
        r = try await mutate(t, owner.token, "label.create", id: lid, ["name": "Dup"])
        XCTAssertEqual(r.status, .conflict)
        r = try await mutate(t, owner.token, "label.create", id: UUID().uuidString, ["name": " "])
        XCTAssertEqual(r.status, .badRequest)
        let labels = try await LabelCount.count(t)
        XCTAssertEqual(labels, 1)

        // Rename with version check.
        r = try await mutate(t, owner.token, "label.rename", id: lid, ["version": 5, "name": "Work"])
        XCTAssertEqual(r.status, .conflict)
        r = try await mutate(t, owner.token, "label.rename", id: lid, ["version": 1, "name": "Work"])
        XCTAssertEqual(r.status, .ok)
        XCTAssertEqual((r.body?["label"] as? [String: Any])?["version"] as? Int, 2)

        // Attach (idempotent) / detach.
        r = try await mutate(t, owner.token, "task.label_add", id: tid, ["labelID": lid])
        XCTAssertEqual(r.status, .ok)
        XCTAssertEqual(((r.body?["label"] as? [String: Any])?["taskIDs"] as? [String])?.map { $0.lowercased() }, [tid.lowercased()])
        r = try await mutate(t, owner.token, "task.label_add", id: tid, ["labelID": lid])
        XCTAssertEqual(r.status, .ok)
        XCTAssertEqual(((r.body?["label"] as? [String: Any])?["taskIDs"] as? [Any])?.count, 1)
        let rest = try await t.json(.GET, "/v1/tasks/\(tid)/labels", token: owner.token)
        XCTAssertEqual((rest.body?["items"] as? [Any])?.count, 1)

        // Feed: one label upsert (latest state) with membership.
        let changed = try await feed(t, owner.token, cursor)
        let upserts = changed.filter { $0["entityType"] as? String == "label" }
        XCTAssertEqual(upserts.count, 1)
        let dto = try XCTUnwrap(upserts[0]["label"] as? [String: Any])
        XCTAssertEqual(dto["name"] as? String, "Work")
        XCTAssertEqual((dto["taskIDs"] as? [Any])?.count, 1)
        // Full state from c0 contains the label too.
        let all = try await labelEntries(t, owner.token)
        XCTAssertEqual(all.count, 1)

        r = try await mutate(t, owner.token, "task.label_remove", id: tid, ["labelID": lid])
        XCTAssertEqual(r.status, .ok)
        XCTAssertEqual(((r.body?["label"] as? [String: Any])?["taskIDs"] as? [Any])?.count, 0)

        // Deleting the task refreshes the label membership; deleting the label yields a tombstone.
        _ = try await mutate(t, owner.token, "task.label_add", id: tid, ["labelID": lid])
        let beforeDelete = try await head(t, owner.token)
        _ = try await mutate(t, owner.token, "task.delete", id: tid, ["version": 1])
        let afterTask = try await feed(t, owner.token, beforeDelete)
        let refreshed = try XCTUnwrap(afterTask.first { $0["entityType"] as? String == "label" }?["label"] as? [String: Any])
        XCTAssertEqual((refreshed["taskIDs"] as? [Any])?.count, 0)

        let beforeLabelDelete = try await head(t, owner.token)
        r = try await mutate(t, owner.token, "label.delete", id: lid, ["version": 1])
        XCTAssertEqual(r.status, .conflict)
        r = try await mutate(t, owner.token, "label.delete", id: lid, ["version": 2])
        XCTAssertEqual(r.status, .ok)
        XCTAssertEqual(r.body?["deleted"] as? Bool, true)
        let tomb = try await feed(t, owner.token, beforeLabelDelete)
        XCTAssertEqual(tomb.filter { $0["entityType"] as? String == "label" && $0["kind"] as? String == "delete" }.count, 1)
        // Deleted ID cannot be recreated; full state has no live label.
        r = try await mutate(t, owner.token, "label.create", id: lid, ["name": "Again"])
        XCTAssertEqual(r.status, .conflict)
        let live = try await labelEntries(t, owner.token, upsertOnly: true)
        XCTAssertTrue(live.isEmpty)
    }

    func testLabelsArePrivateAndRespectTaskVisibility() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let owner = try await account(t), reader = try await account(t), stranger = try await account(t)
        let (pid, tid) = try await setup(t, owner.token)
        let lid = UUID().uuidString
        _ = try await mutate(t, owner.token, "label.create", id: lid, ["name": "Private"])
        // Foreign account: label and rename/delete are 404; labelling a task it cannot read is 404.
        for (type, fields) in [("label.rename", ["version": 1, "name": "x"] as [String: Any]), ("label.delete", [:])] {
            let r = try await mutate(t, stranger.token, type, id: lid, fields)
            XCTAssertEqual(r.status, .notFound, type)
        }
        let own = UUID().uuidString
        _ = try await mutate(t, stranger.token, "label.create", id: own, ["name": "Mine"])
        var r = try await mutate(t, stranger.token, "task.label_add", id: tid, ["labelID": own])
        XCTAssertEqual(r.status, .notFound)
        r = try await mutate(t, stranger.token, "task.label_add", id: tid, ["labelID": lid])
        XCTAssertEqual(r.status, .notFound)
        // Labels never leak through the feed.
        let strangerLabels = try await labelEntries(t, stranger.token)
        XCTAssertEqual(strangerLabels.count, 1)
        let readerLabels = try await labelEntries(t, reader.token)
        XCTAssertEqual(readerLabels.count, 0)

        // A reader may label a task it can read (same rule as PUT /v1/tasks/{id}/labels/{labelID}); the link is
        // private to the reader and invisible to the owner.
        _ = try await t.json(.PUT, "/v1/projects/\(pid)/grants",
            ["principalType": "person", "principalID": reader.id, "role": "read"], token: owner.token)
        let rl = UUID().uuidString
        _ = try await mutate(t, reader.token, "label.create", id: rl, ["name": "R"])
        r = try await mutate(t, reader.token, "task.label_add", id: tid, ["labelID": rl])
        XCTAssertEqual(r.status, .ok)
        XCTAssertEqual(((r.body?["label"] as? [String: Any])?["taskIDs"] as? [Any])?.count, 1)
        let ownerLabels = try await labelEntries(t, owner.token)
        XCTAssertEqual(((ownerLabels.first?["label"] as? [String: Any])?["taskIDs"] as? [Any])?.count, 0)
        // Missing labelID: 400.
        r = try await mutate(t, owner.token, "task.label_add", id: tid, [:])
        XCTAssertEqual(r.status, .badRequest)
    }

    func testRetentionAndCursorSemanticsUnchangedByNewEntities() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let owner = try await account(t)
        let (_, tid) = try await setup(t, owner.token)
        let lid = UUID().uuidString
        _ = try await mutate(t, owner.token, "label.create", id: lid, ["name": "L"])
        _ = try await mutate(t, owner.token, "task.label_add", id: tid, ["labelID": lid])
        _ = try await mutate(t, owner.token, "label.delete", id: lid, [:])
        let cursor = try await head(t, owner.token)
        // Age the log and purge: tombstone purged, floor raised, old cursors expire, c0 still works.
        let old = Date().addingTimeInterval(-200 * 86_400)
        try await SyncChange.query(on: t.app.db).set(\.$createdAt, to: old).update()
        try await SyncMutation.query(on: t.app.db).set(\.$createdAt, to: old).update()
        var cleanup = ExpiredCleanup()
        cleanup.syncRetention = 90 * 86_400
        _ = try await cleanup.run(on: t.app.db)
        let expired = try await t.json(.GET, "/v1/sync/changes?cursor=c1", token: owner.token)
        XCTAssertEqual(expired.status, .gone)
        let full = try await feed(t, owner.token)
        XCTAssertTrue(full.contains { $0["entityType"] as? String == "task" })
        XCTAssertFalse(full.contains { $0["entityType"] as? String == "label" })
        _ = cursor
    }
}

private enum LabelCount {
    static func count(_ t: TestApp) async throws -> Int { try await DiscoveryLabel.query(on: t.app.db).count() }
}
