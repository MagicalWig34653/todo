import Fluent
import XCTVapor
@testable import TodoKit

private struct CollaborationResponse: Sendable {
    let status: HTTPStatus
    let data: Data
    var object: [String: Any] { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }
}
private struct CollaborationFixture {
    let test: TestApp
    let userID: UUID
    let token: String
    let taskID: UUID
    var path: String { "/v1/tasks/\(taskID)" }
}

final class CollaborationTests: XCTestCase, @unchecked Sendable {
    private func fixture() async throws -> CollaborationFixture {
        let test = try await TestApp.make()
        let user = User(displayName: "Collaborator", isAdmin: false)
        try await user.save(on: test.app.db)
        let userID = try user.requireID()
        let token = UUID().uuidString
        try await UserSession(userID: userID, tokenHash: AuthSupport.hash(token), expiresAt: Date().addingTimeInterval(3600)).save(on: test.app.db)
        let project = Project(ownerID: userID, parentID: nil, name: "Collaboration")
        try await project.save(on: test.app.db)
        let task = TodoTask(ownerID: userID, projectID: try project.requireID(), title: "Review")
        try await task.save(on: test.app.db)
        return CollaborationFixture(test: test, userID: userID, token: token, taskID: try task.requireID())
    }
    private func request(_ test: TestApp, _ method: HTTPMethod, _ path: String, token: String? = nil,
                         body: Data? = nil, key: String? = nil) async throws -> CollaborationResponse {
        var result = CollaborationResponse(status: .internalServerError, data: Data())
        try await test.app.test(method, path, beforeRequest: { req in
            if let token { req.headers.bearerAuthorization = .init(token: token) }
            if let key { req.headers.add(name: "Idempotency-Key", value: key) }
            if let body { req.headers.contentType = .json; req.body = ByteBuffer(data: body) }
        }, afterResponse: { res async in result = .init(status: res.status, data: Data(res.body.readableBytesView)) })
        return result
    }
    private func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

    func testCommentsVersioningIdempotencyAndHistory() async throws {
        let f = try await fixture()
        defer { Task { await f.test.shutdown() } }
        let data = try json(["body": "First comment"])
        let created = try await request(f.test, .POST, f.path + "/comments", token: f.token, body: data, key: "retry-1")
        XCTAssertEqual(created.status, .created)
        let id = try XCTUnwrap(created.object["id"] as? String)
        let path = f.path + "/comments/" + id
        let read = try await request(f.test, .GET, path, token: f.token)
        XCTAssertEqual(read.object["body"] as? String, "First comment")
        let updated = try await request(f.test, .PATCH, path, token: f.token, body: json(["body": "Edited", "version": 1]))
        XCTAssertEqual(updated.status, .ok)
        XCTAssertEqual(updated.object["version"] as? Int, 2)
        let stale = try await request(f.test, .PATCH, path, token: f.token, body: json(["body": "Lost", "version": 1]))
        XCTAssertEqual(stale.status, .conflict)
        let staleDelete = try await request(f.test, .DELETE, path, token: f.token, body: json(["version": 1]))
        XCTAssertEqual(staleDelete.status, .conflict)
        let deleted = try await request(f.test, .DELETE, path, token: f.token, body: json(["version": 2]))
        XCTAssertEqual(deleted.status, .noContent)
        let retry = try await request(f.test, .POST, f.path + "/comments", token: f.token, body: data, key: "retry-1")
        XCTAssertEqual(retry.status, .created)
        XCTAssertEqual(retry.object as NSDictionary, created.object as NSDictionary)
        let changed = try await request(f.test, .POST, f.path + "/comments", token: f.token, body: json(["body": "Other"]), key: "retry-1")
        XCTAssertEqual(changed.status, .conflict)
        let missing = try await request(f.test, .GET, path, token: f.token)
        XCTAssertEqual(missing.status, .notFound)
        let events = try await request(f.test, .GET, f.path + "/activity", token: f.token)
        let items = try XCTUnwrap(events.object["items"] as? [[String: Any]])
        XCTAssertEqual(items.compactMap { $0["kind"] as? String }, ["comment.created", "comment.updated", "comment.deleted"])
        XCTAssertTrue(items.allSatisfy { $0["actorType"] as? String == "Person" && $0["actorID"] as? String == f.userID.uuidString })
    }

    func testCriteriaCRUDAndExplicitToggleWithConflicts() async throws {
        let f = try await fixture()
        defer { Task { await f.test.shutdown() } }
        let created = try await request(f.test, .POST, f.path + "/acceptance-criteria", token: f.token, body: json(["text": "Tests pass"]))
        XCTAssertEqual(created.status, .created)
        XCTAssertEqual(created.object["completed"] as? Bool, false)
        let id = try XCTUnwrap(created.object["id"] as? String)
        let path = f.path + "/acceptance-criteria/" + id
        let toggle = try await request(f.test, .PATCH, path, token: f.token, body: json(["version": 1, "completed": true]))
        XCTAssertEqual(toggle.object["completed"] as? Bool, true)
        let stale = try await request(f.test, .PATCH, path, token: f.token, body: json(["version": 1, "completed": false]))
        XCTAssertEqual(stale.status, .conflict)
        let edited = try await request(f.test, .PATCH, path, token: f.token, body: json(["version": 2, "text": "MariaDB tests pass", "completed": false]))
        XCTAssertEqual(edited.object["version"] as? Int, 3)
        let read = try await request(f.test, .GET, path, token: f.token)
        XCTAssertEqual(read.object["text"] as? String, "MariaDB tests pass")
        let list = try await request(f.test, .GET, f.path + "/acceptance-criteria", token: f.token)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: list.data) as? [Any])?.count, 1)
        let deleted = try await request(f.test, .DELETE, path, token: f.token, body: json(["version": 3]))
        XCTAssertEqual(deleted.status, .noContent)
        let events = try await request(f.test, .GET, f.path + "/activity", token: f.token)
        XCTAssertEqual((events.object["items"] as? [Any])?.count, 4)
    }

    func testAccessAndNestedResourceBoundaries() async throws {
        let f = try await fixture()
        defer { Task { await f.test.shutdown() } }
        let other = User(displayName: "Other", isAdmin: false)
        try await other.save(on: f.test.app.db)
        let token = UUID().uuidString
        try await UserSession(userID: try other.requireID(), tokenHash: AuthSupport.hash(token), expiresAt: Date().addingTimeInterval(3600)).save(on: f.test.app.db)
        let comment = try await request(f.test, .POST, f.path + "/comments", token: f.token, body: json(["body": "Private"]))
        let criterion = try await request(f.test, .POST, f.path + "/acceptance-criteria", token: f.token, body: json(["text": "Private"]))
        let commentID = try XCTUnwrap(comment.object["id"] as? String)
        let criterionID = try XCTUnwrap(criterion.object["id"] as? String)
        for (method, suffix, body) in [
            (HTTPMethod.GET, "/comments", nil), (.GET, "/activity", nil), (.GET, "/acceptance-criteria", nil),
            (.POST, "/comments", try json(["body": "Forbidden"])),
            (.PATCH, "/comments/\(commentID)", try json(["body": "Forbidden", "version": 1])),
            (.DELETE, "/comments/\(commentID)", try json(["version": 1])),
            (.POST, "/acceptance-criteria", try json(["text": "Forbidden"])),
            (.PATCH, "/acceptance-criteria/\(criterionID)", try json(["completed": true, "version": 1])),
            (.DELETE, "/acceptance-criteria/\(criterionID)", try json(["version": 1])),
        ] {
            let response = try await request(f.test, method, f.path + suffix, token: token, body: body)
            XCTAssertEqual(response.status, .notFound, suffix)
        }
        let anonymous = try await request(f.test, .GET, f.path + "/comments")
        XCTAssertEqual(anonymous.status, .unauthorized)
        let loadedTask = try await TodoTask.find(f.taskID, on: f.test.app.db)
        let original = try XCTUnwrap(loadedTask)
        let sibling = TodoTask(ownerID: f.userID, projectID: original.projectID, title: "Sibling")
        try await sibling.save(on: f.test.app.db)
        for suffix in ["comments/\(commentID)", "acceptance-criteria/\(criterionID)"] {
            let response = try await request(f.test, .GET, "/v1/tasks/\(try sibling.requireID())/\(suffix)", token: f.token)
            XCTAssertEqual(response.status, .notFound)
        }
        do {
            try await recordActivity(taskID: f.taskID, authorizedUserID: other.requireID(), actorType: .run, actorID: UUID(), kind: "run.started", on: f.test.app.db)
            XCTFail("Foreign task must be rejected")
        } catch { XCTAssertEqual((error as? Abort)?.status, .notFound) }
    }

    func testStableCursorAndPublicRecorderRollback() async throws {
        let f = try await fixture()
        defer { Task { await f.test.shutdown() } }
        for type in [ActivityActorType.integration, .run, .person] {
            try await recordActivity(taskID: f.taskID, authorizedUserID: f.userID, actorType: type, actorID: UUID(), kind: "work.updated", on: f.test.app.db)
        }
        // Equal timestamps must not cause pagination to omit or repeat events.
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        try await ActivityEvent.query(on: f.test.app.db).filter(\.$taskID == f.taskID).set(\.$createdAt, to: timestamp).update()
        let first = try await request(f.test, .GET, f.path + "/activity?limit=2", token: f.token)
        let cursor = try XCTUnwrap(first.object["nextCursor"] as? String)
        try await recordActivity(taskID: f.taskID, authorizedUserID: f.userID, actorType: .run, actorID: UUID(), kind: "work.finished", on: f.test.app.db)
        let next = try await request(f.test, .GET, f.path + "/activity?limit=2&cursor=\(cursor)", token: f.token)
        XCTAssertEqual((next.object["items"] as? [[String: Any]])?.compactMap { $0["sequence"] as? Int }, [3, 4])
        for query in ["cursor=broken", "cursor=\(UUID()):1", "limit=0", "limit=101", "limit=abc"] {
            let response = try await request(f.test, .GET, f.path + "/activity?\(query)", token: f.token)
            XCTAssertEqual(response.status, .badRequest)
        }
        do {
            try await f.test.app.db.transaction { db in
                try await recordActivity(taskID: f.taskID, authorizedUserID: f.userID, actorType: .run, actorID: UUID(), kind: "rolled.back", on: db)
                throw Abort(.conflict)
            }
        } catch { XCTAssertEqual((error as? Abort)?.status, .conflict) }
        let count = try await ActivityEvent.query(on: f.test.app.db).filter(\.$taskID == f.taskID).count()
        XCTAssertEqual(count, 4)
    }

    func testValidationDoesNotProduceActivity() async throws {
        let f = try await fixture()
        defer { Task { await f.test.shutdown() } }
        for body in [" ", String(repeating: "x", count: 10_001)] {
            let response = try await request(f.test, .POST, f.path + "/comments", token: f.token, body: json(["body": body]))
            XCTAssertEqual(response.status, .badRequest)
        }
        let key = try await request(f.test, .POST, f.path + "/comments", token: f.token, body: json(["body": "Valid"]), key: "")
        XCTAssertEqual(key.status, .badRequest)
        let count = try await ActivityEvent.query(on: f.test.app.db).filter(\.$taskID == f.taskID).count()
        XCTAssertEqual(count, 0)
    }

    func testMariaDBConcurrentIdempotencyAndVersionConflictsAcrossReplicas() async throws {
        try XCTSkipUnless(TestApp.useMariaDB, "needs MariaDB (TODO_TEST_MARIADB=1)")
        let f = try await fixture()
        let replica = try await f.test.replica()
        defer { Task { await f.test.shutdown(); await replica.shutdown() } }
        let body = try json(["body": "Exactly one comment"])
        let responses = try await withThrowingTaskGroup(of: CollaborationResponse.self) { group in
            for i in 0..<8 {
                let app = i % 2 == 0 ? f.test : replica
                group.addTask { try await self.request(app, .POST, f.path + "/comments", token: f.token, body: body, key: "concurrent") }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(responses.filter { $0.status == .created }.count, 8)
        let ids = responses.compactMap { $0.object["id"] as? String }
        XCTAssertEqual(Set(ids).count, 1)
        let id = try XCTUnwrap(ids.first)
        let edit = try json(["version": 1, "body": "One winner"])
        let updates = try await withThrowingTaskGroup(of: HTTPStatus.self) { group in
            for i in 0..<8 {
                let app = i % 2 == 0 ? f.test : replica
                group.addTask { try await self.request(app, .PATCH, f.path + "/comments/\(id)", token: f.token, body: edit).status }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(updates.filter { $0 == .ok }.count, 1)
        XCTAssertEqual(updates.filter { $0 == .conflict }.count, 7)
        let count = try await TaskComment.query(on: f.test.app.db).filter(\.$taskID == f.taskID).count()
        let events = try await ActivityEvent.query(on: f.test.app.db).filter(\.$taskID == f.taskID).sort(\.$sequence).all()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(events.map(\.sequence), [1, 2])
        let criterion = try await request(f.test, .POST, f.path + "/acceptance-criteria", token: f.token, body: json(["text": "Concurrent review"]))
        let criterionID = try XCTUnwrap(criterion.object["id"] as? String)
        let toggle = try json(["version": 1, "completed": true])
        let toggles = try await withThrowingTaskGroup(of: HTTPStatus.self) { group in
            for i in 0..<8 {
                let app = i % 2 == 0 ? f.test : replica
                group.addTask { try await self.request(app, .PATCH, f.path + "/acceptance-criteria/\(criterionID)", token: f.token, body: toggle).status }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(toggles.filter { $0 == .ok }.count, 1)
        XCTAssertEqual(toggles.filter { $0 == .conflict }.count, 7)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<8 {
                let app = i % 2 == 0 ? f.test : replica
                group.addTask {
                    try await recordActivity(taskID: f.taskID, authorizedUserID: f.userID, actorType: .run,
                                             actorID: UUID(), kind: "run.progress", on: app.app.db)
                }
            }
            try await group.waitForAll()
        }
        let allEvents = try await ActivityEvent.query(on: f.test.app.db).filter(\.$taskID == f.taskID).sort(\.$sequence).all()
        XCTAssertEqual(allEvents.map(\.sequence), Array(1...12))
        // The database constraint also rejects duplicates outside the route's locking discipline.
        let loadedRecord = try await CommentIdempotency.query(on: f.test.app.db).filter(\.$taskID == f.taskID).first()
        let existing = try XCTUnwrap(loadedRecord)
        let duplicate = CommentIdempotency()
        duplicate.taskID = existing.taskID; duplicate.userID = existing.userID; duplicate.keyHash = existing.keyHash
        duplicate.requestBody = existing.requestBody; duplicate.commentID = existing.commentID
        do { try await duplicate.save(on: f.test.app.db); XCTFail("Unique constraint must reject duplicates") } catch {}
    }
}
