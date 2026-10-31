import Fluent
import SQLKit
import XCTVapor
@testable import TodoKit

/// Backend gaps left open by the PWA/native UIs: project description/colour, favourites and display preferences,
/// sibling order, project comments, the aggregated activity feed, runner device/job lists, column sync mutations
/// and MCP column tools (ADR 0012).
final class ProjectStateTests: XCTestCase {
    private func account(_ t: TestApp, _ name: String = "Test") async throws -> (id: String, token: String) {
        let user = User(displayName: name, isAdmin: false)
        try await user.save(on: t.app.db)
        let token = AuthSupport.randomToken()
        try await UserSession(userID: user.requireID(), tokenHash: AuthSupport.hash(token),
            expiresAt: Date().addingTimeInterval(3600)).save(on: t.app.db)
        return (try user.requireID().uuidString, token)
    }

    @discardableResult private func project(_ t: TestApp, _ token: String, _ name: String = "P", parent: String? = nil,
                                            extra: [String: Any] = [:]) async throws -> String {
        var body: [String: Any] = ["name": name]
        body["parentID"] = parent
        body.merge(extra) { $1 }
        let r = try await t.json(.POST, "/v1/projects", body, token: token)
        XCTAssertEqual(r.status, .created, "\(r.body ?? [:])")
        return try XCTUnwrap(r.body?["id"] as? String)
    }

    @discardableResult private func grant(_ t: TestApp, _ token: String, _ pid: String, _ principal: String, role: String) async throws -> String {
        let r = try await t.json(.PUT, "/v1/projects/\(pid)/grants", ["principalType": "person", "principalID": principal, "role": role], token: token)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
        return try XCTUnwrap(r.body?["id"] as? String)
    }

    private func eq<T: Equatable>(_ a: T, _ b: T, _ message: String = "", line: UInt = #line) { XCTAssertEqual(a, b, message, line: line) }
    private func ok(_ condition: Bool, _ message: String = "", line: UInt = #line) { XCTAssertTrue(condition, message, line: line) }

    private func list(_ t: TestApp, _ token: String) async throws -> [[String: Any]] {
        let r = try await t.json(.GET, "/v1/projects", token: token)
        XCTAssertEqual(r.status, .ok)
        return r.list ?? []
    }

    private func ids(_ projects: [[String: Any]]) -> [String] { projects.compactMap { $0["id"] as? String } }

    /// Client-side sibling order: stored position first; unpositioned projects keep the server's list order
    /// (createdAt has second resolution in JSON, so it cannot break ties on its own).
    private func ordered(_ projects: [[String: Any]], parent: String? = nil) -> [String] {
        projects.enumerated().filter { ($0.element["parentID"] as? String) == parent }.sorted {
            let a = $0.element["position"] as? Int ?? Int.max, b = $1.element["position"] as? Int ?? Int.max
            return a != b ? a < b : $0.offset < $1.offset
        }.compactMap { $0.element["id"] as? String }
    }

    // MARK: 1. Description and colour

    func testProjectDescriptionAndColour() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let a = try await account(t)
        let long = String(repeating: "Ünïcödé ✓ ", count: 900) // ~9000 characters, multi-byte
        let pid = try await project(t, a.token, "Doc", extra: ["description": "  Hello  ", "color": "#a1b2c3"])
        var p = try await list(t, a.token)[0]
        XCTAssertEqual(p["description"] as? String, "Hello")
        XCTAssertEqual(p["color"] as? String, "#A1B2C3")
        XCTAssertNotNil(p["createdAt"] as? String)

        var r = try await t.json(.PATCH, "/v1/projects/\(pid)", ["version": 1, "description": long], token: a.token)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
        XCTAssertEqual((r.body?["description"] as? String)?.count, long.trimmingCharacters(in: .whitespaces).count)
        // Untouched fields stay; empty string clears.
        r = try await t.json(.PATCH, "/v1/projects/\(pid)", ["version": 2, "name": "Renamed"], token: a.token)
        XCTAssertEqual((r.body?["description"] as? String)?.isEmpty, false)
        XCTAssertEqual(r.body?["color"] as? String, "#A1B2C3")
        r = try await t.json(.PATCH, "/v1/projects/\(pid)", ["version": 3, "description": "", "color": ""], token: a.token)
        XCTAssertEqual(r.status, .ok)
        XCTAssertNil(r.body?["description"])
        XCTAssertNil(r.body?["color"])
        // Validation.
        r = try await t.json(.PATCH, "/v1/projects/\(pid)", ["version": 4, "description": String(repeating: "x", count: 10_001)], token: a.token)
        XCTAssertEqual(r.status, .badRequest)
        r = try await t.json(.PATCH, "/v1/projects/\(pid)", ["version": 4, "color": "red"], token: a.token)
        XCTAssertEqual(r.status, .badRequest)
        r = try await t.json(.POST, "/v1/projects", ["name": "X", "description": String(repeating: "x", count: 10_001)], token: a.token)
        XCTAssertEqual(r.status, .badRequest)

        // Sync mutations carry the fields; the feed delivers them.
        let sid = UUID().uuidString
        var m = try await t.json(.POST, "/v1/sync/mutations", ["mutationID": UUID().uuidString, "type": "project.create", "id": sid,
            "name": "Synced", "description": "From sync", "color": "#112233"], token: a.token)
        XCTAssertEqual(m.status, .created, "\(m.body ?? [:])")
        XCTAssertEqual((m.body?["project"] as? [String: Any])?["description"] as? String, "From sync")
        m = try await t.json(.POST, "/v1/sync/mutations", ["mutationID": UUID().uuidString, "type": "project.update", "id": sid,
            "version": 1, "description": "Changed"], token: a.token)
        XCTAssertEqual(m.status, .ok)
        let feed = try await t.json(.GET, "/v1/sync/changes?cursor=c0", token: a.token)
        let last = (feed.body?["changes"] as? [[String: Any]])?.last { $0["entityID"] as? String == sid }
        XCTAssertEqual((last?["project"] as? [String: Any])?["description"] as? String, "Changed")
        p = try await list(t, a.token).first { $0["id"] as? String == sid }!
        XCTAssertEqual(p["color"] as? String, "#112233")

        // A reader sees the description but may not change it.
        let b = try await account(t, "Reader")
        try await grant(t, a.token, pid, b.id, role: "read")
        r = try await t.json(.PATCH, "/v1/projects/\(pid)", ["version": 5, "description": "no"], token: b.token)
        XCTAssertEqual(r.status, .forbidden)
    }

    // MARK: 2. Favourites and display preferences

    func testFavoritesAreOrderedPrivateAndPermissionChecked() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let a = try await account(t), b = try await account(t, "B")
        let p1 = try await project(t, a.token, "1"), p2 = try await project(t, a.token, "2"), p3 = try await project(t, a.token, "3")
        func favs(_ token: String) async throws -> [String] {
            let r = try await t.json(.GET, "/v1/me/favorites", token: token)
            XCTAssertEqual(r.status, .ok)
            let items = r.body?["items"] as? [[String: Any]] ?? []
            XCTAssertEqual(items.compactMap { $0["position"] as? Int }, Array(0..<items.count))
            return items.compactMap { $0["projectID"] as? String }
        }
        eq(try await favs(a.token), [])
        for p in [p1, p2, p3] { eq(try await t.json(.PUT, "/v1/me/favorites/\(p)", token: a.token).status, .ok) }
        eq(try await favs(a.token), [p1, p2, p3])
        // Move p3 to the front, idempotent repeat, move p1 to index 99 (clamped to the end).
        var r = try await t.json(.PUT, "/v1/me/favorites/\(p3)", ["index": 0], token: a.token)
        XCTAssertEqual((r.body?["items"] as? [[String: Any]])?.compactMap { $0["projectID"] as? String }, [p3, p1, p2])
        _ = try await t.json(.PUT, "/v1/me/favorites/\(p3)", ["index": 0], token: a.token)
        _ = try await t.json(.PUT, "/v1/me/favorites/\(p1)", ["index": 99], token: a.token)
        eq(try await favs(a.token), [p3, p2, p1])
        r = try await t.json(.PUT, "/v1/me/favorites/\(p1)", ["index": -1], token: a.token)
        XCTAssertEqual(r.status, .badRequest)
        // The project DTO carries the viewer's flag.
        let projects = try await list(t, a.token)
        XCTAssertEqual(projects.filter { $0["isFavorite"] as? Bool == true }.count, 3)
        XCTAssertEqual(projects.first { $0["id"] as? String == p3 }?["favoritePosition"] as? Int, 0)
        // Remove + idempotent removal; others keep dense order.
        eq(try await t.json(.DELETE, "/v1/me/favorites/\(p2)", token: a.token).status, .noContent)
        eq(try await t.json(.DELETE, "/v1/me/favorites/\(p2)", token: a.token).status, .noContent)
        eq(try await favs(a.token), [p3, p1])
        // Another account neither sees nor can favourite foreign projects (404), and has its own list.
        eq(try await t.json(.PUT, "/v1/me/favorites/\(p1)", token: b.token).status, .notFound)
        eq(try await favs(b.token), [])
        // After sharing, B may favourite it; losing access hides (but keeps) the favourite.
        let g = try await grant(t, a.token, p1, b.id, role: "read")
        eq(try await t.json(.PUT, "/v1/me/favorites/\(p1)", token: b.token).status, .ok)
        eq(try await favs(b.token), [p1])
        eq(try await favs(a.token), [p3, p1])
        _ = try await t.json(.DELETE, "/v1/projects/\(p1)/grants/\(g)", token: a.token)
        eq(try await favs(b.token), [])
        try await grant(t, a.token, p1, b.id, role: "read")
        eq(try await favs(b.token), [p1])
        // Unknown project.
        eq(try await t.json(.PUT, "/v1/me/favorites/\(UUID())", token: a.token).status, .notFound)
    }

    func testProjectDisplayPreferencesValidationRevisionAndIsolation() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let a = try await account(t), b = try await account(t, "B")
        let p = try await project(t, a.token)
        var r = try await t.json(.GET, "/v1/me/project-prefs/\(p)", token: a.token)
        XCTAssertEqual(r.status, .ok)
        XCTAssertEqual(r.body?["revision"] as? Int, 0)
        XCTAssertEqual(r.body?["view"] as? String, "list")
        XCTAssertEqual(r.body?["sort"] as? String, "manual")
        XCTAssertEqual(r.body?["grouping"] as? String, "column")
        XCTAssertEqual(r.body?["showCompleted"] as? Bool, true)
        XCTAssertNil(r.body?["updatedAt"])
        r = try await t.json(.PATCH, "/v1/me/project-prefs/\(p)", ["revision": 0, "view": "board", "showCompleted": false], token: a.token)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
        XCTAssertEqual(r.body?["revision"] as? Int, 1)
        XCTAssertEqual(r.body?["view"] as? String, "board")
        XCTAssertEqual(r.body?["showCompleted"] as? Bool, false)
        XCTAssertEqual(r.body?["sort"] as? String, "manual")
        XCTAssertNotNil(r.body?["updatedAt"] as? String)
        // Stale revision.
        r = try await t.json(.PATCH, "/v1/me/project-prefs/\(p)", ["revision": 0, "sort": "due"], token: a.token)
        XCTAssertEqual(r.status, .conflict)
        r = try await t.json(.PATCH, "/v1/me/project-prefs/\(p)", ["revision": 1, "sort": "priority", "grouping": "due"], token: a.token)
        XCTAssertEqual(r.body?["revision"] as? Int, 2)
        // Strict validation.
        let bad: [[String: Any]] = [
            ["revision": 2], ["view": "board"], ["revision": 2, "view": "kanban"], ["revision": 2, "sort": "random"],
            ["revision": 2, "grouping": "owner"], ["revision": 2, "showCompleted": "yes"], ["revision": 2, "showCompleted": 1],
            ["revision": -1, "view": "list"], ["revision": 2.5, "view": "list"], ["revision": "2", "view": "list"],
            ["revision": 2, "view": "list", "density": "compact"],
        ]
        for body in bad {
            let res = try await t.json(.PATCH, "/v1/me/project-prefs/\(p)", body, token: a.token)
            XCTAssertEqual(res.status, .badRequest, "\(body)")
        }
        // Bulk read lists only projects with stored preferences.
        let all = try await t.json(.GET, "/v1/me/project-prefs", token: a.token)
        XCTAssertEqual((all.body?["items"] as? [[String: Any]])?.count, 1)
        // Isolation: another account has defaults and 404 for the foreign project.
        eq(try await t.json(.GET, "/v1/me/project-prefs/\(p)", token: b.token).status, .notFound)
        try await grant(t, a.token, p, b.id, role: "read")
        r = try await t.json(.GET, "/v1/me/project-prefs/\(p)", token: b.token)
        XCTAssertEqual(r.body?["revision"] as? Int, 0)
        XCTAssertEqual(r.body?["view"] as? String, "list")
        r = try await t.json(.PATCH, "/v1/me/project-prefs/\(p)", ["revision": 0, "sort": "title"], token: b.token)
        XCTAssertEqual(r.status, .ok)
        eq((try await t.json(.GET, "/v1/me/project-prefs/\(p)", token: a.token)).body?["sort"] as? String, "priority")
        eq(try await t.json(.GET, "/v1/me/project-prefs/\(p)").status, .unauthorized)
    }

    func testProjectModeDefaultRuleExplicitChoiceAndBulkDefaults() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let a = try await account(t)
        let plain = try await project(t, a.token, "plain"), agentic = try await project(t, a.token, "agentic")
        // Default: classic without any agent relation, and no stored row is needed for it.
        var r = try await t.json(.GET, "/v1/me/project-prefs/\(plain)", token: a.token)
        XCTAssertEqual(r.body?["mode"] as? String, "classic")
        XCTAssertEqual(r.body?["modeSource"] as? String, "default")
        XCTAssertEqual(r.body?["revision"] as? Int, 0)
        // An agent brief with text makes the derived default `management`.
        r = try await t.json(.PUT, "/v1/projects/\(agentic)/agent-brief", ["text": "## Goals\nShip", "version": 0], token: a.token)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
        r = try await t.json(.GET, "/v1/me/project-prefs/\(agentic)", token: a.token)
        XCTAssertEqual(r.body?["mode"] as? String, "management")
        XCTAssertEqual(r.body?["modeSource"] as? String, "default")
        // Bulk read: stored only by default, every visible project with includeDefaults.
        var all = try await t.json(.GET, "/v1/me/project-prefs", token: a.token)
        XCTAssertEqual((all.body?["items"] as? [[String: Any]])?.count, 0)
        all = try await t.json(.GET, "/v1/me/project-prefs?includeDefaults=true", token: a.token)
        let modes = Dictionary(uniqueKeysWithValues: ((all.body?["items"] as? [[String: Any]]) ?? []).map { ($0["projectID"] as! String, $0["mode"] as! String) })
        XCTAssertEqual(modes[plain.lowercased()] ?? modes[plain], "classic")
        XCTAssertEqual(modes[agentic.lowercased()] ?? modes[agentic], "management")
        // Explicit choice wins over the derived default and bumps the revision.
        r = try await t.json(.PATCH, "/v1/me/project-prefs/\(agentic)", ["revision": 0, "mode": "classic"], token: a.token)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
        XCTAssertEqual(r.body?["mode"] as? String, "classic")
        XCTAssertEqual(r.body?["modeSource"] as? String, "user")
        XCTAssertEqual(r.body?["revision"] as? Int, 1)
        r = try await t.json(.PATCH, "/v1/me/project-prefs/\(plain)", ["revision": 0, "mode": "management", "view": "board"], token: a.token)
        XCTAssertEqual(r.body?["mode"] as? String, "management")
        XCTAssertEqual(r.body?["view"] as? String, "board")
        // Validation.
        for body in [["revision": 1, "mode": "pm"], ["revision": 1, "mode": 1], ["revision": 1, "mode": true]] as [[String: Any]] {
            let res = try await t.json(.PATCH, "/v1/me/project-prefs/\(plain)", body, token: a.token)
            XCTAssertEqual(res.status, .badRequest, "\(body)")
        }
        // Per account: another account with read access still sees the derived default.
        let b = try await account(t, "B")
        try await grant(t, a.token, agentic, b.id, role: "read")
        r = try await t.json(.GET, "/v1/me/project-prefs/\(agentic)", token: b.token)
        XCTAssertEqual(r.body?["mode"] as? String, "management")
    }

    // MARK: 3. Sibling order

    func testSiblingOrderIsPerUserAndRespectsPermissions() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let a = try await account(t), b = try await account(t, "B")
        let p1 = try await project(t, a.token, "1"), p2 = try await project(t, a.token, "2"), p3 = try await project(t, a.token, "3")
        let child = try await project(t, a.token, "child", parent: p1)
        eq(ordered(try await list(t, a.token)), [p1, p2, p3])

        let head = try await t.json(.GET, "/v1/sync/changes", token: a.token)
        let cursor = try XCTUnwrap(head.body?["cursor"] as? String)
        var r = try await t.json(.PUT, "/v1/projects/\(p3)/position", ["index": 0], token: a.token)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
        XCTAssertEqual(r.body?["position"] as? Int, 0)
        XCTAssertEqual(r.body?["version"] as? Int, 1) // pure reorder does not touch the shared project
        eq(ordered(try await list(t, a.token)), [p3, p1, p2])
        // Sync feed: changed siblings are re-delivered with their new position.
        let feed = try await t.json(.GET, "/v1/sync/changes?cursor=\(cursor)", token: a.token)
        let delivered = (feed.body?["changes"] as? [[String: Any]] ?? []).compactMap { $0["project"] as? [String: Any] }
        XCTAssertEqual(Set(delivered.compactMap { $0["id"] as? String }), [p1, p2, p3])
        XCTAssertEqual(delivered.first { $0["id"] as? String == p3 }?["position"] as? Int, 0)
        // Dense positions; index beyond the end clamps; repeat is stable.
        r = try await t.json(.PUT, "/v1/projects/\(p3)/position", ["index": 50], token: a.token)
        eq(ordered(try await list(t, a.token)), [p1, p2, p3])
        eq(Set((try await list(t, a.token)).filter { $0["parentID"] == nil }.compactMap { $0["position"] as? Int }), [0, 1, 2])
        eq((try await t.json(.PUT, "/v1/projects/\(p3)/position", ["index": -1], token: a.token)).status, .badRequest)
        eq((try await t.json(.PUT, "/v1/projects/\(p3)/position", [:], token: a.token)).status.code / 100, 4)
        eq((try await t.json(.PUT, "/v1/projects/\(UUID())/position", ["index": 0], token: a.token)).status, .notFound)

        // Re-parent: needs the version; stale version 409; cycle 422; then position among the new siblings.
        r = try await t.json(.PUT, "/v1/projects/\(p2)/position", ["parentID": p1, "index": 0], token: a.token)
        XCTAssertEqual(r.status, .badRequest)
        r = try await t.json(.PUT, "/v1/projects/\(p2)/position", ["parentID": p1, "index": 0, "version": 9], token: a.token)
        XCTAssertEqual(r.status, .conflict)
        r = try await t.json(.PUT, "/v1/projects/\(p1)/position", ["parentID": child, "index": 0, "version": 1], token: a.token)
        XCTAssertEqual(r.status, .unprocessableEntity)
        r = try await t.json(.PUT, "/v1/projects/\(p2)/position", ["parentID": p1, "index": 0, "version": 1], token: a.token)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
        XCTAssertEqual(r.body?["parentID"] as? String, p1)
        XCTAssertEqual(r.body?["version"] as? Int, 2)
        XCTAssertEqual(r.body?["position"] as? Int, 0)
        eq(ordered(try await list(t, a.token), parent: p1), [p2, child])
        // Back to the root (explicit null).
        r = try await t.json(.PUT, "/v1/projects/\(p2)/position", ["parentID": NSNull(), "index": 0, "version": 2], token: a.token)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
        XCTAssertNil(r.body?["parentID"])
        eq(ordered(try await list(t, a.token)), [p2, p1, p3])

        // A reader gets a private order but cannot restructure the tree.
        let q1 = try await project(t, a.token, "q1"), q2 = try await project(t, a.token, "q2")
        try await grant(t, a.token, q1, b.id, role: "read")
        try await grant(t, a.token, q2, b.id, role: "read")
        let own = try await project(t, b.token, "mine")
        r = try await t.json(.PUT, "/v1/projects/\(q2)/position", ["index": 0], token: b.token)
        XCTAssertEqual(r.status, .ok)
        eq(ordered(try await list(t, b.token)).first, q2)
        eq(ordered(try await list(t, a.token)).firstIndex(of: q1)! < ordered(try await list(t, a.token)).firstIndex(of: q2)!, true)
        r = try await t.json(.PUT, "/v1/projects/\(q2)/position", ["parentID": own, "index": 0, "version": 1], token: b.token)
        XCTAssertEqual(r.status, .forbidden)
        // Foreign / invisible projects are 404.
        eq((try await t.json(.PUT, "/v1/projects/\(p1)/position", ["index": 0], token: b.token)).status, .notFound)

        // Sync mutation type.
        let m = try await t.json(.POST, "/v1/sync/mutations", ["mutationID": UUID().uuidString, "type": "project.position", "id": p3, "index": 0], token: a.token)
        XCTAssertEqual(m.status, .ok, "\(m.body ?? [:])")
        XCTAssertEqual((m.body?["project"] as? [String: Any])?["position"] as? Int, 0)
        eq(ordered(try await list(t, a.token)).first, p3)
    }

    // MARK: 4. Project comments

    func testProjectCommentsRolesIdempotencyAndActivity() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let owner = try await account(t, "Olga"), commenter = try await account(t, "Cem"), reader = try await account(t, "Rita")
        let outsider = try await account(t, "Otto")
        let pid = try await project(t, owner.token)
        try await grant(t, owner.token, pid, commenter.id, role: "comment")
        try await grant(t, owner.token, pid, reader.id, role: "read")

        func post(_ token: String, _ body: String, key: String? = nil) async throws -> (status: HTTPStatus, body: [String: Any]?) {
            var res: (HTTPStatus, [String: Any]?) = (.ok, nil)
            try await t.app.test(.POST, "/v1/projects/\(pid)/comments", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                req.headers.contentType = .json
                if let key { req.headers.add(name: "Idempotency-Key", value: key) }
                req.body = ByteBuffer(data: try JSONSerialization.data(withJSONObject: ["body": body]))
            }, afterResponse: { r async in
                res = (r.status, try? JSONSerialization.jsonObject(with: Data(r.body.readableBytesView)) as? [String: Any])
            })
            return res
        }
        var c = try await post(commenter.token, "  First  ", key: "k1")
        XCTAssertEqual(c.status, .created, "\(c.body ?? [:])")
        XCTAssertEqual(c.body?["body"] as? String, "First")
        XCTAssertEqual(c.body?["authorName"] as? String, "Cem")
        XCTAssertNotNil(c.body?["createdAt"] as? String)
        let cid = try XCTUnwrap(c.body?["id"] as? String)
        // Idempotent replay returns the same comment; a different body with the same key conflicts.
        let again = try await post(commenter.token, "First", key: "k1")
        XCTAssertEqual(again.body?["id"] as? String, cid)
        eq(try await post(commenter.token, "Other", key: "k1").status, .conflict)
        eq(try await post(commenter.token, "x", key: "bad key").status, .badRequest)
        eq(try await post(commenter.token, "   ").status, .badRequest)
        eq(try await post(commenter.token, String(repeating: "x", count: 10_001)).status, .badRequest)
        // Roles: reader may read but not comment; outsiders get 404.
        eq(try await post(reader.token, "no").status, .forbidden)
        eq(try await post(outsider.token, "no").status, .notFound)
        c = try await post(owner.token, "Second")
        XCTAssertEqual(c.status, .created)
        let owned = try XCTUnwrap(c.body?["id"] as? String)
        var listed = try await t.json(.GET, "/v1/projects/\(pid)/comments", token: reader.token)
        XCTAssertEqual(listed.status, .ok)
        XCTAssertEqual(listed.list?.compactMap { $0["body"] as? String }, ["First", "Second"])
        XCTAssertEqual(listed.list?.compactMap { $0["authorName"] as? String }, ["Cem", "Olga"])
        eq(try await t.json(.GET, "/v1/projects/\(pid)/comments", token: outsider.token).status, .notFound)
        // Edit: author only, with version.
        eq(try await t.json(.PATCH, "/v1/projects/\(pid)/comments/\(cid)", ["body": "Hijack", "version": 1], token: owner.token).status, .forbidden)
        eq(try await t.json(.PATCH, "/v1/projects/\(pid)/comments/\(cid)", ["body": "Edited"], token: commenter.token).status, .badRequest)
        eq(try await t.json(.PATCH, "/v1/projects/\(pid)/comments/\(cid)", ["body": "Edited", "version": 7], token: commenter.token).status, .conflict)
        let edited = try await t.json(.PATCH, "/v1/projects/\(pid)/comments/\(cid)", ["body": "Edited", "version": 1], token: commenter.token)
        XCTAssertEqual(edited.body?["version"] as? Int, 2)
        // Delete: foreign comment needs manage (the owner), the commenter cannot delete the owner's.
        eq(try await t.json(.DELETE, "/v1/projects/\(pid)/comments/\(owned)", ["version": 1], token: commenter.token).status, .forbidden)
        eq(try await t.json(.DELETE, "/v1/projects/\(pid)/comments/\(cid)", ["version": 1], token: owner.token).status, .conflict)
        eq(try await t.json(.DELETE, "/v1/projects/\(pid)/comments/\(cid)", ["version": 2], token: owner.token).status, .noContent)
        eq(try await t.json(.DELETE, "/v1/projects/\(pid)/comments/\(cid)", ["version": 2], token: owner.token).status, .notFound)
        listed = try await t.json(.GET, "/v1/projects/\(pid)/comments", token: owner.token)
        XCTAssertEqual(listed.list?.count, 1)

        // Activity events: project-level, ordered, with actor names; visible in the aggregated feed.
        let feed = try await t.json(.GET, "/v1/activity?projectID=\(pid)", token: reader.token)
        XCTAssertEqual(feed.status, .ok)
        let items = feed.body?["items"] as? [[String: Any]] ?? []
        XCTAssertEqual(items.compactMap { $0["kind"] as? String }.sorted(),
            ["comment.created", "comment.created", "comment.deleted", "comment.updated"])
        XCTAssertTrue(items.allSatisfy { $0["source"] as? String == "project" && $0["projectID"] as? String == pid })
        XCTAssertTrue(items.contains { $0["actorName"] as? String == "Cem" })
        // Deleting the project removes comments and events (cascade) without errors.
        eq(try await t.json(.DELETE, "/v1/projects/\(pid)", token: owner.token).status, .noContent)
    }

    // MARK: 5. Activity feed

    func testActivityFeedAggregatesFiltersPagesAndHidesForeignEvents() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let a = try await account(t, "Ada"), b = try await account(t, "Ben")
        let p1 = try await project(t, a.token, "One"), p2 = try await project(t, a.token, "Two")
        let secret = try await project(t, b.token, "Secret")
        for (p, title) in [(p1, "A1"), (p1, "A2"), (p2, "B1")] {
            let r = try await t.json(.POST, "/v1/tasks", ["projectID": p, "title": title], token: a.token)
            XCTAssertEqual(r.status, .created)
        }
        _ = try await t.json(.POST, "/v1/tasks", ["projectID": secret, "title": "hidden"], token: b.token)
        let task = try await t.json(.POST, "/v1/tasks", ["projectID": p1, "title": "C"], token: a.token)
        let tid = try XCTUnwrap(task.body?["id"] as? String)
        _ = try await t.json(.POST, "/v1/tasks/\(tid)/comments", ["body": "task comment"], token: a.token)
        _ = try await t.json(.POST, "/v1/projects/\(p1)/comments", ["body": "project comment"], token: a.token)

        var feed = try await t.json(.GET, "/v1/activity", token: a.token)
        XCTAssertEqual(feed.status, .ok, "\(feed.body ?? [:])")
        var items = feed.body?["items"] as? [[String: Any]] ?? []
        XCTAssertEqual(items.count, 6) // 4 task.created, comment.created (task), comment.created (project)
        XCTAssertFalse(items.contains { $0["projectID"] as? String == secret })
        XCTAssertTrue(items.contains { $0["source"] as? String == "task" && $0["taskTitle"] as? String == "C" && $0["kind"] as? String == "comment.created" })
        XCTAssertEqual(items.first?["actorName"] as? String, "Ada")
        // Newest first.
        let times = items.compactMap { $0["createdAt"] as? String }
        XCTAssertEqual(times, times.sorted(by: >))
        // Project filter.
        feed = try await t.json(.GET, "/v1/activity?projectID=\(p2)", token: a.token)
        XCTAssertEqual((feed.body?["items"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(((feed.body?["items"] as? [[String: Any]])?.first)?["projectName"] as? String, "Two")
        // Paging: limit 4 + cursor yields everything exactly once.
        var seen: [String] = []
        var cursor: String?
        for _ in 0..<5 {
            feed = try await t.json(.GET, "/v1/activity?limit=4" + (cursor.map { "&before=\($0)" } ?? ""), token: a.token)
            XCTAssertEqual(feed.status, .ok)
            items = feed.body?["items"] as? [[String: Any]] ?? []
            seen += items.compactMap { $0["id"] as? String }
            cursor = feed.body?["nextCursor"] as? String
            if cursor == nil { break }
        }
        XCTAssertEqual(seen.count, 6)
        XCTAssertEqual(Set(seen).count, 6)
        // Validation and permissions.
        eq(try await t.json(.GET, "/v1/activity?limit=0", token: a.token).status, .badRequest)
        eq(try await t.json(.GET, "/v1/activity?limit=101", token: a.token).status, .badRequest)
        eq(try await t.json(.GET, "/v1/activity?before=garbage", token: a.token).status, .badRequest)
        eq(try await t.json(.GET, "/v1/activity?projectID=nope", token: a.token).status, .badRequest)
        eq(try await t.json(.GET, "/v1/activity?projectID=\(secret)", token: a.token).status, .notFound)
        eq(try await t.json(.GET, "/v1/activity").status, .unauthorized)
        // B sees only own events until a project is shared.
        feed = try await t.json(.GET, "/v1/activity", token: b.token)
        XCTAssertEqual((feed.body?["items"] as? [[String: Any]])?.count, 1)
        try await grant(t, a.token, p2, b.id, role: "read")
        feed = try await t.json(.GET, "/v1/activity", token: b.token)
        XCTAssertEqual((feed.body?["items"] as? [[String: Any]])?.count, 2)
    }

    /// SQLite stores dates as raw doubles but reads them rounded to microseconds; the cursor must still
    /// exclude the last item of a page (regression: CI saw a repeated item on the next page).
    func testActivityFeedPagingNeverRepeatsItems() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let a = try await account(t, "Ada")
        let p = try await project(t, a.token, "One")
        for i in 0..<40 {
            let r = try await t.json(.POST, "/v1/tasks", ["projectID": p, "title": "T\(i)"], token: a.token)
            XCTAssertEqual(r.status, .created)
        }
        // Linux clocks have nanosecond resolution; emulate sub-microsecond stored values on every platform.
        if let sql = t.app.db as? any SQLDatabase, sql.dialect.name == "sqlite" {
            let events = try await ActivityEvent.query(on: t.app.db).all()
            for (i, e) in events.enumerated() {
                let shifted = (e.createdAt ?? Date()).timeIntervalSince1970 + 1e-7 * Double(1 + i % 4)
                try await sql.raw("UPDATE \(ident: ActivityEvent.schema) SET \(ident: "created_at") = \(bind: shifted) WHERE \(ident: "id") = \(bind: e.requireID())").run()
            }
        }
        var seen: [String] = []
        var cursor: String?
        for _ in 0..<60 {
            let feed = try await t.json(.GET, "/v1/activity?limit=3" + (cursor.map { "&before=\($0)" } ?? ""), token: a.token)
            seen += (feed.body?["items"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            cursor = feed.body?["nextCursor"] as? String
            if cursor == nil { break }
        }
        XCTAssertEqual(seen.count, 40)
        XCTAssertEqual(Set(seen).count, 40)
    }

    // MARK: 6. Runner device / job lists

    func testRunnerDeviceAndJobListsAreOwnerScopedAndSecretFree() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let a = try await account(t, "Ada"), b = try await account(t, "Ben")
        let pid = try await project(t, a.token)
        try await grant(t, a.token, pid, b.id, role: "manage")
        let pair = try await t.json(.POST, "/v1/agents/devices", ["label": "Mac mini"], token: a.token)
        XCTAssertEqual(pair.status, .ok)
        let deviceID = try XCTUnwrap(pair.body?["deviceID"] as? String)
        var devices = try await t.json(.GET, "/v1/agents/devices", token: a.token)
        XCTAssertEqual(devices.status, .ok)
        XCTAssertEqual(devices.list?.count, 1)
        XCTAssertEqual(devices.list?[0]["label"] as? String, "Mac mini")
        XCTAssertEqual(devices.list?[0]["paired"] as? Bool, false)
        // Redeem the code, bind, and create jobs directly (the release flow is covered by AgentTests).
        let paired = try await t.json(.POST, "/v1/runner/pair", ["code": try XCTUnwrap(pair.body?["code"] as? String)])
        let deviceToken = try XCTUnwrap(paired.body?["token"] as? String)
        let bind = try await t.json(.POST, "/v1/agents/bindings", ["projectID": pid, "deviceID": deviceID, "repositoryKey": UUID().uuidString, "label": "repo"], token: a.token)
        XCTAssertEqual(bind.status, .ok, "\(bind.body ?? [:])")
        devices = try await t.json(.GET, "/v1/agents/devices", token: a.token)
        let device = try XCTUnwrap(devices.list?.first)
        XCTAssertEqual(device["paired"] as? Bool, true)
        XCTAssertEqual((device["bindings"] as? [[String: Any]])?.first?["label"] as? String, "repo")
        XCTAssertEqual(device["activeRunCount"] as? Int, 0)
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: device), as: UTF8.self)
        XCTAssertFalse(raw.contains(deviceToken))
        XCTAssertFalse(raw.lowercased().contains("hash"))
        eq((try await t.json(.GET, "/v1/agents/devices", token: b.token)).list?.count, 0)
        eq(try await t.json(.GET, "/v1/agents/devices").status, .unauthorized)

        let bindingID = UUID(uuidString: try XCTUnwrap(bind.body?["id"] as? String))!
        var jobIDs: [UUID] = []
        for (i, state) in ["queued", "awaiting_review", "succeeded"].enumerated() {
            let task = try await t.json(.POST, "/v1/tasks", ["projectID": pid, "title": "T\(i)"], token: a.token)
            let job = AgentJob(taskID: UUID(uuidString: task.body!["id"] as! String)!, projectID: UUID(uuidString: pid)!, bindingID: bindingID,
                requestedBy: UUID(uuidString: a.id)!, taskRevision: 1, mode: "implement", scope: "scope", state: state, progress: "", result: nil)
            try await job.save(on: t.app.db)
            try await AgentEvent(jobID: job.requireID(), runID: nil, kind: "released",
                detail: "", createdAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(i * 10))).save(on: t.app.db)
            jobIDs.append(try job.requireID())
        }
        var jobs = try await t.json(.GET, "/v1/agents/jobs", token: a.token)
        XCTAssertEqual(jobs.status, .ok, "\(jobs.body ?? [:])")
        var items = jobs.body?["items"] as? [[String: Any]] ?? []
        XCTAssertEqual(items.compactMap { ($0["job"] as? [String: Any])?["state"] as? String }, ["succeeded", "awaiting_review", "queued"])
        XCTAssertEqual(items.first?["taskTitle"] as? String, "T2")
        XCTAssertEqual(items.first?["projectName"] as? String, "P")
        // Filters, paging.
        jobs = try await t.json(.GET, "/v1/agents/jobs?projectID=\(pid)&state=queued", token: a.token)
        XCTAssertEqual((jobs.body?["items"] as? [[String: Any]])?.count, 1)
        jobs = try await t.json(.GET, "/v1/agents/jobs?limit=2", token: a.token)
        XCTAssertEqual((jobs.body?["items"] as? [[String: Any]])?.count, 2)
        let next = try XCTUnwrap(jobs.body?["nextCursor"] as? String)
        jobs = try await t.json(.GET, "/v1/agents/jobs?limit=2&before=\(next)", token: a.token)
        items = jobs.body?["items"] as? [[String: Any]] ?? []
        XCTAssertEqual(items.count, 1)
        XCTAssertNil(jobs.body?["nextCursor"])
        eq(try await t.json(.GET, "/v1/agents/jobs?state=bogus", token: a.token).status, .badRequest)
        eq(try await t.json(.GET, "/v1/agents/jobs?limit=0", token: a.token).status, .badRequest)
        eq(try await t.json(.GET, "/v1/agents/jobs?before=x", token: a.token).status, .badRequest)
        // Agent execution is an owner capability: a manager neither lists nor filters by the project.
        let foreignJobs = try await t.json(.GET, "/v1/agents/jobs", token: b.token)
        XCTAssertEqual((foreignJobs.body?["items"] as? [Any])?.count, 0)
        eq(try await t.json(.GET, "/v1/agents/jobs?projectID=\(pid)", token: b.token).status, .forbidden)
        eq(try await t.json(.GET, "/v1/agents/jobs?projectID=\(UUID())", token: a.token).status, .notFound)
        eq(try await t.json(.GET, "/v1/agents/jobs").status, .unauthorized)
    }

    // MARK: 7. Column sync mutations

    func testColumnMutationsThroughSyncAreIdempotentPermissionedAndFeedVisible() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let a = try await account(t), reader = try await account(t, "R")
        let pid = try await project(t, a.token)
        try await grant(t, a.token, pid, reader.id, role: "read")
        func mutate(_ token: String, _ type: String, _ id: String, mutationID: String = UUID().uuidString, _ fields: [String: Any] = [:]) async throws -> (status: HTTPStatus, body: [String: Any]?) {
            var body: [String: Any] = ["mutationID": mutationID, "type": type, "id": id]
            body.merge(fields) { $1 }
            let r = try await t.json(.POST, "/v1/sync/mutations", body, token: token)
            return (r.status, r.body)
        }
        let c1 = UUID().uuidString, c2 = UUID().uuidString, mid = UUID().uuidString
        var r = try await mutate(a.token, "column.create", c1, mutationID: mid, ["projectID": pid, "name": "Todo", "color": "#ff0000"])
        XCTAssertEqual(r.status, .created, "\(r.body ?? [:])")
        XCTAssertEqual((r.body?["column"] as? [String: Any])?["id"] as? String, c1.uppercased() == c1 ? c1 : (r.body?["column"] as? [String: Any])?["id"] as? String)
        XCTAssertEqual((r.body?["column"] as? [String: Any])?["color"] as? String, "#FF0000")
        // Replay of the same mutation does not create a second column.
        r = try await mutate(a.token, "column.create", c1, mutationID: mid, ["projectID": pid, "name": "Todo", "color": "#ff0000"])
        XCTAssertEqual(r.status, .created)
        r = try await mutate(a.token, "column.create", c2, ["projectID": pid, "name": "Done", "isDone": true, "index": 0])
        XCTAssertEqual(r.status, .created)
        let cols = try await t.json(.GET, "/v1/projects/\(pid)/columns", token: a.token)
        XCTAssertEqual(cols.list?.compactMap { $0["name"] as? String }, ["Done", "Todo"])
        // Re-using an ID, invalid input, permissions.
        eq(try await mutate(a.token, "column.create", c1, ["projectID": pid, "name": "Dup"]).status, .conflict)
        eq(try await mutate(a.token, "column.create", UUID().uuidString, ["projectID": pid, "name": "  "]).status, .badRequest)
        eq(try await mutate(a.token, "column.create", UUID().uuidString, ["projectID": pid]).status, .badRequest)
        eq(try await mutate(reader.token, "column.create", UUID().uuidString, ["projectID": pid, "name": "No"]).status, .forbidden)
        eq(try await mutate(a.token, "column.create", UUID().uuidString, ["projectID": UUID().uuidString, "name": "No"]).status, .notFound)

        // Update (rename, move) with version.
        let id1 = (try await t.json(.GET, "/v1/projects/\(pid)/columns", token: a.token)).list!.first { $0["name"] as? String == "Todo" }!
        r = try await mutate(a.token, "column.update", c1, ["version": 99, "name": "X"])
        XCTAssertEqual(r.status, .conflict)
        r = try await mutate(a.token, "column.update", id1["id"] as! String, ["version": id1["version"] as! Int, "name": "Backlog", "index": 0])
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
        XCTAssertEqual((r.body?["column"] as? [String: Any])?["name"] as? String, "Backlog")
        XCTAssertEqual((r.body?["column"] as? [String: Any])?["position"] as? Int, 0)
        eq(try await mutate(reader.token, "column.update", c1, ["version": 1, "name": "No"]).status, .forbidden)

        // Task move through sync, including the done-column rule.
        let task = try await t.json(.POST, "/v1/tasks", ["projectID": pid, "title": "T", "columnID": c1], token: a.token)
        let tid = try XCTUnwrap(task.body?["id"] as? String)
        r = try await mutate(a.token, "task.move_column", tid, ["version": 1, "columnID": c2, "index": 0])
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
        XCTAssertEqual((r.body?["task"] as? [String: Any])?["status"] as? String, "done")
        XCTAssertEqual((r.body?["task"] as? [String: Any])?["columnID"] as? String, c2)
        eq(try await mutate(a.token, "task.move_column", tid, ["version": 1, "columnID": c1]).status, .conflict)
        eq(try await mutate(reader.token, "task.move_column", tid, ["version": 3, "columnID": c1]).status, .forbidden)
        r = try await mutate(a.token, "task.move_column", tid, ["version": (r.body?["task"] as? [String: Any])?["version"] as! Int])
        XCTAssertEqual((r.body?["task"] as? [String: Any])?["columnID"] as? String, nil)

        // Feed shows column upserts; delete with moveTo and tombstone; deleted IDs cannot be resurrected.
        var feed = try await t.json(.GET, "/v1/sync/changes?cursor=c0", token: a.token)
        XCTAssertTrue((feed.body?["changes"] as? [[String: Any]] ?? []).contains { $0["entityType"] as? String == "column" && $0["kind"] as? String == "upsert" })
        r = try await mutate(a.token, "column.delete", c2, ["moveTo": "bogus"])
        XCTAssertEqual(r.status, .badRequest)
        r = try await mutate(a.token, "column.delete", c2, ["moveTo": "none"])
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
        XCTAssertEqual(r.body?["deleted"] as? Bool, true)
        feed = try await t.json(.GET, "/v1/sync/changes?cursor=c0", token: a.token)
        XCTAssertTrue((feed.body?["changes"] as? [[String: Any]] ?? []).contains { $0["entityType"] as? String == "column" && $0["kind"] as? String == "delete" && $0["entityID"] as? String == c2 })
        eq(try await mutate(a.token, "column.create", c2, ["projectID": pid, "name": "Back"]).status, .conflict)
        eq(try await mutate(reader.token, "column.delete", c1).status, .forbidden)
        eq(try await mutate(a.token, "column.delete", UUID().uuidString).status, .notFound)
    }

    // MARK: 8. MCP column tools

    func testMCPColumnToolsFollowScopesAndGrants() async throws {
        let f = try await OAuthFixture.make()
        do {
            let pid = try f.project.requireID().uuidString, otherID = try f.other.requireID().uuidString
            let full = try await f.tokens(scope: "projects:read tasks:read tasks:write")
            func call(_ name: String, _ args: [String: Any], _ access: String) async throws -> (Bool, String) {
                let r = try await f.rpc("tools/call", ["name": name, "arguments": args], access: access)
                let result = try XCTUnwrap(r.body?["result"] as? [String: Any])
                let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
                return (result["isError"] as? Bool ?? false, text)
            }
            let created = try await call("create_column", ["projectID": pid, "name": " Review ", "color": "#00ff00", "isDone": false], full.access)
            XCTAssertFalse(created.0, created.1)
            let column = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(created.1.utf8)) as? [String: Any])
            XCTAssertEqual(column["name"] as? String, "Review")
            let cid = try XCTUnwrap(column["id"] as? String)
            let second = try await call("create_column", ["projectID": pid, "name": "First", "index": 0], full.access)
            XCTAssertFalse(second.0, second.1)
            eq((try await call("create_column", ["projectID": otherID, "name": "No"], full.access)).1, "not_found")
            eq((try await call("create_column", ["projectID": pid, "name": "  "], full.access)).1, "invalid_name")
            eq((try await call("create_column", ["projectID": pid, "name": "x", "color": "red"], full.access)).1, "invalid_color")
            eq((try await call("create_column", ["projectID": pid, "name": "x", "index": 1.5], full.access)).1, "invalid_index")
            // Inserting "First" at index 0 renumbered (and re-versioned) this column.
            let current = try await f.test.json(.GET, "/v1/projects/\(pid)/columns", token: f.session)
            let version = try XCTUnwrap(current.list?.first { $0["id"] as? String == cid }?["version"] as? Int)
            XCTAssertGreaterThan(version, column["version"] as! Int)
            let renamed = try await call("rename_column", ["id": cid, "version": version, "name": "QA"], full.access)
            XCTAssertFalse(renamed.0, renamed.1)
            XCTAssertTrue(renamed.1.contains("\"QA\""))
            eq((try await call("rename_column", ["id": cid, "version": 1, "name": "Stale"], full.access)).1, "version_conflict")
            // A column of a project outside the grant is invisible to the tool.
            let foreign = try await f.test.json(.POST, "/v1/projects/\(otherID)/columns", ["name": "Hidden"], token: f.session)
            let fid = try XCTUnwrap(foreign.body?["id"] as? String)
            eq((try await call("rename_column", ["id": fid, "version": 1, "name": "Nope"], full.access)).1, "not_found")
            eq((try await call("delete_column", ["id": fid], full.access)).1, "not_found")
            let deleted = try await call("delete_column", ["id": cid, "moveTo": "none"], full.access)
            XCTAssertFalse(deleted.0, deleted.1)
            let board = try await f.test.json(.GET, "/v1/projects/\(pid)/columns", token: f.session)
            XCTAssertEqual(board.list?.compactMap { $0["name"] as? String }, ["First"])
            // Scope gating and description in list_projects.
            let readOnly = try await f.tokens(scope: "projects:read")
            eq((try await call("create_column", ["projectID": pid, "name": "No"], readOnly.access)).1, "insufficient_scope")
            eq((try await call("delete_column", ["id": cid], readOnly.access)).1, "insufficient_scope")
            _ = try await f.test.json(.PATCH, "/v1/projects/\(pid)", ["version": 1, "description": "About", "color": "#010203"], token: f.session)
            let projects = try await call("list_projects", [:], readOnly.access)
            let arr = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(projects.1.utf8)) as? [[String: Any]])
            XCTAssertEqual(arr.first?["description"] as? String, "About")
            XCTAssertEqual(arr.first?["color"] as? String, "#010203")
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    // MARK: MariaDB (skipped without TODO_TEST_DB / TODO_TEST_MARIADB)

    func testConcurrentReordersAndIdempotentCommentsAcrossReplicas() async throws {
        try XCTSkipUnless(TestApp.useMariaDB, "needs MariaDB")
        let a = try await TestApp.make()
        let b = try await a.replica()
        defer { Task { await a.shutdown(); await b.shutdown() } }
        let u = try await account(a)
        var projects: [String] = []
        for i in 0..<8 { projects.append(try await project(a, u.token, "P\(i)")) }

        let statuses = try await withThrowingTaskGroup(of: HTTPStatus.self) { group -> [HTTPStatus] in
            for (i, p) in projects.enumerated() {
                let app = i % 2 == 0 ? a : b
                let body = try JSONSerialization.data(withJSONObject: ["index": (i * 3) % 8])
                group.addTask { try await app.rawStatus(.PUT, "/v1/projects/\(p)/position", body: body, token: u.token) }
                let fav = try JSONSerialization.data(withJSONObject: ["index": 0])
                group.addTask { try await app.rawStatus(.PUT, "/v1/me/favorites/\(p)", body: fav, token: u.token) }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertTrue(statuses.allSatisfy { $0 == .ok }, "\(statuses)")
        let listed = try await list(b, u.token)
        XCTAssertEqual(listed.compactMap { $0["position"] as? Int }.sorted(), Array(0..<8), "dense unique positions")
        XCTAssertEqual(listed.compactMap { $0["favoritePosition"] as? Int }.sorted(), Array(0..<8))
        let favs = try await b.json(.GET, "/v1/me/favorites", token: u.token)
        XCTAssertEqual((favs.body?["items"] as? [[String: Any]])?.count, 8)

        // Same idempotency key from both replicas at once: one comment.
        let pid = projects[0]
        let counts = try await withThrowingTaskGroup(of: HTTPStatus.self) { group -> [HTTPStatus] in
            for i in 0..<6 {
                let app = i % 2 == 0 ? a : b
                group.addTask {
                    var status = HTTPStatus.ok
                    try await app.app.test(.POST, "/v1/projects/\(pid)/comments", beforeRequest: { req in
                        req.headers.bearerAuthorization = .init(token: u.token)
                        req.headers.contentType = .json
                        req.headers.add(name: "Idempotency-Key", value: "same-key")
                        req.body = ByteBuffer(data: try JSONSerialization.data(withJSONObject: ["body": "once"]))
                    }, afterResponse: { r async in status = r.status })
                    return status
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertTrue(counts.allSatisfy { $0 == .created }, "\(counts)")
        let comments = try await a.json(.GET, "/v1/projects/\(pid)/comments", token: u.token)
        XCTAssertEqual(comments.list?.count, 1)
    }
}
