import Fluent
import XCTVapor
@testable import TodoKit

final class UpdateProjectToolTests: XCTestCase {
    private func call(_ f: OAuthFixture, _ args: [String: Any], access: String) async throws -> (isError: Bool, json: [String: Any]?, text: String) {
        let r = try await f.rpc("tools/call", ["name": "update_project", "arguments": args], access: access)
        let result = try XCTUnwrap(r.body?["result"] as? [String: Any])
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        return (result["isError"] as? Bool ?? false, (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any], text)
    }

    func testRenameAndDescribeThenPartialUpdates() async throws {
        let f = try await OAuthFixture.make()
        do {
            let t = try await f.tokens(scope: "projects:read projects:write")
            let pid = try f.project.requireID().uuidString
            let first = try await call(f, ["projectID": pid, "version": 1, "name": "Renamed", "description": "New text", "color": "#112233"], access: t.access)
            XCTAssertFalse(first.isError, first.text)
            XCTAssertEqual(first.json?["name"] as? String, "Renamed")
            XCTAssertEqual(first.json?["description"] as? String, "New text")
            XCTAssertEqual(first.json?["color"] as? String, "#112233")
            XCTAssertEqual(first.json?["version"] as? Int, 2)
            XCTAssertEqual(first.json?["id"] as? String, pid)
            // Only the description: name and colour stay.
            let second = try await call(f, ["projectID": pid, "version": 2, "description": "Only text"], access: t.access)
            XCTAssertFalse(second.isError, second.text)
            XCTAssertEqual(second.json?["name"] as? String, "Renamed")
            XCTAssertEqual(second.json?["description"] as? String, "Only text")
            XCTAssertEqual(second.json?["color"] as? String, "#112233")
            // Empty description clears it.
            let cleared = try await call(f, ["projectID": pid, "version": 3, "description": ""], access: t.access)
            XCTAssertFalse(cleared.isError, cleared.text)
            XCTAssertTrue(cleared.json?["description"] == nil || cleared.json?["description"] is NSNull)
            XCTAssertEqual(cleared.json?["name"] as? String, "Renamed")
            let listed = try await f.rpc("tools/call", ["name": "list_projects", "arguments": [:]], access: t.access)
            let listText = try XCTUnwrap(((listed.body?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String)
            XCTAssertTrue(listText.contains("Renamed"))
            // Stale version, empty name and bad colour are rejected and change nothing.
            let stale = try await call(f, ["projectID": pid, "version": 1, "name": "Stale"], access: t.access)
            XCTAssertTrue(stale.isError); XCTAssertEqual(stale.text, "version_conflict")
            let empty = try await call(f, ["projectID": pid, "version": 4, "name": "   "], access: t.access)
            XCTAssertTrue(empty.isError); XCTAssertEqual(empty.text, "invalid_name")
            let badColor = try await call(f, ["projectID": pid, "version": 4, "color": "red"], access: t.access)
            XCTAssertTrue(badColor.isError)
            let stored = try await XCTUnwrapAsync { try await Project.find(f.project.requireID(), on: f.test.app.db) }
            XCTAssertEqual(stored.name, "Renamed"); XCTAssertEqual(stored.version, 4)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testProjectOutsideGrantIsNotFound() async throws {
        let f = try await OAuthFixture.make()
        do {
            let t = try await f.tokens(scope: "projects:read projects:write")
            let r = try await call(f, ["projectID": try f.other.requireID().uuidString, "version": 1, "name": "Hijack"], access: t.access)
            XCTAssertTrue(r.isError); XCTAssertEqual(r.text, "not_found")
            let stored = try await XCTUnwrapAsync { try await Project.find(f.other.requireID(), on: f.test.app.db) }
            XCTAssertEqual(stored.name, "Excluded")
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testScopeRequiredAndToolListed() async throws {
        let f = try await OAuthFixture.make()
        do {
            let readOnly = try await f.tokens(scope: "projects:read")
            let list = try await f.rpc("tools/list", access: readOnly.access)
            let names = ((list.body?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            XCTAssertFalse(names.contains("update_project"))
            let denied = try await call(f, ["projectID": try f.project.requireID().uuidString, "version": 1, "name": "X"], access: readOnly.access)
            XCTAssertTrue(denied.isError)
            let writer = try await f.tokens(scope: "projects:read projects:write")
            let list2 = try await f.rpc("tools/list", access: writer.access)
            let names2 = ((list2.body?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            XCTAssertTrue(names2.contains("update_project"))
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testReadOnlyRoleIsRejected() async throws {
        let f = try await OAuthFixture.make()
        do {
            let owner = User(displayName: "Owner", isAdmin: false); try await owner.save(on: f.test.app.db)
            let shared = Project(ownerID: try owner.requireID(), parentID: nil, name: "Shared"); try await shared.save(on: f.test.app.db)
            try await ProjectSharing(project: shared).save(on: f.test.app.db)
            try await ProjectGrant(projectID: try shared.requireID(), principalType: "person", principalID: try f.user.requireID(), role: .read).save(on: f.test.app.db)
            let auth = try await f.authorization(scope: "projects:read projects:write")
            let consent = try await f.test.json(.POST, "/oauth/consent", ["consent_token": try XCTUnwrap(auth.body?["consent_token"]), "approve": true,
                "project_ids": [try shared.requireID().uuidString]], token: f.session)
            let items = try XCTUnwrap(URLComponents(string: try XCTUnwrap(consent.body?["redirect_uri"] as? String))?.queryItems)
            let ex = try await f.exchange(try XCTUnwrap(items.first { $0.name == "code" }?.value))
            let access = try XCTUnwrap(ex.body?["access_token"] as? String)
            let r = try await call(f, ["projectID": try shared.requireID().uuidString, "version": 1, "name": "Mine now"], access: access)
            XCTAssertTrue(r.isError, r.text)
            let stored = try await XCTUnwrapAsync { try await Project.find(shared.requireID(), on: f.test.app.db) }
            XCTAssertEqual(stored.name, "Shared"); XCTAssertEqual(stored.version, 1)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testUpdateWritesChangeFeedEntry() async throws {
        let f = try await OAuthFixture.make()
        do {
            let t = try await f.tokens(scope: "projects:read projects:write")
            let pid = try f.project.requireID()
            let before = try await SyncChange.query(on: f.test.app.db).filter(\.$entityID == pid).filter(\.$kind == "upsert").count()
            let r = try await call(f, ["projectID": pid.uuidString, "version": 1, "name": "Feed"], access: t.access)
            XCTAssertFalse(r.isError, r.text)
            let after = try await SyncChange.query(on: f.test.app.db).filter(\.$entityID == pid).filter(\.$kind == "upsert").count()
            XCTAssertEqual(after, before + 1)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }
}

private func XCTUnwrapAsync<T>(_ value: () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let v = try await value(); return try XCTUnwrap(v, file: file, line: line)
}
