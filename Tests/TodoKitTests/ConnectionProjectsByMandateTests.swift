import Fluent
import XCTVapor
@testable import TodoKit

/// Card E71B0FF1 (ADR 0032 addendum 24.11.2026): a connection with an active brain mandate reads and changes the project
/// list of the person's OTHER connections via MCP (`list_connections`, `set_connection_projects`), limited to the projects
/// named in its own mandate. Everything runs through the real `/mcp` interface with OAuth tokens.
final class ConnectionProjectsByMandateTests: XCTestCase {
    struct Env {
        let f: OAuthFixture
        /// The connection that holds (or will hold) the mandate, and the connection whose projects it changes.
        let brain: String, watcher: String
        let brainGrant: UUID, watcherGrant: UUID
        let p1: UUID, p2: UUID, p3: UUID
        /// A connection of another person (no token needed, it is only ever a target).
        let strangerGrant: UUID
    }

    private static let scopes = "projects:read projects:write tasks:read tasks:write comments:write"

    private func env() async throws -> Env {
        let f = try await OAuthFixture.make()
        let b = try await f.tokens(scope: Self.scopes)
        let gB = try unwrap(try await OAuthGrant.query(on: f.test.app.db).first())
        let w = try await f.tokens(scope: Self.scopes)
        let gW = try unwrap(try await OAuthGrant.query(on: f.test.app.db).filter(\.$id != gB.requireID()).first())
        gW.name = "Wächter (Mac)"; try await gW.save(on: f.test.app.db)
        let p1 = try f.project.requireID(), p2 = try f.other.requireID()
        let p3Project = Project(ownerID: try f.user.requireID(), parentID: nil, name: "Third")
        try await p3Project.save(on: f.test.app.db)
        let p3 = try p3Project.requireID()
        // The brain's own grant lists only P1; the watcher sees P1 as well (the fixture's consent).
        let stranger = User(displayName: "Stranger", isAdmin: false); try await stranger.save(on: f.test.app.db)
        let foreign = OAuthGrant(userID: try stranger.requireID(), clientID: gB.clientID, resource: gB.resource, scopes: ["projects:read"], projects: [p1], name: "Foreign")
        try await foreign.save(on: f.test.app.db)
        return Env(f: f, brain: b.access, watcher: w.access, brainGrant: try gB.requireID(), watcherGrant: try gW.requireID(),
                   p1: p1, p2: p2, p3: p3, strangerGrant: try foreign.requireID())
    }

    private func call(_ e: Env, _ token: String, _ name: String, _ args: [String: Any]) async throws -> (isError: Bool, text: String, json: Any?) {
        let r = try await e.f.rpc("tools/call", ["name": name, "arguments": args], access: token)
        let result = try XCTUnwrap(r.body?["result"] as? [String: Any], "no result for \(name): \(r.body ?? [:])")
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        return (result["isError"] as? Bool ?? false, text, try? JSONSerialization.jsonObject(with: Data(text.utf8)))
    }

    @discardableResult
    private func mandate(_ e: Env, grant: UUID? = nil, projects: [UUID]? = nil) async throws -> HTTPStatus {
        let r = try await e.f.test.json(.PUT, "/v1/settings/brain-mandate",
            ["grantID": (grant ?? e.brainGrant).uuidString, "projectIDs": (projects ?? [e.p1, e.p2]).map(\.uuidString)], token: e.f.session)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
        return r.status
    }

    private func set(_ e: Env, grant: UUID? = nil, add: [UUID] = [], remove: [UUID] = [], quote: String? = "Lino: gib die Projekte frei",
                     token: String? = nil) async throws -> (isError: Bool, text: String, json: [String: Any]?) {
        var args: [String: Any] = ["grantID": (grant ?? e.watcherGrant).uuidString]
        if !add.isEmpty { args["addProjectIDs"] = add.map(\.uuidString) }
        if !remove.isEmpty { args["removeProjectIDs"] = remove.map(\.uuidString) }
        if let quote { args["quote"] = quote }
        let r = try await call(e, token ?? e.brain, "set_connection_projects", args)
        return (r.isError, r.text, r.json as? [String: Any])
    }

    private func projects(_ e: Env, _ grant: UUID) async throws -> Set<UUID> {
        Set(try unwrap(try await OAuthGrant.find(grant, on: e.f.test.app.db)).projects)
    }

    private func audit(_ e: Env) async throws -> [[String: Any]] {
        let r = try await e.f.test.json(.GET, "/v1/settings/brain-mandate/audit", token: e.f.session)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
        return r.body?["items"] as? [[String: Any]] ?? []
    }

    private func unwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T { try XCTUnwrap(value, file: file, line: line) }

    private func run(_ body: (Env) async throws -> Void) async throws {
        let e = try await env()
        do { try await body(e) } catch { await e.f.test.shutdown(); throw error }
        await e.f.test.shutdown()
    }

    // MARK: Reading

    func testListConnectionsShowsOnlyProjectsOfTheOwnMandate() async throws {
        try await run { e in
            try await mandate(e, projects: [e.p1, e.p2])
            let w = try unwrap(try await OAuthGrant.find(e.watcherGrant, on: e.f.test.app.db))
            w.projects = [e.p1, e.p3]; try await w.save(on: e.f.test.app.db)
            let r = try await call(e, e.brain, "list_connections", [:])
            XCTAssertFalse(r.isError, r.text)
            let rows = try XCTUnwrap(r.json as? [[String: Any]])
            // Only the other connection of the same person: not the caller itself, not the stranger's.
            XCTAssertEqual(rows.compactMap { $0["grantID"] as? String }, [e.watcherGrant.uuidString])
            let row = try XCTUnwrap(rows.first)
            XCTAssertEqual(row["name"] as? String, "Wächter (Mac)")
            XCTAssertEqual(row["clientName"] as? String, "Test Client")
            XCTAssertNotNil(row["scopes"] as? [String])
            XCTAssertTrue(row.keys.contains("lastUsedAt"))
            // P3 is in the watcher's grant but not in the brain's mandate: invisible.
            let listed = try XCTUnwrap(row["projects"] as? [[String: Any]])
            XCTAssertEqual(listed.compactMap { $0["id"] as? String }, [e.p1.uuidString])
            XCTAssertEqual(listed.first?["name"] as? String, "Allowed")
            XCTAssertFalse(r.text.contains(e.p3.uuidString), "a project outside the mandate must not appear anywhere")
        }
    }

    func testListConnectionsSkipsRevokedConnectionsAndNeedsAnActiveMandate() async throws {
        try await run { e in
            let none = try await call(e, e.brain, "list_connections", [:])
            XCTAssertEqual(none.text, "brain_mandate_required")
            // A mandate of another connection does not help this one.
            try await mandate(e, grant: e.watcherGrant)
            let other = try await call(e, e.brain, "list_connections", [:])
            XCTAssertEqual(other.text, "brain_mandate_required")
            try await mandate(e)
            let ok = try await call(e, e.brain, "list_connections", [:])
            XCTAssertEqual((ok.json as? [[String: Any]])?.count, 1, ok.text)
            let w = try unwrap(try await OAuthGrant.find(e.watcherGrant, on: e.f.test.app.db))
            w.revoked = true; try await w.save(on: e.f.test.app.db)
            let after = try await call(e, e.brain, "list_connections", [:])
            XCTAssertEqual((after.json as? [[String: Any]])?.count, 0, after.text)
            _ = try await e.f.test.json(.DELETE, "/v1/settings/brain-mandate", token: e.f.session)
            let revoked = try await call(e, e.brain, "list_connections", [:])
            XCTAssertEqual(revoked.text, "brain_mandate_required")
        }
    }

    func testToolsNeedTheirScopes() async throws {
        try await run { e in
            let readOnly = try await e.f.tokens(scope: "projects:read tasks:read")
            let tools = try await e.f.rpc("tools/list", access: readOnly.access)
            let names = ((tools.body?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            XCTAssertTrue(names.contains("list_connections"))
            XCTAssertFalse(names.contains("set_connection_projects"))
            let denied = try await call(e, readOnly.access, "set_connection_projects", ["grantID": e.watcherGrant.uuidString, "addProjectIDs": [e.p1.uuidString], "quote": "ja"])
            XCTAssertEqual(denied.text, "insufficient_scope")
        }
    }

    // MARK: Setting

    func testAddAndRemoveProjectsOfAnotherConnection() async throws {
        try await run { e in
            try await mandate(e, projects: [e.p1, e.p2])
            let before = try await call(e, e.watcher, "list_projects", [:])
            XCTAssertEqual((before.json as? [[String: Any]])?.compactMap { $0["id"] as? String }, [e.p1.uuidString])
            let added = try await set(e, add: [e.p2])
            XCTAssertFalse(added.isError, added.text)
            XCTAssertEqual(added.json?["grantID"] as? String, e.watcherGrant.uuidString)
            XCTAssertEqual(added.json?["added"] as? [String], [e.p2.uuidString])
            XCTAssertEqual((added.json?["projects"] as? [[String: Any]])?.compactMap { $0["id"] as? String }.sorted(), [e.p1, e.p2].map(\.uuidString).sorted())
            try await assertEqual(try await projects(e, e.watcherGrant), [e.p1, e.p2])
            // The very point of the card: the watcher connection now sees the project through its own token.
            let seen = try await call(e, e.watcher, "list_projects", [:])
            XCTAssertEqual(Set((seen.json as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []), [e.p1.uuidString, e.p2.uuidString])
            let removed = try await set(e, remove: [e.p1])
            XCTAssertFalse(removed.isError, removed.text)
            XCTAssertEqual(removed.json?["removed"] as? [String], [e.p1.uuidString])
            try await assertEqual(try await projects(e, e.watcherGrant), [e.p2])
            // add and remove in one call
            let both = try await set(e, add: [e.p1], remove: [e.p2])
            XCTAssertFalse(both.isError, both.text)
            try await assertEqual(try await projects(e, e.watcherGrant), [e.p1])
        }
    }

    func testAddMarksTheAccessRequestGranted() async throws {
        try await run { e in
            try await mandate(e)
            try await ConnectionAccessRequest(grantID: e.watcherGrant, projectID: e.p2, userID: try e.f.user.requireID(), now: Date()).save(on: e.f.test.app.db)
            let r = try await set(e, add: [e.p2])
            XCTAssertFalse(r.isError, r.text)
            let row = try unwrap(try await ConnectionAccessRequest.query(on: e.f.test.app.db).filter(\.$grantID == e.watcherGrant).first())
            XCTAssertEqual(row.state, "granted")
        }
    }

    func testProjectsOutsideTheMandateStayUntouchedAndInvisibleInTheTarget() async throws {
        try await run { e in
            try await mandate(e, projects: [e.p1, e.p2])
            let w = try unwrap(try await OAuthGrant.find(e.watcherGrant, on: e.f.test.app.db))
            w.projects = [e.p1, e.p3]; try await w.save(on: e.f.test.app.db)
            let r = try await set(e, add: [e.p2], remove: [e.p1])
            XCTAssertFalse(r.isError, r.text)
            try await assertEqual(try await projects(e, e.watcherGrant), [e.p2, e.p3])
            XCTAssertFalse(r.text.contains(e.p3.uuidString), "the result must not reveal projects outside the mandate")
        }
    }

    func testRemovingTheLastProjectFollowsTheProjectsRequiredRule() async throws {
        try await run { e in
            try await mandate(e)
            let w = try unwrap(try await OAuthGrant.find(e.watcherGrant, on: e.f.test.app.db))
            // Without projects:write the connection must keep at least one project (same rule as ConnectionService.remove).
            w.scopes = ["projects:read", "tasks:read"]; w.projects = [e.p1]; try await w.save(on: e.f.test.app.db)
            let refused = try await set(e, remove: [e.p1])
            XCTAssertEqual(refused.text, "projects_required")
            try await assertEqual(try await projects(e, e.watcherGrant), [e.p1])
            // Moving the project in the same call keeps the list non-empty.
            let swap = try await set(e, add: [e.p2], remove: [e.p1])
            XCTAssertFalse(swap.isError, swap.text)
            try await assertEqual(try await projects(e, e.watcherGrant), [e.p2])
            // With projects:write an empty list is allowed (create_project extends it).
            w.scopes = ["projects:read", "projects:write"]; try await w.save(on: e.f.test.app.db)
            let empty = try await set(e, remove: [e.p2])
            XCTAssertFalse(empty.isError, empty.text)
            try await assertEqual(try await projects(e, e.watcherGrant), [])
        }
    }

    func testSettingIsIdempotentAndAuditsOnlyRealChanges() async throws {
        try await run { e in
            try await mandate(e)
            let first = try await set(e, add: [e.p2])
            XCTAssertFalse(first.isError, first.text)
            // Already there / not there: no error, no change.
            let again = try await set(e, add: [e.p1, e.p2], remove: [e.p3])
            XCTAssertFalse(again.isError, again.text)
            XCTAssertEqual(again.json?["added"] as? [String], [])
            XCTAssertEqual(again.json?["removed"] as? [String], [])
            try await assertEqual(try await projects(e, e.watcherGrant), [e.p1, e.p2])
            let rows = try await audit(e)
            XCTAssertEqual(rows.count, 1, "only the real change is audited: \(rows)")
        }
    }

    func testAuditRowCarriesQuoteTargetAndProject() async throws {
        try await run { e in
            try await mandate(e)
            _ = try await set(e, add: [e.p2], quote: "Lino: Waechter soll Formular Backend sehen")
            _ = try await set(e, remove: [e.p2], quote: "Lino: doch wieder weg")
            let rows = try await audit(e)
            XCTAssertEqual(rows.count, 2, "\(rows)")
            let added = try XCTUnwrap(rows.first { $0["kind"] as? String == "connection.project_added" })
            XCTAssertEqual(added["quote"] as? String, "Lino: Waechter soll Formular Backend sehen")
            XCTAssertEqual(added["grantID"] as? String, e.brainGrant.uuidString, "the acting connection")
            XCTAssertEqual(added["subjectID"] as? String, e.watcherGrant.uuidString, "the changed connection")
            XCTAssertEqual(added["projectID"] as? String, e.p2.uuidString)
            XCTAssertTrue(added["taskID"] == nil || added["taskID"] is NSNull, "no card involved")
            let removed = try XCTUnwrap(rows.first { $0["kind"] as? String == "connection.project_removed" })
            XCTAssertEqual(removed["quote"] as? String, "Lino: doch wieder weg")
            XCTAssertEqual(removed["projectID"] as? String, e.p2.uuidString)
        }
    }

    func testAuditListsDecisionsAndConnectionChangesTogether() async throws {
        try await run { e in
            try await mandate(e)
            let task = TodoTask(ownerID: try e.f.user.requireID(), projectID: e.p1, title: "T", details: "")
            try await task.save(on: e.f.test.app.db)
            let asked = try await call(e, e.watcher, "request_review", ["taskID": try task.requireID().uuidString, "summary": "Done"])
            XCTAssertFalse(asked.isError, asked.text)
            let decided = try await call(e, e.brain, "decide_review", ["taskID": try task.requireID().uuidString, "decision": "accept", "quote": "Lino: ja"])
            XCTAssertFalse(decided.isError, decided.text)
            _ = try await set(e, add: [e.p2])
            let kinds = try await audit(e).compactMap { $0["kind"] as? String }
            XCTAssertEqual(kinds, ["connection.project_added", "review.accepted"], "newest first")
        }
    }

    // MARK: Refusals

    func testForeignPersonsConnectionIsNotFoundAndIndistinguishableFromAnUnknownOne() async throws {
        try await run { e in
            try await mandate(e)
            let foreign = try await set(e, grant: e.strangerGrant, add: [e.p1])
            let unknown = try await set(e, grant: UUID(), add: [e.p1])
            XCTAssertEqual(foreign.text, "not_found")
            XCTAssertEqual(unknown.text, foreign.text, "no information leak about foreign grants")
            XCTAssertEqual(foreign.isError, unknown.isError)
            // Not even a missing mandate or quote reveals the difference: the foreign grant is 404 first.
            let noQuote = try await set(e, grant: e.strangerGrant, add: [e.p3], quote: nil)
            XCTAssertEqual(noQuote.text, "not_found")
            try await assertEqual(try await projects(e, e.strangerGrant), [e.p1])
            try await assertEqual(try await audit(e).count, 0)
        }
    }

    func testForeignPersonsMandateHolderCannotTouchThisPersonsConnection() async throws {
        try await run { e in
            // The stranger holds a mandate row for their own connection; it is no authority over the person's connections.
            let stranger = try unwrap(try await OAuthGrant.find(e.strangerGrant, on: e.f.test.app.db))
            try await BrainMandate(userID: stranger.userID, grantID: e.strangerGrant, projects: [e.p1]).save(on: e.f.test.app.db)
            let r = try await set(e, add: [e.p2])
            XCTAssertEqual(r.text, "brain_mandate_required", "the caller's own mandate is what counts")
            try await assertEqual(try await projects(e, e.watcherGrant), [e.p1])
        }
    }

    func testOwnConnectionIsRefusedEvenWithMandate() async throws {
        try await run { e in
            let without = try await set(e, grant: e.brainGrant, add: [e.p2])
            XCTAssertEqual(without.text, "cannot_change_own_connection", "checked before the mandate")
            try await mandate(e)
            let with = try await set(e, grant: e.brainGrant, add: [e.p2])
            XCTAssertEqual(with.text, "cannot_change_own_connection")
            try await assertEqual(try await projects(e, e.brainGrant), [e.p1])
        }
    }

    func testWithoutMandateIsRefused() async throws {
        try await run { e in
            let none = try await set(e, add: [e.p2])
            XCTAssertEqual(none.text, "brain_mandate_required")
            // A mandate of the target connection is no authority for the caller.
            try await mandate(e, grant: e.watcherGrant)
            let other = try await set(e, add: [e.p2])
            XCTAssertEqual(other.text, "brain_mandate_required")
            try await assertEqual(try await projects(e, e.watcherGrant), [e.p1])
        }
    }

    func testProjectOutsideTheMandateIsRefusedAndNothingIsAppliedPartially() async throws {
        try await run { e in
            try await mandate(e, projects: [e.p1, e.p2])
            let single = try await set(e, add: [e.p3])
            XCTAssertEqual(single.text, "outside_brain_mandate")
            // Mixed list: P2 would be fine, P3 is not: nothing at all happens.
            let mixed = try await set(e, add: [e.p2, e.p3])
            XCTAssertEqual(mixed.text, "outside_brain_mandate")
            let mixedRemove = try await set(e, add: [e.p2], remove: [e.p3])
            XCTAssertEqual(mixedRemove.text, "outside_brain_mandate")
            let removeOnly = try await set(e, remove: [e.p1, e.p3])
            XCTAssertEqual(removeOnly.text, "outside_brain_mandate")
            try await assertEqual(try await projects(e, e.watcherGrant), [e.p1])
            try await assertEqual(try await audit(e).count, 0)
        }
    }

    func testRevokedMandateAndRevokedConnectionsAreRefused() async throws {
        try await run { e in
            try await mandate(e)
            let ok = try await set(e, add: [e.p2])
            XCTAssertFalse(ok.isError, ok.text)
            let del = try await e.f.test.json(.DELETE, "/v1/settings/brain-mandate", token: e.f.session)
            XCTAssertEqual(del.status, .noContent)
            let revoked = try await set(e, remove: [e.p2])
            XCTAssertEqual(revoked.text, "brain_mandate_required")
            try await assertEqual(try await projects(e, e.watcherGrant), [e.p1, e.p2])
            // A revoked caller connection is rejected at the door (the mandate is void with it).
            try await mandate(e)
            let grant = try unwrap(try await OAuthGrant.find(e.brainGrant, on: e.f.test.app.db))
            grant.revoked = true; try await grant.save(on: e.f.test.app.db)
            let gone = try await e.f.rpc("tools/call", ["name": "set_connection_projects", "arguments": ["grantID": e.watcherGrant.uuidString, "addProjectIDs": [e.p1.uuidString], "quote": "ja"]], access: e.brain)
            XCTAssertEqual(gone.status, .unauthorized)
        }
    }

    func testMandateRevokedRightBeforeTheCallWins() async throws {
        try await run { e in
            try await mandate(e)
            _ = try await set(e, add: [e.p2])
            // Revoke via REST, then call straight away with the same, still valid token: the mandate is re-read under lock.
            _ = try await e.f.test.json(.DELETE, "/v1/settings/brain-mandate/\(e.brainGrant.uuidString)", token: e.f.session)
            let r = try await set(e, remove: [e.p2])
            XCTAssertEqual(r.text, "brain_mandate_required")
            try await assertEqual(try await projects(e, e.watcherGrant), [e.p1, e.p2])
            // Shrinking the mandate takes effect immediately as well.
            try await mandate(e, projects: [e.p1])
            let shrunk = try await set(e, remove: [e.p2])
            XCTAssertEqual(shrunk.text, "outside_brain_mandate")
        }
    }

    func testRevokedTargetConnectionIsRefused() async throws {
        try await run { e in
            let w = try unwrap(try await OAuthGrant.find(e.watcherGrant, on: e.f.test.app.db))
            w.revoked = true; try await w.save(on: e.f.test.app.db)
            // Target problems come before the mandate check.
            let noMandate = try await set(e, add: [e.p2])
            XCTAssertEqual(noMandate.text, "grant_revoked")
            try await mandate(e)
            let r = try await set(e, add: [e.p2])
            XCTAssertEqual(r.text, "grant_revoked")
            try await assertEqual(try await projects(e, e.watcherGrant), [e.p1])
        }
    }

    func testQuoteIsRequiredAndBounded() async throws {
        try await run { e in
            try await mandate(e)
            for quote in [nil, "", "   "] as [String?] {
                let r = try await set(e, add: [e.p2], quote: quote)
                XCTAssertEqual(r.text, "quote_required")
            }
            let long = try await set(e, add: [e.p2], quote: String(repeating: "x", count: 2001))
            XCTAssertEqual(long.text, "invalid_quote")
            let atLimit = try await set(e, add: [e.p2], quote: String(repeating: "x", count: 2000))
            XCTAssertFalse(atLimit.isError, atLimit.text)
            let rows = try await audit(e)
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual((rows.first?["quote"] as? String)?.count, 2000)
        }
    }

    func testProjectTheirPersonCannotReadAnymoreIsRefused() async throws {
        try await run { e in
            let owner = User(displayName: "Owner", isAdmin: false); try await owner.save(on: e.f.test.app.db)
            let shared = Project(ownerID: try owner.requireID(), parentID: nil, name: "Shared"); try await shared.save(on: e.f.test.app.db)
            try await ProjectSharing(project: shared).save(on: e.f.test.app.db)
            let share = ProjectGrant(projectID: try shared.requireID(), principalType: "person", principalID: try e.f.user.requireID(), role: .read)
            try await share.save(on: e.f.test.app.db)
            let sid = try shared.requireID()
            try await mandate(e, projects: [e.p1, sid])
            // The person loses access after the mandate was given: the mandate alone is not enough, like ConnectionService.add.
            try await share.delete(on: e.f.test.app.db)
            let r = try await set(e, add: [sid])
            XCTAssertEqual(r.text, "not_found")
            try await assertEqual(try await projects(e, e.watcherGrant), [e.p1])
            try await assertEqual(try await audit(e).count, 0)
        }
    }

    func testArgumentValidation() async throws {
        try await run { e in
            try await mandate(e)
            let w = e.watcherGrant.uuidString, p = e.p2.uuidString
            let cases: [([String: Any], String)] = [
                (["grantID": w, "quote": "ja"], "invalid_projects"),
                (["grantID": w, "addProjectIDs": [], "removeProjectIDs": [], "quote": "ja"], "invalid_projects"),
                (["grantID": w, "addProjectIDs": [p], "removeProjectIDs": [p], "quote": "ja"], "invalid_projects"),
                (["grantID": w, "addProjectIDs": (0..<51).map { _ in UUID().uuidString }, "quote": "ja"], "invalid_projects"),
                (["grantID": w, "removeProjectIDs": (0..<51).map { _ in UUID().uuidString }, "quote": "ja"], "invalid_projects"),
                (["grantID": "nope", "addProjectIDs": [p], "quote": "ja"], "invalid_id"),
                (["grantID": w, "addProjectIDs": ["nope"], "quote": "ja"], "invalid_id"),
                (["grantID": w, "addProjectIDs": p, "quote": "ja"], "invalid_projects"),
                (["addProjectIDs": [p], "quote": "ja"], "invalid_arguments"),
                (["grantID": w, "addProjectIDs": [p], "quote": "ja", "projectIDs": [p]], "invalid_arguments"),
            ]
            for (args, reason) in cases {
                let r = try await call(e, e.brain, "set_connection_projects", args)
                XCTAssertEqual(r.text, reason, "\(args)")
            }
            try await assertEqual(try await projects(e, e.watcherGrant), [e.p1])
            // 50 is still fine (all outside the mandate here, but the shape is accepted).
            let fifty = try await call(e, e.brain, "set_connection_projects", ["grantID": w, "addProjectIDs": (0..<50).map { _ in UUID().uuidString }, "quote": "ja"])
            XCTAssertEqual(fifty.text, "outside_brain_mandate")
        }
    }

    // MARK: No way to change mandates

    func testNoMcpToolChangesMandatesAndSettingProjectsLeavesThemAlone() async throws {
        try await run { e in
            try await mandate(e, grant: e.brainGrant, projects: [e.p1, e.p2])
            try await mandate(e, grant: e.watcherGrant, projects: [e.p1])
            let tools = try await e.f.rpc("tools/list", access: e.brain)
            let names = ((tools.body?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            XCTAssertFalse(names.contains { $0.contains("mandate") }, "no MCP tool is named after a mandate: \(names.filter { $0.contains("mandate") })")
            let def = try XCTUnwrap(((tools.body?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.first { $0["name"] as? String == "set_connection_projects" })
            let props = Set(((def["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])?.keys.map { $0 } ?? [])
            XCTAssertEqual(props, ["grantID", "addProjectIDs", "removeProjectIDs", "quote"])
            for name in ["set_brain_mandate", "grant_brain_mandate", "revoke_brain_mandate"] {
                let r = try await e.f.rpc("tools/call", ["name": name, "arguments": [:]], access: e.brain)
                XCTAssertNotNil(r.body?["error"], "\(name) must not exist")
            }
            let before = try await BrainMandate.query(on: e.f.test.app.db).all().map { "\($0.grantID) \($0.projects.map(\.uuidString).sorted()) \($0.revokedAt == nil) \($0.updatedAt)" }.sorted()
            // The target holds a mandate itself; changing its projects does not touch it.
            let r = try await set(e, add: [e.p2])
            XCTAssertFalse(r.isError, r.text)
            let after = try await BrainMandate.query(on: e.f.test.app.db).all().map { "\($0.grantID) \($0.projects.map(\.uuidString).sorted()) \($0.revokedAt == nil) \($0.updatedAt)" }.sorted()
            XCTAssertEqual(before, after)
            // And the mandate endpoint still refuses OAuth tokens.
            let put = try await e.f.test.json(.PUT, "/v1/settings/brain-mandate", ["grantID": e.watcherGrant.uuidString, "projectIDs": [e.p2.uuidString]], token: e.brain)
            XCTAssertEqual(put.status, .unauthorized)
        }
    }

    // MARK: Two connections with mandates

    func testTwoMandatedConnectionsChangeEachOthersProjects() async throws {
        try await run { e in
            try await mandate(e, grant: e.brainGrant, projects: [e.p1, e.p2])
            try await mandate(e, grant: e.watcherGrant, projects: [e.p3])
            // The watcher may only touch its own mandate's project (P3) on the brain; the brain only P1/P2 on the watcher.
            let denied = try await set(e, grant: e.brainGrant, add: [e.p2], token: e.watcher)
            XCTAssertEqual(denied.text, "outside_brain_mandate")
            let ok = try await set(e, grant: e.brainGrant, add: [e.p3], token: e.watcher)
            XCTAssertFalse(ok.isError, ok.text)
            try await assertEqual(try await projects(e, e.brainGrant), [e.p1, e.p3])
            let back = try await set(e, add: [e.p2])
            XCTAssertFalse(back.isError, back.text)
            try await assertEqual(try await projects(e, e.watcherGrant), [e.p1, e.p2])
        }
    }

    func testOppositeCallsAtTheSameTimeDoNotDeadlock() async throws {
        guard TestApp.useMariaDB else { throw XCTSkip("row locks required (MariaDB)") }
        try await run { e in
            try await mandate(e, grant: e.brainGrant, projects: [e.p1, e.p2])
            try await mandate(e, grant: e.watcherGrant, projects: [e.p1, e.p2])
            let f = e.f
            let pairs = [(e.brain, e.watcherGrant), (e.watcher, e.brainGrant)]
            let p2 = e.p2.uuidString
            for key in ["addProjectIDs", "removeProjectIDs"] {
                for _ in 0..<5 {
                    let texts = try await withThrowingTaskGroup(of: String.self) { group in
                        for (token, target) in pairs {
                            group.addTask {
                                let r = try await f.rpc("tools/call", ["name": "set_connection_projects",
                                    "arguments": ["grantID": target.uuidString, key: [p2], "quote": "ja"]], access: token)
                                let content = ((r.body?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String
                                return content ?? "no result"
                            }
                        }
                        var out: [String] = []
                        for try await t in group { out.append(t) }
                        return out
                    }
                    for t in texts { XCTAssertFalse(t.contains("deadlock") || t == "invalid_arguments" || t == "no result", t) }
                }
            }
        }
    }
}
