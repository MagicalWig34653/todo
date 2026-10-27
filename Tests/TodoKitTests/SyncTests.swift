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

    func testSyncMutationsEmitActivityEvents() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let owner = try await account(t)
        let pid = UUID().uuidString, tid = UUID().uuidString
        _ = try await mutate(t, owner.token, "project.create", id: pid, ["name": "Sync"])
        _ = try await mutate(t, owner.token, "task.create", id: tid, ["projectID": pid, "title": "A"])
        let r = try await mutate(t, owner.token, "task.update", id: tid, ["version": 1, "status": "done"])
        XCTAssertEqual(r.status, .ok)
        let activity = try await t.json(.GET, "/v1/tasks/\(tid)/activity", token: owner.token)
        let kinds = (activity.body?["items"] as? [[String: Any]] ?? []).compactMap { $0["kind"] as? String }
        XCTAssertTrue(kinds.contains("task.created"), "\(kinds)")
        XCTAssertTrue(kinds.contains("task.status_changed"), "\(kinds)")
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

    private func cursor(_ t: TestApp, _ token: String) async throws -> String {
        let feed = try await changes(t, token)
        return try XCTUnwrap(feed.body?["cursor"] as? String)
    }

    private func assertFeed(_ t: TestApp, _ token: String, after cursor: String,
        upserts: Set<String> = [], deletes: Set<String> = [], file: StaticString = #filePath, line: UInt = #line) async throws {
        let feed = try await changes(t, token, cursor)
        XCTAssertEqual(feed.status, .ok, file: file, line: line)
        for (kind, expected) in [("upsert", upserts), ("delete", deletes)] {
            let actual = entries(feed.body).filter { $0["kind"] as? String == kind }
                .compactMap { ($0["entityID"] as? String)?.lowercased() }
            XCTAssertEqual(Set(actual), Set(expected.map { $0.lowercased() }), file: file, line: line)
        }
    }

    func testGrantSubtreeRevocationRegrantAndPagingAcrossReplicas() async throws {
        let t = try await TestApp.make(), replica = try await t.replica()
        defer { Task { await t.shutdown(); await replica.shutdown() } }
        let owner = try await account(t), guest = try await account(t), stranger = try await account(t)
        let root = UUID().uuidString, child = UUID().uuidString, task = UUID().uuidString
        _ = try await mutate(t, owner.token, "project.create", id: root, ["name": "Root"])
        _ = try await mutate(t, owner.token, "project.create", id: child, ["name": "Child", "parentID": root])
        _ = try await mutate(t, owner.token, "task.create", id: task, ["title": "Old task", "projectID": child])
        let before = try await cursor(replica, guest.token)
        let grant = try await t.json(.PUT, "/v1/projects/\(root)/grants",
            ["principalType": "person", "principalID": guest.id, "role": "read"], token: owner.token)
        XCTAssertEqual(grant.status, .ok)
        let gid = try XCTUnwrap(grant.body?["id"] as? String)
        try await assertFeed(replica, guest.token, after: before, upserts: [root, child, task])
        let granted = try await cursor(replica, guest.token)
        let removal = try await t.json(.DELETE, "/v1/projects/\(root)/grants/\(gid)", token: owner.token)
        XCTAssertEqual(removal.status, .noContent)
        try await assertFeed(replica, guest.token, after: granted, deletes: [root, child, task])
        try await assertFeed(replica, owner.token, after: granted)
        try await assertFeed(replica, stranger.token, after: before)
        let revoked = try await cursor(replica, guest.token)
        let deleted = try await SyncRecorder.wasDeleted(UUID(uuidString: task)!, on: replica.app.db)
        XCTAssertFalse(deleted, "Revocation must not permanently reserve an entity ID")
        _ = try await t.json(.PUT, "/v1/projects/\(root)/grants",
            ["principalType": "person", "principalID": guest.id, "role": "read"], token: owner.token)
        try await assertFeed(replica, guest.token, after: revoked, upserts: [root, child, task])
        // Historical revocations cannot delete currently readable entities, even across page boundaries.
        var pageCursor = before
        var visible = Set<String>()
        for _ in 0..<30 {
            let page = try await replica.json(.GET, "/v1/sync/changes?cursor=\(pageCursor)&limit=1", token: guest.token)
            for row in entries(page.body) {
                XCTAssertEqual(row["kind"] as? String, "upsert")
                visible.insert(try XCTUnwrap(row["entityID"] as? String).lowercased())
            }
            pageCursor = try XCTUnwrap(page.body?["cursor"] as? String)
            if page.body?["hasMore"] as? Bool == false { break }
        }
        XCTAssertEqual(visible, Set([root, child, task].map { $0.lowercased() }))
    }

    func testTeamAcceptanceAndRemovalPreserveAlternativeAccess() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let owner = try await account(t), guest = try await account(t)
        let root = UUID().uuidString, child = UUID().uuidString, task = UUID().uuidString
        _ = try await mutate(t, owner.token, "project.create", id: root, ["name": "Root"])
        _ = try await mutate(t, owner.token, "project.create", id: child, ["name": "Child", "parentID": root])
        _ = try await mutate(t, owner.token, "task.create", id: task, ["title": "T", "projectID": child])
        let team = try await t.json(.POST, "/v1/teams", ["name": "Team"], token: owner.token)
        let teamID = try XCTUnwrap(team.body?["id"] as? String)
        _ = try await t.json(.PUT, "/v1/projects/\(root)/grants",
            ["principalType": "team", "principalID": teamID, "role": "read"], token: owner.token)
        let before = try await cursor(t, guest.token)
        _ = try await t.json(.PUT, "/v1/teams/\(teamID)/members", ["userID": guest.id, "isAdmin": false], token: owner.token)
        try await assertFeed(t, guest.token, after: before)
        let accepted = try await t.json(.POST, "/v1/teams/\(teamID)/accept", token: guest.token)
        XCTAssertEqual(accepted.status, .noContent)
        try await assertFeed(t, guest.token, after: before, upserts: [root, child, task])
        _ = try await t.json(.PUT, "/v1/projects/\(child)/grants",
            ["principalType": "person", "principalID": guest.id, "role": "read"], token: owner.token)
        let granted = try await cursor(t, guest.token)
        let removed = try await t.json(.DELETE, "/v1/teams/\(teamID)/members/\(guest.id)", token: owner.token)
        XCTAssertEqual(removed.status, .noContent)
        // Child stays visible, but its parent reference must now be redacted.
        try await assertFeed(t, guest.token, after: granted, upserts: [child], deletes: [root])
        let feed = try await changes(t, guest.token, granted)
        let dto = entries(feed.body).first { $0["kind"] as? String == "upsert" }?["project"] as? [String: Any]
        XCTAssertNil(dto?["parentID"] as? String)
    }

    func testTaskAndProjectMovesEmitVisibilityChanges() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let owner = try await account(t), sourceGuest = try await account(t), targetGuest = try await account(t)
        let source = UUID().uuidString, target = UUID().uuidString, child = UUID().uuidString, task = UUID().uuidString
        for id in [source, target] { _ = try await mutate(t, owner.token, "project.create", id: id, ["name": "Root"]) }
        _ = try await mutate(t, owner.token, "project.create", id: child, ["name": "Child", "parentID": source])
        _ = try await mutate(t, owner.token, "task.create", id: task, ["title": "T", "projectID": child])
        for (project, guest) in [(source, sourceGuest), (target, targetGuest)] {
            _ = try await t.json(.PUT, "/v1/projects/\(project)/grants",
                ["principalType": "person", "principalID": guest.id, "role": "read"], token: owner.token)
        }
        let before = try await cursor(t, owner.token)
        let moved = try await t.json(.PATCH, "/v1/tasks/\(task)", ["version": 1, "projectID": target], token: owner.token)
        XCTAssertEqual(moved.status, .ok)
        try await assertFeed(t, sourceGuest.token, after: before, deletes: [task])
        try await assertFeed(t, targetGuest.token, after: before, upserts: [task])
        try await assertFeed(t, owner.token, after: before, upserts: [task])
        let back = try await mutate(t, owner.token, "task.update", id: task, ["version": 2, "projectID": child])
        XCTAssertEqual(back.status, .ok)
        let beforeProjectMove = try await cursor(t, owner.token)
        let projectMove = try await mutate(t, owner.token, "project.update", id: child, ["version": 1, "parentID": target])
        XCTAssertEqual(projectMove.status, .ok)
        try await assertFeed(t, sourceGuest.token, after: beforeProjectMove, deletes: [child, task])
        try await assertFeed(t, targetGuest.token, after: beforeProjectMove, upserts: [child, task])
    }

    func testInheritanceOwnershipAndRollback() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let owner = try await account(t), guest = try await account(t)
        let root = UUID().uuidString, child = UUID().uuidString, task = UUID().uuidString
        _ = try await mutate(t, owner.token, "project.create", id: root, ["name": "Root"])
        _ = try await mutate(t, owner.token, "project.create", id: child, ["name": "Child", "parentID": root])
        _ = try await mutate(t, owner.token, "task.create", id: task, ["title": "T", "projectID": child])
        _ = try await t.json(.PUT, "/v1/projects/\(root)/grants",
            ["principalType": "person", "principalID": guest.id, "role": "read"], token: owner.token)
        let before = try await cursor(t, guest.token)
        let restricted = try await t.json(.PUT, "/v1/projects/\(child)/inheritance",
            ["version": 1, "inherits": false], token: owner.token)
        XCTAssertEqual(restricted.status, .ok)
        try await assertFeed(t, guest.token, after: before, deletes: [child, task])
        let restrictedCursor = try await cursor(t, guest.token)
        let transferred = try await t.json(.PUT, "/v1/projects/\(child)/owner",
            ["version": 2, "ownerType": "person", "ownerID": guest.id], token: owner.token)
        XCTAssertEqual(transferred.status, .ok)
        try await assertFeed(t, guest.token, after: restrictedCursor, upserts: [child, task])
        try await assertFeed(t, owner.token, after: restrictedCursor, deletes: [child, task])
        let head = try await cursor(t, guest.token)
        do {
            try await t.app.db.transaction { db in
                try await lockSharingGraph(on: db)
                let before = try await SyncRecorder.visibility(on: db)
                // Change ownership inside the transaction, then abort after recording its visibility effects.
                let storedPolicy = try await ProjectSharing.query(on: db).filter(\.$projectID == UUID(uuidString: child)!).first()
                let policy = try XCTUnwrap(storedPolicy)
                policy.ownerID = UUID(uuidString: owner.id)!
                try await policy.save(on: db)
                try await SyncRecorder.recordVisibilityChanges(from: before, on: db)
                throw Abort(.conflict)
            }
            XCTFail("Expected rollback")
        } catch let error as Abort { XCTAssertEqual(error.status, .conflict) }
        let afterRollback = try await cursor(t, guest.token)
        XCTAssertEqual(afterRollback, head)
        try await assertFeed(t, guest.token, after: head)
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
