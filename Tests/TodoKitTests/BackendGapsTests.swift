import Fluent
import XCTVapor
@testable import TodoKit

/// Activity from planning routes, resolved names, scoped user directory and planning data in task lists.
final class BackendGapsTests: XCTestCase {
    private func account(_ t: TestApp, _ name: String) async throws -> (id: String, token: String) {
        let user = User(displayName: name, isAdmin: false)
        try await user.save(on: t.app.db)
        let token = AuthSupport.randomToken()
        try await UserSession(userID: user.requireID(), tokenHash: AuthSupport.hash(token),
            expiresAt: Date().addingTimeInterval(3600)).save(on: t.app.db)
        return (try user.requireID().uuidString, token)
    }

    private func kinds(_ t: TestApp, _ task: String, _ token: String) async throws -> [String] {
        let r = try await t.json(.GET, "/v1/tasks/\(task)/activity", token: token)
        XCTAssertEqual(r.status, .ok)
        return (r.body?["items"] as? [[String: Any]] ?? []).compactMap { $0["kind"] as? String }
    }

    func testTaskRoutesWriteActivityAndPlanningDataAppearsInList() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let a = try await account(t, "Anna Alpha")
        let project = try await t.json(.POST, "/v1/projects", ["name": "P"], token: a.token)
        let other = try await t.json(.POST, "/v1/projects", ["name": "Q"], token: a.token)
        let pid = try XCTUnwrap(project.body?["id"] as? String)
        let task = try await t.json(.POST, "/v1/tasks", ["projectID": pid, "title": "One"], token: a.token)
        let tid = try XCTUnwrap(task.body?["id"] as? String)
        var version = try XCTUnwrap(task.body?["version"] as? Int)
        var r = try await t.json(.PATCH, "/v1/tasks/\(tid)", ["version": version, "title": "Two"], token: a.token)
        XCTAssertEqual(r.status, .ok)
        version = try XCTUnwrap(r.body?["version"] as? Int)
        r = try await t.json(.PATCH, "/v1/tasks/\(tid)", ["version": version, "status": "in_progress",
            "projectID": try XCTUnwrap(other.body?["id"] as? String)], token: a.token)
        XCTAssertEqual(r.status, .ok)
        // A rejected stale write must not leave an event behind.
        r = try await t.json(.PATCH, "/v1/tasks/\(tid)", ["version": 1, "title": "Stale"], token: a.token)
        XCTAssertEqual(r.status, .conflict)
        // A no-op patch records nothing.
        let current = try await t.json(.GET, "/v1/tasks", token: a.token)
        version = try XCTUnwrap(current.list?.first?["version"] as? Int)
        r = try await t.json(.PATCH, "/v1/tasks/\(tid)", ["version": version, "title": "Two"], token: a.token)
        XCTAssertEqual(r.status, .ok)
        let planning = try await t.json(.PUT, "/v1/planning/tasks/\(tid)", ["priority": 2,
            "dueAt": "2026-11-01T10:00:00Z", "reminders": ["2026-11-01T09:00:00Z"]], token: a.token)
        XCTAssertEqual(planning.status, .ok, "\(planning.body ?? [:])")
        let found = try await kinds(t, tid, a.token)
        XCTAssertEqual(found, ["task.created", "task.updated", "task.status_changed", "task.moved", "task.planning_updated"])

        let list = try await t.json(.GET, "/v1/tasks", token: a.token)
        let entry = try XCTUnwrap(list.list?.first { $0["id"] as? String == tid })
        let summary = try XCTUnwrap(entry["planning"] as? [String: Any])
        XCTAssertEqual(summary["priority"] as? Int, 2)
        XCTAssertEqual(summary["reminderCount"] as? Int, 1)
        XCTAssertEqual(summary["hasRecurrence"] as? Bool, false)
        XCTAssertNotNil(summary["dueAt"])
        // Planning data is only part of the list, not of single-task mutation responses.
        XCTAssertNil(r.body?["planning"])

        // A task without a planning row reports defaults.
        let plain = try await t.json(.POST, "/v1/tasks", ["projectID": pid, "title": "Plain"], token: a.token)
        let again = try await t.json(.GET, "/v1/tasks?projectID=\(pid)", token: a.token)
        let plainSummary = try XCTUnwrap(again.list?.first { $0["id"] as? String == plain.body?["id"] as? String }?["planning"] as? [String: Any])
        XCTAssertEqual(plainSummary["priority"] as? Int, 0)
        XCTAssertNil(plainSummary["dueAt"])
    }

    func testCommentAuthorsAndActivityActorsAreNamed() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let a = try await account(t, "Anna Alpha"), b = try await account(t, "Bert Beta")
        let project = try await t.json(.POST, "/v1/projects", ["name": "P"], token: a.token)
        let pid = try XCTUnwrap(project.body?["id"] as? String)
        let task = try await t.json(.POST, "/v1/tasks", ["projectID": pid, "title": "T"], token: a.token)
        let tid = try XCTUnwrap(task.body?["id"] as? String)
        let grant = try await t.json(.PUT, "/v1/projects/\(pid)/grants", ["principalType": "person", "principalID": b.id, "role": "comment"], token: a.token)
        XCTAssertEqual(grant.status, .ok)
        let created = try await t.json(.POST, "/v1/tasks/\(tid)/comments", ["body": "Hello"], token: b.token)
        XCTAssertEqual(created.status, .created)
        XCTAssertEqual(created.body?["authorName"] as? String, "Bert Beta")
        let comments = try await t.json(.GET, "/v1/tasks/\(tid)/comments", token: a.token)
        XCTAssertEqual(comments.list?.first?["authorName"] as? String, "Bert Beta")
        let activity = try await t.json(.GET, "/v1/tasks/\(tid)/activity", token: a.token)
        let items = try XCTUnwrap(activity.body?["items"] as? [[String: Any]])
        XCTAssertEqual(items.first { $0["kind"] as? String == "comment.created" }?["actorName"] as? String, "Bert Beta")
        XCTAssertEqual(items.first { $0["kind"] as? String == "task.created" }?["actorName"] as? String, "Anna Alpha")
    }

    func testDirectorySearchIsScopedAndInvitationsShowTeamName() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let a = try await account(t, "Anna Alpha"), b = try await account(t, "Berta Alphorn")
        let c = try await account(t, "Carl Alpine"), stranger = try await account(t, "Alpha Stranger")

        // Without a relationship nobody is found, not even by exact name.
        var search = try await t.json(.GET, "/v1/users/search?q=Alp", token: a.token)
        XCTAssertEqual(search.status, .ok)
        XCTAssertEqual(search.list?.count, 0)
        let short = try await t.json(.GET, "/v1/users/search?q=A", token: a.token)
        XCTAssertEqual(short.status, .badRequest)
        let unauthenticated = try await t.json(.GET, "/v1/users/search?q=Alp")
        XCTAssertEqual(unauthenticated.status, .unauthorized)

        // Team admin finds an invited (not yet accepted) person they added; unrelated people stay hidden.
        let team = try await t.json(.POST, "/v1/teams", ["name": "Kernteam"], token: a.token)
        let teamID = try XCTUnwrap(team.body?["id"] as? String)
        // Invitation requires knowing the account ID once; afterwards the directory shows the invitee.
        let invite = try await t.json(.PUT, "/v1/teams/\(teamID)/members", ["userID": b.id, "isAdmin": false], token: a.token)
        XCTAssertEqual(invite.status, .ok)
        search = try await t.json(.GET, "/v1/users/search?q=alp", token: a.token)
        XCTAssertEqual(search.list?.compactMap { $0["displayName"] as? String }, ["Berta Alphorn"])
        XCTAssertEqual(Set(search.list?.first?.keys.map { $0 } ?? []), ["id", "displayName"])

        // The invitee sees the team name, not only the ID; the pending invitee finds nobody before accepting.
        let pending = try await t.json(.GET, "/v1/team-invitations", token: b.token)
        XCTAssertEqual(pending.list?.first?["teamName"] as? String, "Kernteam")
        search = try await t.json(.GET, "/v1/users/search?q=Anna", token: b.token)
        XCTAssertEqual(search.list?.count, 0)
        let accepted = try await t.json(.POST, "/v1/teams/\(teamID)/accept", token: b.token)
        XCTAssertEqual(accepted.status, .noContent)
        search = try await t.json(.GET, "/v1/users/search?q=Anna", token: b.token)
        XCTAssertEqual(search.list?.compactMap { $0["displayName"] as? String }, ["Anna Alpha"])
        let members = try await t.json(.GET, "/v1/teams/\(teamID)/members", token: b.token)
        XCTAssertEqual(Set(members.list?.compactMap { $0["displayName"] as? String } ?? []), ["Anna Alpha", "Berta Alphorn"])

        // Project grants connect a manager to the grantee and the grantee to the owner, but not siblings.
        let project = try await t.json(.POST, "/v1/projects", ["name": "P"], token: a.token)
        let pid = try XCTUnwrap(project.body?["id"] as? String)
        let grant = try await t.json(.PUT, "/v1/projects/\(pid)/grants", ["principalType": "person", "principalID": c.id, "role": "read"], token: a.token)
        XCTAssertEqual(grant.status, .ok)
        search = try await t.json(.GET, "/v1/users/search?q=carl", token: a.token)
        XCTAssertEqual(search.list?.count, 1)
        search = try await t.json(.GET, "/v1/users/search?q=anna", token: c.token)
        XCTAssertEqual(search.list?.count, 1)
        search = try await t.json(.GET, "/v1/users/search?q=berta", token: c.token)
        XCTAssertEqual(search.list?.count, 0)
        search = try await t.json(.GET, "/v1/users/search?q=stranger", token: a.token)
        XCTAssertEqual(search.list?.count, 0)
        _ = stranger
    }
}
