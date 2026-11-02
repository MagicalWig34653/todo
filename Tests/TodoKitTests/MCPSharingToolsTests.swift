import Fluent
import XCTVapor
@testable import TodoKit

final class MCPSharingToolsTests: XCTestCase {
    private struct Called { let isError: Bool; let text: String; let json: Any? }
    private func call(_ f: OAuthFixture, _ name: String, _ args: [String: Any] = [:], _ access: String) async throws -> Called {
        let r = try await f.rpc("tools/call", ["name": name, "arguments": args], access: access)
        let result = try XCTUnwrap(r.body?["result"] as? [String: Any], String(describing: r.body))
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        return Called(isError: result["isError"] as? Bool ?? false, text: text, json: try? JSONSerialization.jsonObject(with: Data(text.utf8)))
    }
    private let all = "projects:read tasks:read sharing:read sharing:write teams:read teams:write"
    private func fixture(scope: String? = nil, _ run: (OAuthFixture, String) async throws -> Void) async throws {
        let f = try await OAuthFixture.make()
        do { let t = try await f.tokens(scope: scope ?? all); try await run(f, t.access) }
        catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }
    private func person(_ f: OAuthFixture, _ name: String) async throws -> User {
        let u = User(displayName: name, isAdmin: false); try await u.save(on: f.test.app.db); return u
    }
    private func team(_ f: OAuthFixture, name: String = "Crew", members: [User] = []) async throws -> Team {
        let db = f.test.app.db
        let t = Team(name: name, founderID: try f.user.requireID()); try await t.save(on: db)
        try await TeamMembership(teamID: t.requireID(), userID: f.user.requireID(), isAdmin: true, accepted: true).save(on: db)
        for m in members { try await TeamMembership(teamID: t.requireID(), userID: m.requireID(), isAdmin: false, accepted: true).save(on: db) }
        return t
    }
    private func grantCount(_ f: OAuthFixture) async throws -> Int { try await ProjectGrant.query(on: f.test.app.db).count() }
    private func isConfirmation(_ c: Called) -> Bool { c.isError && (c.json as? [String: Any])?["error"] as? String == "confirmation_required" }
    private func requestID(_ c: Called) throws -> UUID {
        try XCTUnwrap(UUID(uuidString: try XCTUnwrap((c.json as? [String: Any])?["actionRequestID"] as? String)))
    }

    func testRegistrationAndScopes() {
        for n in ["list_project_grants", "get_project_visibility", "set_project_grant", "revoke_project_grant", "list_teams", "list_team_members", "create_team", "invite_team_member"] {
            XCTAssertTrue(MCPController.tools.contains { $0.name == n }, n)
        }
        for s in ["sharing:read", "sharing:write", "teams:read", "teams:write"] { XCTAssertTrue(OAuthController.scopes.contains(s), s) }
    }

    func testReadsGrantsVisibilityAndGrantBoundary() async throws {
        try await fixture { f, access in
            let pid = try f.project.requireID().uuidString
            let friend = try await self.person(f, "Friend")
            try await ProjectGrant(projectID: f.project.requireID(), principalType: "person", principalID: friend.requireID(), role: .edit).save(on: f.test.app.db)
            let grants = try await self.call(f, "list_project_grants", ["projectID": pid], access)
            XCTAssertFalse(grants.isError, grants.text)
            let list = try XCTUnwrap(grants.json as? [[String: Any]])
            XCTAssertEqual(list.count, 1); XCTAssertEqual(list[0]["principalName"] as? String, "Friend")
            let vis = try await self.call(f, "get_project_visibility", ["projectID": pid], access)
            XCTAssertEqual((vis.json as? [String: Any])?["role"] as? String, "manage")
            let other = try await self.call(f, "get_project_visibility", ["projectID": pid, "userID": try friend.requireID().uuidString], access)
            XCTAssertEqual((other.json as? [String: Any])?["role"] as? String, "edit")
            let out = try await self.call(f, "list_project_grants", ["projectID": try f.other.requireID().uuidString], access)
            XCTAssertEqual(out.text, "not_found")
            let out2 = try await self.call(f, "get_project_visibility", ["projectID": UUID().uuidString], access)
            XCTAssertEqual(out2.text, "not_found")
        }
    }

    func testMissingScopeHidesAndBlocksTools() async throws {
        try await fixture(scope: "projects:read tasks:read") { f, access in
            let r = try await self.call(f, "list_project_grants", ["projectID": try f.project.requireID().uuidString], access)
            XCTAssertTrue(r.isError); XCTAssertEqual(r.text, "insufficient_scope")
            let list = try await f.rpc("tools/list", access: access)
            let names = ((list.body?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            XCTAssertFalse(names.contains("set_project_grant"))
            XCTAssertFalse(names.contains("list_teams"))
        }
    }

    func testMissingRoleIsForbidden() async throws {
        try await fixture { f, access in
            let owner = try await self.person(f, "Owner")
            let p = try f.project.requireID()
            let sharing = try ProjectSharing(project: f.project); sharing.ownerID = try owner.requireID()
            try await sharing.save(on: f.test.app.db)
            try await ProjectGrant(projectID: p, principalType: "person", principalID: f.user.requireID(), role: .read).save(on: f.test.app.db)
            let r = try await self.call(f, "list_project_grants", ["projectID": p.uuidString], access)
            XCTAssertTrue(r.isError); XCTAssertEqual(r.text, "Forbidden")
            let s = try await self.call(f, "set_project_grant", ["projectID": p.uuidString, "principalType": "person", "principalID": try owner.requireID().uuidString, "role": "read"], access)
            XCTAssertEqual(s.text, "Forbidden")
        }
    }

    func testSetGrantDirectForOwnTeamAndColleagueAndReplacesRole() async throws {
        try await fixture { f, access in
            let pid = try f.project.requireID().uuidString
            let colleague = try await self.person(f, "Colleague")
            let t = try await self.team(f, members: [colleague])
            let viaTeam = try await self.call(f, "set_project_grant", ["projectID": pid, "principalType": "team", "principalID": try t.requireID().uuidString, "role": "edit"], access)
            XCTAssertFalse(viaTeam.isError, viaTeam.text)
            XCTAssertEqual((viaTeam.json as? [String: Any])?["principalName"] as? String, "Crew")
            let cid = try colleague.requireID().uuidString
            let viaPerson = try await self.call(f, "set_project_grant", ["projectID": pid, "principalType": "person", "principalID": cid, "role": "read"], access)
            XCTAssertFalse(viaPerson.isError, viaPerson.text)
            let again = try await self.call(f, "set_project_grant", ["projectID": pid, "principalType": "person", "principalID": cid, "role": "comment"], access)
            XCTAssertFalse(again.isError, again.text)
            let count = try await self.grantCount(f)
            XCTAssertEqual(count, 2)
            let row = try await ProjectGrant.query(on: f.test.app.db).filter(\.$principalType == "person").first()
            XCTAssertEqual(row?.role, .comment)
        }
    }

    func testStrangerManageRoleAndForeignSubprojectNeedConfirmation() async throws {
        try await fixture { f, access in
            let pid = try f.project.requireID().uuidString
            let stranger = try await self.person(f, "Stranger")
            let colleague = try await self.person(f, "Colleague")
            _ = try await self.team(f, members: [colleague])
            let sid = try stranger.requireID().uuidString, cid = try colleague.requireID().uuidString
            let a = try await self.call(f, "set_project_grant", ["projectID": pid, "principalType": "person", "principalID": sid, "role": "read"], access)
            XCTAssertTrue(self.isConfirmation(a), a.text)
            let b = try await self.call(f, "set_project_grant", ["projectID": pid, "principalType": "person", "principalID": cid, "role": "manage"], access)
            XCTAssertTrue(self.isConfirmation(b), b.text)
            let child = Project(ownerID: try f.user.requireID(), parentID: try f.project.requireID(), name: "Child")
            try await child.save(on: f.test.app.db)
            let c = try await self.call(f, "set_project_grant", ["projectID": pid, "principalType": "person", "principalID": cid, "role": "read"], access)
            XCTAssertTrue(self.isConfirmation(c), c.text)
            let count = try await self.grantCount(f)
            XCTAssertEqual(count, 0)
            let again = try await self.call(f, "set_project_grant", ["projectID": pid, "principalType": "person", "principalID": sid, "role": "read"], access)
            XCTAssertEqual(try self.requestID(again), try self.requestID(a))
            let done = try await ActionRequestService(user: f.user, db: f.test.app.db).confirm(try self.requestID(a))
            XCTAssertEqual(done.state, "executed"); XCTAssertEqual(done.result?.code, "grant_set")
            let after = try await self.grantCount(f)
            XCTAssertEqual(after, 1)
        }
    }

    func testBrokenInputsAndUnknownPrincipals() async throws {
        try await fixture { f, access in
            let pid = try f.project.requireID().uuidString
            let bad: [[String: Any]] = [
                ["projectID": pid, "principalType": "group", "principalID": UUID().uuidString, "role": "read"],
                ["projectID": pid, "principalType": "person", "principalID": "x", "role": "read"],
                ["projectID": pid, "principalType": "person", "principalID": UUID().uuidString, "role": "owner"],
                ["projectID": pid, "principalType": "person", "principalID": UUID().uuidString, "role": 5],
                ["projectID": 1, "principalType": "person", "principalID": UUID().uuidString, "role": "read"],
                ["projectID": pid, "principalType": "person", "principalID": UUID().uuidString],
                ["projectID": pid, "principalType": "person", "principalID": UUID().uuidString, "role": "read", "extra": 1]]
            for args in bad { let r = try await self.call(f, "set_project_grant", args, access); XCTAssertTrue(r.isError, r.text) }
            let ghost = try await self.call(f, "set_project_grant", ["projectID": pid, "principalType": "person", "principalID": UUID().uuidString, "role": "read"], access)
            XCTAssertEqual(ghost.text, "not_found")
            let foreignTeam = Team(name: "Foreign", founderID: try await self.person(f, "Foreigner").requireID()); try await foreignTeam.save(on: f.test.app.db)
            let ft = try await self.call(f, "set_project_grant", ["projectID": pid, "principalType": "team", "principalID": try foreignTeam.requireID().uuidString, "role": "read"], access)
            XCTAssertEqual(ft.text, "not_found")
            for v: Any in [0, 1.5, 1e40, "1"] {
                let r = try await self.call(f, "revoke_project_grant", ["projectID": pid, "grantID": UUID().uuidString, "version": v], access)
                XCTAssertTrue(r.isError); XCTAssertFalse(self.isConfirmation(r), r.text)
            }
            let count = try await self.grantCount(f)
            XCTAssertEqual(count, 0)
        }
    }

    func testRevokeIsOnlyARequestAndVersionConflictOnConfirm() async throws {
        try await fixture { f, access in
            let pid = try f.project.requireID()
            let friend = try await self.person(f, "Friend")
            let g = ProjectGrant(projectID: pid, principalType: "person", principalID: try friend.requireID(), role: .edit)
            try await g.save(on: f.test.app.db)
            let r = try await self.call(f, "revoke_project_grant", ["projectID": pid.uuidString, "grantID": try g.requireID().uuidString, "version": f.project.version], access)
            XCTAssertTrue(self.isConfirmation(r), r.text)
            let still = try await self.grantCount(f)
            XCTAssertEqual(still, 1)
            let missing = try await self.call(f, "revoke_project_grant", ["projectID": pid.uuidString, "grantID": UUID().uuidString], access)
            XCTAssertEqual(missing.text, "not_found")
            f.project.version += 1; try await f.project.save(on: f.test.app.db)
            let done = try await ActionRequestService(user: f.user, db: f.test.app.db).confirm(try self.requestID(r))
            XCTAssertEqual(done.state, "failed"); XCTAssertEqual(done.result?.code, "version_conflict")
            let kept = try await self.grantCount(f)
            XCTAssertEqual(kept, 1)
            let r2 = try await self.call(f, "revoke_project_grant", ["projectID": pid.uuidString, "grantID": try g.requireID().uuidString], access)
            let ok = try await ActionRequestService(user: f.user, db: f.test.app.db).confirm(try self.requestID(r2))
            XCTAssertEqual(ok.result?.code, "grant_revoked")
            let gone = try await self.grantCount(f)
            XCTAssertEqual(gone, 0)
        }
    }

    func testTeamsCreateInviteListAndAdminInviteNeedsConfirmation() async throws {
        try await fixture { f, access in
            let created = try await self.call(f, "create_team", ["name": "  Alpha  "], access)
            XCTAssertFalse(created.isError, created.text)
            let tid = try XCTUnwrap((created.json as? [String: Any])?["id"] as? String)
            XCTAssertEqual((created.json as? [String: Any])?["name"] as? String, "Alpha")
            for name: Any in ["", "   ", String(repeating: "x", count: 201), 5] {
                let r = try await self.call(f, "create_team", ["name": name], access); XCTAssertTrue(r.isError, r.text)
            }
            let teams = try await self.call(f, "list_teams", [:], access)
            XCTAssertEqual((teams.json as? [[String: Any]])?.count, 1)
            let invitee = try await self.person(f, "Invitee")
            let iid = try invitee.requireID().uuidString
            let inv = try await self.call(f, "invite_team_member", ["teamID": tid, "userID": iid], access)
            XCTAssertFalse(inv.isError, inv.text)
            XCTAssertEqual((inv.json as? [String: Any])?["accepted"] as? Bool, false)
            let members = try await self.call(f, "list_team_members", ["teamID": tid], access)
            let names = (members.json as? [[String: Any]])?.compactMap { $0["displayName"] as? String }.sorted()
            XCTAssertEqual(names, ["Invitee", "OAuth User"])
            let admin = try await self.call(f, "invite_team_member", ["teamID": tid, "userID": iid, "isAdmin": true], access)
            XCTAssertTrue(self.isConfirmation(admin), admin.text)
            let row = try await TeamMembership.query(on: f.test.app.db).filter(\.$userID == invitee.requireID()).first()
            XCTAssertEqual(row?.isAdmin, false)
            let foreign = Team(name: "Foreign", founderID: try await self.person(f, "Foreigner").requireID()); try await foreign.save(on: f.test.app.db)
            let lm = try await self.call(f, "list_team_members", ["teamID": try foreign.requireID().uuidString], access)
            XCTAssertEqual(lm.text, "not_found")
            let it = try await self.call(f, "invite_team_member", ["teamID": try foreign.requireID().uuidString, "userID": iid], access)
            XCTAssertEqual(it.text, "not_found")
            let ghost = try await self.call(f, "invite_team_member", ["teamID": tid, "userID": UUID().uuidString], access)
            XCTAssertEqual(ghost.text, "not_found")
            let badFlag = try await self.call(f, "invite_team_member", ["teamID": tid, "userID": UUID().uuidString, "isAdmin": "yes"], access)
            XCTAssertTrue(badFlag.isError)
        }
    }

    func testInviteRequiresTeamAdmin() async throws {
        try await fixture { f, access in
            let founder = try await self.person(f, "Founder")
            let t = Team(name: "Theirs", founderID: try founder.requireID()); try await t.save(on: f.test.app.db)
            try await TeamMembership(teamID: t.requireID(), userID: founder.requireID(), isAdmin: true, accepted: true).save(on: f.test.app.db)
            try await TeamMembership(teamID: t.requireID(), userID: f.user.requireID(), isAdmin: false, accepted: true).save(on: f.test.app.db)
            let other = try await self.person(f, "Other")
            let r = try await self.call(f, "invite_team_member", ["teamID": try t.requireID().uuidString, "userID": try other.requireID().uuidString], access)
            XCTAssertEqual(r.text, "Forbidden")
        }
    }
}
