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

    private typealias Reply = (status: HTTPStatus, body: [String: Any]?, list: [[String: Any]]?, cookie: String?)
    static let scopes = CommandCenterTests.scopes + " projects:write"

    private func env() async throws -> Env {
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

    private func run(_ body: (Env) async throws -> Void) async throws {
        let e = try await env()
        do { try await body(e) } catch { await e.f.test.shutdown(); throw error }
        await e.f.test.shutdown()
    }

    // MARK: Helpers

    private func rest(_ e: Env, _ method: HTTPMethod, _ path: String, _ body: [String: Any]? = nil, token: String? = nil) async throws -> Reply {
        try await e.f.test.json(method, path, body, token: token ?? e.f.session)
    }

    private func call(_ e: Env, _ token: String, _ name: String, _ args: [String: Any] = [:]) async throws -> (isError: Bool, text: String, json: Any?) {
        let r = try await e.f.rpc("tools/call", ["name": name, "arguments": args], access: token)
        let result = try XCTUnwrap(r.body?["result"] as? [String: Any], "no result for \(name): \(r.body ?? [:])")
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        return (result["isError"] as? Bool ?? false, text, try? JSONSerialization.jsonObject(with: Data(text.utf8)))
    }

    private func ids(_ value: Any?) -> Set<UUID> { Set((value as? [String] ?? []).compactMap(UUID.init(uuidString:))) }
    private func strings(_ ids: [UUID]) -> [String] { ids.map(\.uuidString) }

    private func group(_ e: Env, _ name: String, _ projects: [UUID]) async throws -> UUID {
        let r = try await rest(e, .POST, "/v1/project-groups", ["name": name, "projectIDs": strings(projects)])
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
        return try XCTUnwrap(((r.body?["group"] as? [String: Any])?["id"] as? String).flatMap(UUID.init(uuidString:)))
    }

    @discardableResult
    private func setMembers(_ e: Env, _ group: UUID, _ projects: [UUID], dryRun: Bool = false) async throws -> [[String: Any]] {
        let r = try await rest(e, .PATCH, "/v1/project-groups/\(group)\(dryRun ? "?dryRun=true" : "")", ["projectIDs": strings(projects)])
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
        return r.body?["changes"] as? [[String: Any]] ?? []
    }

    private func selection(mode: String = "selected", groups: [UUID] = [], excluded: [UUID] = [], excludedGroups: [UUID] = []) -> [String: Any] {
        ["mode": mode, "groupIDs": strings(groups), "excludedProjectIDs": strings(excluded), "excludedGroupIDs": strings(excludedGroups)]
    }

    @discardableResult
    private func mandate(_ e: Env, grant: UUID? = nil, projects: [UUID] = [], _ rule: [String: Any]? = nil, expect: HTTPStatus = .ok) async throws -> Reply {
        var body: [String: Any] = ["grantID": (grant ?? e.brainGrant).uuidString, "projectIDs": strings(projects)]
        if let rule { body["selection"] = rule }
        let r = try await rest(e, .PUT, "/v1/settings/brain-mandate", body)
        XCTAssertEqual(r.status, expect, "\(r.body ?? [:])")
        return r
    }

    @discardableResult
    private func access(_ e: Env, _ grant: UUID, projects: [UUID] = [], _ rule: [String: Any]? = nil, expect: HTTPStatus = .ok) async throws -> Reply {
        var body: [String: Any] = ["project_ids": strings(projects)]
        if let rule { body["selection"] = rule }
        let r = try await rest(e, .PUT, "/oauth/grants/\(grant)/projects", body)
        XCTAssertEqual(r.status, expect, "\(r.body ?? [:])")
        return r
    }

    /// The projects `get_connection` reports: what the connection reaches.
    private func reach(_ e: Env, _ token: String) async throws -> Set<UUID> {
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
    private func review(_ e: Env, _ project: UUID) async throws -> String {
        let task = TodoTask(ownerID: try e.f.user.requireID(), projectID: project, title: "T")
        try await task.save(on: e.f.test.app.db)
        try await access(e, e.agentGrant, projects: [e.p1, project])
        let r = try await call(e, e.agent, "request_review", ["taskID": try task.requireID().uuidString, "summary": "Done"])
        XCTAssertFalse(r.isError, r.text)
        return try XCTUnwrap((r.json as? [String: Any])?["id"] as? String)
    }

    private func decide(_ e: Env, _ review: String) async throws -> (isError: Bool, text: String) {
        let r = try await call(e, e.brain, "decide_review", ["reviewID": review, "decision": "accept", "quote": "Lino: ok"])
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
