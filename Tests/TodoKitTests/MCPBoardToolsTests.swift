import Fluent
import XCTVapor
@testable import TodoKit

/// Batch 6 (docs/MCP-PARITAET.md): column edits and templates, task order, favorites and per-project display settings.
final class MCPBoardToolsTests: XCTestCase {
    private struct Called { let isError: Bool; let text: String; let json: Any? }
    private func call(_ f: OAuthFixture, _ name: String, _ args: [String: Any] = [:], _ access: String) async throws -> Called {
        let r = try await f.rpc("tools/call", ["name": name, "arguments": args], access: access)
        let result = try XCTUnwrap(r.body?["result"] as? [String: Any], String(describing: r.body))
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        return Called(isError: result["isError"] as? Bool ?? false, text: text, json: try? JSONSerialization.jsonObject(with: Data(text.utf8)))
    }
    private let all = "projects:read projects:write tasks:read tasks:write"
    private func fixture(_ run: (OAuthFixture, String) async throws -> Void) async throws {
        let f = try await OAuthFixture.make()
        do { let t = try await f.tokens(scope: all); try await run(f, t.access) }
        catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }
    private func expect(_ f: OAuthFixture, _ name: String, _ args: [String: Any], _ access: String, _ code: String,
                        file: StaticString = #filePath, line: UInt = #line) async throws {
        let c = try await call(f, name, args, access)
        XCTAssertEqual(c.text, code, file: file, line: line)
    }
    private func obj(_ c: Called) -> [String: Any] { (c.json as? [String: Any]) ?? [:] }
    private func readOnly(_ f: OAuthFixture) async throws -> String { try await f.tokens(scope: "projects:read tasks:read").access }
    private func extend(_ f: OAuthFixture, _ projects: [Project]) async throws {
        let g = try await XCTUnwrapAsync(try await OAuthGrant.query(on: f.test.app.db).first())
        g.projects.append(contentsOf: try projects.map { try $0.requireID() })
        try await g.save(on: f.test.app.db)
    }
    private func stranger(_ f: OAuthFixture) async throws -> Project {
        let u = User(displayName: "Stranger", isAdmin: false); try await u.save(on: f.test.app.db)
        let p = Project(ownerID: try u.requireID(), parentID: nil, name: "Foreign"); try await p.save(on: f.test.app.db)
        try await extend(f, [p])
        return p
    }
    private func column(_ f: OAuthFixture, _ name: String, position: Int, project: Project? = nil) async throws -> ProjectColumn {
        let c = ProjectColumn(projectID: try (project ?? f.project).requireID(), name: name, color: nil, isDone: false, position: position)
        try await c.save(on: f.test.app.db); return c
    }

    func testRegistrationAndScopes() {
        let expected = ["update_column": "tasks:write", "apply_column_template": "tasks:write", "reorder_tasks": "tasks:write",
                        "list_favorites": "projects:read", "set_project_favorite": "projects:write",
                        "get_project_prefs": "projects:read", "update_project_prefs": "projects:write"]
        for (n, s) in expected { XCTAssertEqual(MCPController.tools.first { $0.name == n }?.scope, s, n) }
    }

    func testMissingScopeIsRejected() async throws {
        try await fixture { f, _ in
            let ro = try await readOnly(f)
            let pid = try f.project.requireID().uuidString
            for (name, args) in [("update_column", ["id": pid, "version": 1, "name": "x"]), ("apply_column_template", ["projectID": pid, "source": "status"]),
                                 ("reorder_tasks", ["projectID": pid, "status": "open", "taskIDs": [String]()]),
                                 ("set_project_favorite", ["projectID": pid, "favorite": true]),
                                 ("update_project_prefs", ["projectID": pid, "revision": 0, "view": "board"])] as [(String, [String: Any])] {
                let c = try await call(f, name, args, ro)
                XCTAssertEqual(c.text, "insufficient_scope", name)
            }
        }
    }

    // MARK: update_column

    func testUpdateColumnChangesFieldsAndChecksVersion() async throws {
        try await fixture { f, t in
            let a = try await column(f, "A", position: 0), b = try await column(f, "B", position: 1)
            let ok = try await call(f, "update_column", ["id": b.requireID().uuidString, "version": 1, "name": " Review ", "color": "#ff0000", "isDone": true, "index": 0], t)
            XCTAssertFalse(ok.isError, ok.text)
            XCTAssertEqual(obj(ok)["name"] as? String, "Review")
            XCTAssertEqual(obj(ok)["color"] as? String, "#FF0000")
            XCTAssertEqual(obj(ok)["isDone"] as? Bool, true)
            XCTAssertEqual(obj(ok)["position"] as? Int, 0)
            let aPos = try await ProjectColumn.find(a.requireID(), on: f.test.app.db)?.position
            XCTAssertEqual(aPos, 1)
            let stale = try await call(f, "update_column", ["id": b.requireID().uuidString, "version": 1, "name": "Z"], t)
            XCTAssertEqual(stale.text, "version_conflict")
            // Empty color removes it.
            let fresh = try await XCTUnwrapAsync(try await ProjectColumn.find(b.requireID(), on: f.test.app.db))
            let cleared = try await call(f, "update_column", ["id": b.requireID().uuidString, "version": fresh.version, "color": ""], t)
            XCTAssertFalse(cleared.isError, cleared.text)
            let bColor = try await ProjectColumn.find(b.requireID(), on: f.test.app.db)?.color
            XCTAssertNil(bColor)
        }
    }

    func testUpdateColumnRejectsBadInputAndForeignProjects() async throws {
        try await fixture { f, t in
            let a = try await column(f, "A", position: 0)
            let id = try a.requireID().uuidString
            for args in [["id": id, "version": 1], ["id": id, "version": 1.5, "name": "x"], ["id": id, "version": 1, "index": -1],
                         ["id": id, "version": 1, "isDone": "yes"], ["id": id, "version": 1, "color": 5]] as [[String: Any]] {
                let c = try await call(f, "update_column", args, t)
                XCTAssertTrue(c.isError, "\(args)")
                XCTAssertTrue(c.text.hasPrefix("invalid_"), c.text)
            }
            try await expect(f, "update_column", ["id": id, "version": 1, "color": "red"], t, "invalid_color")
            // Column of a project outside the grant: not_found.
            let outside = try await column(f, "O", position: 0, project: f.other)
            try await expect(f, "update_column", ["id": outside.requireID().uuidString, "version": 1, "name": "x"], t, "not_found")
            // In the grant, but the account has no role.
            let foreign = try await stranger(f)
            let fc = try await column(f, "F", position: 0, project: foreign)
            try await expect(f, "update_column", ["id": fc.requireID().uuidString, "version": 1, "name": "x"], t, "not_found")
        }
    }

    // MARK: apply_column_template

    func testApplyColumnTemplate() async throws {
        try await fixture { f, t in
            let pid = try f.project.requireID()
            let task = TodoTask(ownerID: try f.user.requireID(), projectID: pid, title: "T", details: ""); task.status = "done"
            try await task.save(on: f.test.app.db)
            let ok = try await call(f, "apply_column_template", ["projectID": pid.uuidString, "source": "status"], t)
            XCTAssertFalse(ok.isError, ok.text)
            XCTAssertEqual((ok.json as? [[String: Any]])?.map { $0["name"] as? String }, ["Offen", "In Arbeit", "Erledigt"])
            let moved = try await XCTUnwrapAsync(try await TodoTask.find(task.requireID(), on: f.test.app.db))
            XCTAssertNotNil(moved.columnID)
            try await expect(f, "apply_column_template", ["projectID": pid.uuidString, "source": "status"], t, "columns_exist")
            // Copy from another project in the grant.
            let target = Project(ownerID: try f.user.requireID(), parentID: nil, name: "Target"); try await target.save(on: f.test.app.db)
            try await extend(f, [target])
            let copy = try await call(f, "apply_column_template", ["projectID": target.requireID().uuidString, "source": pid.uuidString], t)
            XCTAssertFalse(copy.isError, copy.text)
            XCTAssertEqual((copy.json as? [[String: Any]])?.count, 3)
        }
    }

    func testApplyColumnTemplateRejectsOutsideAndBadInput() async throws {
        try await fixture { f, t in
            let pid = try f.project.requireID().uuidString
            try await expect(f, "apply_column_template", ["projectID": f.other.requireID().uuidString, "source": "status"], t, "not_found")
            // Source outside the grant does not leak.
            try await expect(f, "apply_column_template", ["projectID": pid, "source": f.other.requireID().uuidString], t, "not_found")
            try await expect(f, "apply_column_template", ["projectID": pid, "source": "nonsense"], t, "invalid_source")
            try await expect(f, "apply_column_template", ["projectID": pid, "source": 7], t, "invalid_source")
            let foreign = try await stranger(f)
            try await expect(f, "apply_column_template", ["projectID": foreign.requireID().uuidString, "source": "status"], t, "not_found")
            let columnCount = try await ProjectColumn.query(on: f.test.app.db).count()
            XCTAssertEqual(columnCount, 0)
        }
    }

    // MARK: reorder_tasks

    func testReorderTasks() async throws {
        try await fixture { f, t in
            let pid = try f.project.requireID()
            var ids: [UUID] = []
            for title in ["a", "b", "c"] {
                let task = TodoTask(ownerID: try f.user.requireID(), projectID: pid, title: title, details: "")
                try await task.save(on: f.test.app.db); ids.append(try task.requireID())
            }
            let order = [ids[2], ids[0], ids[1]]
            let ok = try await call(f, "reorder_tasks", ["projectID": pid.uuidString, "status": "open", "taskIDs": order.map(\.uuidString)], t)
            XCTAssertFalse(ok.isError, ok.text)
            XCTAssertEqual(obj(ok)["count"] as? Int, 3)
            for (i, id) in order.enumerated() {
                let pos = try await TaskPlanning.find(id, on: f.test.app.db)?.position
                XCTAssertEqual(pos, i)
            }
            // Incomplete list: board changed.
            let partial = try await call(f, "reorder_tasks", ["projectID": pid.uuidString, "status": "open", "taskIDs": [ids[0].uuidString]], t)
            XCTAssertEqual(partial.text, "board_changed")
            // Bad input.
            try await expect(f, "reorder_tasks", ["projectID": pid.uuidString, "status": "bogus", "taskIDs": [String]()], t, "invalid_status")
            try await expect(f, "reorder_tasks", ["projectID": pid.uuidString, "status": "open", "taskIDs": ["x"]], t, "invalid_taskIDs")
            try await expect(f, "reorder_tasks", ["projectID": pid.uuidString, "status": "open", "taskIDs": [ids[0].uuidString, ids[0].uuidString]], t, "invalid_taskIDs")
            try await expect(f, "reorder_tasks", ["projectID": f.other.requireID().uuidString, "status": "open", "taskIDs": [String]()], t, "not_found")
            let foreign = try await stranger(f)
            try await expect(f, "reorder_tasks", ["projectID": foreign.requireID().uuidString, "status": "open", "taskIDs": [String]()], t, "not_found")
        }
    }

    // MARK: favorites

    func testFavoritesAddMoveRemoveAndGrantFilter() async throws {
        try await fixture { f, t in
            let second = Project(ownerID: try f.user.requireID(), parentID: nil, name: "Second"); try await second.save(on: f.test.app.db)
            try await extend(f, [second])
            let p1 = try f.project.requireID().uuidString, p2 = try second.requireID().uuidString
            let none = try await call(f, "list_favorites", [:], t)
            XCTAssertEqual((none.json as? [Any])?.count, 0)
            _ = try await call(f, "set_project_favorite", ["projectID": p1, "favorite": true], t)
            let two = try await call(f, "set_project_favorite", ["projectID": p2, "favorite": true, "index": 0], t)
            XCTAssertEqual((two.json as? [[String: Any]])?.map { $0["projectID"] as? String }, [p2, p1])
            // Favorite outside the grant stays hidden from this connection.
            _ = try await ProjectStateService(user: f.user, db: f.test.app.db).setFavorite(f.other.requireID(), index: nil)
            let listed = try await call(f, "list_favorites", [:], t)
            XCTAssertEqual((listed.json as? [[String: Any]])?.count, 2)
            let removed = try await call(f, "set_project_favorite", ["projectID": p2, "favorite": false], t)
            XCTAssertEqual((removed.json as? [[String: Any]])?.map { $0["projectID"] as? String }, [p1])
            // Errors.
            try await expect(f, "set_project_favorite", ["projectID": f.other.requireID().uuidString, "favorite": true], t, "not_found")
            try await expect(f, "set_project_favorite", ["projectID": p1, "favorite": "yes"], t, "invalid_favorite")
            try await expect(f, "set_project_favorite", ["projectID": p1, "favorite": true, "index": -1], t, "invalid_index")
            try await expect(f, "set_project_favorite", ["projectID": p1, "favorite": false, "index": 0], t, "invalid_index")
            let foreign = try await stranger(f)
            try await expect(f, "set_project_favorite", ["projectID": foreign.requireID().uuidString, "favorite": true], t, "not_found")
        }
    }

    // MARK: project prefs

    func testProjectPrefsReadWriteAndConflict() async throws {
        try await fixture { f, t in
            let pid = try f.project.requireID().uuidString
            let initial = try await call(f, "get_project_prefs", ["projectID": pid], t)
            XCTAssertEqual(obj(initial)["revision"] as? Int, 0)
            let ok = try await call(f, "update_project_prefs", ["projectID": pid, "revision": 0, "view": "board", "sort": "due", "showCompleted": false, "mode": "management"], t)
            XCTAssertFalse(ok.isError, ok.text)
            XCTAssertEqual(obj(ok)["view"] as? String, "board")
            XCTAssertEqual(obj(ok)["showCompleted"] as? Bool, false)
            XCTAssertEqual(obj(ok)["mode"] as? String, "management")
            XCTAssertEqual(obj(ok)["revision"] as? Int, 1)
            try await expect(f, "update_project_prefs", ["projectID": pid, "revision": 0, "view": "list"], t, "revision_conflict")
            let again = try await call(f, "get_project_prefs", ["projectID": pid], t)
            XCTAssertEqual(obj(again)["sort"] as? String, "due")
            XCTAssertEqual(obj(again)["modeSource"] as? String, "user")
        }
    }

    func testProjectPrefsRejectBadInputAndForeignProjects() async throws {
        try await fixture { f, t in
            let pid = try f.project.requireID().uuidString
            try await expect(f, "update_project_prefs", ["projectID": pid, "revision": 0], t, "empty_project_prefs")
            try await expect(f, "update_project_prefs", ["projectID": pid, "revision": 0, "view": "grid"], t, "invalid_view")
            try await expect(f, "update_project_prefs", ["projectID": pid, "revision": 0, "showCompleted": "no"], t, "invalid_showCompleted")
            try await expect(f, "update_project_prefs", ["projectID": pid, "revision": -1, "view": "list"], t, "revision_required")
            try await expect(f, "get_project_prefs", ["projectID": f.other.requireID().uuidString], t, "not_found")
            try await expect(f, "update_project_prefs", ["projectID": f.other.requireID().uuidString, "revision": 0, "view": "list"], t, "not_found")
            let foreign = try await stranger(f)
            try await expect(f, "get_project_prefs", ["projectID": foreign.requireID().uuidString], t, "not_found")
            try await expect(f, "update_project_prefs", ["projectID": foreign.requireID().uuidString, "revision": 0, "view": "list"], t, "not_found")
        }
    }

    func testDeleteColumnStaysAConfirmationRequest() async throws {
        try await fixture { f, t in
            let c = try await column(f, "A", position: 0)
            let r = try await call(f, "delete_column", ["id": c.requireID().uuidString], t)
            XCTAssertTrue(r.isError)
            XCTAssertEqual(obj(r)["error"] as? String, "confirmation_required")
            let still = try await ProjectColumn.find(c.requireID(), on: f.test.app.db)
            XCTAssertNotNil(still)
        }
    }
}
