import Fluent
import XCTVapor
@testable import TodoKit

/// Step 2 of the multi-repository plan: REST and MCP on top of several bindings per project.
final class MCPRepositoryBindingsTests: XCTestCase {
    private typealias Reply = (isError: Bool, json: [String: Any]?, array: [[String: Any]]?, text: String)

    private func call(_ f: OAuthFixture, _ name: String, _ args: [String: Any], access: String) async throws -> Reply {
        let r = try await f.rpc("tools/call", ["name": name, "arguments": args], access: access)
        let result = try XCTUnwrap(r.body?["result"] as? [String: Any])
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        let object = try? JSONSerialization.jsonObject(with: Data(text.utf8))
        return (result["isError"] as? Bool ?? false, object as? [String: Any], object as? [[String: Any]], text)
    }

    private func run(_ body: (OAuthFixture, String) async throws -> Void) async throws {
        let f = try await OAuthFixture.make()
        do {
            let t = try await f.tokens(scope: "projects:read projects:write tasks:read tasks:write")
            try await body(f, t.access)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testToolsAreRegisteredWithScopes() async throws {
        let f = try await OAuthFixture.make()
        do {
            let read = try await f.tokens(scope: "projects:read")
            let list = try await f.rpc("tools/list", access: read.access)
            let tools = ((list.body?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            XCTAssertTrue(tools.contains("list_repository_bindings"))
            XCTAssertFalse(tools.contains("unbind_repository"), "needs tasks:write")
            let denied = try await call(f, "unbind_repository", ["projectID": f.project.requireID().uuidString, "repository": "local/a"], access: read.access)
            XCTAssertTrue(denied.isError)
            let write = try await f.tokens(scope: "projects:read tasks:write")
            let all = try await f.rpc("tools/list", access: write.access)
            let names = ((all.body?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            XCTAssertTrue(names.contains("unbind_repository"))
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testMultipleBindingsThroughMCP() async throws {
        try await run { f, access in
            let pid = try f.project.requireID().uuidString
            let first = try await call(f, "bind_repository", ["projectID": pid, "repository": "github.com/acme/one"], access: access)
            XCTAssertFalse(first.isError, first.text)
            let second = try await call(f, "bind_repository", ["projectID": pid, "repository": "github.com/acme/two", "staleAfterDays": 9], access: access)
            XCTAssertEqual(second.json?["repository"] as? String, "github.com/acme/two")
            let rec = try await call(f, "record_sync", ["projectID": pid, "summary": "x"], access: access)
            XCTAssertEqual(rec.text, "repository_required")
            let ok = try await call(f, "record_sync", ["projectID": pid, "summary": "one done", "repository": "GitHub.com/Acme/One"], access: access)
            XCTAssertFalse(ok.isError, ok.text)

            let status = try await call(f, "get_sync_status", ["projectID": pid], access: access)
            XCTAssertEqual(status.json?["repository"] as? String, "github.com/acme/two", "never beats fresh")
            XCTAssertEqual((status.json?["bindings"] as? [[String: Any]])?.count, 2)
            let one = try await call(f, "get_sync_status", ["projectID": pid, "repository": "github.com/acme/one"], access: access)
            XCTAssertEqual(one.json?["state"] as? String, "fresh"); XCTAssertEqual(one.json?["lastSummary"] as? String, "one done")
            let missing = try await call(f, "get_sync_status", ["projectID": pid, "repository": "github.com/acme/nope"], access: access)
            XCTAssertEqual(missing.text, "not_bound")

            let list = try await call(f, "list_repository_bindings", ["projectID": pid], access: access)
            XCTAssertEqual(list.array?.compactMap { $0["repository"] as? String }, ["github.com/acme/one", "github.com/acme/two"])

            let stale = try await call(f, "get_stale_projects", [:], access: access)
            let entry = try XCTUnwrap(stale.array?.first)
            let staleBindings = try XCTUnwrap(entry["staleBindings"] as? [[String: Any]])
            XCTAssertEqual(staleBindings.compactMap { $0["repository"] as? String }, ["github.com/acme/two"])

            let ambiguous = try await call(f, "bind_repository", ["projectID": pid, "staleAfterDays": 5], access: access)
            XCTAssertEqual(ambiguous.text, "repository_required")

            let removed = try await call(f, "unbind_repository", ["projectID": pid, "repository": "github.com/acme/two"], access: access)
            XCTAssertFalse(removed.isError, removed.text)
            XCTAssertEqual(((removed.json?["sync"] as? [String: Any])?["bindings"] as? [[String: Any]])?.count, 1)
            XCTAssertNotNil(removed.json?["effect"])
            let again = try await call(f, "unbind_repository", ["projectID": pid, "repository": "github.com/acme/two"], access: access)
            XCTAssertEqual(again.text, "not_bound")
            // The remaining binding kept its history.
            let kept = try await call(f, "get_sync_status", ["projectID": pid], access: access)
            XCTAssertEqual(kept.json?["lastSummary"] as? String, "one done")
        }
    }

    func testTooManyBindingsAndAlreadyBoundMapToCodes() async throws {
        try await run { f, access in
            let pid = try f.project.requireID().uuidString
            for i in 0..<ProjectSyncService.maxBindings {
                let r = try await call(f, "bind_repository", ["projectID": pid, "repository": "local/repo-\(i)"], access: access)
                XCTAssertFalse(r.isError, r.text)
            }
            let over = try await call(f, "bind_repository", ["projectID": pid, "repository": "local/one-too-many"], access: access)
            XCTAssertEqual(over.text, "too_many_bindings")
            let other = try f.other.requireID().uuidString
            let taken = try await call(f, "bind_repository", ["projectID": other, "repository": "local/repo-3"], access: access)
            XCTAssertEqual(taken.text, "not_found", "other project is outside the grant")
        }
    }

    func testForeignProjectIsNotFoundForNewToolsAndParams() async throws {
        try await run { f, access in
            let other = try f.other.requireID().uuidString
            for (name, args) in [("list_repository_bindings", ["projectID": other]),
                                 ("unbind_repository", ["projectID": other, "repository": "local/x"]),
                                 ("get_sync_status", ["projectID": other, "repository": "local/x"]),
                                 ("record_sync", ["projectID": other, "summary": "x", "repository": "local/x"])] as [(String, [String: Any])] {
                let r = try await call(f, name, args, access: access)
                XCTAssertEqual(r.text, "not_found", name)
            }
        }
    }

    func testReadRoleCanListButNotUnbind() async throws {
        try await run { f, access in
            let db = f.test.app.db
            let pid = try f.project.requireID()
            _ = try await call(f, "bind_repository", ["projectID": pid.uuidString, "repository": "local/a"], access: access)
            let owner = User(displayName: "Owner", isAdmin: false); try await owner.save(on: db)
            let policy = try await ProjectSharing.query(on: db).filter(\.$projectID == pid).first() ?? ProjectSharing(project: f.project)
            policy.ownerID = try owner.requireID(); try await policy.save(on: db)
            try await ProjectGrant(projectID: pid, principalType: "person", principalID: f.user.requireID(), role: .read).save(on: db)
            let list = try await call(f, "list_repository_bindings", ["projectID": pid.uuidString], access: access)
            XCTAssertFalse(list.isError, list.text)
            let unbind = try await call(f, "unbind_repository", ["projectID": pid.uuidString, "repository": "local/a"], access: access)
            XCTAssertTrue(unbind.isError); XCTAssertEqual(unbind.text.lowercased(), "forbidden")
            let bind = try await call(f, "bind_repository", ["projectID": pid.uuidString, "repository": "local/b"], access: access)
            XCTAssertTrue(bind.isError)
            let count = try await ProjectRepositoryBinding.query(on: db).filter(\.$projectID == pid).count()
            XCTAssertEqual(count, 1)
            // REST agrees.
            let rest = try await f.test.json(.DELETE, "/v1/projects/\(pid)/bindings?repository=local/a", token: f.session)
            XCTAssertEqual(rest.status, .forbidden)
        }
    }

    func testRESTBindingsListSyncCompatibilityAndDelete() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let user = User(displayName: "R", isAdmin: false); try await user.save(on: t.app.db)
        let token = AuthSupport.randomToken()
        try await UserSession(userID: user.requireID(), tokenHash: AuthSupport.hash(token), expiresAt: Date().addingTimeInterval(3600)).save(on: t.app.db)
        let created = try await t.json(.POST, "/v1/projects", ["name": "P"], token: token)
        let pid = try XCTUnwrap(created.body?["id"] as? String)
        let outsider = User(displayName: "O", isAdmin: false); try await outsider.save(on: t.app.db)
        let otherToken = AuthSupport.randomToken()
        try await UserSession(userID: outsider.requireID(), tokenHash: AuthSupport.hash(otherToken), expiresAt: Date().addingTimeInterval(3600)).save(on: t.app.db)

        let empty = try await t.json(.GET, "/v1/projects/\(pid)/sync", token: token)
        XCTAssertEqual(empty.body?["bound"] as? Bool, false)
        XCTAssertEqual((empty.body?["bindings"] as? [Any])?.count, 0)

        let one = try await t.json(.PUT, "/v1/projects/\(pid)/sync", ["repository": "github.com/acme/one"], token: token)
        XCTAssertEqual(one.status, .ok, "\(one.body ?? [:])")
        let two = try await t.json(.PUT, "/v1/projects/\(pid)/sync", ["repository": "github.com/acme/two"], token: token)
        XCTAssertEqual(two.body?["repository"] as? String, "github.com/acme/two")

        let flat = try await t.json(.GET, "/v1/projects/\(pid)/sync", token: token)
        XCTAssertEqual(flat.body?["bound"] as? Bool, true)
        XCTAssertEqual((flat.body?["bindings"] as? [[String: Any]])?.count, 2)
        let selected = try await t.json(.GET, "/v1/projects/\(pid)/sync?repository=github.com/acme/one", token: token)
        XCTAssertEqual(selected.body?["repository"] as? String, "github.com/acme/one")
        let unknown = try await t.json(.GET, "/v1/projects/\(pid)/sync?repository=github.com/acme/nope", token: token)
        XCTAssertEqual(unknown.status, .conflict)

        let list = try await t.json(.GET, "/v1/projects/\(pid)/bindings", token: token)
        XCTAssertEqual(list.status, .ok)
        XCTAssertEqual(list.list?.compactMap { $0["repository"] as? String }, ["github.com/acme/one", "github.com/acme/two"])

        // Invisible project: 404 for every route; missing parameter: 400.
        for (method, path) in [(HTTPMethod.GET, "bindings"), (.GET, "sync"), (.DELETE, "bindings?repository=github.com/acme/one")] {
            let r = try await t.json(method, "/v1/projects/\(pid)/\(path)", token: otherToken)
            XCTAssertEqual(r.status, .notFound, path)
        }
        let noParam = try await t.json(.DELETE, "/v1/projects/\(pid)/bindings", token: token)
        XCTAssertEqual(noParam.status, .badRequest)

        let del = try await t.json(.DELETE, "/v1/projects/\(pid)/bindings?repository=github.com/acme/one", token: token)
        XCTAssertEqual(del.status, .ok, "\(del.body ?? [:])")
        XCTAssertEqual(del.body?["repository"] as? String, "github.com/acme/two")
        let gone = try await t.json(.DELETE, "/v1/projects/\(pid)/bindings?repository=github.com/acme/one", token: token)
        XCTAssertEqual(gone.status, .conflict)
    }
}
