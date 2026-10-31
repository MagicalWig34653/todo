import Fluent
import XCTVapor
@testable import TodoKit

final class ProjectSyncTests: XCTestCase {
    static let scopes = "projects:read projects:write tasks:read tasks:write comments:write attachments:read agents:read"

    private func call(_ f: OAuthFixture, _ name: String, _ args: [String: Any], access: String) async throws -> (isError: Bool, json: Any?, text: String) {
        let r = try await f.rpc("tools/call", ["name": name, "arguments": args], access: access)
        let result = try XCTUnwrap(r.body?["result"] as? [String: Any])
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        return (result["isError"] as? Bool ?? false, try? JSONSerialization.jsonObject(with: Data(text.utf8)), text)
    }

    func testRepositoryKeyNormalisation() throws {
        XCTAssertEqual(try RepositoryKey.normalize("https://user:tok@GitHub.com/Foo/Bar.git"), "github.com/foo/bar")
        XCTAssertEqual(try RepositoryKey.normalize("git@github.com:Foo/Bar.git"), "github.com/foo/bar")
        XCTAssertEqual(try RepositoryKey.normalize("ssh://git@host.example:2222/a/b.git/"), "host.example/a/b")
        XCTAssertEqual(try RepositoryKey.normalize("local/My-Project"), "local/my-project")
        XCTAssertThrowsError(try RepositoryKey.normalize("a b"))
        XCTAssertThrowsError(try RepositoryKey.normalize(""))
    }

    func testPromptsListAndGet() async throws {
        let f = try await OAuthFixture.make()
        do {
            let t = try await f.tokens(scope: "tasks:read")
            let list = try await f.rpc("prompts/list", access: t.access)
            let names = ((list.body?["result"] as? [String: Any])?["prompts"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            XCTAssertEqual(Set(names), ["setup_project", "sync_project", "session_start"])
            let get = try await f.rpc("prompts/get", ["name": "setup_project", "arguments": ["name": "Demo"]], access: t.access)
            let message = ((get.body?["result"] as? [String: Any])?["messages"] as? [[String: Any]])?.first
            let text = (message?["content"] as? [String: Any])?["text"] as? String ?? ""
            XCTAssertTrue(text.contains("\"Demo\"") && text.contains("find_project_by_repository") && text.contains("import_plan") && text.contains("<!-- todolino:begin -->"))
            let bad = try await f.rpc("prompts/get", ["name": "nope"], access: t.access)
            XCTAssertNotNil(bad.body?["error"])
            let badArg = try await f.rpc("prompts/get", ["name": "session_start", "arguments": ["x": "y"]], access: t.access)
            XCTAssertNotNil(badArg.body?["error"])
            let init_ = try await f.rpc("initialize", ["protocolVersion": "2025-11-25"], access: t.access)
            XCTAssertNotNil(((init_.body?["result"] as? [String: Any])?["capabilities"] as? [String: Any])?["prompts"])
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testSetupFlowIdempotentImportAndFreshness() async throws {
        let f = try await OAuthFixture.make()
        do {
            let t = try await f.tokens(scope: Self.scopes)
            let missing = try await call(f, "find_project_by_repository", ["repository": "git@github.com:Acme/Demo.git"], access: t.access)
            XCTAssertEqual((missing.json as? [String: Any])?["found"] as? Bool, false)
            let created = try await call(f, "create_project", ["name": "Demo", "repository": "https://github.com/acme/demo"], access: t.access)
            XCTAssertFalse(created.isError, created.text)
            let pid = try XCTUnwrap(((created.json as? [String: Any])?["project"] as? [String: Any])?["id"] as? String)
            let dup = try await call(f, "create_project", ["name": "Demo2", "repository": "github.com/acme/demo.git"], access: t.access)
            XCTAssertTrue(dup.isError); XCTAssertEqual(dup.text, "repository_already_bound")
            let found = try await call(f, "find_project_by_repository", ["repository": "https://github.com/acme/demo.git"], access: t.access)
            XCTAssertEqual(((found.json as? [String: Any])?["matches"] as? [[String: Any]])?.first?["projectID"] as? String, pid)

            let plan: [String: Any] = ["projectID": pid, "applyWorkflowColumns": true, "items": [
                ["externalKey": "p/login", "title": "Login", "criteria": ["Passkey works"], "children": [
                    ["externalKey": "p/login/ui", "title": "Login UI"], ["externalKey": "p/login/api", "title": "Login API", "status": "done"]]],
                ["externalKey": "p/docs", "title": "Docs", "backlog": true, "blockedReason": "waits for design"]]]
            let first = try await call(f, "import_plan", plan, access: t.access)
            XCTAssertFalse(first.isError, first.text)
            let r1 = try XCTUnwrap(first.json as? [String: Any])
            XCTAssertEqual(r1["created"] as? Int, 4); XCTAssertEqual(r1["columnsCreated"] as? Bool, true)
            let second = try await call(f, "import_plan", plan, access: t.access)
            let r2 = try XCTUnwrap(second.json as? [String: Any])
            XCTAssertEqual(r2["created"] as? Int, 0); XCTAssertEqual(r2["unchanged"] as? Int, 4)
            var changed = plan
            var items = plan["items"] as! [[String: Any]]; items[1]["title"] = "Documentation"; changed["items"] = items
            let thirdCall = try await call(f, "import_plan", changed, access: t.access)
            let third = try XCTUnwrap(thirdCall.json as? [String: Any])
            XCTAssertEqual(third["updated"] as? Int, 1)
            let dryCall = try await call(f, "import_plan", ["projectID": pid, "dryRun": true, "items": [["externalKey": "new", "title": "New"]]], access: t.access)
            let dry = try XCTUnwrap(dryCall.json as? [String: Any])
            XCTAssertEqual(dry["created"] as? Int, 1)
            let keys = try await call(f, "list_plan_keys", ["projectID": pid], access: t.access)
            XCTAssertEqual((keys.json as? [[String: Any]])?.count, 4)
            let feature = try await XCTUnwrapAsync { try await TodoTask.query(on: f.test.app.db).filter(\.$title == "Login").first() }
            let wf = try await TaskWorkflow.find(feature.id, on: f.test.app.db)
            XCTAssertEqual(wf?.kind, "feature")

            // Freshness
            let never = try await call(f, "get_sync_status", ["projectID": pid], access: t.access)
            XCTAssertEqual((never.json as? [String: Any])?["state"] as? String, "never")
            let recorded = try await call(f, "record_sync", ["projectID": pid, "summary": "initial setup", "repoRef": "main@abc"], access: t.access)
            XCTAssertEqual((recorded.json as? [String: Any])?["state"] as? String, "fresh")
            func state() async throws -> (String?, Int?) {
                let cc = try await call(f, "get_command_center", ["projectID": pid], access: t.access)
                let o = try XCTUnwrap(cc.json as? [String: Any])
                let entry = (o["projects"] as? [[String: Any]])?.first { $0["projectID"] as? String == pid }
                return ((entry?["sync"] as? [String: Any])?["state"] as? String, (o["summary"] as? [String: Any])?["staleProjects"] as? Int)
            }
            var s = try await state(); XCTAssertEqual(s.0, "fresh"); XCTAssertEqual(s.1, 0)
            let binding = try await XCTUnwrapAsync { try await ProjectBinding.find(UUID(uuidString: pid), on: f.test.app.db) }
            binding.lastSyncedAt = Date().addingTimeInterval(-4 * 86_400); try await binding.save(on: f.test.app.db)
            s = try await state(); XCTAssertEqual(s.0, "stale"); XCTAssertEqual(s.1, 1)
            let stale = try await call(f, "get_stale_projects", [:], access: t.access)
            XCTAssertEqual((stale.json as? [[String: Any]])?.count, 1)
            let threshold = try await call(f, "bind_repository", ["projectID": pid, "staleAfterDays": 7], access: t.access)
            XCTAssertEqual((threshold.json as? [String: Any])?["state"] as? String, "fresh")
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testRightsScopesAndForeignProjects() async throws {
        let f = try await OAuthFixture.make()
        do {
            let readOnly = try await f.tokens(scope: "projects:read tasks:read")
            let names = try await f.rpc("tools/list", access: readOnly.access)
            let list = ((names.body?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            XCTAssertTrue(list.contains("get_sync_status")); XCTAssertFalse(list.contains("import_plan")); XCTAssertFalse(list.contains("create_project"))
            let denied = try await call(f, "create_project", ["name": "X"], access: readOnly.access)
            XCTAssertTrue(denied.isError)
            let full = try await f.tokens(scope: Self.scopes)
            // The granted project is f.project; f.other is outside the grant.
            let other = other(f)
            for (name, args) in [("get_sync_status", ["projectID": other]), ("bind_repository", ["projectID": other, "repository": "local/x"]),
                                 ("record_sync", ["projectID": other, "summary": "x"]), ("import_plan", ["projectID": other, "items": [["externalKey": "a", "title": "A"]]])] as [(String, [String: Any])] {
                let r = try await call(f, name, args, access: full.access)
                XCTAssertTrue(r.isError); XCTAssertEqual(r.text, "not_found", name)
            }
            let own = try f.project.requireID().uuidString
            let notBound = try await call(f, "record_sync", ["projectID": own, "summary": "x"], access: full.access)
            XCTAssertEqual(notBound.text, "not_bound")
            let tooDeep = try await call(f, "import_plan", ["projectID": own, "items": [["externalKey": "a", "title": "A", "children": [["externalKey": "b", "title": "B", "children": [["externalKey": "c", "title": "C"]]]]]]], access: full.access)
            XCTAssertEqual(tooDeep.text, "plan_too_deep")
            let dupKey = try await call(f, "import_plan", ["projectID": own, "items": [["externalKey": "a", "title": "A"], ["externalKey": "a", "title": "B"]]], access: full.access)
            XCTAssertEqual(dupKey.text, "duplicate_external_key")
            let ownID = try f.project.requireID()
            let nothing = try await TodoTask.query(on: f.test.app.db).filter(\.$projectID == ownID).count()
            XCTAssertEqual(nothing, 0)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }
    private func other(_ f: OAuthFixture) -> String { f.other.id!.uuidString }
}

private func XCTUnwrapAsync<T>(_ value: () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let v = try await value(); return try XCTUnwrap(v, file: file, line: line)
}
