import Fluent
import XCTVapor
@testable import TodoKit

final class SharingTests: XCTestCase {
    private func make() async throws -> TestApp {
        try await TestApp.make()
    }

    private func account(_ t: TestApp) async throws -> (id: String, token: String) {
        let user = User(displayName: "Test", isAdmin: false)
        try await user.save(on: t.app.db)
        let token = AuthSupport.randomToken()
        try await UserSession(userID: user.requireID(), tokenHash: AuthSupport.hash(token),
            expiresAt: Date().addingTimeInterval(3600)).save(on: t.app.db)
        return (try user.requireID().uuidString, token)
    }

    private func project(_ t: TestApp, _ token: String, parent: String? = nil) async throws -> String {
        var body = ["name": "Project"]
        body["parentID"] = parent
        let result = try await t.json(.POST, "/v1/projects", body, token: token)
        XCTAssertEqual(result.status, .created)
        return try XCTUnwrap(result.body?["id"] as? String)
    }

    @discardableResult private func grant(_ t: TestApp, _ token: String, _ pid: String,
        _ principal: String, role: String, type: String = "person"
    ) async throws -> String {
        let result = try await t.json(.PUT, "/v1/projects/\(pid)/grants", [
            "principalType": type, "principalID": principal, "role": role,
        ], token: token)
        XCTAssertEqual(result.status, .ok)
        return try XCTUnwrap(result.body?["id"] as? String)
    }

    func testSQLiteAppsAreIsolatedAndReplicasShareTheSameDatabase() async throws {
        try XCTSkipIf(TestApp.useMariaDB, "checks the SQLite test fixture")
        let original = try await make()
        let replica = try await original.replica()
        let independent = try await make()
        defer { Task { await original.shutdown(); await replica.shutdown(); await independent.shutdown() } }
        let owner = try await account(original)
        let pid = try await project(original, owner.token)
        let shared = try await replica.json(.GET, "/v1/projects", token: owner.token)
        XCTAssertEqual(shared.status, .ok)
        XCTAssertEqual(shared.list?.first?["id"] as? String, pid)
        let isolated = try await independent.json(.GET, "/v1/projects", token: owner.token)
        XCTAssertEqual(isolated.status, .unauthorized)
    }

    func testTeamRevocationPreservesOnlyTheIndependentDirectGrant() async throws {
        let t = try await make()
        defer { Task { await t.shutdown() } }
        let owner = try await account(t), guest = try await account(t)
        let root = try await project(t, owner.token)
        let leaf = try await project(t, owner.token, parent: root)
        let team = try await t.json(.POST, "/v1/teams", ["name": "Shared"], token: owner.token)
        let tid = try XCTUnwrap(team.body?["id"] as? String)
        _ = try await t.json(.PUT, "/v1/teams/\(tid)/members", ["userID": guest.id, "isAdmin": false], token: owner.token)
        _ = try await t.json(.POST, "/v1/teams/\(tid)/accept", token: guest.token)
        try await grant(t, owner.token, root, tid, role: "edit", type: "team")
        let direct = try await grant(t, owner.token, leaf, guest.id, role: "read")
        let inherited = try await t.json(.GET, "/v1/projects/\(leaf)/visibility", token: guest.token)
        XCTAssertEqual(inherited.body?["role"] as? String, "edit")
        let revoke = try await t.json(.DELETE, "/v1/teams/\(tid)/members/\(guest.id)", token: owner.token)
        XCTAssertEqual(revoke.status, .noContent)
        let visible = try await t.json(.GET, "/v1/projects", token: guest.token)
        XCTAssertEqual(visible.list?.count, 1)
        XCTAssertEqual(visible.list?.first?["id"] as? String, leaf)
        XCTAssertNil(visible.list?.first?["parentID"] as? String)
        let remaining = try await t.json(.GET, "/v1/projects/\(leaf)/visibility", token: guest.token)
        XCTAssertEqual(remaining.body?["role"] as? String, "read")
        let denied = try await t.json(.POST, "/v1/tasks", ["projectID": leaf, "title": "Denied"], token: guest.token)
        XCTAssertEqual(denied.status, .forbidden)
        _ = try await t.json(.DELETE, "/v1/projects/\(leaf)/grants/\(direct)", token: owner.token)
        let gone = try await t.json(.GET, "/v1/projects/\(leaf)/visibility", token: guest.token)
        XCTAssertEqual(gone.status, .notFound)
    }

    func testRoleMatrixAndIndependentCapabilities() async throws {
        let t = try await make()
        defer { Task { await t.shutdown() } }
        let owner = try await account(t), guest = try await account(t)
        let pid = try await project(t, owner.token)
        let task = try await t.json(.POST, "/v1/tasks", ["projectID": pid, "title": "Shared"], token: owner.token)
        let taskID = try XCTUnwrap(task.body?["id"] as? String)
        var version = 1
        for (role, editable, manageable) in [("read", false, false), ("comment", false, false), ("edit", true, false), ("manage", true, true)] {
            try await grant(t, owner.token, pid, guest.id, role: role)
            let list = try await t.json(.GET, "/v1/tasks", token: guest.token)
            XCTAssertTrue(list.list?.contains { $0["id"] as? String == taskID } ?? false)
            let creation = try await t.json(.POST, "/v1/tasks", ["projectID": pid, "title": role], token: guest.token)
            XCTAssertEqual(creation.status, editable ? .created : .forbidden, role)
            let subproject = try await t.json(.POST, "/v1/projects", ["name": role, "parentID": pid], token: guest.token)
            XCTAssertEqual(subproject.status, manageable ? .created : .forbidden, role)
            let edit = try await t.json(.PATCH, "/v1/tasks/\(taskID)", ["version": version, "title": role], token: guest.token)
            XCTAssertEqual(edit.status, editable ? .ok : .forbidden, role)
            if editable { version += 1 }
            let grants = try await t.json(.GET, "/v1/projects/\(pid)/grants", token: guest.token)
            XCTAssertEqual(grants.status, manageable ? .ok : .forbidden, role)
            let deletion = try await t.json(.DELETE, "/v1/projects/\(pid)", token: guest.token)
            XCTAssertEqual(deletion.status, .forbidden, role)
            let taskDeletion = try await t.json(.DELETE, "/v1/tasks/\(taskID)", token: guest.token)
            XCTAssertEqual(taskDeletion.status, .forbidden, role)
            let transfer = try await t.json(.PUT, "/v1/projects/\(pid)/owner", ["version": 1, "ownerType": "person", "ownerID": guest.id], token: guest.token)
            XCTAssertEqual(transfer.status, .forbidden, role)
            let visibility = try await t.json(.GET, "/v1/projects/\(pid)/visibility", token: guest.token)
            XCTAssertEqual(visibility.body?["role"] as? String, role)
            for flag in ["canTransferOwnership", "canDelete", "canManageTeam", "canStartAgent"] {
                XCTAssertEqual(visibility.body?[flag] as? Bool, false, flag)
            }
        }
    }

    func testIsolatedChildRedactsParentAndRevokesImmediately() async throws {
        let t = try await make()
        defer { Task { await t.shutdown() } }
        let owner = try await account(t), guest = try await account(t)
        let root = try await project(t, owner.token)
        let child = try await project(t, owner.token, parent: root)
        let sibling = try await project(t, owner.token, parent: root)
        for pid in [root, child, sibling] {
            _ = try await t.json(.POST, "/v1/tasks", ["projectID": pid, "title": "Private"], token: owner.token)
        }
        let gid = try await grant(t, owner.token, child, guest.id, role: "manage")
        let projects = try await t.json(.GET, "/v1/projects", token: guest.token)
        XCTAssertEqual(projects.list?.count, 1)
        XCTAssertNil(projects.list?.first?["parentID"] as? String)
        let tasks = try await t.json(.GET, "/v1/tasks", token: guest.token)
        XCTAssertEqual(tasks.list?.count, 1)
        let taskID = try XCTUnwrap(tasks.list?.first?["id"] as? String)
        let hiddenMove = try await t.json(.PATCH, "/v1/tasks/\(taskID)", ["version": 1, "projectID": sibling], token: guest.token)
        XCTAssertEqual(hiddenMove.status, .notFound)
        for pid in [root, sibling] {
            let probe = try await t.json(.GET, "/v1/tasks?projectID=\(pid)", token: guest.token)
            XCTAssertEqual(probe.status, .notFound)
        }
        let rename = try await t.json(.PATCH, "/v1/projects/\(child)", ["version": 1, "name": "Visible"], token: guest.token)
        XCTAssertEqual(rename.status, .ok)
        XCTAssertNil(rename.body?["parentID"] as? String)
        let inspect = try await t.json(.GET, "/v1/projects/\(child)/visibility?userID=\(guest.id)", token: owner.token)
        XCTAssertEqual(inspect.body?["role"] as? String, "manage")
        let revoke = try await t.json(.DELETE, "/v1/projects/\(child)/grants/\(gid)", token: owner.token)
        XCTAssertEqual(revoke.status, .noContent)
        let after = try await t.json(.GET, "/v1/tasks", token: guest.token)
        XCTAssertEqual(after.list?.count, 0)
        let revokedWrite = try await t.json(.PATCH, "/v1/tasks/\(taskID)", ["version": 1, "title": "Denied"], token: guest.token)
        XCTAssertEqual(revokedWrite.status, .notFound)
        let denied = try await t.json(.GET, "/v1/projects/\(child)/visibility", token: guest.token)
        XCTAssertEqual(denied.status, .notFound)
        let inspectedAfter = try await t.json(.GET, "/v1/projects/\(child)/visibility?userID=\(guest.id)", token: owner.token)
        XCTAssertEqual(inspectedAfter.status, .ok)
        XCTAssertNil(inspectedAfter.body?["role"] as? String)
    }

    func testRestrictionPreservesDirectGrantsAndCutsAncestorGrants() async throws {
        let t = try await make()
        defer { Task { await t.shutdown() } }
        let owner = try await account(t), guest = try await account(t)
        let root = try await project(t, owner.token)
        let child = try await project(t, owner.token, parent: root)
        let leaf = try await project(t, owner.token, parent: child)
        try await grant(t, owner.token, root, guest.id, role: "manage")
        try await grant(t, owner.token, child, guest.id, role: "read")
        let before = try await t.json(.GET, "/v1/projects/\(leaf)/visibility", token: guest.token)
        XCTAssertEqual(before.body?["role"] as? String, "manage")
        let restrict = try await t.json(.PUT, "/v1/projects/\(child)/inheritance", ["version": 1, "inherits": false], token: owner.token)
        XCTAssertEqual(restrict.status, .ok)
        for pid in [child, leaf] {
            let result = try await t.json(.GET, "/v1/projects/\(pid)/visibility", token: guest.token)
            XCTAssertEqual(result.body?["role"] as? String, "read")
        }
        let stale = try await t.json(.PUT, "/v1/projects/\(child)/inheritance", ["version": 1, "inherits": true], token: owner.token)
        XCTAssertEqual(stale.status, .conflict)
        let cycle = try await t.json(.PATCH, "/v1/projects/\(root)", ["version": 1, "parentID": leaf], token: owner.token)
        XCTAssertEqual(cycle.status, .unprocessableEntity)
    }

    func testTeamInvitationAcceptanceRevocationAndOwnership() async throws {
        let t = try await make()
        defer { Task { await t.shutdown() } }
        let owner = try await account(t), guest = try await account(t), outsider = try await account(t)
        let team = try await t.json(.POST, "/v1/teams", ["name": "Team"], token: owner.token)
        let tid = try XCTUnwrap(team.body?["id"] as? String)
        let pid = try await project(t, owner.token)
        let teamGrant = try await grant(t, owner.token, pid, tid, role: "edit", type: "team")
        let invite = try await t.json(.PUT, "/v1/teams/\(tid)/members", ["userID": guest.id, "isAdmin": false], token: owner.token)
        XCTAssertEqual(invite.status, .ok)
        let pending = try await t.json(.GET, "/v1/projects/\(pid)/visibility", token: guest.token)
        XCTAssertEqual(pending.status, .notFound)
        let invitations = try await t.json(.GET, "/v1/team-invitations", token: guest.token)
        XCTAssertEqual(invitations.list?.count, 1)
        let forgedAccept = try await t.json(.POST, "/v1/teams/\(tid)/accept", token: outsider.token)
        XCTAssertEqual(forgedAccept.status, .notFound)
        let founderRemoval = try await t.json(.DELETE, "/v1/teams/\(tid)/members/\(owner.id)", token: owner.token)
        XCTAssertEqual(founderRemoval.status, .conflict)
        let accept = try await t.json(.POST, "/v1/teams/\(tid)/accept", token: guest.token)
        XCTAssertEqual(accept.status, .noContent)
        let visible = try await t.json(.GET, "/v1/projects/\(pid)/visibility", token: guest.token)
        XCTAssertEqual(visible.body?["role"] as? String, "edit")
        let denied = try await t.json(.PUT, "/v1/teams/\(tid)/members", ["userID": outsider.id, "isAdmin": true], token: guest.token)
        XCTAssertEqual(denied.status, .forbidden)
        let probe = try await t.json(.GET, "/v1/teams/\(tid)/members", token: outsider.token)
        XCTAssertEqual(probe.status, .notFound)
        let remove = try await t.json(.DELETE, "/v1/teams/\(tid)/members/\(guest.id)", token: owner.token)
        XCTAssertEqual(remove.status, .noContent)
        let revoked = try await t.json(.GET, "/v1/projects/\(pid)/visibility", token: guest.token)
        XCTAssertEqual(revoked.status, .notFound)
        let transfer = try await t.json(.PUT, "/v1/projects/\(pid)/owner", ["version": 1, "ownerType": "team", "ownerID": tid], token: owner.token)
        XCTAssertEqual(transfer.body?["canDelete"] as? Bool, true)
        _ = try await t.json(.DELETE, "/v1/projects/\(pid)/grants/\(teamGrant)", token: owner.token)
        _ = try await t.json(.PUT, "/v1/teams/\(tid)/members", ["userID": guest.id, "isAdmin": false], token: owner.token)
        _ = try await t.json(.POST, "/v1/teams/\(tid)/accept", token: guest.token)
        let teamOwned = try await t.json(.GET, "/v1/projects/\(pid)/visibility", token: guest.token)
        XCTAssertEqual(teamOwned.body?["role"] as? String, "read")
        XCTAssertEqual(teamOwned.body?["canTransferOwnership"] as? Bool, false)
        let personal = try await project(t, owner.token)
        let teamList = try await t.json(.GET, "/v1/projects", token: guest.token)
        XCTAssertFalse(teamList.list?.contains { $0["id"] as? String == personal } ?? true)
    }

    func testOwnershipTransferRemovesCreatorAccessAndProtectsSubtree() async throws {
        let t = try await make()
        defer { Task { await t.shutdown() } }
        let owner = try await account(t), guest = try await account(t)
        let root = try await project(t, owner.token), child = try await project(t, owner.token, parent: root)
        let transfer = try await t.json(.PUT, "/v1/projects/\(child)/owner", ["version": 1, "ownerType": "person", "ownerID": guest.id], token: owner.token)
        XCTAssertEqual(transfer.status, .ok)
        let denied = try await t.json(.GET, "/v1/projects/\(child)/visibility", token: owner.token)
        XCTAssertEqual(denied.status, .notFound)
        let deletion = try await t.json(.DELETE, "/v1/projects/\(root)", token: owner.token)
        XCTAssertEqual(deletion.status, .conflict)
        let visible = try await t.json(.GET, "/v1/projects", token: guest.token)
        XCTAssertEqual(visible.list?.count, 1)
        XCTAssertNil(visible.list?.first?["parentID"] as? String)
    }

    func testMariaDBConcurrentOpposingMovesAndGrantUpsertsAcrossReplicas() async throws {
        try XCTSkipUnless(TestApp.useMariaDB, "requires MariaDB")
        let a = try await make(), b = try await a.replica()
        defer { Task { await a.shutdown(); await b.shutdown() } }
        let owner = try await account(a), guest = try await account(a)
        let first = try await project(a, owner.token), second = try await project(a, owner.token)
        let moves = try await withThrowingTaskGroup(of: HTTPStatus.self) { group in
            for (app, source, target) in [(a, first, second), (b, second, first)] {
                let body = try JSONSerialization.data(withJSONObject: ["version": 1, "parentID": target])
                group.addTask { try await app.rawStatus(.PATCH, "/v1/projects/\(source)", body: body, token: owner.token) }
            }
            return try await group.reduce(into: [HTTPStatus]()) { $0.append($1) }
        }
        XCTAssertEqual(moves.filter { $0 == .ok }.count, 1)
        XCTAssertEqual(moves.filter { $0 == .unprocessableEntity }.count, 1)
        let body = try JSONSerialization.data(withJSONObject: ["principalType": "person", "principalID": guest.id, "role": "edit"])
        let grants = try await withThrowingTaskGroup(of: HTTPStatus.self) { group in
            for i in 0..<8 {
                let app = i % 2 == 0 ? a : b
                group.addTask { try await app.rawStatus(.PUT, "/v1/projects/\(first)/grants", body: body, token: owner.token) }
            }
            return try await group.reduce(into: [HTTPStatus]()) { $0.append($1) }
        }
        XCTAssertTrue(grants.allSatisfy { $0 == .ok }, "\(grants)")
        let stored = try await a.json(.GET, "/v1/projects/\(first)/grants", token: owner.token)
        XCTAssertEqual(stored.list?.count, 1)
        let gid = try XCTUnwrap(stored.list?.first?["id"] as? String)
        let revoke = try await a.json(.DELETE, "/v1/projects/\(first)/grants/\(gid)", token: owner.token)
        XCTAssertEqual(revoke.status, .noContent)
        let after = try await b.json(.GET, "/v1/projects/\(first)/visibility", token: guest.token)
        XCTAssertEqual(after.status, .notFound)
    }
}
