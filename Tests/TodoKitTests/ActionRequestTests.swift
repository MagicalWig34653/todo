import Fluent
import XCTVapor
@testable import TodoKit

/// ADR 0026: confirmation requests for large MCP actions.
final class ActionRequestTests: XCTestCase {
    private struct Called { let isError: Bool; let json: [String: Any]?; let text: String }

    private func call(_ f: OAuthFixture, _ name: String, _ args: [String: Any], access: String) async throws -> Called {
        let r = try await f.rpc("tools/call", ["name": name, "arguments": args], access: access)
        let result = try XCTUnwrap(r.body?["result"] as? [String: Any])
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        return Called(isError: result["isError"] as? Bool ?? false, json: (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any], text: text)
    }

    private func scopes() -> String { "projects:read projects:write tasks:read tasks:write" }

    private func requestID(_ c: Called) throws -> String {
        XCTAssertTrue(c.isError)
        XCTAssertEqual(c.json?["error"] as? String, "confirmation_required", c.text)
        return try XCTUnwrap(c.json?["actionRequestID"] as? String)
    }

    private func projectExists(_ f: OAuthFixture, _ p: Project) async throws -> Bool {
        try await Project.find(p.requireID(), on: f.test.app.db) != nil
    }

    func testCallCreatesRequestInsteadOfDeletingAndIsIdempotent() async throws {
        let f = try await OAuthFixture.make()
        do {
            let t = try await f.tokens(scope: scopes())
            let pid = try f.project.requireID().uuidString
            try await TodoTask(ownerID: f.user.requireID(), projectID: f.project.requireID(), title: "A", details: "").save(on: f.test.app.db)
            let first = try requestID(try await call(f, "delete_project", ["projectID": pid], access: t.access))
            let second = try requestID(try await call(f, "delete_project", ["projectID": pid], access: t.access))
            XCTAssertEqual(first, second)
            let v1 = try await projectExists(f, f.project)
            XCTAssertTrue(v1)
            let rows = try await ActionRequest.query(on: f.test.app.db).all()
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows[0].state, "pending")
            XCTAssertEqual(rows[0].impact.tasks, 1)
            XCTAssertTrue(rows[0].summary.contains("Allowed"), rows[0].summary)
            // The agent sees it as pending.
            let got = try await call(f, "get_action_request", ["id": first], access: t.access)
            XCTAssertFalse(got.isError)
            XCTAssertEqual(got.json?["state"] as? String, "pending")
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testConfirmDeletesAndSecondConfirmIsIdempotent() async throws {
        let f = try await OAuthFixture.make()
        do {
            let t = try await f.tokens(scope: scopes())
            let id = try requestID(try await call(f, "delete_project", ["projectID": try f.project.requireID().uuidString], access: t.access))
            let list = try await f.test.json(.GET, "/v1/action-requests?state=pending", token: f.session)
            XCTAssertEqual(list.status, .ok)
            XCTAssertEqual(list.list?.count, 1)
            let a = try await f.test.json(.POST, "/v1/action-requests/\(id)/confirm", token: f.session)
            XCTAssertEqual(a.status, .ok)
            XCTAssertEqual(a.body?["state"] as? String, "executed")
            XCTAssertEqual((a.body?["result"] as? [String: Any])?["code"] as? String, "deleted")
            let v2 = try await projectExists(f, f.project)
            XCTAssertFalse(v2)
            let b = try await f.test.json(.POST, "/v1/action-requests/\(id)/confirm", token: f.session)
            XCTAssertEqual(b.status, .ok)
            XCTAssertEqual(b.body?["state"] as? String, "executed")
            XCTAssertEqual(b.body?["executedAt"] as? String, a.body?["executedAt"] as? String)
            let got = try await call(f, "get_action_request", ["id": id], access: t.access)
            XCTAssertEqual(got.json?["state"] as? String, "executed")
            let rej = try await f.test.json(.POST, "/v1/action-requests/\(id)/reject", token: f.session)
            XCTAssertEqual(rej.status, .conflict)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testRejectKeepsProject() async throws {
        let f = try await OAuthFixture.make()
        do {
            let t = try await f.tokens(scope: scopes())
            let id = try requestID(try await call(f, "delete_project", ["projectID": try f.project.requireID().uuidString], access: t.access))
            let r = try await f.test.json(.POST, "/v1/action-requests/\(id)/reject", token: f.session)
            XCTAssertEqual(r.status, .ok)
            XCTAssertEqual(r.body?["state"] as? String, "rejected")
            let v3 = try await projectExists(f, f.project)
            XCTAssertTrue(v3)
            let c = try await f.test.json(.POST, "/v1/action-requests/\(id)/confirm", token: f.session)
            XCTAssertEqual(c.status, .conflict)
            let v4 = try await projectExists(f, f.project)
            XCTAssertTrue(v4)
            // A new identical call after the rejection opens a new request.
            let again = try requestID(try await call(f, "delete_project", ["projectID": try f.project.requireID().uuidString], access: t.access))
            XCTAssertNotEqual(again, id)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testStrangerSeesNothingAndCannotDecide() async throws {
        let f = try await OAuthFixture.make()
        do {
            let t = try await f.tokens(scope: scopes())
            let id = try requestID(try await call(f, "delete_project", ["projectID": try f.project.requireID().uuidString], access: t.access))
            let stranger = User(displayName: "Stranger", isAdmin: false); try await stranger.save(on: f.test.app.db)
            let token = AuthSupport.randomToken()
            try await UserSession(userID: stranger.requireID(), tokenHash: AuthSupport.hash(token), expiresAt: Date().addingTimeInterval(3600)).save(on: f.test.app.db)
            for path in ["/v1/action-requests/\(id)"] {
                let r = try await f.test.json(.GET, path, token: token)
                XCTAssertEqual(r.status, .notFound)
            }
            let v5 = try await f.test.json(.POST, "/v1/action-requests/\(id)/confirm", token: token).status
            XCTAssertEqual(v5, .notFound)
            let v6 = try await f.test.json(.POST, "/v1/action-requests/\(id)/reject", token: token).status
            XCTAssertEqual(v6, .notFound)
            let v7 = try await f.test.json(.GET, "/v1/action-requests", token: token).list?.count
            XCTAssertEqual(v7, 0)
            let v8 = try await projectExists(f, f.project)
            XCTAssertTrue(v8)
            // Another connection of the same account cannot read it through MCP either.
            let other = try await f.tokens(scope: scopes())
            _ = other
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testProjectOutsideGrantIsNotFound() async throws {
        let f = try await OAuthFixture.make()
        do {
            let t = try await f.tokens(scope: scopes())
            let r = try await call(f, "delete_project", ["projectID": try f.other.requireID().uuidString], access: t.access)
            XCTAssertTrue(r.isError); XCTAssertEqual(r.text, "not_found")
            let v9 = try await ActionRequest.query(on: f.test.app.db).count()
            XCTAssertEqual(v9, 0)
            let v10 = try await projectExists(f, f.other)
            XCTAssertTrue(v10)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testSubprojectOutsideGrantBlocksDeletion() async throws {
        let f = try await OAuthFixture.make()
        do {
            let t = try await f.tokens(scope: scopes())
            let child = Project(ownerID: try f.user.requireID(), parentID: try f.project.requireID(), name: "Child")
            try await child.save(on: f.test.app.db)
            let r = try await call(f, "delete_project", ["projectID": try f.project.requireID().uuidString], access: t.access)
            XCTAssertTrue(r.isError); XCTAssertEqual(r.text, "not_found")
            let v11 = try await ActionRequest.query(on: f.test.app.db).count()
            XCTAssertEqual(v11, 0)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testExpiredRequestCannotBeConfirmedAndCleanupMarksIt() async throws {
        let f = try await OAuthFixture.make()
        do {
            let t = try await f.tokens(scope: scopes())
            let id = try requestID(try await call(f, "delete_project", ["projectID": try f.project.requireID().uuidString], access: t.access))
            let rowOpt = try await ActionRequest.find(UUID(uuidString: id), on: f.test.app.db)
            let row = try XCTUnwrap(rowOpt)
            row.expiresAt = Date().addingTimeInterval(-60)
            try await row.save(on: f.test.app.db)
            let v12 = try await f.test.json(.GET, "/v1/action-requests?state=pending", token: f.session).list?.count
            XCTAssertEqual(v12, 0)
            let c = try await f.test.json(.POST, "/v1/action-requests/\(id)/confirm", token: f.session)
            XCTAssertEqual(c.status, .gone)
            let v13 = try await projectExists(f, f.project)
            XCTAssertTrue(v13)
            let got = try await f.test.json(.GET, "/v1/action-requests/\(id)", token: f.session)
            XCTAssertEqual(got.body?["state"] as? String, "expired")
            try await ExpiredCleanup().run(on: f.test.app.db)
            let v14 = try await ActionRequest.find(UUID(uuidString: id), on: f.test.app.db)?.state
            XCTAssertEqual(v14, "expired")
            // Old decided rows disappear.
            row.expiresAt = Date().addingTimeInterval(-40 * 86_400)
            try await row.save(on: f.test.app.db)
            try await ExpiredCleanup().run(on: f.test.app.db)
            let v15 = try await ActionRequest.find(UUID(uuidString: id), on: f.test.app.db)
            XCTAssertNil(v15)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testRightsAreCheckedAgainWhenExecuting() async throws {
        let f = try await OAuthFixture.make()
        do {
            let t = try await f.tokens(scope: scopes())
            let id = try requestID(try await call(f, "delete_project", ["projectID": try f.project.requireID().uuidString], access: t.access))
            // Ownership moves to somebody else in the meantime.
            let owner = User(displayName: "New owner", isAdmin: false); try await owner.save(on: f.test.app.db)
            let policy = try ProjectSharing(project: f.project)
            policy.ownerType = "person"; policy.ownerID = try owner.requireID()
            try await policy.save(on: f.test.app.db)
            let c = try await f.test.json(.POST, "/v1/action-requests/\(id)/confirm", token: f.session)
            XCTAssertEqual(c.status, .ok)
            XCTAssertEqual(c.body?["state"] as? String, "failed")
            XCTAssertEqual((c.body?["result"] as? [String: Any])?["ok"] as? Bool, false)
            let v16 = try await projectExists(f, f.project)
            XCTAssertTrue(v16)
            let got = try await call(f, "get_action_request", ["id": id], access: t.access)
            XCTAssertEqual(got.json?["state"] as? String, "failed")
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testRevokedConnectionFailsExecution() async throws {
        let f = try await OAuthFixture.make()
        do {
            let t = try await f.tokens(scope: scopes())
            let id = try requestID(try await call(f, "delete_project", ["projectID": try f.project.requireID().uuidString], access: t.access))
            for grant in try await OAuthGrant.query(on: f.test.app.db).all() { grant.revoked = true; try await grant.save(on: f.test.app.db) }
            let c = try await f.test.json(.POST, "/v1/action-requests/\(id)/confirm", token: f.session)
            XCTAssertEqual(c.body?["state"] as? String, "failed")
            XCTAssertEqual((c.body?["result"] as? [String: Any])?["code"] as? String, "connection_revoked")
            let v17 = try await projectExists(f, f.project)
            XCTAssertTrue(v17)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testDeleteTaskAndTransferOwner() async throws {
        let f = try await OAuthFixture.make()
        do {
            let t = try await f.tokens(scope: scopes())
            let task = TodoTask(ownerID: try f.user.requireID(), projectID: try f.project.requireID(), title: "Doomed", details: "")
            try await task.save(on: f.test.app.db)
            let id = try requestID(try await call(f, "delete_task", ["taskID": try task.requireID().uuidString], access: t.access))
            let v18 = try await TodoTask.find(task.requireID(), on: f.test.app.db)
            XCTAssertNotNil(v18)
            let done = try await f.test.json(.POST, "/v1/action-requests/\(id)/confirm", token: f.session)
            XCTAssertEqual(done.body?["state"] as? String, "executed")
            let v19 = try await TodoTask.find(task.requireID(), on: f.test.app.db)
            XCTAssertNil(v19)

            let target = User(displayName: "Heir", isAdmin: false); try await target.save(on: f.test.app.db)
            let tid = try requestID(try await call(f, "transfer_project_owner",
                ["projectID": try f.project.requireID().uuidString, "ownerType": "person", "ownerID": try target.requireID().uuidString, "version": f.project.version], access: t.access))
            let before = try await ProjectSharing.query(on: f.test.app.db).filter(\.$projectID == f.project.requireID()).first()
            XCTAssertNotEqual(before?.ownerID, try target.requireID())
            let moved = try await f.test.json(.POST, "/v1/action-requests/\(tid)/confirm", token: f.session)
            XCTAssertEqual(moved.body?["state"] as? String, "executed", "\(moved.body ?? [:])")
            let after = try await ProjectSharing.query(on: f.test.app.db).filter(\.$projectID == f.project.requireID()).first()
            XCTAssertEqual(after?.ownerID, try target.requireID())
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testScopeAndToolList() async throws {
        let f = try await OAuthFixture.make()
        do {
            let readOnly = try await f.tokens(scope: "projects:read tasks:read")
            let denied = try await call(f, "delete_project", ["projectID": try f.project.requireID().uuidString], access: readOnly.access)
            XCTAssertTrue(denied.isError); XCTAssertNotEqual(denied.json?["error"] as? String, "confirmation_required")
            let list = try await f.rpc("tools/list", access: readOnly.access)
            let names = ((list.body?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            XCTAssertFalse(names.contains("delete_project"))
            XCTAssertTrue(names.contains("get_action_request"))
            let v20 = try await ActionRequest.query(on: f.test.app.db).count()
            XCTAssertEqual(v20, 0)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testFeedAndSummaryShowPendingRequest() async throws {
        let f = try await OAuthFixture.make()
        do {
            let t = try await f.tokens(scope: scopes())
            let id = try requestID(try await call(f, "delete_project", ["projectID": try f.project.requireID().uuidString], access: t.access))
            let feed = try await f.test.json(.GET, "/v1/feed", token: f.session)
            let cards = try XCTUnwrap(feed.body?["confirmations"] as? [[String: Any]])
            XCTAssertEqual(cards.count, 1)
            XCTAssertEqual(cards[0]["id"] as? String, id)
            XCTAssertEqual((cards[0]["impact"] as? [String: Any])?["destructive"] as? Bool, true)
            let cc = try await f.test.json(.GET, "/v1/command-center", token: f.session)
            XCTAssertEqual((cc.body?["summary"] as? [String: Any])?["pendingConfirmations"] as? Int, 1, "\(cc.body ?? [:])")
            _ = try await f.test.json(.POST, "/v1/action-requests/\(id)/reject", token: f.session)
            let after = try await f.test.json(.GET, "/v1/feed", token: f.session)
            XCTAssertEqual((after.body?["confirmations"] as? [Any])?.count, 0)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testWaitForEventsReportsDecisionWithoutContent() async throws {
        let f = try await OAuthFixture.make()
        do {
            let t = try await f.tokens(scope: scopes())
            let id = try requestID(try await call(f, "delete_project", ["projectID": try f.project.requireID().uuidString], access: t.access))
            let first = try await call(f, "wait_for_events", [:], access: t.access)
            let token = try XCTUnwrap(first.json?["token"] as? String)
            _ = try await f.test.json(.POST, "/v1/action-requests/\(id)/reject", token: f.session)
            let woken = try await call(f, "wait_for_events", ["since": token, "timeoutSeconds": 2], access: t.access)
            XCTAssertEqual(woken.json?["changed"] as? Bool, true, woken.text)
            let hints = try XCTUnwrap(woken.json?["hints"] as? [[String: Any]])
            let hint = try XCTUnwrap(hints.first { $0["kind"] as? String == "action_request" })
            XCTAssertEqual(hint["actionRequestID"] as? String, id)
            XCTAssertNil(hint["summary"])
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }
}
