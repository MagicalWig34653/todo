import Fluent
import XCTVapor
@testable import TodoKit

/// Subtask links must never carry reads across a project boundary (moved children, legacy cross-project links).
final class SubtaskLinkSecurityTests: XCTestCase {
    private func account(_ t: TestApp) async throws -> (id: String, token: String) {
        let user = User(displayName: "Test", isAdmin: false)
        try await user.save(on: t.app.db)
        let token = AuthSupport.randomToken()
        try await UserSession(userID: user.requireID(), tokenHash: AuthSupport.hash(token),
            expiresAt: Date().addingTimeInterval(3600)).save(on: t.app.db)
        return (try user.requireID().uuidString, token)
    }

    private func project(_ t: TestApp, _ token: String) async throws -> String {
        let r = try await t.json(.POST, "/v1/projects", ["name": "P"], token: token)
        return try XCTUnwrap(r.body?["id"] as? String)
    }

    private func task(_ t: TestApp, _ token: String, _ pid: String, _ title: String) async throws -> String {
        let r = try await t.json(.POST, "/v1/tasks", ["projectID": pid, "title": title], token: token)
        XCTAssertEqual(r.status, .created, "\(String(describing: r.body))")
        return try XCTUnwrap(r.body?["id"] as? String)
    }

    private struct World {
        let t: TestApp; let owner: (id: String, token: String); let reader: (id: String, token: String)
        let shared: String; let hidden: String; let parent: String; let child: String
    }

    private func world() async throws -> World {
        let t = try await TestApp.make()
        let owner = try await account(t), reader = try await account(t)
        let shared = try await project(t, owner.token), hidden = try await project(t, owner.token)
        let g = try await t.json(.PUT, "/v1/projects/\(shared)/grants", ["principalType": "person", "principalID": reader.id, "role": "read"], token: owner.token)
        XCTAssertEqual(g.status, .ok)
        let parent = try await task(t, owner.token, shared, "Parent")
        let child = try await task(t, owner.token, shared, "Secret child")
        let s = try await t.json(.PUT, "/v1/tasks/\(child)/structure", ["parentTaskID": parent], token: owner.token)
        XCTAssertEqual(s.status, .ok, "\(String(describing: s.body))")
        return World(t: t, owner: owner, reader: reader, shared: shared, hidden: hidden, parent: parent, child: child)
    }

    private func version(_ w: World, _ id: String) async throws -> Int {
        let row = try await TodoTask.find(UUID(uuidString: id), on: w.t.app.db)
        return try XCTUnwrap(row).version
    }

    private func assertNoLeak(_ w: World, file: StaticString = #filePath, line: UInt = #line) async throws {
        let ctx = try await w.t.json(.GET, "/v1/tasks/\(w.parent)/context", token: w.reader.token)
        XCTAssertEqual(ctx.status, .ok, file: file, line: line)
        XCTAssertEqual((ctx.body?["subtasks"] as? [Any])?.count ?? 0, 0, "child leaked via context", file: file, line: line)
        XCTAssertFalse(String(describing: ctx.body).contains("Secret child"), file: file, line: line)
        for q in ["view=list&includeSubtasks=true", "view=kanban", ""] {
            let cc = try await w.t.json(.GET, "/v1/command-center?\(q)", token: w.reader.token)
            XCTAssertEqual(cc.status, .ok, q, file: file, line: line)
            XCTAssertFalse(String(describing: cc.body).contains("Secret child"), "child leaked via command center \(q)", file: file, line: line)
        }
    }

    func testMovedChildIsUnlinkedAndNotReadableThroughOldParent() async throws {
        let w = try await world()
        defer { Task { await w.t.shutdown() } }
        let before = try await w.t.json(.GET, "/v1/tasks/\(w.parent)/context", token: w.reader.token)
        XCTAssertEqual((before.body?["subtasks"] as? [Any])?.count, 1)
        let v = try await version(w, w.child)
        let moved = try await w.t.json(.PATCH, "/v1/tasks/\(w.child)", ["version": v, "projectID": w.hidden], token: w.owner.token)
        XCTAssertEqual(moved.status, .ok)
        let wf = try await TaskWorkflow.find(UUID(uuidString: w.child), on: w.t.app.db)
        XCTAssertNil(wf?.parentTaskID, "the link must be removed on move")
        try await assertNoLeak(w)
    }

    func testMovedParentReleasesItsChildren() async throws {
        let w = try await world()
        defer { Task { await w.t.shutdown() } }
        let v = try await version(w, w.parent)
        let moved = try await w.t.json(.PATCH, "/v1/tasks/\(w.parent)", ["version": v, "projectID": w.hidden], token: w.owner.token)
        XCTAssertEqual(moved.status, .ok)
        let wf = try await TaskWorkflow.find(UUID(uuidString: w.child), on: w.t.app.db)
        XCTAssertNil(wf?.parentTaskID)
    }

    func testLegacyCrossProjectLinkDoesNotLeakAndDoesNotCrash() async throws {
        let w = try await world()
        defer { Task { await w.t.shutdown() } }
        // Simulate data from before the fix: child row moved to another project, link kept.
        let found = try await TodoTask.find(UUID(uuidString: w.child), on: w.t.app.db)
        let row = try XCTUnwrap(found)
        row.projectID = try XCTUnwrap(UUID(uuidString: w.hidden))
        try await row.save(on: w.t.app.db)
        try await assertNoLeak(w)
        // The owner (sees both projects) must not crash either.
        for q in ["view=list&includeSubtasks=true", "view=kanban", ""] {
            let cc = try await w.t.json(.GET, "/v1/command-center?\(q)", token: w.owner.token)
            XCTAssertEqual(cc.status, .ok, q)
        }
        let ctx = try await w.t.json(.GET, "/v1/tasks/\(w.parent)/context", token: w.owner.token)
        XCTAssertEqual((ctx.body?["subtasks"] as? [Any])?.count ?? 0, 0)
    }

    func testMigrationClearsExistingCrossProjectLinks() async throws {
        let w = try await world()
        defer { Task { await w.t.shutdown() } }
        let found = try await TodoTask.find(UUID(uuidString: w.child), on: w.t.app.db)
        let row = try XCTUnwrap(found)
        row.projectID = try XCTUnwrap(UUID(uuidString: w.hidden))
        try await row.save(on: w.t.app.db)
        try await ClearCrossProjectSubtaskLinks().prepare(on: w.t.app.db)
        let wf = try await TaskWorkflow.find(UUID(uuidString: w.child), on: w.t.app.db)
        XCTAssertNil(wf?.parentTaskID)
    }
}
