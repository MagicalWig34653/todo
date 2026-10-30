import Fluent
import XCTVapor
@testable import TodoKit

final class ColumnTests: XCTestCase {
    private func account(_ t: TestApp) async throws -> (id: String, token: String) {
        let user = User(displayName: "Test", isAdmin: false)
        try await user.save(on: t.app.db)
        let token = AuthSupport.randomToken()
        try await UserSession(userID: user.requireID(), tokenHash: AuthSupport.hash(token),
            expiresAt: Date().addingTimeInterval(3600)).save(on: t.app.db)
        return (try user.requireID().uuidString, token)
    }

    private func project(_ t: TestApp, _ token: String, name: String = "P", parent: String? = nil) async throws -> String {
        var body = ["name": name]; body["parentID"] = parent
        let r = try await t.json(.POST, "/v1/projects", body, token: token)
        XCTAssertEqual(r.status, .created)
        return try XCTUnwrap(r.body?["id"] as? String)
    }

    private func task(_ t: TestApp, _ token: String, _ pid: String, _ title: String, column: String? = nil) async throws -> [String: Any] {
        var body: [String: Any] = ["projectID": pid, "title": title]
        if let column { body["columnID"] = column }
        let r = try await t.json(.POST, "/v1/tasks", body, token: token)
        XCTAssertEqual(r.status, .created, "\(r.body ?? [:])")
        return try XCTUnwrap(r.body)
    }

    private func column(_ t: TestApp, _ token: String, _ pid: String, _ name: String, isDone: Bool = false, index: Int? = nil) async throws -> [String: Any] {
        var body: [String: Any] = ["name": name, "isDone": isDone]
        if let index { body["index"] = index }
        let r = try await t.json(.POST, "/v1/projects/\(pid)/columns", body, token: token)
        XCTAssertEqual(r.status, .created, "\(r.body ?? [:])")
        return try XCTUnwrap(r.body)
    }

    private func board(_ t: TestApp, _ token: String, _ pid: String) async throws -> [String: Any] {
        let r = try await t.json(.GET, "/v1/projects/\(pid)/board", token: token)
        XCTAssertEqual(r.status, .ok)
        return try XCTUnwrap(r.body)
    }

    typealias Reply = (status: HTTPStatus, body: [String: Any]?, list: [[String: Any]]?, cookie: String?)
    private func expect(_ expected: HTTPStatus, _ r: Reply, msg: String = "", line: UInt = #line) {
        XCTAssertEqual(r.status, expected, msg, line: line)
    }
    private func expectText(_ r: (Bool, String), _ text: String, line: UInt = #line) {
        XCTAssertEqual(r.1, text, line: line)
    }
    private func expectOK(_ r: (Bool, String), line: UInt = #line) {
        XCTAssertFalse(r.0, r.1, line: line)
    }
    private func titles(_ tasks: Any?) -> [String] { (tasks as? [[String: Any]])?.compactMap { $0["title"] as? String } ?? [] }
    private func col(_ board: [String: Any], _ i: Int) -> [String: Any] { (board["columns"] as! [[String: Any]])[i] }

    func testStatusBoardWithoutColumnsThenTemplate() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let a = try await account(t)
        let p = try await project(t, a.token)
        _ = try await task(t, a.token, p, "A")
        let done = try await task(t, a.token, p, "B")
        _ = try await t.json(.PATCH, "/v1/tasks/\(done["id"] as! String)", ["version": 1, "status": "done"], token: a.token)
        var b = try await board(t, a.token, p)
        XCTAssertEqual(b["mode"] as? String, "status")
        XCTAssertEqual((b["columns"] as? [[String: Any]])?.compactMap { $0["key"] as? String }, ["open", "in_progress", "in_review", "done"])
        XCTAssertEqual(titles(col(b, 0)["tasks"]), ["A"])
        XCTAssertEqual(titles(col(b, 3)["tasks"]), ["B"])
        XCTAssertEqual((b["unassigned"] as? [Any])?.count, 0)

        let tpl = try await t.json(.POST, "/v1/projects/\(p)/columns/template", ["source": "status"], token: a.token)
        XCTAssertEqual(tpl.status, .created)
        XCTAssertEqual(tpl.list?.compactMap { $0["name"] as? String }, ["Offen", "In Arbeit", "Erledigt"])
        b = try await board(t, a.token, p)
        XCTAssertEqual(b["mode"] as? String, "columns")
        XCTAssertEqual(titles(col(b, 0)["tasks"]), ["A"])
        XCTAssertEqual(titles(col(b, 2)["tasks"]), ["B"])
        XCTAssertEqual(col(b, 2)["isDone"] as? Bool, true)
        let again = try await t.json(.POST, "/v1/projects/\(p)/columns/template", ["source": "status"], token: a.token)
        XCTAssertEqual(again.status, .conflict)

        // Copy another project's columns.
        let q = try await project(t, a.token, name: "Q")
        let copy = try await t.json(.POST, "/v1/projects/\(q)/columns/template", ["source": p], token: a.token)
        XCTAssertEqual(copy.status, .created)
        XCTAssertEqual(copy.list?.count, 3)
        XCTAssertNotEqual(copy.list?.first?["id"] as? String, tpl.list?.first?["id"] as? String)
    }

    func testColumnCrudOrderingValidationAndVersions() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let a = try await account(t)
        let p = try await project(t, a.token)
        let ideas = try await column(t, a.token, p, "  Projektideen  ")
        let cid = ideas["id"] as! String
        XCTAssertEqual(ideas["name"] as? String, "Projektideen")
        _ = try await column(t, a.token, p, "Aktiv")
        let first = try await column(t, a.token, p, "Zuerst", index: 0)
        let list = try await t.json(.GET, "/v1/projects/\(p)/columns", token: a.token)
        XCTAssertEqual(list.list?.compactMap { $0["name"] as? String }, ["Zuerst", "Projektideen", "Aktiv"])
        XCTAssertEqual(list.list?.compactMap { $0["position"] as? Int }, [0, 1, 2])

        for bad: [String: Any] in [["name": "  "], ["name": String(repeating: "x", count: 101)], ["name": "x", "color": "red"], ["name": "x", "index": -1]] {
            let r = try await t.json(.POST, "/v1/projects/\(p)/columns", bad, token: a.token)
            XCTAssertEqual(r.status, .badRequest, "\(bad)")
        }
        // Inserting "Zuerst" before it shifted the position, so the version moved on.
        let version = list.list!.first { $0["id"] as? String == cid }!["version"] as! Int
        XCTAssertGreaterThan(version, ideas["version"] as! Int)
        let upd = try await t.json(.PATCH, "/v1/projects/\(p)/columns/\(cid)", ["version": version, "name": "Ideen", "color": "#aabbcc", "index": 2], token: a.token)
        XCTAssertEqual(upd.status, .ok)
        XCTAssertEqual(upd.body?["color"] as? String, "#AABBCC")
        XCTAssertEqual(upd.body?["position"] as? Int, 2)
        let stale = try await t.json(.PATCH, "/v1/projects/\(p)/columns/\(cid)", ["version": version, "name": "Nope"], token: a.token)
        XCTAssertEqual(stale.status, .conflict)
        let cleared = try await t.json(.PATCH, "/v1/projects/\(p)/columns/\(cid)", ["version": upd.body!["version"]!, "color": ""], token: a.token)
        XCTAssertTrue(cleared.body?["color"] == nil || cleared.body?["color"] is NSNull)
        let after = try await t.json(.GET, "/v1/projects/\(p)/columns", token: a.token)
        XCTAssertEqual(after.list?.compactMap { $0["name"] as? String }, ["Zuerst", "Aktiv", "Ideen"])
        XCTAssertEqual(after.list?.compactMap { $0["position"] as? Int }, [0, 1, 2])
        XCTAssertEqual(first["position"] as? Int, 0)
    }

    func testMoveOrderDoneColumnStatusRuleAndStatusPatch() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let a = try await account(t)
        let p = try await project(t, a.token)
        let todo = try await column(t, a.token, p, "Todo")
        let doing = try await column(t, a.token, p, "Doing")
        let done = try await column(t, a.token, p, "Done", isDone: true)
        let (todoID, doingID, doneID) = (todo["id"] as! String, doing["id"] as! String, done["id"] as! String)
        let t1 = try await task(t, a.token, p, "T1", column: todoID)
        let t2 = try await task(t, a.token, p, "T2", column: todoID)
        let t3 = try await task(t, a.token, p, "T3")
        var b = try await board(t, a.token, p)
        XCTAssertEqual(titles(col(b, 0)["tasks"]), ["T1", "T2"])
        XCTAssertEqual(titles(b["unassigned"]), ["T3"])

        // Insert at index 0 of the same column, then into another column.
        var m = try await t.json(.PUT, "/v1/tasks/\(t2["id"] as! String)/column", ["version": 1, "columnID": todoID, "index": 0], token: a.token)
        XCTAssertEqual(m.status, .ok)
        XCTAssertEqual(m.body?["version"] as? Int, 2)
        XCTAssertEqual(m.body?["boardPosition"] as? Int, 0)
        m = try await t.json(.PUT, "/v1/tasks/\(t3["id"] as! String)/column", ["version": 1, "columnID": todoID, "index": 99], token: a.token)
        b = try await board(t, a.token, p)
        XCTAssertEqual(titles(col(b, 0)["tasks"]), ["T2", "T1", "T3"])
        XCTAssertEqual((col(b, 0)["tasks"] as! [[String: Any]]).compactMap { $0["boardPosition"] as? Int }, [0, 1, 2])
        XCTAssertEqual((b["unassigned"] as? [Any])?.count, 0)

        // Stale version -> 409; into done column -> status done; out of it -> reopened.
        let stale = try await t.json(.PUT, "/v1/tasks/\(t1["id"] as! String)/column", ["version": 7, "columnID": doingID], token: a.token)
        XCTAssertEqual(stale.status, .conflict)
        let toDone = try await t.json(.PUT, "/v1/tasks/\(t1["id"] as! String)/column", ["version": 1, "columnID": doneID], token: a.token)
        XCTAssertEqual(toDone.body?["status"] as? String, "done")
        XCTAssertEqual(toDone.body?["columnID"] as? String, doneID)
        let back = try await t.json(.PUT, "/v1/tasks/\(t1["id"] as! String)/column", ["version": toDone.body!["version"]!, "columnID": doingID], token: a.token)
        XCTAssertEqual(back.body?["status"] as? String, "open")
        XCTAssertEqual(back.body?["columnID"] as? String, doingID)

        // PATCH status done pulls the task into the done column; reopening leaves it.
        let patched = try await t.json(.PATCH, "/v1/tasks/\(t2["id"] as! String)", ["version": 2, "status": "done"], token: a.token)
        XCTAssertEqual(patched.body?["columnID"] as? String, doneID)
        let reopened = try await t.json(.PATCH, "/v1/tasks/\(t2["id"] as! String)", ["version": patched.body!["version"]!, "status": "open"], token: a.token)
        XCTAssertEqual(reopened.body?["columnID"] as? String, todoID)
        // Unassigned task completed lands in the done column.
        let loose = try await task(t, a.token, p, "Loose")
        let completed = try await t.json(.PATCH, "/v1/tasks/\(loose["id"] as! String)", ["version": 1, "status": "done"], token: a.token)
        XCTAssertEqual(completed.body?["columnID"] as? String, doneID)

        // Unassign; foreign / unknown column is 404; negative index 400.
        let un = try await t.json(.PUT, "/v1/tasks/\(t3["id"] as! String)/column", ["version": m.body!["version"]!, "columnID": NSNull()], token: a.token)
        XCTAssertEqual(un.status, .ok)
        XCTAssertTrue(un.body?["columnID"] == nil || un.body?["columnID"] is NSNull)
        let other = try await project(t, a.token, name: "Other")
        let foreign = try await column(t, a.token, other, "Elsewhere")
        let wrong = try await t.json(.PUT, "/v1/tasks/\(t3["id"] as! String)/column", ["version": un.body!["version"]!, "columnID": foreign["id"]!], token: a.token)
        XCTAssertEqual(wrong.status, .notFound)
        let neg = try await t.json(.PUT, "/v1/tasks/\(t3["id"] as! String)/column", ["version": un.body!["version"]!, "columnID": doingID, "index": -1], token: a.token)
        XCTAssertEqual(neg.status, .badRequest)
    }

    func testDeleteColumnMovesTasksAndMovingProjectsResetsColumn() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let a = try await account(t)
        let p = try await project(t, a.token)
        let c1 = try await column(t, a.token, p, "C1"), c2 = try await column(t, a.token, p, "C2"), c3 = try await column(t, a.token, p, "C3")
        let id1 = c1["id"] as! String, id2 = c2["id"] as! String, id3 = c3["id"] as! String
        _ = try await task(t, a.token, p, "x", column: id2)
        _ = try await task(t, a.token, p, "y", column: id2)
        _ = try await task(t, a.token, p, "z", column: id1)
        // Default: tasks move to the first remaining column, appended in order.
        var r = try await t.json(.DELETE, "/v1/projects/\(p)/columns/\(id2)", token: a.token)
        XCTAssertEqual(r.status, .noContent)
        var b = try await board(t, a.token, p)
        XCTAssertEqual(titles(col(b, 0)["tasks"]), ["z", "x", "y"])
        XCTAssertEqual((b["columns"] as! [[String: Any]]).compactMap { $0["position"] as? Int }, [0, 1])
        // Explicit target and "none".
        r = try await t.json(.DELETE, "/v1/projects/\(p)/columns/\(id1)?moveTo=\(id3)", token: a.token)
        XCTAssertEqual(r.status, .noContent)
        b = try await board(t, a.token, p)
        XCTAssertEqual(titles(col(b, 0)["tasks"]), ["z", "x", "y"])
        let missing = try await t.json(.DELETE, "/v1/projects/\(p)/columns/\(id3)?moveTo=\(id1)", token: a.token)
        XCTAssertEqual(missing.status, .notFound)
        let stale = try await t.json(.DELETE, "/v1/projects/\(p)/columns/\(id3)?version=99", token: a.token)
        XCTAssertEqual(stale.status, .conflict)
        r = try await t.json(.DELETE, "/v1/projects/\(p)/columns/\(id3)?moveTo=none", token: a.token)
        b = try await board(t, a.token, p)
        XCTAssertEqual(b["mode"] as? String, "status")
        let tasks = try await t.json(.GET, "/v1/tasks?projectID=\(p)", token: a.token)
        XCTAssertTrue(tasks.list!.allSatisfy { $0["columnID"] == nil || $0["columnID"] is NSNull })

        // Moving a task into another project clears its column (columns are per project).
        let q = try await project(t, a.token, name: "Q")
        let cq = try await column(t, a.token, p, "Back")
        let moving = try await task(t, a.token, p, "mv", column: cq["id"] as? String)
        let moved = try await t.json(.PATCH, "/v1/tasks/\(moving["id"] as! String)", ["version": 1, "projectID": q], token: a.token)
        XCTAssertEqual(moved.status, .ok)
        XCTAssertTrue(moved.body?["columnID"] == nil || moved.body?["columnID"] is NSNull)
        // Deleting a project cascades its columns.
        let del = try await t.json(.DELETE, "/v1/projects/\(p)", token: a.token)
        XCTAssertEqual(del.status, .noContent)
        let count = try await ProjectColumn.query(on: t.app.db).count()
        XCTAssertEqual(count, 0)
    }

    func testPermissions() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let owner = try await account(t), reader = try await account(t), editor = try await account(t), stranger = try await account(t)
        let p = try await project(t, owner.token)
        let child = try await project(t, owner.token, name: "Child", parent: p)
        for (u, role) in [(reader, "read"), (editor, "edit")] {
            let g = try await t.json(.PUT, "/v1/projects/\(p)/grants", ["principalType": "person", "principalID": u.id, "role": role], token: owner.token)
            XCTAssertEqual(g.status, .ok)
        }
        let col = try await column(t, owner.token, p, "Col")
        let cid = col["id"] as! String
        let tk = try await task(t, owner.token, p, "T", column: cid)
        let tid = tk["id"] as! String

        // Read: may look, may not write.
        expect(.ok, try await t.json(.GET, "/v1/projects/\(p)/board", token: reader.token))
        expect(.ok, try await t.json(.GET, "/v1/projects/\(p)/columns", token: reader.token))
        expect(.forbidden, try await t.json(.POST, "/v1/projects/\(p)/columns", ["name": "x"], token: reader.token))
        expect(.forbidden, try await t.json(.PATCH, "/v1/projects/\(p)/columns/\(cid)", ["version": 1, "name": "x"], token: reader.token))
        expect(.forbidden, try await t.json(.DELETE, "/v1/projects/\(p)/columns/\(cid)", token: reader.token))
        expect(.forbidden, try await t.json(.PUT, "/v1/tasks/\(tid)/column", ["version": 1, "columnID": NSNull()], token: reader.token))
        expect(.forbidden, try await t.json(.POST, "/v1/projects/\(child)/columns/template", ["source": "status"], token: reader.token))
        // Edit: may change columns and move tasks.
        expect(.created, try await t.json(.POST, "/v1/projects/\(p)/columns", ["name": "Edited"], token: editor.token))
        expect(.ok, try await t.json(.PUT, "/v1/tasks/\(tid)/column", ["version": 1, "columnID": NSNull()], token: editor.token))
        // Inherited read reaches the child project, but columns are not inherited.
        let childBoard = try await board(t, reader.token, child)
        XCTAssertEqual(childBoard["mode"] as? String, "status")
        // Stranger: everything is 404, including path/column mismatches.
        for (m, path, body): (HTTPMethod, String, [String: Any]?) in [
            (.GET, "/v1/projects/\(p)/board", nil), (.GET, "/v1/projects/\(p)/columns", nil),
            (.POST, "/v1/projects/\(p)/columns", ["name": "x"]), (.PATCH, "/v1/projects/\(p)/columns/\(cid)", ["version": 1]),
            (.DELETE, "/v1/projects/\(p)/columns/\(cid)", nil), (.PUT, "/v1/tasks/\(tid)/column", ["version": 1, "columnID": cid]),
            (.POST, "/v1/projects/\(p)/columns/template", ["source": "status"]),
        ] {
            let r = try await t.json(m, path, body, token: stranger.token)
            XCTAssertEqual(r.status, .notFound, "\(m) \(path)")
        }
        // A column cannot be addressed through another project's path.
        let mine = try await project(t, stranger.token, name: "Mine")
        expect(.notFound, try await t.json(.DELETE, "/v1/projects/\(mine)/columns/\(cid)", token: stranger.token))
        // Template source must be readable.
        expect(.notFound, try await t.json(.POST, "/v1/projects/\(mine)/columns/template", ["source": p], token: stranger.token))
        expect(.unauthorized, try await t.json(.GET, "/v1/projects/\(p)/board"))
    }

    func testSyncFeedCarriesColumnsAndTombstones() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let owner = try await account(t), guest = try await account(t)
        let p = try await project(t, owner.token)
        let c = try await column(t, owner.token, p, "Feed")
        let cid = c["id"] as! String
        let feed = try await t.json(.GET, "/v1/sync/changes?cursor=c0", token: owner.token)
        let entries = feed.body?["changes"] as? [[String: Any]] ?? []
        let colEntry = entries.first { $0["entityType"] as? String == "column" }
        XCTAssertEqual((colEntry?["column"] as? [String: Any])?["name"] as? String, "Feed")
        let guestEmpty = try await t.json(.GET, "/v1/sync/changes?cursor=c0", token: guest.token)
        XCTAssertFalse((guestEmpty.body?["changes"] as? [[String: Any]] ?? []).contains { $0["entityType"] as? String == "column" })
        // Access gained -> column upsert; access lost -> tombstone; delete -> tombstone.
        let g = try await t.json(.PUT, "/v1/projects/\(p)/grants", ["principalType": "person", "principalID": guest.id, "role": "read"], token: owner.token)
        let gained = try await t.json(.GET, "/v1/sync/changes?cursor=c0", token: guest.token)
        XCTAssertTrue((gained.body?["changes"] as? [[String: Any]] ?? []).contains { $0["entityType"] as? String == "column" && $0["kind"] as? String == "upsert" })
        let cursor = gained.body!["cursor"] as! String
        _ = try await t.json(.DELETE, "/v1/projects/\(p)/columns/\(cid)", token: owner.token)
        let gone = try await t.json(.GET, "/v1/sync/changes?cursor=\(cursor)", token: guest.token)
        XCTAssertTrue((gone.body?["changes"] as? [[String: Any]] ?? []).contains { $0["entityType"] as? String == "column" && $0["kind"] as? String == "delete" && $0["entityID"] as? String == cid })
        _ = g
    }

    func testMCPToolsFollowScopesAndGrants() async throws {
        let f = try await OAuthFixture.make()
        do {
            let pid = try f.project.requireID().uuidString, otherID = try f.other.requireID().uuidString
            _ = try await f.test.json(.POST, "/v1/projects/\(pid)/columns", ["name": "A"], token: f.session)
            let b = try await f.test.json(.POST, "/v1/projects/\(pid)/columns", ["name": "B"], token: f.session)
            let task = try await f.test.json(.POST, "/v1/tasks", ["projectID": pid, "title": "T"], token: f.session)
            let tid = task.body!["id"] as! String
            let full = try await f.tokens(scope: "projects:read tasks:read tasks:write")
            func call(_ name: String, _ args: [String: Any], _ access: String) async throws -> (Bool, String) {
                let r = try await f.rpc("tools/call", ["name": name, "arguments": args], access: access)
                let result = try XCTUnwrap(r.body?["result"] as? [String: Any])
                let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
                return (result["isError"] as? Bool ?? false, text)
            }
            let list = try await call("list_columns", ["projectID": pid], full.access)
            XCTAssertFalse(list.0)
            XCTAssertTrue(list.1.contains("\"mode\":\"columns\""))
            expectText(try await call("list_columns", ["projectID": otherID], full.access), "not_found")
            let moved = try await call("move_task_to_column", ["id": tid, "version": 1, "columnID": b.body!["id"]!, "index": 0], full.access)
            XCTAssertFalse(moved.0, moved.1)
            XCTAssertTrue(moved.1.contains(b.body!["id"] as! String))
            expectText(try await call("move_task_to_column", ["id": tid, "version": 1, "columnID": NSNull()], full.access), "version_conflict")
            // Scope gating.
            let readOnly = try await f.tokens(scope: "projects:read")
            expectText(try await call("move_task_to_column", ["id": tid, "version": 2, "columnID": NSNull()], readOnly.access), "insufficient_scope")
            expectOK(try await call("list_columns", ["projectID": pid], readOnly.access))
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    // MARK: MariaDB (skipped without TODO_TEST_DB / TODO_TEST_MARIADB)

    func testConcurrentMovesAndColumnCreationAcrossReplicas() async throws {
        try XCTSkipUnless(TestApp.useMariaDB, "needs MariaDB")
        let a = try await TestApp.make()
        let b = try await a.replica()
        defer { Task { await a.shutdown(); await b.shutdown() } }
        let u = try await account(a)
        let p = try await project(a, u.token)
        let c1 = try await column(a, u.token, p, "One"), c2 = try await column(a, u.token, p, "Two")
        let tk = try await task(a, u.token, p, "T", column: c1["id"] as? String)
        let tid = tk["id"] as! String

        // Same version, eight concurrent moves from both replicas: exactly one winner. All target c2 so the winner is
        // deterministic for the final count (a winner moving to c1 made the c2 count 10 instead of 11).
        let statuses = try await withThrowingTaskGroup(of: HTTPStatus.self) { group -> [HTTPStatus] in
            for i in 0..<8 {
                let app = i % 2 == 0 ? a : b
                let body = try JSONSerialization.data(withJSONObject: ["version": 1, "columnID": c2["id"]!, "index": 0])
                group.addTask { try await app.rawStatus(.PUT, "/v1/tasks/\(tid)/column", body: body, token: u.token) }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(statuses.filter { $0 == .ok }.count, 1, "\(statuses)")
        XCTAssertEqual(statuses.filter { $0 == .conflict }.count, 7, "\(statuses)")

        // Concurrent column creation with index 0 and task creation: dense unique positions, dense board positions.
        let results = try await withThrowingTaskGroup(of: HTTPStatus.self) { group -> [HTTPStatus] in
            for i in 0..<10 {
                let app = i % 2 == 0 ? a : b
                let body = try JSONSerialization.data(withJSONObject: ["name": "N\(i)", "index": 0])
                group.addTask { try await app.rawStatus(.POST, "/v1/projects/\(p)/columns", body: body, token: u.token) }
                let tb = try JSONSerialization.data(withJSONObject: ["projectID": p, "title": "Q\(i)", "columnID": c2["id"]!])
                group.addTask { try await app.rawStatus(.POST, "/v1/tasks", body: tb, token: u.token) }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertTrue(results.allSatisfy { $0 == .created }, "\(results)")
        let cols = try await a.json(.GET, "/v1/projects/\(p)/columns", token: u.token)
        XCTAssertEqual(cols.list?.compactMap { $0["position"] as? Int }, Array(0..<12))
        let brd = try await board(b, u.token, p)
        let c2tasks = (brd["columns"] as! [[String: Any]]).first { $0["id"] as? String == c2["id"] as? String }
        let positions = (c2tasks?["tasks"] as? [[String: Any]])?.compactMap { $0["boardPosition"] as? Int } ?? []
        XCTAssertEqual(positions, Array(0..<positions.count))
        XCTAssertEqual(positions.count, 11)
    }
}
