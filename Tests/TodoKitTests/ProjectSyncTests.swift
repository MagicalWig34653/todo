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

    /// update_task with projectID must carry the plan key to the target project (no duplicate on the next import_plan).
    func testMovingTaskKeepsPlanKey() async throws {
        let f = try await OAuthFixture.make()
        do {
            let t = try await f.tokens(scope: Self.scopes)
            func projectID(_ name: String) async throws -> String {
                let r = try await call(f, "create_project", ["name": name], access: t.access)
                XCTAssertFalse(r.isError, r.text)
                return try XCTUnwrap(((r.json as? [String: Any])?["project"] as? [String: Any])?["id"] as? String)
            }
            let a = try await projectID("Source"), b = try await projectID("Target")
            let items: [[String: Any]] = [["externalKey": "p/one", "title": "One"], ["externalKey": "p/two", "title": "Two"]]
            let imported = try await call(f, "import_plan", ["projectID": a, "items": items], access: t.access)
            XCTAssertFalse(imported.isError, imported.text)
            func keys(_ project: String) async throws -> [String] {
                let r = try await call(f, "list_plan_keys", ["projectID": project], access: t.access)
                return ((r.json as? [[String: Any]]) ?? []).compactMap { $0["externalKey"] as? String }
            }
            let rows = try await XCTUnwrapAsync { try await TaskExternalKey.query(on: f.test.app.db).filter(\.$externalKey == "p/one").first() }
            let task = try await XCTUnwrapAsync { try await TodoTask.find(rows.taskID, on: f.test.app.db) }
            let moved = try await call(f, "update_task", ["id": rows.taskID.uuidString, "version": task.version, "projectID": b], access: t.access)
            XCTAssertFalse(moved.isError, moved.text)
            let sourceKeys = try await keys(a), targetKeys = try await keys(b)
            XCTAssertEqual(sourceKeys, ["p/two"]); XCTAssertEqual(targetKeys, ["p/one"])
            // Importing the same plan item into the target finds the moved task instead of duplicating it.
            let again = try await call(f, "import_plan", ["projectID": b, "items": [["externalKey": "p/one", "title": "One"]]], access: t.access)
            XCTAssertEqual((again.json as? [String: Any])?["created"] as? Int, 0, again.text)
            let titles = try await TodoTask.query(on: f.test.app.db).filter(\.$title == "One").count()
            XCTAssertEqual(titles, 1)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    // MARK: Plan key handling on project moves

    private func newProject(_ f: OAuthFixture, _ name: String, _ access: String) async throws -> String {
        let r = try await call(f, "create_project", ["name": name], access: access)
        XCTAssertFalse(r.isError, r.text)
        return try XCTUnwrap(((r.json as? [String: Any])?["project"] as? [String: Any])?["id"] as? String)
    }

    private func planKeys(_ f: OAuthFixture, _ project: String, _ access: String) async throws -> [String] {
        let r = try await call(f, "list_plan_keys", ["projectID": project], access: access)
        XCTAssertFalse(r.isError, r.text)
        return ((r.json as? [[String: Any]]) ?? []).compactMap { $0["externalKey"] as? String }.sorted()
    }

    private func taskID(_ f: OAuthFixture, key: String, project: String) async throws -> UUID {
        let pid = try XCTUnwrap(UUID(uuidString: project))
        let row = try await XCTUnwrapAsync { try await TaskExternalKey.query(on: f.test.app.db).filter(\.$projectID == pid).filter(\.$externalKey == key).first() }
        return row.taskID
    }

    private func moveTask(_ f: OAuthFixture, _ id: UUID, to project: String, _ access: String) async throws -> (isError: Bool, json: Any?, text: String) {
        let task = try await XCTUnwrapAsync { try await TodoTask.find(id, on: f.test.app.db) }
        return try await call(f, "update_task", ["id": id.uuidString, "version": task.version, "projectID": project], access: access)
    }

    func testMovingTaskWithTakenKeyInTargetLosesKeyWithoutDataLoss() async throws {
        let f = try await OAuthFixture.make()
        do {
            let t = try await f.tokens(scope: Self.scopes)
            let a = try await newProject(f, "Source", t.access), b = try await newProject(f, "Target", t.access)
            _ = try await call(f, "import_plan", ["projectID": a, "items": [["externalKey": "p/one", "title": "Moved"]]], access: t.access)
            _ = try await call(f, "import_plan", ["projectID": b, "items": [["externalKey": "p/one", "title": "Resident"]]], access: t.access)
            let movedID = try await taskID(f, key: "p/one", project: a)
            let residentID = try await taskID(f, key: "p/one", project: b)
            let r = try await moveTask(f, movedID, to: b, t.access)
            XCTAssertFalse(r.isError, r.text)
            let moved = try await XCTUnwrapAsync { try await TodoTask.find(movedID, on: f.test.app.db) }
            XCTAssertEqual(moved.title, "Moved"); XCTAssertEqual(moved.projectID, UUID(uuidString: b))
            let keyRowsOfMoved = try await TaskExternalKey.query(on: f.test.app.db).filter(\.$taskID == movedID).count()
            XCTAssertEqual(keyRowsOfMoved, 0)
            let stillResident = try await taskID(f, key: "p/one", project: b)
            XCTAssertEqual(stillResident, residentID)
            let sourceKeys = try await planKeys(f, a, t.access), targetKeys = try await planKeys(f, b, t.access)
            XCTAssertEqual(sourceKeys, []); XCTAssertEqual(targetKeys, ["p/one"])
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testMovingTaskWithoutKeyAndBackAgain() async throws {
        let f = try await OAuthFixture.make()
        do {
            let t = try await f.tokens(scope: Self.scopes)
            let a = try await newProject(f, "Source", t.access), b = try await newProject(f, "Target", t.access)
            // (2) task without any plan key
            let created = try await call(f, "create_task", ["projectID": a, "title": "Keyless"], access: t.access)
            XCTAssertFalse(created.isError, created.text)
            let keylessID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap((created.json as? [String: Any])?["id"] as? String ?? ((created.json as? [String: Any])?["task"] as? [String: Any])?["id"] as? String)))
            let r = try await moveTask(f, keylessID, to: b, t.access)
            XCTAssertFalse(r.isError, r.text)
            let keyless = try await XCTUnwrapAsync { try await TodoTask.find(keylessID, on: f.test.app.db) }
            XCTAssertEqual(keyless.projectID, UUID(uuidString: b))
            let none = try await planKeys(f, b, t.access)
            XCTAssertEqual(none, [])
            // (3) move a keyed task there and back: the key returns when it is free
            _ = try await call(f, "import_plan", ["projectID": a, "items": [["externalKey": "p/one", "title": "One"]]], access: t.access)
            let id = try await taskID(f, key: "p/one", project: a)
            let there = try await moveTask(f, id, to: b, t.access)
            XCTAssertFalse(there.isError, there.text)
            let targetKeys = try await planKeys(f, b, t.access)
            XCTAssertEqual(targetKeys, ["p/one"])
            let back = try await moveTask(f, id, to: a, t.access)
            XCTAssertFalse(back.isError, back.text)
            let sourceKeys = try await planKeys(f, a, t.access), targetAfter = try await planKeys(f, b, t.access)
            XCTAssertEqual(sourceKeys, ["p/one"]); XCTAssertEqual(targetAfter, [])
            // Back-move while the source key was re-taken meanwhile: the returning task loses its key.
            let there2 = try await moveTask(f, id, to: b, t.access)
            XCTAssertFalse(there2.isError, there2.text)
            _ = try await call(f, "import_plan", ["projectID": a, "items": [["externalKey": "p/one", "title": "Replacement"]]], access: t.access)
            let back2 = try await moveTask(f, id, to: a, t.access)
            XCTAssertFalse(back2.isError, back2.text)
            let replacement = try await taskID(f, key: "p/one", project: a)
            XCTAssertNotEqual(replacement, id)
            let rows = try await TaskExternalKey.query(on: f.test.app.db).filter(\.$taskID == id).count()
            XCTAssertEqual(rows, 0)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testMovingParentOrChildDetachesLinkAndKeepsChildKeysInSource() async throws {
        let f = try await OAuthFixture.make()
        do {
            let t = try await f.tokens(scope: Self.scopes)
            let a = try await newProject(f, "Source", t.access), b = try await newProject(f, "Target", t.access)
            let plan: [[String: Any]] = [["externalKey": "f/1", "title": "Feature", "children": [
                ["externalKey": "f/1/a", "title": "Child A"], ["externalKey": "f/1/b", "title": "Child B"]]]]
            let imp = try await call(f, "import_plan", ["projectID": a, "items": plan], access: t.access)
            XCTAssertFalse(imp.isError, imp.text)
            let featureID = try await taskID(f, key: "f/1", project: a)
            let childA = try await taskID(f, key: "f/1/a", project: a), childB = try await taskID(f, key: "f/1/b", project: a)
            let parentBefore = try await TaskWorkflow.find(childA, on: f.test.app.db)?.parentTaskID
            XCTAssertEqual(parentBefore, featureID)
            // Move a child: it leaves its parent and brings its key along.
            let rc = try await moveTask(f, childB, to: b, t.access)
            XCTAssertFalse(rc.isError, rc.text)
            let childBParent = try await TaskWorkflow.find(childB, on: f.test.app.db)?.parentTaskID
            XCTAssertNil(childBParent)
            let afterChildSource = try await planKeys(f, a, t.access), afterChildTarget = try await planKeys(f, b, t.access)
            XCTAssertEqual(afterChildSource, ["f/1", "f/1/a"]); XCTAssertEqual(afterChildTarget, ["f/1/b"])
            // Move the feature: remaining child is released, its key stays in the source.
            let rf = try await moveTask(f, featureID, to: b, t.access)
            XCTAssertFalse(rf.isError, rf.text)
            let childAParent = try await TaskWorkflow.find(childA, on: f.test.app.db)?.parentTaskID
            XCTAssertNil(childAParent)
            let childAProject = try await TodoTask.find(childA, on: f.test.app.db)?.projectID
            XCTAssertEqual(childAProject, UUID(uuidString: a))
            let sourceKeys = try await planKeys(f, a, t.access), targetKeys = try await planKeys(f, b, t.access)
            XCTAssertEqual(sourceKeys, ["f/1/a"]); XCTAssertEqual(targetKeys, ["f/1", "f/1/b"])
            let all = try await TodoTask.query(on: f.test.app.db).filter(\.$id ~~ [featureID, childA, childB]).count()
            XCTAssertEqual(all, 3)
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
