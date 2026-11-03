import Fluent
import XCTVapor
@testable import TodoKit

final class ConnectionTests: XCTestCase {
    private func grantID(_ f: OAuthFixture) async throws -> UUID {
        let g = try await OAuthGrant.query(on: f.test.app.db).first()
        return try XCTUnwrap(g?.id)
    }
    private func fixture(_ run: (OAuthFixture, String) async throws -> Void) async throws {
        let f = try await OAuthFixture.make()
        do { let t = try await f.tokens(scope: "projects:read tasks:read tasks:write sharing:read"); try await run(f, t.access) }
        catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }
    private func tool(_ f: OAuthFixture, _ name: String, _ args: [String: Any], _ access: String) async throws -> String {
        let r = try await f.rpc("tools/call", ["name": name, "arguments": args], access: access)
        let result = try XCTUnwrap(r.body?["result"] as? [String: Any], String(describing: r.body))
        return try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
    }
    private func requests(_ f: OAuthFixture) async throws -> [ConnectionAccessRequest] {
        try await ConnectionAccessRequest.query(on: f.test.app.db).all()
    }

    // MARK: Names (task B)

    func testDefaultNameFromClientAndNameChosenOnConsent() async throws {
        let f = try await OAuthFixture.make()
        do {
            let auth = try await f.authorization()
            XCTAssertEqual(auth.body?["default_name"] as? String, "Test Client")
            func consent(_ name: Any?) async throws -> HTTPStatus {
                let a = try await f.authorization()
                var body: [String: Any] = ["consent_token": try XCTUnwrap(a.body?["consent_token"]), "approve": true, "project_ids": [try f.project.requireID().uuidString]]
                if let name { body["connection_name"] = name }
                return try await f.test.json(.POST, "/oauth/consent", body, token: f.session).status
            }
            let bad = try await consent(String(repeating: "x", count: 81))
            XCTAssertEqual(bad, .badRequest)
            let control = try await consent("a\u{0007}b")
            XCTAssertEqual(control, .badRequest)
            let blank = try await consent("   ")
            XCTAssertEqual(blank, .ok)
            let named = try await consent("  Mac mini   Claude Code ")
            XCTAssertEqual(named, .ok)
            let list = try await f.test.json(.GET, "/oauth/grants", token: f.session).list ?? []
            XCTAssertEqual(Set(list.compactMap { $0["name"] as? String }), ["Test Client", "Mac mini Claude Code"])
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testRenameIsOwnerOnlyAndValidated() async throws {
        try await fixture { f, access in
            let gid = try await self.grantID(f)
            let ok = try await f.test.json(.PATCH, "/oauth/grants/\(gid)", ["name": "Build-Mac"], token: f.session)
            XCTAssertEqual(ok.status, .ok); XCTAssertEqual(ok.body?["name"] as? String, "Build-Mac")
            for bad in ["", "   ", String(repeating: "y", count: 81)] {
                let r = try await f.test.json(.PATCH, "/oauth/grants/\(gid)", ["name": bad], token: f.session)
                XCTAssertEqual(r.status, .badRequest, bad)
            }
            let stranger = User(displayName: "Stranger", isAdmin: false); try await stranger.save(on: f.test.app.db)
            let token = AuthSupport.randomToken()
            try await UserSession(userID: stranger.requireID(), tokenHash: AuthSupport.hash(token), expiresAt: Date().addingTimeInterval(3600)).save(on: f.test.app.db)
            let denied = try await f.test.json(.PATCH, "/oauth/grants/\(gid)", ["name": "Mine now"], token: token)
            XCTAssertEqual(denied.status, .notFound)
            let conn = try await self.tool(f, "get_connection", [:], access)
            XCTAssertTrue(conn.contains("Build-Mac"), conn)
            let tmp1 = try await OAuthGrant.find(gid, on: f.test.app.db)?.lastUsedAt
            XCTAssertNotNil(tmp1, "MCP use records last_used_at")
        }
    }

    // MARK: Share dialog (task A)

    func testShareDialogListsAddsAndRemovesConnections() async throws {
        try await fixture { f, _ in
            let pid = try f.project.requireID(), otherPID = try f.other.requireID(), gid = try await self.grantID(f)
            let listed = try await f.test.json(.GET, "/v1/projects/\(pid)/connections", token: f.session)
            XCTAssertEqual(listed.status, .ok)
            let row = try XCTUnwrap(listed.list?.first)
            XCTAssertEqual(row["name"] as? String, "Test Client"); XCTAssertEqual(row["role"] as? String, "manage")
            XCTAssertEqual(row["isOwn"] as? Bool, true); XCTAssertEqual(row["ownerName"] as? String, "OAuth User")
            let tmp2 = (try await f.test.json(.GET, "/v1/projects/\(otherPID)/connections", token: f.session).list ?? []).count
            XCTAssertEqual(tmp2, 0)
            // Add the second project, idempotently.
            for _ in 0..<2 {
                let added = try await f.test.json(.PUT, "/v1/projects/\(otherPID)/connections", ["grantID": gid.uuidString], token: f.session)
                XCTAssertEqual(added.status, .ok); XCTAssertEqual(added.list?.count, 1)
            }
            let tmp3 = Set(try await OAuthGrant.find(gid, on: f.test.app.db)?.projects ?? [])
            XCTAssertEqual(tmp3, [pid, otherPID])
            // Remove access again.
            let gone = try await f.test.json(.DELETE, "/v1/projects/\(otherPID)/connections/\(gid)", token: f.session)
            XCTAssertEqual(gone.status, .noContent)
            let tmp4 = try await OAuthGrant.find(gid, on: f.test.app.db)?.projects
            XCTAssertEqual(tmp4, [pid])
            // The last project of a connection without projects:write cannot be removed here.
            let last = try await f.test.json(.DELETE, "/v1/projects/\(pid)/connections/\(gid)", token: f.session)
            XCTAssertEqual(last.status, .badRequest)
        }
    }

    func testRoleIsCappedByOwnerAndForeignRightsAreRespected() async throws {
        try await fixture { f, _ in
            let db = f.test.app.db, gid = try await self.grantID(f)
            // A project owned by someone else, shared read-only with the connection's owner and managed by a third person.
            let boss = User(displayName: "Boss", isAdmin: false), mgr = User(displayName: "Mgr", isAdmin: false)
            try await boss.save(on: db); try await mgr.save(on: db)
            let project = Project(ownerID: try boss.requireID(), parentID: nil, name: "Shared")
            try await project.save(on: db)
            let pid = try project.requireID()
            try await ProjectGrant(projectID: pid, principalType: "person", principalID: f.user.requireID(), role: .read).save(on: db)
            try await ProjectGrant(projectID: pid, principalType: "person", principalID: mgr.requireID(), role: .manage).save(on: db)
            let g0 = try await OAuthGrant.find(gid, on: db); let g = try XCTUnwrap(g0); g.projects.append(pid); try await g.save(on: db)
            let mgrToken = AuthSupport.randomToken()
            try await UserSession(userID: mgr.requireID(), tokenHash: AuthSupport.hash(mgrToken), expiresAt: Date().addingTimeInterval(3600)).save(on: db)
            // The owner only reads: no manage, so no list for them.
            let denied = try await f.test.json(.GET, "/v1/projects/\(pid)/connections", token: f.session).status
            XCTAssertTrue([HTTPStatus.forbidden, .notFound].contains(denied), "\(denied)")
            // The manager sees the connection with the owner's read role and may remove, not add.
            let list = try await f.test.json(.GET, "/v1/projects/\(pid)/connections", token: mgrToken)
            XCTAssertEqual(list.list?.first?["role"] as? String, "read"); XCTAssertEqual(list.list?.first?["isOwn"] as? Bool, false)
            let tmp5 = try await f.test.json(.PUT, "/v1/projects/\(pid)/connections", ["grantID": gid.uuidString], token: mgrToken).status
            XCTAssertEqual(tmp5, .notFound)
            let tmp6 = try await f.test.json(.DELETE, "/v1/projects/\(pid)/connections/\(gid)", token: mgrToken).status
            XCTAssertEqual(tmp6, .noContent)
            // If the owner loses access, the connection disappears from the list.
            try await ProjectGrant.query(on: db).filter(\.$principalID == f.user.requireID()).delete()
            let g20 = try await OAuthGrant.find(gid, on: db); let g2 = try XCTUnwrap(g20); g2.projects.append(pid); try await g2.save(on: db)
            let tmp7 = try await f.test.json(.GET, "/v1/projects/\(pid)/connections", token: mgrToken).list?.count
            XCTAssertEqual(tmp7, 0)
        }
    }

    // MARK: Access notices (task C)

    func testDeniedProjectIsNotedOncePerConnectionAndAnswerIsUnchanged() async throws {
        try await fixture { f, access in
            let otherPID = try f.other.requireID().uuidString
            let unknown = try await self.tool(f, "list_tasks", ["projectID": UUID().uuidString], access)
            XCTAssertEqual(unknown, "not_found")
            var rows = try await self.requests(f)
            XCTAssertEqual(rows.count, 0, "unknown projects leave nothing behind")
            let first = try await self.tool(f, "list_tasks", ["projectID": otherPID], access)
            XCTAssertEqual(first, "not_found", "same answer as for a project that does not exist")
            let task = TodoTask(ownerID: try f.user.requireID(), projectID: try f.other.requireID(), title: "Hidden")
            try await task.save(on: f.test.app.db)
            let viaTask = try await self.tool(f, "get_task", ["id": try task.requireID().uuidString], access)
            XCTAssertEqual(viaTask, "not_found")
            rows = try await self.requests(f)
            XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows[0].count, 1, "repeats inside the flood interval are not counted")
            XCTAssertEqual(rows[0].state, "open")
            // After the interval a repeat raises the counter.
            let row = rows[0]; row.lastAt = Date().addingTimeInterval(-120); try await row.save(on: f.test.app.db)
            _ = try await self.tool(f, "list_tasks", ["projectID": otherPID], access)
            let tmp8 = try await self.requests(f).first?.count
            XCTAssertEqual(tmp8, 2)
            // The notice shows up in "Für dich" without project contents.
            let feed = try await f.test.json(.GET, "/v1/feed", token: f.session)
            let notice = try XCTUnwrap((feed.body?["accessRequests"] as? [[String: Any]])?.first)
            XCTAssertEqual(notice["connectionName"] as? String, "Test Client"); XCTAssertEqual(notice["projectName"] as? String, "Excluded")
            XCTAssertEqual(notice["count"] as? Int, 2); XCTAssertEqual(notice["role"] as? String, "manage")
            XCTAssertFalse(String(describing: notice).contains("Hidden"))
        }
    }

    func testNothingIsRecordedWhenOwnerCannotReadTheProject() async throws {
        try await fixture { f, access in
            let db = f.test.app.db
            let boss = User(displayName: "Boss", isAdmin: false); try await boss.save(on: db)
            let secret = Project(ownerID: try boss.requireID(), parentID: nil, name: "Secret"); try await secret.save(on: db)
            let answer = try await self.tool(f, "list_tasks", ["projectID": try secret.requireID().uuidString], access)
            XCTAssertEqual(answer, "not_found")
            let tmp9 = try await self.requests(f).count
            XCTAssertEqual(tmp9, 0)
        }
    }

    func testAllowAddsProjectAndIgnoreSilencesIt() async throws {
        try await fixture { f, access in
            let db = f.test.app.db, gid = try await self.grantID(f)
            let otherPID = try f.other.requireID()
            _ = try await self.tool(f, "list_tasks", ["projectID": otherPID.uuidString], access)
            let reqs183 = try await self.requests(f)
            let id = try XCTUnwrap(reqs183.first?.id)
            // A stranger cannot decide.
            let stranger = User(displayName: "S", isAdmin: false); try await stranger.save(on: db)
            let st = AuthSupport.randomToken()
            try await UserSession(userID: stranger.requireID(), tokenHash: AuthSupport.hash(st), expiresAt: Date().addingTimeInterval(3600)).save(on: db)
            let tmp10 = try await f.test.json(.POST, "/v1/connection-access-requests/\(id)/allow", token: st).status
            XCTAssertEqual(tmp10, .notFound)
            let tmp11 = try await f.test.json(.POST, "/v1/connection-access-requests/\(id)/allow", token: f.session).status
            XCTAssertEqual(tmp11, .noContent)
            let g12 = try await OAuthGrant.find(gid, on: db)
            let tmp12 = try XCTUnwrap(g12).projects.contains(otherPID)
            XCTAssertTrue(tmp12)
            let tmp13 = try await self.requests(f).first?.state
            XCTAssertEqual(tmp13, "granted")
            // The agent now reads the project.
            let ok = try await self.tool(f, "list_tasks", ["projectID": otherPID.uuidString], access)
            XCTAssertNotEqual(ok, "not_found")
            let tmp14 = ((try await f.test.json(.GET, "/v1/feed", token: f.session)).body?["accessRequests"] as? [Any])?.count
            XCTAssertEqual(tmp14, 0)
            // Withdraw it again, ask again: ignored notices stay quiet but are counted.
            try await ConnectionService.remove(project: otherPID, grantID: gid, actor: f.user, db: db)
            let reqs203 = try await self.requests(f)
            let row = try XCTUnwrap(reqs203.first); row.lastAt = Date().addingTimeInterval(-120); try await row.save(on: db)
            _ = try await self.tool(f, "list_tasks", ["projectID": otherPID.uuidString], access)
            let tmp15 = try await self.requests(f).first?.state
            XCTAssertEqual(tmp15, "open", "a withdrawn grant reopens the notice")
            let tmp16 = try await f.test.json(.POST, "/v1/connection-access-requests/\(id)/ignore", token: f.session).status
            XCTAssertEqual(tmp16, .noContent)
            let reqs209 = try await self.requests(f)
            let ignored = try XCTUnwrap(reqs209.first); ignored.lastAt = Date().addingTimeInterval(-120); try await ignored.save(on: db)
            _ = try await self.tool(f, "list_tasks", ["projectID": otherPID.uuidString], access)
            let tmp17 = try await self.requests(f).first?.state
            XCTAssertEqual(tmp17, "ignored")
            let tmp18 = ((try await f.test.json(.GET, "/v1/feed", token: f.session)).body?["accessRequests"] as? [Any])?.count
            XCTAssertEqual(tmp18, 0)
        }
    }

    func testCleanupRemovesOldNotices() async throws {
        try await fixture { f, access in
            let db = f.test.app.db
            _ = try await self.tool(f, "list_tasks", ["projectID": try f.other.requireID().uuidString], access)
            let reqs222 = try await self.requests(f)
            let row = try XCTUnwrap(reqs222.first)
            let tmp19 = try await ExpiredCleanup().run(on: db).accessNotices
            XCTAssertEqual(tmp19, 0)
            row.lastAt = Date().addingTimeInterval(-31 * 86_400); try await row.save(on: db)
            let tmp20 = try await ExpiredCleanup().run(on: db).accessNotices
            XCTAssertEqual(tmp20, 1)
            let tmp21 = try await self.requests(f).count
            XCTAssertEqual(tmp21, 0)
        }
    }
}
