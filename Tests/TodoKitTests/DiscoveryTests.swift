import Fluent
import XCTVapor
@testable import TodoKit

final class DiscoveryTests: XCTestCase {
    private func account(_ t: TestApp, _ name: String) async throws -> (User, String) {
        let user = User(displayName: name, isAdmin: false)
        try await user.save(on: t.app.db)
        let token = AuthSupport.randomToken()
        try await UserSession(userID: user.requireID(), tokenHash: AuthSupport.hash(token), expiresAt: .distantFuture)
            .save(on: t.app.db)
        return (user, token)
    }

    private func project(_ t: TestApp, _ user: User, _ name: String) async throws -> Project {
        let project = Project(ownerID: try user.requireID(), parentID: nil, name: name)
        try await project.save(on: t.app.db)
        return project
    }

    private func task(_ t: TestApp, _ user: User, _ project: Project, _ title: String, details: String = "", id: UUID? = nil) async throws -> TodoTask {
        let task = TodoTask(ownerID: try user.requireID(), projectID: try project.requireID(), title: title, details: details)
        task.id = id
        try await task.save(on: t.app.db)
        return task
    }

    private func items(_ response: [String: Any]?) -> [[String: Any]] { response?["items"] as? [[String: Any]] ?? [] }
    private func encoded(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: .alphanumerics)! }

    func testAuthenticationAndPrivateMetadata() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        for path in ["/v1/search", "/v1/labels", "/v1/filters"] {
            let result = try await t.json(.GET, path)
            XCTAssertEqual(result.status, .unauthorized)
        }
        let (alice, a) = try await account(t, "Alice")
        let (bob, b) = try await account(t, "Bob")
        let p = try await project(t, alice, "Private project")
        let ownTask = try await task(t, alice, p, "Private task")
        let foreignProject = try await project(t, bob, "Foreign")
        let foreignTask = try await task(t, bob, foreignProject, "Foreign")
        let label = try await t.json(.POST, "/v1/labels", ["name": "Personal"], token: a)
        XCTAssertEqual(label.status, .created)
        let lid = label.body!["id"] as! String
        let tid = try ownTask.requireID()
        for _ in 0..<2 {
            let attach = try await t.json(.PUT, "/v1/tasks/\(tid)/labels/\(lid)", token: a)
            XCTAssertEqual(attach.status, .noContent)
        }
        let links = try await DiscoveryTaskLabel.query(on: t.app.db).all()
        XCTAssertEqual(links.count, 1)
        let ownLabels = try await t.json(.GET, "/v1/tasks/\(tid)/labels", token: a)
        XCTAssertEqual(items(ownLabels.body).count, 1)
        let filter = try await t.json(.POST, "/v1/filters", ["name": "Mine", "criteria": ["labelID": lid, "status": "open"]], token: a)
        XCTAssertEqual(filter.status, .created)
        let fid = filter.body!["id"] as! String
        let results = try await t.json(.GET, "/v1/filters/\(fid)/results", token: a)
        XCTAssertEqual(items(results.body).first?["id"] as? String, tid.uuidString)
        for path in ["/v1/labels", "/v1/filters", "/v1/search"] {
            let response = try await t.json(.GET, path, token: b)
            if path != "/v1/search" { XCTAssertTrue(items(response.body).isEmpty) }
            XCTAssertFalse(String(describing: response.body).contains("Private"))
            XCTAssertFalse(String(describing: response.body).contains("Personal"))
        }
        for (method, path) in [(HTTPMethod.PATCH, "/v1/labels/\(lid)"), (.DELETE, "/v1/labels/\(lid)"),
                               (.GET, "/v1/filters/\(fid)/results"), (.PATCH, "/v1/filters/\(fid)"), (.DELETE, "/v1/filters/\(fid)"),
                               (.GET, "/v1/tasks/\(tid)/labels"), (.PUT, "/v1/tasks/\(tid)/labels/\(lid)"), (.DELETE, "/v1/tasks/\(tid)/labels/\(lid)")] {
            let response = try await t.json(method, path, ["name": "Hack", "version": 1, "criteria": [:]], token: b)
            XCTAssertEqual(response.status, .notFound, path)
        }
        let foreignTaskID = try foreignTask.requireID()
        let attachForeign = try await t.json(.PUT, "/v1/tasks/\(foreignTaskID)/labels/\(lid)", token: a)
        XCTAssertEqual(attachForeign.status, .notFound)
        let pid = try p.requireID()
        for query in ["labelID=\(lid)", "projectID=\(pid)"] {
            let response = try await t.json(.GET, "/v1/search?\(query)", token: b)
            XCTAssertEqual(response.status, .notFound)
        }
        let foreignFilter = try await t.json(.POST, "/v1/filters", ["name": "Hack", "criteria": ["labelID": lid]], token: b)
        XCTAssertEqual(foreignFilter.status, .notFound)
        let update = try await t.json(.PATCH, "/v1/labels/\(lid)", ["name": "Renamed", "version": 1], token: a)
        XCTAssertEqual(update.body?["version"] as? Int, 2)
        let stale = try await t.json(.PATCH, "/v1/labels/\(lid)", ["name": "Lost", "version": 1], token: a)
        XCTAssertEqual(stale.status, .conflict)
        let filterUpdate = try await t.json(.PATCH, "/v1/filters/\(fid)", ["name": "Updated", "criteria": ["q": "Private"], "version": 1], token: a)
        XCTAssertEqual(filterUpdate.body?["version"] as? Int, 2)
        let filterStale = try await t.json(.PATCH, "/v1/filters/\(fid)", ["name": "Lost", "criteria": [:], "version": 1], token: a)
        XCTAssertEqual(filterStale.status, .conflict)
        let detach = try await t.json(.DELETE, "/v1/tasks/\(tid)/labels/\(lid)", token: a)
        XCTAssertEqual(detach.status, .noContent)
        let empty = try await t.json(.GET, "/v1/tasks/\(tid)/labels", token: a)
        XCTAssertTrue(items(empty.body).isEmpty)
        _ = try await t.json(.PUT, "/v1/tasks/\(tid)/labels/\(lid)", token: a)
        let deleteLabel = try await t.json(.DELETE, "/v1/labels/\(lid)", token: a)
        XCTAssertEqual(deleteLabel.status, .noContent)
        let remainingLinks = try await DiscoveryTaskLabel.query(on: t.app.db).count()
        XCTAssertEqual(remainingLinks, 0)
        let deleteFilter = try await t.json(.DELETE, "/v1/filters/\(fid)", token: a)
        XCTAssertEqual(deleteFilter.status, .noContent)
    }

    func testManyToManyAndSavedCriteriaAreLive() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let (alice, a) = try await account(t, "Alice")
        let p = try await project(t, alice, "Work")
        let other = try await project(t, alice, "Other")
        let first = try await task(t, alice, p, "Needle one")
        let second = try await task(t, alice, p, "Needle two")
        let outside = try await task(t, alice, other, "Needle three")
        let label = try await t.json(.POST, "/v1/labels", ["name": "Focus"], token: a)
        let extra = try await t.json(.POST, "/v1/labels", ["name": "Extra"], token: a)
        let lid = label.body!["id"] as! String
        for task in [first, second, outside] {
            let result = try await t.json(.PUT, "/v1/tasks/\(task.requireID())/labels/\(lid)", token: a)
            XCTAssertEqual(result.status, .noContent)
        }
        _ = try await t.json(.PUT, "/v1/tasks/\(first.requireID())/labels/\(extra.body!["id"]!)", token: a)
        let labels = try await t.json(.GET, "/v1/tasks/\(first.requireID())/labels", token: a)
        XCTAssertEqual(items(labels.body).count, 2)
        let criteria: [String: Any] = ["q": "Needle", "projectID": try p.requireID().uuidString, "labelID": lid, "status": "open"]
        let filter = try await t.json(.POST, "/v1/filters", ["name": "Focus", "criteria": criteria], token: a)
        XCTAssertEqual(filter.status, .created)
        let path = "/v1/filters/\(filter.body!["id"]!)/results"
        let initial = try await t.json(.GET, path, token: a)
        XCTAssertEqual(Set(items(initial.body).map { $0["id"] as! String }), [try first.requireID().uuidString, try second.requireID().uuidString])
        second.status = "done"
        try await second.save(on: t.app.db)
        let updated = try await t.json(.GET, path, token: a)
        XCTAssertEqual(items(updated.body).map { $0["id"] as! String }, [try first.requireID().uuidString])
        _ = try await t.json(.DELETE, "/v1/labels/\(lid)", token: a)
        let missingLabel = try await t.json(.GET, path, token: a)
        XCTAssertEqual(missingLabel.status, .notFound)
        let emptyName = try await t.json(.POST, "/v1/labels", ["name": "  "], token: a)
        XCTAssertEqual(emptyName.status, .badRequest)
        let badStatus = try await t.json(.POST, "/v1/filters", ["name": "Bad", "criteria": ["status": "invalid"]], token: a)
        XCTAssertEqual(badStatus.status, .badRequest)
    }

    func testLiteralSubstringSearchAndProjectNames() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let (alice, a) = try await account(t, "Alice")
        let p = try await project(t, alice, "Plain")
        let percent = try await task(t, alice, p, "100% ready")
        let underscore = try await task(t, alice, p, "under_score")
        let bang = try await task(t, alice, p, "Bang", details: "literal!value")
        let slash = try await task(t, alice, p, "Back\\slash")
        let injection = try await task(t, alice, p, "' OR 1=1 --")
        _ = try await task(t, alice, p, "100X ready underXscore")
        for (q, expected) in [("%", percent), ("_", underscore), ("!", bang), ("\\", slash), ("' OR 1=1 --", injection), ("teral!val", bang)] {
            let response = try await t.json(.GET, "/v1/search?q=\(encoded(q))", token: a)
            XCTAssertEqual(response.status, .ok)
            XCTAssertEqual(items(response.body).map { $0["id"] as! String }, [try expected.requireID().uuidString], q)
        }
        let named = try await project(t, alice, "needle project")
        let namedTask = try await task(t, alice, named, "Different title")
        let response = try await t.json(.GET, "/v1/search?q=needle", token: a)
        XCTAssertEqual(items(response.body).map { $0["kind"] as! String }, ["project", "task"])
        XCTAssertEqual(items(response.body).last?["id"] as? String, try namedTask.requireID().uuidString)
    }

    func testRevocationIsRecheckedForCursorAndSavedFilters() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let (alice, a) = try await account(t, "Alice")
        let (bob, b) = try await account(t, "Bob")
        let p = try await project(t, alice, "Visible")
        let revoked = try await project(t, alice, "Revoked secret")
        let first = UUID(uuidString: "10000000-0000-0000-0000-000000000010")!
        let second = UUID(uuidString: "10000000-0000-0000-0000-000000000020")!
        let third = UUID(uuidString: "10000000-0000-0000-0000-000000000030")!
        _ = try await task(t, alice, p, "First", id: first)
        _ = try await task(t, alice, revoked, "Revoked secret", id: second)
        _ = try await task(t, alice, p, "Last", id: third)
        let filter = try await t.json(.POST, "/v1/filters", ["name": "Open", "criteria": ["status": "open"]], token: a)
        let fid = filter.body!["id"] as! String
        let scoped = try await t.json(.POST, "/v1/filters", ["name": "Scoped", "criteria": ["projectID": try revoked.requireID().uuidString]], token: a)
        let scopedID = scoped.body!["id"] as! String
        let page = try await t.json(.GET, "/v1/filters/\(fid)/results?limit=1", token: a)
        XCTAssertEqual(items(page.body).first?["id"] as? String, first.uuidString)
        let cursor = page.body!["nextCursor"] as! String
        // Current ProjectAccess has ownership only. Changing project ownership revokes access while
        // deliberately retaining the task owner and saved criteria to catch stale authorization.
        revoked.ownerID = try bob.requireID()
        try await revoked.save(on: t.app.db)
        let next = try await t.json(.GET, "/v1/filters/\(fid)/results?limit=1&cursor=\(cursor)", token: a)
        XCTAssertEqual(items(next.body).map { $0["id"] as! String }, [third.uuidString])
        XCTAssertNil(next.body?["nextCursor"])
        XCTAssertFalse(String(describing: next.body).contains("Revoked secret"))
        XCTAssertNil(next.body?["total"])
        let scopedResult = try await t.json(.GET, "/v1/filters/\(scopedID)/results", token: a)
        XCTAssertEqual(scopedResult.status, .notFound)
        let label = try await t.json(.POST, "/v1/labels", ["name": "Mine"], token: a)
        let attach = try await t.json(.PUT, "/v1/tasks/\(second)/labels/\(label.body!["id"]!)", token: a)
        XCTAssertEqual(attach.status, .notFound)
        let labels = try await t.json(.GET, "/v1/tasks/\(second)/labels", token: a)
        XCTAssertEqual(labels.status, .notFound)
        // Tasks follow their current project, so Bob sees exactly the task in the project he now owns.
        let bobResult = try await t.json(.GET, "/v1/search?status=open", token: b)
        XCTAssertEqual(items(bobResult.body).map { $0["id"] as! String }, [second.uuidString])
        let wrongUser = try await t.json(.GET, "/v1/search?status=open&cursor=\(cursor)", token: b)
        XCTAssertEqual(wrongUser.status, .badRequest)
        let wrongQuery = try await t.json(.GET, "/v1/search?q=changed&cursor=\(cursor)", token: a)
        XCTAssertEqual(wrongQuery.status, .badRequest)
    }

    func testStablePagingAcrossCandidateBatchesAndMetadataLists() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let (alice, a) = try await account(t, "Alice")
        let (bob, _) = try await account(t, "Bob")
        let hidden = try await project(t, bob, "Hidden")
        let visible = try await project(t, alice, "Visible")
        // More than one internal batch of inaccessible matches must not cause an empty public page.
        for i in 1...101 {
            let id = UUID(uuidString: String(format: "20000000-0000-0000-0000-%012d", i))!
            _ = try await task(t, bob, hidden, "Match", id: id)
        }
        var expected = Set<String>()
        for i in 102...104 {
            let id = UUID(uuidString: String(format: "20000000-0000-0000-0000-%012d", i))!
            _ = try await task(t, alice, visible, "Match", id: id)
            expected.insert(id.uuidString)
            _ = try await t.json(.POST, "/v1/labels", ["name": "Label \(i)"], token: a)
            _ = try await t.json(.POST, "/v1/filters", ["name": "Filter \(i)", "criteria": [:]], token: a)
        }
        for path in ["/v1/search?status=open&", "/v1/search?", "/v1/labels?", "/v1/filters?"] {
            var cursor: String?
            var seen: [String] = []
            repeat {
                let page = try await t.json(.GET, path + "limit=1" + (cursor.map { "&cursor=\($0)" } ?? ""), token: a)
                XCTAssertEqual(page.status, .ok)
                seen += items(page.body).map { $0["id"] as! String }
                cursor = page.body?["nextCursor"] as? String
                XCTAssertLessThanOrEqual(seen.count, 4)
                if seen.count > 4 { break }
            } while cursor != nil
            XCTAssertEqual(Set(seen).count, seen.count)
            if path.contains("status") { XCTAssertEqual(Set(seen), expected) }
            else { XCTAssertEqual(seen.count, path == "/v1/search?" ? 4 : 3) }
        }
        for query in ["limit=0", "limit=101", "cursor=broken", "projectID=bad", "status=unknown"] {
            let response = try await t.json(.GET, "/v1/search?\(query)", token: a)
            XCTAssertEqual(response.status, .badRequest, query)
        }
    }

    func testTeamGrantsDriveSearchVisibility() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let (alice, a) = try await account(t, "Alice")
        let (bob, b) = try await account(t, "Bob")
        let shared = try await project(t, alice, "Needle shared")
        let hidden = try await project(t, alice, "Needle hidden")
        _ = try await task(t, alice, shared, "Needle visible task")
        _ = try await task(t, alice, hidden, "Needle hidden task")
        let before = try await t.json(.GET, "/v1/search?q=needle", token: b)
        XCTAssertTrue(items(before.body).isEmpty)
        XCTAssertNil(before.body?["total"])
        let team = try await t.json(.POST, "/v1/teams", ["name": "Crew"], token: a)
        let teamID = team.body!["id"] as! String
        let bobID = try bob.requireID().uuidString
        _ = try await t.json(.PUT, "/v1/teams/\(teamID)/members", ["userID": bobID, "isAdmin": false], token: a)
        // A pending invitation grants nothing.
        let sharedID = try shared.requireID().uuidString
        let grant = try await t.json(.PUT, "/v1/projects/\(sharedID)/grants",
            ["principalType": "team", "principalID": teamID, "role": "read"], token: a)
        XCTAssertEqual(grant.status, .ok)
        let pending = try await t.json(.GET, "/v1/search?q=needle", token: b)
        XCTAssertTrue(items(pending.body).isEmpty)
        _ = try await t.json(.POST, "/v1/teams/\(teamID)/accept", token: b)
        let after = try await t.json(.GET, "/v1/search?q=needle", token: b)
        let titles = items(after.body).map { ($0["task"] as? [String: Any])?["title"] as? String ?? ($0["project"] as! [String: Any])["name"] as! String }
        XCTAssertEqual(Set(titles), ["Needle shared", "Needle visible task"])
        XCTAssertFalse(String(describing: after.body).contains("hidden"))
        let denied = try await t.json(.GET, "/v1/search?projectID=\(try hidden.requireID())", token: b)
        XCTAssertEqual(denied.status, .notFound)
        let revoke = try await t.json(.DELETE, "/v1/teams/\(teamID)/members/\(bobID)", token: a)
        XCTAssertEqual(revoke.status, .noContent)
        let revoked = try await t.json(.GET, "/v1/search?q=needle", token: b)
        XCTAssertTrue(items(revoked.body).isEmpty)
    }
}
