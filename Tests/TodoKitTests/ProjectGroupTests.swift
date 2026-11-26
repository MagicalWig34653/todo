import Fluent
import SQLKit
import XCTVapor
@testable import TodoKit

/// Card BEF08998 part 3 (ADR 0037): project groups and rule selections ("all owned except") for the brain mandate and for a
/// connection's grant. Everything runs through the real REST and MCP interfaces.
final class ProjectGroupTests: XCTestCase {
    struct Env {
        let f: OAuthFixture
        /// `agent` requests reviews, `brain` holds the mandate. Both consented to project P1 only.
        let agent: String, brain: String
        let agentGrant: UUID, brainGrant: UUID
        let p1: UUID, p2: UUID
    }

    typealias Reply = (status: HTTPStatus, body: [String: Any]?, list: [[String: Any]]?, cookie: String?)
    static let scopes = CommandCenterTests.scopes + " projects:write"

    fileprivate func env() async throws -> Env {
        let f = try await OAuthFixture.make()
        let a = try await f.tokens(scope: Self.scopes)
        let firstGrant = try await OAuthGrant.query(on: f.test.app.db).first()?.id
        let gA = try XCTUnwrap(firstGrant)
        let b = try await f.tokens(scope: Self.scopes)
        let secondGrant = try await OAuthGrant.query(on: f.test.app.db).filter(\.$id != gA).first()?.id
        let gB = try XCTUnwrap(secondGrant)
        return Env(f: f, agent: a.access, brain: b.access, agentGrant: gA, brainGrant: gB,
                   p1: try f.project.requireID(), p2: try f.other.requireID())
    }

    fileprivate func run(_ body: (Env) async throws -> Void) async throws {
        let e = try await env()
        do { try await body(e) } catch { await e.f.test.shutdown(); throw error }
        await e.f.test.shutdown()
    }

    // MARK: Helpers

    fileprivate func rest(_ e: Env, _ method: HTTPMethod, _ path: String, _ body: [String: Any]? = nil, token: String? = nil) async throws -> Reply {
        try await e.f.test.json(method, path, body, token: token ?? e.f.session)
    }

    fileprivate func call(_ e: Env, _ token: String, _ name: String, _ args: [String: Any] = [:]) async throws -> (isError: Bool, text: String, json: Any?) {
        let r = try await e.f.rpc("tools/call", ["name": name, "arguments": args], access: token)
        let result = try XCTUnwrap(r.body?["result"] as? [String: Any], "no result for \(name): \(r.body ?? [:])")
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        return (result["isError"] as? Bool ?? false, text, try? JSONSerialization.jsonObject(with: Data(text.utf8)))
    }

    fileprivate func ids(_ value: Any?) -> Set<UUID> { Set((value as? [String] ?? []).compactMap(UUID.init(uuidString:))) }
    fileprivate func strings(_ ids: [UUID]) -> [String] { ids.map(\.uuidString) }

    fileprivate func group(_ e: Env, _ name: String, _ projects: [UUID]) async throws -> UUID {
        let r = try await rest(e, .POST, "/v1/project-groups", ["name": name, "projectIDs": strings(projects)])
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
        return try XCTUnwrap(((r.body?["group"] as? [String: Any])?["id"] as? String).flatMap(UUID.init(uuidString:)))
    }

    @discardableResult
    fileprivate func setMembers(_ e: Env, _ group: UUID, _ projects: [UUID], dryRun: Bool = false) async throws -> [[String: Any]] {
        let r = try await rest(e, .PATCH, "/v1/project-groups/\(group)\(dryRun ? "?dryRun=true" : "")", ["projectIDs": strings(projects)])
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
        return r.body?["changes"] as? [[String: Any]] ?? []
    }

    fileprivate func selection(mode: String = "selected", groups: [UUID] = [], excluded: [UUID] = [], excludedGroups: [UUID] = []) -> [String: Any] {
        ["mode": mode, "groupIDs": strings(groups), "excludedProjectIDs": strings(excluded), "excludedGroupIDs": strings(excludedGroups)]
    }

    @discardableResult
    fileprivate func mandate(_ e: Env, grant: UUID? = nil, projects: [UUID] = [], _ rule: [String: Any]? = nil, expect: HTTPStatus = .ok) async throws -> Reply {
        var body: [String: Any] = ["grantID": (grant ?? e.brainGrant).uuidString, "projectIDs": strings(projects)]
        if let rule { body["selection"] = rule }
        let r = try await rest(e, .PUT, "/v1/settings/brain-mandate", body)
        XCTAssertEqual(r.status, expect, "\(r.body ?? [:])")
        return r
    }

    @discardableResult
    fileprivate func access(_ e: Env, _ grant: UUID, projects: [UUID] = [], _ rule: [String: Any]? = nil, expect: HTTPStatus = .ok) async throws -> Reply {
        var body: [String: Any] = ["project_ids": strings(projects)]
        if let rule { body["selection"] = rule }
        let r = try await rest(e, .PUT, "/oauth/grants/\(grant)/projects", body)
        XCTAssertEqual(r.status, expect, "\(r.body ?? [:])")
        return r
    }

    /// The projects `get_connection` reports: what the connection reaches.
    fileprivate func reach(_ e: Env, _ token: String) async throws -> Set<UUID> {
        let r = try await call(e, token, "get_connection")
        let rows = (r.json as? [String: Any])?["projects"] as? [[String: Any]] ?? []
        return Set(rows.compactMap { ($0["id"] as? String).flatMap(UUID.init(uuidString:)) })
    }

    private func mandated(_ e: Env, _ token: String? = nil) async throws -> Set<UUID> {
        let r = try await call(e, token ?? e.brain, "get_connection")
        return ids(((r.json as? [String: Any])?["brainMandate"] as? [String: Any])?["projectIDs"])
    }

    /// A project of this person, created the way a person creates one (REST).
    private func project(_ e: Env, _ name: String) async throws -> UUID {
        let r = try await rest(e, .POST, "/v1/projects", ["name": name])
        XCTAssertTrue(r.status == .ok || r.status == .created, "\(r.status) \(r.body ?? [:])")
        return try XCTUnwrap((r.body?["id"] as? String).flatMap(UUID.init(uuidString:)))
    }

    /// A project of another person, shared with this person.
    private func foreign(_ e: Env) async throws -> (project: UUID, grant: ProjectGrant) {
        let other = User(displayName: "Other", isAdmin: false); try await other.save(on: e.f.test.app.db)
        let p = Project(ownerID: try other.requireID(), parentID: nil, name: "Shared"); try await p.save(on: e.f.test.app.db)
        let share = ProjectGrant(projectID: try p.requireID(), principalType: "person", principalID: try e.f.user.requireID(), role: .edit)
        try await share.save(on: e.f.test.app.db)
        return (try p.requireID(), share)
    }

    /// A review requested by the agent connection in `project` (which is added to the agent's list first); returns the review id.
    fileprivate func review(_ e: Env, _ project: UUID) async throws -> String {
        let task = TodoTask(ownerID: try e.f.user.requireID(), projectID: project, title: "T")
        try await task.save(on: e.f.test.app.db)
        try await access(e, e.agentGrant, projects: [e.p1, project])
        let r = try await call(e, e.agent, "request_review", ["taskID": try task.requireID().uuidString, "summary": "Done"])
        XCTAssertFalse(r.isError, r.text)
        return try XCTUnwrap((r.json as? [String: Any])?["id"] as? String)
    }

    fileprivate func decide(_ e: Env, _ review: String) async throws -> (isError: Bool, text: String) {
        let row = try await TaskReview.find(UUID(uuidString: review), on: e.f.test.app.db)
        let taskID = try XCTUnwrap(row).taskID
        let r = try await call(e, e.brain, "decide_review", ["taskID": taskID.uuidString, "decision": "accept", "quote": "Lino: ok"])
        return (r.isError, r.text)
    }

    // MARK: Groups as a REST resource

    func testGroupsAreManagedByThePersonOnly() async throws {
        try await run { e in
            let g = try await group(e, "Arbeit", [e.p1])
            let list = try await rest(e, .GET, "/v1/project-groups")
            let rows = try XCTUnwrap(list.body?["groups"] as? [[String: Any]])
            XCTAssertEqual(rows.compactMap { $0["name"] as? String }, ["Arbeit"])
            XCTAssertEqual(ids(rows.first?["projectIDs"]), [e.p1])
            // An OAuth token is no person session.
            for (method, path) in [(HTTPMethod.GET, "/v1/project-groups"), (.POST, "/v1/project-groups"), (.PATCH, "/v1/project-groups/\(g)"),
                                   (.DELETE, "/v1/project-groups/\(g)"), (.PUT, "/v1/projects/\(e.p1)/groups"), (.POST, "/v1/project-selection/preview")] {
                let r = try await rest(e, method, path, ["name": "x", "projectIDs": [String](), "groupIDs": [String]()], token: e.brain)
                XCTAssertEqual(r.status, .unauthorized, "\(method) \(path)")
            }
            // No MCP tool writes groups, memberships or mandates; the only group tool reads.
            let tools = try await e.f.rpc("tools/list", access: e.brain)
            let names = ((tools.body?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            XCTAssertEqual(names.filter { $0.contains("group") || $0.contains("mandate") }, ["list_project_groups"])
        }
    }

    func testNamesAreUniqueAndForeignThingsAreNotFound() async throws {
        try await run { e in
            let g = try await group(e, "Arbeit", [])
            let again = try await rest(e, .POST, "/v1/project-groups", ["name": " arbeit "])
            XCTAssertEqual(again.status, .conflict, "\(again.body ?? [:])")
            let empty = try await rest(e, .POST, "/v1/project-groups", ["name": "  "])
            XCTAssertEqual(empty.status, .badRequest)
            // A project the person cannot read cannot become a member.
            let stranger = User(displayName: "S", isAdmin: false); try await stranger.save(on: e.f.test.app.db)
            let hidden = Project(ownerID: try stranger.requireID(), parentID: nil, name: "Hidden"); try await hidden.save(on: e.f.test.app.db)
            let r = try await rest(e, .PATCH, "/v1/project-groups/\(g)", ["projectIDs": [try hidden.requireID().uuidString]])
            XCTAssertEqual(r.status, .notFound)
            // A group of another person does not exist for this person.
            let token = AuthSupport.randomToken()
            try await UserSession(userID: stranger.requireID(), tokenHash: AuthSupport.hash(token), expiresAt: Date().addingTimeInterval(600)).save(on: e.f.test.app.db)
            let theirs = try await rest(e, .PATCH, "/v1/project-groups/\(g)", ["name": "mine"], token: token)
            XCTAssertEqual(theirs.status, .notFound)
            let theirList = try await rest(e, .GET, "/v1/project-groups", token: token)
            XCTAssertEqual((theirList.body?["groups"] as? [Any])?.count, 0)
            try await mandate(e, selection(groups: [UUID()]), expect: .notFound)
            try await mandate(e, selection(excludedGroups: [UUID()]), expect: .notFound)
            try await mandate(e, selection(mode: "everything"), expect: .badRequest)
            try await mandate(e, selection(), expect: .badRequest)
        }
    }

    // MARK: Resolution

    func testMandateByGroupFollowsMembershipImmediately() async throws {
        try await run { e in
            let g = try await group(e, "Brain", [e.p1])
            try await mandate(e, selection(groups: [g]))
            try await assertEqual(try await mandated(e), [e.p1])
            try await access(e, e.brainGrant, selection(groups: [g]))
            try await assertEqual(try await reach(e, e.brain), [e.p1])
            let r = try await review(e, e.p2)
            // P2 is in neither list yet.
            let hidden = try await decide(e, r)
            XCTAssertTrue(hidden.isError, hidden.text)
            // Joining the group is enough, for the grant and for the mandate.
            try await setMembers(e, g, [e.p1, e.p2])
            try await assertEqual(try await mandated(e), [e.p1, e.p2])
            try await assertEqual(try await reach(e, e.brain), [e.p1, e.p2])
            // Leaving it withdraws at once: the mandate first (grant still reaches P2).
            try await access(e, e.brainGrant, projects: [e.p1, e.p2])
            try await setMembers(e, g, [e.p1])
            let gone = try await decide(e, r)
            XCTAssertTrue(gone.text.contains("outside_brain_mandate"), gone.text)
            try await setMembers(e, g, [e.p1, e.p2])
            let ok = try await decide(e, r)
            XCTAssertFalse(ok.isError, ok.text)
        }
    }

    func testDeletingAGroupWithdrawsAccessAtOnce() async throws {
        try await run { e in
            let g = try await group(e, "G", [e.p2])
            try await access(e, e.agentGrant, projects: [e.p1], selection(groups: [g]))
            try await assertEqual(try await reach(e, e.agent), [e.p1, e.p2])
            let before = try await call(e, e.agent, "list_tasks", ["projectID": e.p2.uuidString])
            XCTAssertFalse(before.isError, before.text)
            let r = try await rest(e, .DELETE, "/v1/project-groups/\(g)")
            XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
            try await assertEqual(try await reach(e, e.agent), [e.p1])
            let after = try await call(e, e.agent, "list_tasks", ["projectID": e.p2.uuidString])
            XCTAssertTrue(after.isError, after.text)
        }
    }

    func testAllExceptIncludesNewOwnedProjectsAndExclusionWins() async throws {
        try await run { e in
            let shared = try await foreign(e)
            let blocked = try await group(e, "Privat", [])
            try await access(e, e.agentGrant, selection(mode: "all_except", excluded: [e.p2], excludedGroups: [blocked]))
            try await assertEqual(try await reach(e, e.agent), [e.p1])
            // A project the person creates later is included; a project of someone else is not.
            let new = try await project(e, "Neu")
            try await assertEqual(try await reach(e, e.agent), [e.p1, new])
            // A shared project only by explicit choice or through a group.
            try await access(e, e.agentGrant, projects: [shared.project, e.p2], selection(mode: "all_except", excluded: [e.p2], excludedGroups: [blocked]))
            try await assertEqual(try await reach(e, e.agent), [e.p1, new, shared.project])
            // An excluded group wins over the explicit choice.
            try await setMembers(e, blocked, [shared.project, new])
            try await assertEqual(try await reach(e, e.agent), [e.p1])
            let shown = try await rest(e, .GET, "/oauth/grants")
            let row = try XCTUnwrap(shown.list?.first { ($0["id"] as? String)?.uppercased() == e.agentGrant.uuidString })
            XCTAssertEqual(ids(row["project_ids"]), [e.p1])
            let rule = try XCTUnwrap(row["selection"] as? [String: Any])
            XCTAssertEqual(rule["mode"] as? String, "all_except")
            XCTAssertEqual(ids(rule["excludedGroupIDs"]), [blocked])
            XCTAssertEqual(ids(rule["projectIDs"]), [shared.project, e.p2])
            // Deleting an excluded group keeps its projects excluded.
            let r = try await rest(e, .DELETE, "/v1/project-groups/\(blocked)")
            XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
            try await assertEqual(try await reach(e, e.agent), [e.p1])
        }
    }

    func testSelectionIsAlwaysCutWithTheCurrentReadRight() async throws {
        try await run { e in
            let shared = try await foreign(e)
            let g = try await group(e, "G", [shared.project])
            try await access(e, e.brainGrant, selection(groups: [g]))
            try await mandate(e, selection(groups: [g]))
            try await assertEqual(try await mandated(e), [shared.project])
            try await shared.grant.delete(on: e.f.test.app.db)
            try await assertEqual(try await mandated(e), [])
            try await assertEqual(try await reach(e, e.brain), [])
            let list = try await call(e, e.brain, "list_project_groups")
            XCTAssertEqual((list.json as? [Any])?.count, 0, list.text)
            // Giving a project away takes it out of "all".
            try await access(e, e.agentGrant, selection(mode: "all_except"))
            try await assertEqual(try await reach(e, e.agent), [e.p1, e.p2])
            let heir = User(displayName: "Heir", isAdmin: false); try await heir.save(on: e.f.test.app.db)
            let policy = try ProjectSharing(project: e.f.other)
            policy.ownerType = "person"; policy.ownerID = try heir.requireID(); try await policy.save(on: e.f.test.app.db)
            try await assertEqual(try await reach(e, e.agent), [e.p1])
        }
    }

    // MARK: Agents must not widen selections

    func testProjectsCreatedByAnAgentDoNotWidenOtherSelections() async throws {
        try await run { e in
            let g = try await group(e, "G", [e.p1])
            try await mandate(e, selection(mode: "all_except"))
            try await access(e, e.brainGrant, selection(mode: "all_except", groups: [g]))
            let made = try await call(e, e.agent, "create_project", ["name": "Vom Agenten"])
            XCTAssertFalse(made.isError, made.text)
            let new = try XCTUnwrap((((made.json as? [String: Any])?["project"] as? [String: Any])?["id"] as? String).flatMap(UUID.init(uuidString:)))
            // The creator reaches it (as before), nobody else does: neither another grant nor a mandate.
            let creator = try await reach(e, e.agent)
            XCTAssertTrue(creator.contains(new))
            try await assertEqual(try await reach(e, e.brain), [e.p1, e.p2])
            try await assertEqual(try await mandated(e), [e.p1, e.p2])
            // Not even the creator's own mandate grows.
            try await mandate(e, grant: e.agentGrant, selection(mode: "all_except"))
            try await assertEqual(try await mandated(e, e.agent), [e.p1, e.p2])
            let preview = try await rest(e, .POST, "/v1/project-selection/preview", ["projectIDs": [String](), "selection": selection(mode: "all_except")])
            XCTAssertEqual(preview.status, .ok, "\(preview.body ?? [:])")
            XCTAssertEqual(ids(preview.body?["projectIDs"]), [e.p1, e.p2])
            XCTAssertEqual(ids(preview.body?["agentCreatedProjectIDs"]), [new])
            // The person decides: through a group (or an explicit choice) it counts.
            try await setMembers(e, g, [e.p1, new])
            try await assertEqual(try await reach(e, e.brain), [e.p1, e.p2, new])
        }
    }

    func testAgentWritesNeverChangeWhatOtherSelectionsCover() async throws {
        try await run { e in
            let g = try await group(e, "G", [e.p1])
            try await mandate(e, selection(groups: [g]))
            try await access(e, e.agentGrant, projects: [e.p1, e.p2])
            // Moving a project below a group member inherits nothing.
            let found = try await Project.find(e.p2, on: e.f.test.app.db)
            let version = try XCTUnwrap(found).version
            let moved = try await call(e, e.agent, "move_project", ["projectID": e.p2.uuidString, "version": version, "parentID": e.p1.uuidString])
            XCTAssertFalse(moved.isError, moved.text)
            try await assertEqual(try await mandated(e), [e.p1])
            // A sub-project an agent creates below a group member joins nothing.
            let made = try await call(e, e.agent, "create_project", ["name": "Kind", "parentID": e.p1.uuidString])
            XCTAssertFalse(made.isError, made.text)
            try await assertEqual(try await mandated(e), [e.p1])
        }
    }

    // MARK: MCP reading and single projects

    func testMCPShowsOnlyWhatTheConnectionReaches() async throws {
        try await run { e in
            let g = try await group(e, "Sichtbar", [e.p1, e.p2])
            _ = try await group(e, "Verborgen", [e.p2])
            try await access(e, e.agentGrant, projects: [e.p1])
            let list = try await call(e, e.agent, "list_project_groups")
            XCTAssertFalse(list.isError, list.text)
            let rows = try XCTUnwrap(list.json as? [[String: Any]])
            XCTAssertEqual(rows.compactMap { $0["name"] as? String }, ["Sichtbar"])
            XCTAssertEqual((rows.first?["projects"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, [e.p1.uuidString])
            XCTAssertFalse(list.text.uppercased().contains(e.p2.uuidString))
            try await access(e, e.brainGrant, selection(groups: [g]))
            try await mandate(e, selection(mode: "all_except", excluded: [e.p2]))
            let info = try await call(e, e.brain, "get_connection")
            let body = try XCTUnwrap(info.json as? [String: Any])
            let selected = try XCTUnwrap(body["selection"] as? [String: Any], info.text)
            XCTAssertEqual(selected["mode"] as? String, "selected")
            XCTAssertEqual((selected["groups"] as? [[String: Any]])?.compactMap { $0["name"] as? String }, ["Sichtbar"])
            let m = try XCTUnwrap(body["brainMandate"] as? [String: Any])
            XCTAssertEqual(m["mode"] as? String, "all_except")
            XCTAssertEqual(ids(m["projectIDs"]), [e.p1])
        }
    }

    func testSetConnectionProjectsWorksWithRules() async throws {
        try await run { e in
            let g = try await group(e, "G", [e.p2])
            let blocked = try await group(e, "Nie", [])
            try await mandate(e, projects: [e.p1, e.p2])
            try await access(e, e.agentGrant, projects: [e.p1], selection(groups: [g], excludedGroups: [blocked]))
            let args: ([UUID], [UUID]) -> [String: Any] = { add, remove in
                ["grantID": e.agentGrant.uuidString, "addProjectIDs": add.map(\.uuidString), "removeProjectIDs": remove.map(\.uuidString), "quote": "Lino: ja"]
            }
            // The list shows what the target reaches inside the own mandate, including the group.
            let list = try await call(e, e.brain, "list_connections")
            let row = try XCTUnwrap((list.json as? [[String: Any]])?.first)
            XCTAssertEqual(Set((row["projects"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }), Set(strings([e.p1, e.p2])))
            // Removing a project that comes through a group excludes it; adding lifts that exclusion again.
            let removed = try await call(e, e.brain, "set_connection_projects", args([], [e.p2]))
            XCTAssertFalse(removed.isError, removed.text)
            try await assertEqual(try await reach(e, e.agent), [e.p1])
            let added = try await call(e, e.brain, "set_connection_projects", args([e.p2], []))
            XCTAssertFalse(added.isError, added.text)
            try await assertEqual(try await reach(e, e.agent), [e.p1, e.p2])
            // An excluded group is the person's rule: nothing is applied.
            try await setMembers(e, blocked, [e.p2])
            let refused = try await call(e, e.brain, "set_connection_projects", args([e.p2], [e.p1]))
            XCTAssertTrue(refused.text.contains("excluded_by_group"), refused.text)
            try await assertEqual(try await reach(e, e.agent), [e.p1])
        }
    }

    func testPlainListWithoutSelectionReplacesTheRule() async throws {
        try await run { e in
            let g = try await group(e, "G", [e.p2])
            try await access(e, e.agentGrant, projects: [], selection(groups: [g]))
            // An old client sends only the list it shows: exactly that stays.
            let r = try await access(e, e.agentGrant, projects: [e.p1])
            XCTAssertTrue(r.body?["selection"] == nil || r.body?["selection"] is NSNull)
            try await setMembers(e, g, [e.p1, e.p2])
            try await assertEqual(try await reach(e, e.agent), [e.p1])
            try await mandate(e, selection(groups: [g]))
            try await mandate(e, projects: [e.p1])
            try await setMembers(e, g, [e.p2])
            try await assertEqual(try await mandated(e), [e.p1])
        }
    }

    // MARK: Preview, project settings, audit, recommendation

    func testPreviewDryRunAndAuditOfGroupChanges() async throws {
        try await run { e in
            let g = try await group(e, "Brain", [e.p1])
            try await mandate(e, selection(groups: [g]))
            let dry = try await setMembers(e, g, [e.p2], dryRun: true)
            let change = try XCTUnwrap(dry.first { $0["kind"] as? String == "mandate" })
            XCTAssertEqual(ids(change["added"]), [e.p2])
            XCTAssertEqual(ids(change["removed"]), [e.p1])
            try await assertEqual(try await mandated(e), [e.p1])
            var audit = try await rest(e, .GET, "/v1/settings/brain-mandate/audit")
            XCTAssertEqual((audit.body?["items"] as? [Any])?.count, 0)
            // Project settings: the person's groups of one project.
            let put = try await rest(e, .PUT, "/v1/projects/\(e.p2)/groups", ["groupIDs": [g.uuidString]])
            XCTAssertEqual(put.status, .ok, "\(put.body ?? [:])")
            let read = try await rest(e, .GET, "/v1/projects/\(e.p2)/groups")
            XCTAssertEqual(ids(read.body?["groupIDs"]), [g])
            try await assertEqual(try await mandated(e), [e.p1, e.p2])
            _ = try await rest(e, .DELETE, "/v1/project-groups/\(g)")
            audit = try await rest(e, .GET, "/v1/settings/brain-mandate/audit")
            let items = try XCTUnwrap(audit.body?["items"] as? [[String: Any]])
            let kinds = items.compactMap { i in (i["kind"] as? String).map { "\($0) \((i["projectID"] as? String) ?? "")" } }.sorted()
            XCTAssertEqual(kinds, ["mandate.group_added \(e.p2)", "mandate.group_removed \(e.p1)", "mandate.group_removed \(e.p2)"].sorted())
            XCTAssertTrue((items.first?["quote"] as? String)?.contains("Brain") ?? false, "\(items)")
        }
    }

    func testBrainRecommendationFollowsTheResolvedMandate() async throws {
        try await run { e in
            let g = try await group(e, "Brain", [e.p2])
            try await mandate(e, selection(groups: [g]))
            try await access(e, e.brainGrant, projects: [e.p2])
            let r = try await review(e, e.p2)
            let row = try await TaskReview.find(UUID(uuidString: r), on: e.f.test.app.db)
            let taskID = try XCTUnwrap(row).taskID
            let c = try await call(e, e.brain, "add_comment", ["taskID": taskID.uuidString, "reviewID": r, "body": "Empfehlung: annehmen"])
            XCTAssertFalse(c.isError, c.text)
            func recommended() async throws -> Bool? {
                let list = try await rest(e, .GET, "/v1/reviews?status=pending")
                return (list.list ?? list.body?["items"] as? [[String: Any]])?.first { ($0["id"] as? String)?.uppercased() == r.uppercased() }?["brainRecommended"] as? Bool
            }
            try await assertEqual(try await recommended(), true)
            try await setMembers(e, g, [])
            try await assertEqual(try await recommended(), false)
        }
    }
}

/// Takeover after a new sign-in (ADR 0036) with rules, and concurrency of group changes against decisions (ADR 0037).
extension ProjectGroupTests {
    private func signIn(_ e: Env, takeover: String? = nil, rule: [String: Any]? = nil, projects: [UUID],
                        between: (() async throws -> Void)? = nil) async throws -> (offer: [String: Any]?, status: HTTPStatus, grant: UUID?) {
        let auth = try await e.f.authorization(scope: Self.scopes)
        let offer = auth.body?["takeover"] as? [String: Any]
        let before = Set(try await OAuthGrant.query(on: e.f.test.app.db).all().compactMap(\.id))
        try await between?()
        var body: [String: Any] = ["consent_token": try XCTUnwrap(auth.body?["consent_token"]), "approve": true, "project_ids": strings(projects)]
        if let rule { body["selection"] = rule }
        if takeover != nil { body["takeover_grant_id"] = try XCTUnwrap(offer?["grant_id"] as? String) }
        let r = try await rest(e, .POST, "/oauth/consent", body)
        let new = try await OAuthGrant.query(on: e.f.test.app.db).all().compactMap(\.id).filter { !before.contains($0) }.first
        return (offer, r.status, new)
    }

    private func explicitMandate(_ e: Env, _ grant: UUID) async throws -> (covered: Set<UUID>, explicit: Set<UUID>, rule: [String: Any]?) {
        let r = try await rest(e, .GET, "/v1/settings/brain-mandate")
        let row = try XCTUnwrap((r.body?["mandates"] as? [[String: Any]])?.first { ($0["grantID"] as? String)?.uppercased() == grant.uuidString })
        return (ids(row["projectIDs"]), ids(row["explicitProjectIDs"]), row["selection"] as? [String: Any])
    }

    /// Only one earlier connection may match, so the fixture's two are cut to the brain's.
    private func onlyBrain(_ e: Env) async throws {
        let r = try await rest(e, .DELETE, "/oauth/grants/\(e.agentGrant)")
        XCTAssertEqual(r.status, .noContent)
    }

    func testTakeoverKeepsTheRuleAndGroupRemovalStillWithdraws() async throws {
        try await run { e in
            try await onlyBrain(e)
            let g = try await group(e, "G", [e.p2])
            try await access(e, e.brainGrant, projects: [e.p1], selection(groups: [g]))
            try await mandate(e, selection(groups: [g]))
            let r = try await signIn(e, takeover: "yes", rule: selection(groups: [g]), projects: [e.p1])
            XCTAssertEqual(r.status, .ok)
            XCTAssertEqual(ids((r.offer?["selection"] as? [String: Any])?["groupIDs"]), [g])
            let mandateOffer = try XCTUnwrap(r.offer?["mandate"] as? [String: Any])
            XCTAssertEqual(ids(mandateOffer["project_ids"]), [e.p2])
            XCTAssertEqual(ids((mandateOffer["selection"] as? [String: Any])?["groupIDs"]), [g])
            let new = try XCTUnwrap(r.grant)
            let m = try await explicitMandate(e, new)
            XCTAssertEqual(m.covered, [e.p2])
            // Group members must not become explicit: leaving the group has to withdraw.
            XCTAssertEqual(m.explicit, [])
            try await setMembers(e, g, [])
            let after = try await explicitMandate(e, new)
            XCTAssertEqual(after.covered, [])
            let list = try await rest(e, .GET, "/oauth/grants")
            let row = try XCTUnwrap(list.list?.first { ($0["id"] as? String)?.uppercased() == new.uuidString })
            XCTAssertEqual(ids(row["project_ids"]), [e.p1])
        }
    }

    func testTakeoverNeverStartsWiderThanThePageShowed() async throws {
        try await run { e in
            try await onlyBrain(e)
            let g = try await group(e, "G", [e.p1])
            try await mandate(e, selection(groups: [g]))
            // The group grows between the page and the click.
            let r = try await signIn(e, takeover: "yes", projects: [e.p1, e.p2], between: { try await self.setMembers(e, g, [e.p1, e.p2]) })
            XCTAssertEqual(r.status, .ok)
            let m = try await explicitMandate(e, try XCTUnwrap(r.grant))
            XCTAssertEqual(m.covered, [e.p1])
        }
    }

    func testTakeoverRefusesAChangedMandateRuleAndDropsUncheckedProjects() async throws {
        try await run { e in
            try await onlyBrain(e)
            try await access(e, e.brainGrant, projects: [e.p1, e.p2])
            try await mandate(e, selection(mode: "all_except"))
            let changed = try await signIn(e, takeover: "yes", projects: [e.p1, e.p2], between: { try await self.mandate(e, projects: [e.p1]) })
            XCTAssertEqual(changed.status, .conflict)
            try await mandate(e, selection(mode: "all_except"))
            let r = try await signIn(e, takeover: "yes", projects: [e.p1])
            XCTAssertEqual(r.status, .ok)
            let m = try await explicitMandate(e, try XCTUnwrap(r.grant))
            XCTAssertEqual(m.covered, [e.p1])
            XCTAssertEqual(ids(m.rule?["excludedProjectIDs"]), [e.p2])
        }
    }

    /// The taken over mandate stays within what the person confirmed: every mandate project that was not chosen is
    /// excluded in the new rule, so no later group membership and no "all except" brings it back.
    func testTakeoverExcludesEveryUnconfirmedMandateProject() async throws {
        for variant in ["all_except", "left-and-back", "group"] {
            try await run { e in
                try await onlyBrain(e)
                let g = try await group(e, "G", [e.p1, e.p2])
                try await access(e, e.brainGrant, projects: [e.p1])
                try await mandate(e, variant == "all_except" ? selection(mode: "all_except") : selection(groups: [g]))
                // "left-and-back": shown on the page, gone from the group at the click, added again afterwards.
                let r = try await signIn(e, takeover: "yes", projects: [e.p1], between: variant == "left-and-back" ? { _ = try await self.setMembers(e, g, [e.p1]) } : nil)
                XCTAssertEqual(r.status, .ok, variant)
                let new = try XCTUnwrap(r.grant)
                let first = try await explicitMandate(e, new)
                XCTAssertEqual(first.covered, [e.p1], variant)
                XCTAssertEqual(ids(first.rule?["excludedProjectIDs"]), [e.p2], variant)
                // Even with access to it again, the mandate does not return to the project.
                try await access(e, new, projects: [e.p1, e.p2])
                _ = try await setMembers(e, g, [e.p1])
                _ = try await setMembers(e, g, [e.p1, e.p2])
                let later = try await explicitMandate(e, new)
                XCTAssertEqual(later.covered, [e.p1], variant)
            }
        }
    }

    /// The page needs to know what the person had named: with a rule only those are ticked.
    func testTakeoverOfferNamesTheExplicitProjectsApartFromGroupMembers() async throws {
        try await run { e in
            try await onlyBrain(e)
            let g = try await group(e, "G", [e.p2])
            try await access(e, e.brainGrant, projects: [e.p1])
            try await mandate(e, selection(groups: [g]))
            let r = try await signIn(e, takeover: "yes", projects: [e.p1])
            let offer = try XCTUnwrap(r.offer)
            XCTAssertEqual(ids(offer["explicit_project_ids"]), [e.p1])
            XCTAssertEqual(ids(offer["project_ids"]), [e.p1, e.p2])
        }
    }

    /// The limits of the security review (ADR 0036) hold for connections with rules too.
    func testTakeoverLimitsHoldWithRules() async throws {
        try await run { e in
            try await onlyBrain(e)
            let g = try await group(e, "G", [e.p1])
            try await access(e, e.brainGrant, selection(groups: [g]))
            try await mandate(e, selection(mode: "all_except"))
            let db = e.f.test.app.db
            let found = try await OAuthGrant.find(e.brainGrant, on: db)
            let old = try XCTUnwrap(found)
            let now = Date()
            old.revoke(.replay, now: now); try await old.save(on: db)
            let clientRow = try await OAuthClient.find(old.clientID, on: db)
            let client = try XCTUnwrap(clientRow)
            func offered(_ c: OAuthClient, days: Double) async throws -> Bool {
                if case .one = try await OAuthTakeover.find(user: e.f.user, client: c, redirect: e.f.redirect,
                    resource: e.f.test.settings.oauthResource, now: now.addingTimeInterval(days * 86_400), on: db) { return true }
                return false
            }
            // Seven days, rule or not.
            let inside = try await offered(client, days: 6.9)
            let outside = try await offered(client, days: 7.1)
            XCTAssertTrue(inside); XCTAssertFalse(outside)
            // By name only with a distinctive name.
            func second(_ name: String) async throws -> OAuthClient {
                let r = try await e.f.test.json(.POST, "/oauth/register", ["client_name": name, "redirect_uris": [e.f.redirect]])
                let id = try XCTUnwrap(r.body?["client_id"] as? String)
                let row = try await OAuthClient.query(on: db).all().first { "\($0.id!)".uppercased() == id.uppercased() }
                return try XCTUnwrap(row)
            }
            let sameName = try await second(client.name)
            let byName = try await offered(sameName, days: 1)
            XCTAssertTrue(byName)
            client.name = OAuthClient.defaultName; try await client.save(on: db)
            let unnamed = try await second(OAuthClient.defaultName)
            let byDefaultName = try await offered(unnamed, days: 1)
            XCTAssertFalse(byDefaultName)
        }
    }

    func testTakeoverWithoutCommonProjectLeavesOneProtocolRowWithRules() async throws {
        try await run { e in
            try await onlyBrain(e)
            let g = try await group(e, "G", [e.p1])
            try await access(e, e.brainGrant, selection(groups: [g]))
            try await mandate(e, selection(groups: [g]))
            let r = try await signIn(e, takeover: "yes", projects: [e.p2])
            XCTAssertEqual(r.status, .ok)
            let new = try XCTUnwrap(r.grant)
            let rows = try await BrainConnectionAudit.query(on: e.f.test.app.db).filter(\.$grantID == new).all()
            XCTAssertEqual(rows.map(\.kind), ["connection.taken_over"])
            XCTAssertEqual(rows.map(\.projectID), [e.brainGrant])
            let list = try await rest(e, .GET, "/v1/settings/brain-mandate")
            let mandates = list.body?["mandates"] as? [[String: Any]] ?? []
            XCTAssertFalse(mandates.contains { ($0["grantID"] as? String)?.uppercased() == new.uuidString })
        }
    }

    /// Lesson of the token rotation (security review 26.11.2026): the locks of a group change must stay on the person's own
    /// rows. Without a fitting index order MariaDB walks the whole primary key and locks other people's mandates.
    func testGroupChangeLocksOnlyThePersonsRows() async throws {
        guard TestApp.useMariaDB else { throw XCTSkip("row locks required (MariaDB)") }
        let t = try await TestApp.make()
        do {
            let app = t.app, db = app.db
            let client = OAuthClient(name: "locks", redirects: []); try await client.save(on: db)
            let clientID = try client.requireID()
            func person(_ connections: Int) async throws -> (user: UUID, mandate: UUID, grant: UUID) {
                let u = User(displayName: "locks \(UUID())", isAdmin: false); try await u.save(on: db)
                let userID = try u.requireID()
                var last = (mandate: UUID(), grant: UUID())
                for _ in 0..<connections {
                    let g = OAuthGrant(userID: userID, clientID: clientID, resource: "r", scopes: [], projects: []); try await g.save(on: db)
                    let m = BrainMandate(userID: userID, grantID: try g.requireID(), projects: []); try await m.save(on: db)
                    last = (try m.requireID(), try g.requireID())
                }
                return (userID, last.mandate, last.grant)
            }
            // One person owns nearly every row: the case in which the optimiser prefers the primary key.
            let a = try await person(60), b = try await person(2)
            let sql = try XCTUnwrap(db as? any SQLDatabase)
            try await sql.raw("ANALYZE TABLE brain_mandates, oauth_grants").run()
            var loops = app.eventLoopGroup.makeIterator()
            let first = try XCTUnwrap(loops.next()), second = try XCTUnwrap(loops.next())
            let holding = try XCTUnwrap(app.databases.database(logger: app.logger, on: first))
            let asking = try XCTUnwrap(app.databases.database(logger: app.logger, on: second))
            try await holding.transaction { holder in
                try await ProjectGroupService.lock(userID: a.user, on: holder)
                try await asking.transaction { other in
                    try await (other as! any SQLDatabase).raw("SET innodb_lock_wait_timeout = 1").run()
                    try await lockRow(table: BrainMandate.schema, id: b.mandate, on: other)
                    try await lockRow(table: OAuthGrant.schema, id: b.grant, on: other)
                }
            }
        } catch { await t.shutdown(); XCTFail("\(String(reflecting: error))"); return }
        await t.shutdown()
    }

    /// Group changes lock mandates before grants like decisions do; on MariaDB a wrong order shows up as a deadlock error.
    func testGroupChangesDecisionsAndAccessChangesAtOnce() async throws {
        guard TestApp.useMariaDB else { throw XCTSkip("row locks required (MariaDB)") }
        try await run { e in
            let g = try await group(e, "G", [e.p2])
            try await access(e, e.brainGrant, selection(groups: [g]))
            try await mandate(e, selection(groups: [g]))
            let f = e.f, brain = e.brain
            let p2 = e.p2.uuidString, p1 = e.p1.uuidString, gid = g.uuidString, brainGrant = e.brainGrant.uuidString, agentGrant = e.agentGrant.uuidString
            for round in 0..<8 {
                let r = try await review(e, e.p2)
                let row = try await TaskReview.find(UUID(uuidString: r), on: f.test.app.db)
                let task = try XCTUnwrap(row).taskID.uuidString
                let members = round % 2 == 0 ? [String]() : [p2]
                let results = try await withThrowingTaskGroup(of: String.self) { tasks in
                    tasks.addTask {
                        let d = try await f.rpc("tools/call", ["name": "decide_review", "arguments": ["taskID": task, "decision": "accept", "quote": "ok"]], access: brain)
                        let text = ((d.body?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String ?? "no result"
                        let fine = text.contains("outside_brain_mandate") || text.contains("not_found") || (d.body?["result"] as? [String: Any])?["isError"] as? Bool != true
                        return fine ? "ok" : text
                    }
                    tasks.addTask {
                        let c = try await f.test.json(.PATCH, "/v1/project-groups/\(gid)", ["projectIDs": members], token: f.session)
                        return c.status == .ok ? "ok" : "group \(c.body ?? [:])"
                    }
                    tasks.addTask {
                        let a = try await f.test.json(.PUT, "/oauth/grants/\(agentGrant)/projects", ["project_ids": [p1], "selection": ["groupIDs": [gid]]], token: f.session)
                        return a.status == .ok ? "ok" : "access \(a.body ?? [:])"
                    }
                    tasks.addTask {
                        let m = try await f.test.json(.PUT, "/v1/settings/brain-mandate", ["grantID": brainGrant, "projectIDs": [String](), "selection": ["groupIDs": [gid]]], token: f.session)
                        return m.status == .ok ? "ok" : "mandate \(m.body ?? [:])"
                    }
                    var out: [String] = []
                    for try await t in tasks { out.append(t) }
                    return out
                }
                XCTAssertEqual(results, ["ok", "ok", "ok", "ok"], "round \(round)")
                try await setMembers(e, g, [e.p2])
            }
        }
    }
}
