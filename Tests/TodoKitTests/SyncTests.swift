import Fluent
import XCTVapor
@testable import TodoKit

final class SyncTests: XCTestCase {
    private func account(_ t: TestApp) async throws -> (id: String, token: String) {
        let user = User(displayName: "Test", isAdmin: false)
        try await user.save(on: t.app.db)
        let token = AuthSupport.randomToken()
        try await UserSession(userID: user.requireID(), tokenHash: AuthSupport.hash(token),
            expiresAt: Date().addingTimeInterval(3600)).save(on: t.app.db)
        return (try user.requireID().uuidString, token)
    }

    private func mutate(_ t: TestApp, _ token: String, _ type: String, id: String, mutationID: String = UUID().uuidString,
        _ fields: [String: Any] = [:]) async throws -> (status: HTTPStatus, body: [String: Any]?) {
        var body: [String: Any] = ["mutationID": mutationID, "type": type, "id": id]
        body.merge(fields) { $1 }
        let r = try await t.json(.POST, "/v1/sync/mutations", body, token: token)
        return (r.status, r.body)
    }

    private func changes(_ t: TestApp, _ token: String, _ cursor: String = "c0") async throws -> (status: HTTPStatus, body: [String: Any]?) {
        let r = try await t.json(.GET, "/v1/sync/changes?cursor=\(cursor)", token: token)
        return (r.status, r.body)
    }

    private func entries(_ body: [String: Any]?) -> [[String: Any]] { body?["changes"] as? [[String: Any]] ?? [] }

    func testFeedMutationsAndTombstonesRoundTrip() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let owner = try await account(t)
        let pid = UUID().uuidString, tid = UUID().uuidString

        var r = try await mutate(t, owner.token, "project.create", id: pid, ["name": "Sync"])
        XCTAssertEqual(r.status, .created)
        r = try await mutate(t, owner.token, "task.create", id: tid, ["projectID": pid, "title": "A"])
        XCTAssertEqual(r.status, .created)
        XCTAssertEqual((r.body?["task"] as? [String: Any])?["id"] as? String, tid)

        var feed = try await changes(t, owner.token)
        XCTAssertEqual(feed.status, .ok)
        XCTAssertEqual(entries(feed.body).map { $0["entityType"] as? String }, ["project", "task"])
        let cursor = try XCTUnwrap(feed.body?["cursor"] as? String)

        // REST edits appear in the feed too (middleware, no bypass); only changes after the cursor are returned.
        let patch = try await t.json(.PATCH, "/v1/tasks/\(tid)", ["version": 1, "title": "B"], token: owner.token)
        XCTAssertEqual(patch.status, .ok)
        feed = try await changes(t, owner.token, cursor)
        XCTAssertEqual(entries(feed.body).count, 1)
        XCTAssertEqual((entries(feed.body)[0]["task"] as? [String: Any])?["title"] as? String, "B")

        // Stale version: 409.
        r = try await mutate(t, owner.token, "task.update", id: tid, ["version": 1, "title": "C"])
        XCTAssertEqual(r.status, .conflict)
        r = try await mutate(t, owner.token, "task.update", id: tid, ["version": 2, "title": "C"])
        XCTAssertEqual(r.status, .ok)

        // Deleting the project tombstones the project and its task.
        let before = try XCTUnwrap(feed.body?["cursor"] as? String)
        let del = try await t.json(.DELETE, "/v1/projects/\(pid)", token: owner.token)
        XCTAssertEqual(del.status, .noContent)
        feed = try await changes(t, owner.token, before)
        let deletes = entries(feed.body).filter { $0["kind"] as? String == "delete" }
        XCTAssertEqual(Set(deletes.compactMap { ($0["entityID"] as? String)?.lowercased() }), [pid.lowercased(), tid.lowercased()])
        // A tombstoned ID cannot be recreated.
        r = try await mutate(t, owner.token, "project.create", id: pid, ["name": "Again"])
        XCTAssertEqual(r.status, .conflict)
        // A full resync from 0 contains no live upserts of the deleted entities.
        feed = try await changes(t, owner.token)
        XCTAssertTrue(entries(feed.body).filter { $0["kind"] as? String == "upsert" }.isEmpty)
    }

    func testMutationIsIdempotentAndRejectsReusedIDWithOtherPayload() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let owner = try await account(t)
        let pid = UUID().uuidString, mid = UUID().uuidString
        let first = try await mutate(t, owner.token, "project.create", id: pid, mutationID: mid, ["name": "Once"])
        let second = try await mutate(t, owner.token, "project.create", id: pid, mutationID: mid, ["name": "Once"])
        XCTAssertEqual(first.status, .created)
        XCTAssertEqual(second.status, .created)
        XCTAssertEqual(second.body?["cursor"] as? String, first.body?["cursor"] as? String)
        let other = try await mutate(t, owner.token, "project.create", id: pid, mutationID: mid, ["name": "Different"])
        XCTAssertEqual(other.status, .conflict)
        let projects = try await t.json(.GET, "/v1/projects", token: owner.token)
        XCTAssertEqual(projects.list?.count, 1)
        // The same mutation ID of another account is independent.
        let second2 = try await account(t)
        let foreign = try await mutate(t, second2.token, "project.create", id: UUID().uuidString, mutationID: mid, ["name": "Mine"])
        XCTAssertEqual(foreign.status, .created)
    }

    func testPermissionsMatchRESTAndFeedIsScoped() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let owner = try await account(t), guest = try await account(t), stranger = try await account(t)
        let pid = UUID().uuidString, tid = UUID().uuidString
        _ = try await mutate(t, owner.token, "project.create", id: pid, ["name": "Private"])
        _ = try await mutate(t, owner.token, "task.create", id: tid, ["projectID": pid, "title": "T"])

        // Stranger: nothing visible, cannot touch it (404, never 403 or 200).
        let v1 = try await changes(t, stranger.token).body
        XCTAssertTrue(entries(v1).isEmpty)
        var r = try await mutate(t, stranger.token, "task.update", id: tid, ["version": 1, "title": "x"])
        XCTAssertEqual(r.status, .notFound)
        r = try await mutate(t, stranger.token, "project.delete", id: pid)
        XCTAssertEqual(r.status, .notFound)
        r = try await mutate(t, stranger.token, "task.create", id: UUID().uuidString, ["projectID": pid, "title": "x"])
        XCTAssertEqual(r.status, .notFound)

        // Read-only guest sees the data but cannot write; owner-only delete is 403 at most.
        let grant = try await t.json(.PUT, "/v1/projects/\(pid)/grants",
            ["principalType": "person", "principalID": guest.id, "role": "read"], token: owner.token)
        XCTAssertEqual(grant.status, .ok)
        let v2 = try await changes(t, guest.token).body
        XCTAssertEqual(entries(v2).count, 2)
        r = try await mutate(t, guest.token, "task.update", id: tid, ["version": 1, "title": "x"])
        XCTAssertEqual(r.status, .forbidden)
        r = try await mutate(t, guest.token, "task.delete", id: tid)
        XCTAssertEqual(r.status, .forbidden)

        // Tombstones are delivered only to those who could read the object when it was deleted.
        let guestFeed = try await changes(t, guest.token)
        let cursor = try XCTUnwrap(guestFeed.body?["cursor"] as? String)
        let v3 = try await t.json(.DELETE, "/v1/projects/\(pid)", token: owner.token).status
        XCTAssertEqual(v3, .noContent)
        let v4 = try await changes(t, guest.token, cursor).body
        XCTAssertEqual(entries(v4).filter { $0["kind"] as? String == "delete" }.count, 2)
        let v5 = try await changes(t, stranger.token).body
        XCTAssertTrue(entries(v5).isEmpty)
    }

    func testInvalidInputAndCursors() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let owner = try await account(t)
        let anon = try await t.json(.GET, "/v1/sync/changes")
        XCTAssertEqual(anon.status, .unauthorized)
        let v6 = try await changes(t, owner.token, "garbage").status
        XCTAssertEqual(v6, .badRequest)
        let v7 = try await changes(t, owner.token, "c999").status
        XCTAssertEqual(v7, .conflict)
        var r = try await mutate(t, owner.token, "nonsense", id: UUID().uuidString)
        XCTAssertEqual(r.status, .badRequest)
        r = try await mutate(t, owner.token, "project.update", id: UUID().uuidString, ["name": "x"])
        XCTAssertEqual(r.status, .badRequest)
        // Paging: limit 1 walks the log without losing entries.
        for _ in 0..<3 { _ = try await mutate(t, owner.token, "project.create", id: UUID().uuidString, ["name": "P"]) }
        var cursor = "c0", seen = 0, rounds = 0
        while rounds < 10 {
            rounds += 1
            let page = try await t.json(.GET, "/v1/sync/changes?cursor=\(cursor)&limit=1", token: owner.token)
            seen += entries(page.body).count
            cursor = try XCTUnwrap(page.body?["cursor"] as? String)
            if page.body?["hasMore"] as? Bool == false { break }
        }
        XCTAssertEqual(seen, 3)
    }

    func testConcurrentDuplicateDeliveriesAcrossReplicasApplyOnce() async throws {
        try XCTSkipUnless(TestApp.useMariaDB, "needs real row locking across connections")
        let a = try await TestApp.make()
        let b = try await a.replica()
        defer { Task { await a.shutdown(); await b.shutdown() } }
        let owner = try await account(a)
        let pid = UUID().uuidString, mid = UUID().uuidString
        let payload = try JSONSerialization.data(withJSONObject: [
            "mutationID": mid, "type": "project.create", "id": pid, "name": "Race",
        ])
        async let s1 = a.rawStatus(.POST, "/v1/sync/mutations", body: payload, token: owner.token)
        async let s2 = b.rawStatus(.POST, "/v1/sync/mutations", body: payload, token: owner.token)
        async let s3 = a.rawStatus(.POST, "/v1/sync/mutations", body: payload, token: owner.token)
        let statuses = try await [s1, s2, s3]
        XCTAssertEqual(statuses, [.created, .created, .created])
        let v8 = try await Project.query(on: a.app.db).count()
        XCTAssertEqual(v8, 1)
        let v9 = try await SyncChange.query(on: a.app.db).count()
        XCTAssertEqual(v9, 1)
        // Sequence numbers are gap-free under concurrent writers.
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<8 {
                let app = i.isMultiple(of: 2) ? a : b
                let body = (try? JSONSerialization.data(withJSONObject: [
                    "mutationID": UUID().uuidString, "type": "project.create", "id": UUID().uuidString, "name": "P\(i)",
                ])) ?? Data()
                group.addTask { _ = try? await app.rawStatus(.POST, "/v1/sync/mutations", body: body, token: owner.token) }
            }
        }
        let seqs = try await SyncChange.query(on: a.app.db).sort(\.$seq).all().map(\.seq)
        XCTAssertEqual(seqs, Array(1...seqs.count))
        XCTAssertEqual(seqs.count, 9)
    }
}
