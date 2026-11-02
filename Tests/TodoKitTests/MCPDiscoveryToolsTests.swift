import Fluent
import XCTVapor
@testable import TodoKit

final class MCPDiscoveryToolsTests: XCTestCase {
    func testDiscoveryToolRegistrationAndScopes() {
        let expected = ["search_tasks", "list_labels", "create_label", "update_label", "set_task_labels", "delete_label", "list_filters", "create_filter", "update_filter", "run_filter", "delete_filter"]
        for name in expected { XCTAssertTrue(MCPController.tools.contains { $0.name == name }, name) }
        for scope in ["labels:read", "labels:write", "filters:read", "filters:write"] { XCTAssertTrue(OAuthController.scopes.contains(scope), scope) }
    }
}

extension MCPDiscoveryToolsTests {
    private func call(_ f: OAuthFixture, _ name: String, _ args: [String: Any] = [:], _ access: String) async throws -> (error: Bool, text: String, value: Any?) {
        let r = try await f.rpc("tools/call", ["name": name, "arguments": args], access: access)
        let result = try XCTUnwrap(r.body?["result"] as? [String: Any], String(describing: r.body))
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        return (result["isError"] as? Bool ?? false, text, try? JSONSerialization.jsonObject(with: Data(text.utf8)))
    }
    private var scopes: String { "tasks:read labels:read labels:write filters:read filters:write" }
    private func fixture(_ run: (OAuthFixture, String) async throws -> Void) async throws {
        let f = try await OAuthFixture.make()
        do { let t = try await f.tokens(scope: scopes); try await run(f, t.access) }
        catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testSearchGrantBeforeLimitAndMalformedArguments() async throws {
        try await fixture { f, access in
            let db = f.test.app.db
            let allowed = TodoTask(ownerID: try f.user.requireID(), projectID: try f.project.requireID(), title: "Needle", details: "visible")
            try await allowed.save(on: db)
            for _ in 0..<110 { try await TodoTask(ownerID: f.user.requireID(), projectID: f.other.requireID(), title: "Needle", details: "SECRET EXCLUDED").save(on: db) }
            let r = try await call(f, "search_tasks", ["query": "Needle", "limit": 1], access)
            XCTAssertFalse(r.error, r.text)
            XCTAssertFalse(r.text.contains("SECRET"))
            let items = (r.value as? [String: Any])?["items"] as? [[String: Any]]
            XCTAssertEqual(items?.count, 1)
            XCTAssertEqual(items?.first?["id"] as? String, allowed.id?.uuidString)
            for args: [String: Any] in [["query": "Needle", "projectID": try f.other.requireID().uuidString], ["query": "Needle", "projectID": UUID().uuidString]] {
                let r = try await call(f, "search_tasks", args, access); XCTAssertEqual(r.text, "not_found")
            }
            for args: [String: Any] in [["query": 5], ["query": "x", "limit": 1.5], ["query": "x", "limit": 101], ["query": "x", "limit": 1e40], ["query": "x", "status": "wrong"], ["query": String(repeating: "x", count: 501)]] {
                let r = try await call(f, "search_tasks", args, access); XCTAssertTrue(r.error, r.text)
            }
        }
    }

    func testLabelsCRUDReplacementPrivacyAndConflict() async throws {
        try await fixture { f, access in
            let db = f.test.app.db
            let t = TodoTask(ownerID: try f.user.requireID(), projectID: try f.project.requireID(), title: "Task", details: "")
            try await t.save(on: db)
            let created = try await call(f, "create_label", ["name": "Mine", "color": "#123abc"], access)
            XCTAssertFalse(created.error, created.text)
            let label = try XCTUnwrap(created.value as? [String: Any]); let id = try XCTUnwrap(label["id"] as? String)
            XCTAssertEqual(label["color"] as? String, "#123abc")
            let updated = try await call(f, "update_label", ["labelID": id, "version": 1, "name": "Renamed"], access)
            XCTAssertEqual((updated.value as? [String: Any])?["version"] as? Int, 2)
            let stale = try await call(f, "update_label", ["labelID": id, "version": 1, "name": "Lost"], access); XCTAssertEqual(stale.text, "version_conflict")
            let listed = try await call(f, "list_labels", [:], access); XCTAssertEqual((listed.value as? [[String: Any]])?.count, 1)
            let other = User(displayName: "Other", isAdmin: false); try await other.save(on: db)
            let foreign = DiscoveryLabel(ownerID: try other.requireID(), name: "PRIVATE"); try await foreign.save(on: db)
            try await DiscoveryTaskLabel(taskID: t.requireID(), labelID: foreign.requireID()).save(on: db)
            let set = try await call(f, "set_task_labels", ["taskID": try t.requireID().uuidString, "labelIDs": [id]], access); XCTAssertFalse(set.error, set.text)
            let clear = try await call(f, "set_task_labels", ["taskID": try t.requireID().uuidString, "labelIDs": []], access); XCTAssertFalse(clear.error)
            let links = try await DiscoveryTaskLabel.query(on: db).filter(\.$taskID == t.requireID()).all()
            XCTAssertEqual(links.map(\.labelID), [try foreign.requireID()])
            let excluded = TodoTask(ownerID: try f.user.requireID(), projectID: try f.other.requireID(), title: "Excluded", details: ""); try await excluded.save(on: db)
            let denied = try await call(f, "set_task_labels", ["taskID": try excluded.requireID().uuidString, "labelIDs": [id]], access); XCTAssertEqual(denied.text, "not_found")
            for name in ["update_label", "delete_label"] {
                let denied = try await call(f, name, ["labelID": try foreign.requireID().uuidString, "version": 1], access); XCTAssertEqual(denied.text, "not_found")
            }
            for args: [String: Any] in [["name": ""], ["name": "x", "color": "red"], ["name": "x", "color": "#123abc\n"]] {
                let r = try await call(f, "create_label", args, access); XCTAssertTrue(r.error)
            }
            let bad = try await call(f, "set_task_labels", ["taskID": try t.requireID().uuidString, "labelIDs": [id, 5]], access); XCTAssertTrue(bad.error)
        }
    }

    func testFiltersCRUDRunGrantLabelLinksAndConflict() async throws {
        try await fixture { f, access in
            let db = f.test.app.db
            let label = DiscoveryLabel(ownerID: try f.user.requireID(), name: "Both"); try await label.save(on: db)
            for project in [f.project, f.other] {
                let t = TodoTask(ownerID: try f.user.requireID(), projectID: try project.requireID(), title: project.name, details: "")
                try await t.save(on: db); try await DiscoveryTaskLabel(taskID: t.requireID(), labelID: label.requireID()).save(on: db)
            }
            let created = try await call(f, "create_filter", ["name": "Mine", "query": ["labelID": try label.requireID().uuidString]], access)
            XCTAssertFalse(created.error, created.text)
            let id = try XCTUnwrap((created.value as? [String: Any])?["id"] as? String)
            let result = try await call(f, "run_filter", ["filterID": id, "limit": 100], access)
            XCTAssertFalse(result.error, result.text); XCTAssertFalse(result.text.contains("Excluded"))
            XCTAssertEqual(((result.value as? [String: Any])?["items"] as? [Any])?.count, 1)
            let updated = try await call(f, "update_filter", ["filterID": id, "version": 1, "query": "Allowed"], access); XCTAssertFalse(updated.error, updated.text)
            let stale = try await call(f, "update_filter", ["filterID": id, "version": 1, "name": "Lost"], access); XCTAssertEqual(stale.text, "version_conflict")
            let listed = try await call(f, "list_filters", [:], access); XCTAssertEqual((listed.value as? [Any])?.count, 1)
            let denied = try await call(f, "create_filter", ["name": "Excluded", "query": ["projectID": try f.other.requireID().uuidString]], access); XCTAssertEqual(denied.text, "not_found")
            let foreign = User(displayName: "Other", isAdmin: false); try await foreign.save(on: db)
            let row = try DiscoverySavedFilter(ownerID: foreign.requireID(), name: "PRIVATE", criteria: DiscoveryCriteria()); try await row.save(on: db)
            for name in ["run_filter", "update_filter", "delete_filter"] {
                let args: [String: Any] = name == "update_filter" ? ["filterID": try row.requireID().uuidString, "version": 1] : ["filterID": try row.requireID().uuidString]
                let r = try await call(f, name, args, access); XCTAssertEqual(r.text, "not_found")
            }
        }
    }

    func testEveryToolRequiresItsScopeAndExistingConnectionsDoNotGainScopes() async throws {
        let f = try await OAuthFixture.make()
        do {
            let old = try await f.tokens(scope: "projects:read")
            for tool in MCPController.discoveryTools {
                let r = try await call(f, tool.name, [:], old.access); XCTAssertEqual(r.text, "insufficient_scope", tool.name)
            }
            let list = try await f.rpc("tools/list", access: old.access)
            let names = ((list.body?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            XCTAssertFalse(names.contains("create_label"))
            let metadata = try await f.test.json(.GET, "/.well-known/oauth-authorization-server")
            XCTAssertTrue((metadata.body?["scopes_supported"] as? [String])?.contains("filters:write") == true)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testEveryToolRejectsMalformedInputAndRunRequiresTaskRead() async throws {
        try await fixture { f, access in
            let id = UUID().uuidString
            let cases: [(String, [String: Any])] = [
                ("search_tasks", ["query": 5]), ("list_labels", ["unexpected": true]),
                ("create_label", ["name": 5]), ("update_label", ["labelID": id, "version": 1.5]),
                ("set_task_labels", ["taskID": id, "labelIDs": "bad"]), ("delete_label", ["labelID": "bad"]),
                ("list_filters", ["unexpected": true]), ("create_filter", ["name": "x", "query": ["unexpected": true]]),
                ("update_filter", ["filterID": id, "version": 1e40]), ("run_filter", ["filterID": "bad"]),
                ("delete_filter", ["filterID": id, "version": -1])]
            for (name, args) in cases {
                let r = try await call(f, name, args, access); XCTAssertTrue(r.error, name + ": " + r.text)
            }
            let row = try await DiscoveryService(user: f.user, db: f.test.app.db).createFilter(name: "Outside", criteria: DiscoveryCriteria(projectID: f.other.requireID()))
            let run = try await call(f, "run_filter", ["filterID": row.id.uuidString], access); XCTAssertEqual(run.text, "not_found")
            let readOnly = try await f.tokens(scope: "filters:read")
            let denied = try await call(f, "run_filter", ["filterID": row.id.uuidString], readOnly.access); XCTAssertEqual(denied.text, "insufficient_scope")
        }
    }

    func testDeleteRequestsConfirmAndRecheckVersions() async throws {
        try await fixture { f, access in
            for isLabel in [true, false] {
                let created = try await call(f, isLabel ? "create_label" : "create_filter", isLabel ? ["name": "Delete"] : ["name": "Delete", "query": ""], access)
                let id = try XCTUnwrap((created.value as? [String: Any])?["id"] as? String)
                let key = isLabel ? "labelID" : "filterID"
                let deleted = try await call(f, isLabel ? "delete_label" : "delete_filter", [key: id, "version": 1], access)
                XCTAssertTrue(deleted.error)
                XCTAssertEqual((deleted.value as? [String: Any])?["error"] as? String, "confirmation_required")
                let request = try XCTUnwrap((deleted.value as? [String: Any])?["actionRequestID"] as? String)
                let list = try await call(f, isLabel ? "list_labels" : "list_filters", [:], access); XCTAssertEqual((list.value as? [Any])?.count, 1)
                let confirmed = try await f.test.json(.POST, "/v1/action-requests/\(request)/confirm", token: f.session)
                XCTAssertEqual(confirmed.body?["state"] as? String, "executed")
                let after = try await call(f, isLabel ? "list_labels" : "list_filters", [:], access); XCTAssertEqual((after.value as? [Any])?.count, 0)
            }
        }
    }
}

extension MCPDiscoveryToolsTests {
    func testReadRoleSufficesForPrivateLabelsAndRevocationHidesTasks() async throws {
        try await fixture { f, access in
            let db = f.test.app.db
            let owner = User(displayName: "Owner", isAdmin: false); try await owner.save(on: db)
            let policy = try await ProjectSharing.query(on: db).filter(\.$projectID == f.project.requireID()).first() ?? ProjectSharing(project: f.project)
            policy.ownerID = try owner.requireID(); try await policy.save(on: db)
            let share = ProjectGrant(projectID: try f.project.requireID(), principalType: "person", principalID: try f.user.requireID(), role: .read)
            try await share.save(on: db)
            let t = TodoTask(ownerID: try owner.requireID(), projectID: try f.project.requireID(), title: "Shared needle", details: "")
            try await t.save(on: db)
            let label = DiscoveryLabel(ownerID: try f.user.requireID(), name: "Private"); try await label.save(on: db)
            let args: [String: Any] = ["taskID": try t.requireID().uuidString, "labelIDs": [try label.requireID().uuidString]]
            let set = try await call(f, "set_task_labels", args, access); XCTAssertFalse(set.error, set.text)
            let filter = try await call(f, "create_filter", ["name": "Shared", "query": ["labelID": try label.requireID().uuidString]], access)
            let fid = try XCTUnwrap((filter.value as? [String: Any])?["id"] as? String)
            try await share.delete(on: db)
            let hidden = try await call(f, "search_tasks", ["query": "needle"], access)
            XCTAssertFalse(hidden.error); XCTAssertEqual(((hidden.value as? [String: Any])?["items"] as? [Any])?.count, 0)
            let run = try await call(f, "run_filter", ["filterID": fid], access)
            XCTAssertFalse(run.error); XCTAssertEqual(((run.value as? [String: Any])?["items"] as? [Any])?.count, 0)
            let gone = try await call(f, "set_task_labels", args, access); XCTAssertEqual(gone.text, "not_found")
        }
    }

    func testConfirmationRechecksVersionAndScopeAndDoesNotDelete() async throws {
        try await fixture { f, access in
            for isLabel in [true, false] {
                let create = isLabel ? "create_label" : "create_filter"
                let update = isLabel ? "update_label" : "update_filter"
                let delete = isLabel ? "delete_label" : "delete_filter"
                let key = isLabel ? "labelID" : "filterID"
                let created = try await call(f, create, isLabel ? ["name": "Keep"] : ["name": "Keep", "query": ""], access)
                let id = try XCTUnwrap((created.value as? [String: Any])?["id"] as? String)
                let deletion = try await call(f, delete, [key: id, "version": 1], access)
                let request = try XCTUnwrap((deletion.value as? [String: Any])?["actionRequestID"] as? String)
                let updated = try await call(f, update, [key: id, "version": 1, "name": "Changed"], access); XCTAssertFalse(updated.error, updated.text)
                let confirmed = try await f.test.json(.POST, "/v1/action-requests/\(request)/confirm", token: f.session)
                XCTAssertEqual(confirmed.body?["state"] as? String, "failed")
                XCTAssertEqual((confirmed.body?["result"] as? [String: Any])?["code"] as? String, "version_conflict")
                let again = try await call(f, delete, [key: id, "version": 2], access)
                let next = try XCTUnwrap((again.value as? [String: Any])?["actionRequestID"] as? String)
                let stored = try await ActionRequest.find(UUID(uuidString: next), on: f.test.app.db)
                let foundGrant = try await OAuthGrant.find(stored?.grantID, on: f.test.app.db)
                let grant = try XCTUnwrap(foundGrant)
                grant.scopes.removeAll { $0 == (isLabel ? "labels:write" : "filters:write") }
                try await grant.save(on: f.test.app.db)
                let denied = try await f.test.json(.POST, "/v1/action-requests/\(next)/confirm", token: f.session)
                XCTAssertEqual(denied.body?["state"] as? String, "failed")
                XCTAssertEqual((denied.body?["result"] as? [String: Any])?["code"] as? String, "insufficient_scope")
                // Restore this fixture's grant for the second metadata type.
                grant.scopes = scopes.split(separator: " ").map(String.init); try await grant.save(on: f.test.app.db)
            }
        }
    }
}
