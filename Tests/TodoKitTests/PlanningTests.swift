import XCTVapor
@testable import TodoKit

final class PlanningTests: XCTestCase {
    private func twoUsers(_ t: TestApp) async throws -> (a: String, b: String) {
        let a = try await t.register(token: "bootstrap-secret", name: "Alice")
        let inv = try await t.json(.POST, "/v1/invitations", token: a.session)
        let b = try await t.register(token: inv.body!["token"] as! String, name: "Bob")
        return (a.session, b.session)
    }

    func testRequiresAuthentication() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        for path in ["/v1/projects", "/v1/tasks"] {
            let r = try await t.json(.GET, path)
            XCTAssertEqual(r.status, .unauthorized, path)
        }
    }

    func testProjectTreeTasksAndIsolation() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let (a, b) = try await twoUsers(t)

        let root = try await t.json(.POST, "/v1/projects", ["name": "Website"], token: a)
        XCTAssertEqual(root.status, .created)
        let rootID = root.body!["id"] as! String
        let child = try await t.json(.POST, "/v1/projects", ["name": "Relaunch", "parentID": rootID], token: a)
        XCTAssertEqual(child.body?["parentID"] as? String, rootID)
        let childID = child.body!["id"] as! String

        let task = try await t.json(.POST, "/v1/tasks", ["projectID": childID, "title": "Logo"], token: a)
        XCTAssertEqual(task.status, .created)
        let taskID = task.body!["id"] as! String
        XCTAssertEqual(task.body?["status"] as? String, "open")

        // Bob sees nothing of Alice's data and cannot touch it; foreign ids look like missing ones.
        let bobProjects = try await t.json(.GET, "/v1/projects", token: b)
        XCTAssertEqual(bobProjects.list?.count, 0)
        let bobTasks = try await t.json(.GET, "/v1/tasks", token: b)
        XCTAssertEqual(bobTasks.list?.count, 0)
        let probe = try await t.json(.GET, "/v1/tasks?projectID=\(childID)", token: b)
        XCTAssertEqual(probe.status, .notFound)
        let bobSubproject = try await t.json(.POST, "/v1/projects", ["name": "x", "parentID": rootID], token: b)
        XCTAssertEqual(bobSubproject.status, .notFound)
        let bobTaskIn = try await t.json(.POST, "/v1/tasks", ["projectID": childID, "title": "x"], token: b)
        XCTAssertEqual(bobTaskIn.status, .notFound)
        let bobPatch = try await t.json(.PATCH, "/v1/tasks/\(taskID)", ["version": 1, "title": "hacked"], token: b)
        XCTAssertEqual(bobPatch.status, .notFound)
        let bobDelete = try await t.json(.DELETE, "/v1/projects/\(rootID)", token: b)
        XCTAssertEqual(bobDelete.status, .notFound)

        // Cycles are rejected: root under its own child, and under itself.
        let cycle = try await t.json(.PATCH, "/v1/projects/\(rootID)", ["version": 1, "parentID": childID], token: a)
        XCTAssertEqual(cycle.status, .unprocessableEntity)
        let selfParent = try await t.json(.PATCH, "/v1/projects/\(rootID)", ["version": 1, "parentID": rootID], token: a)
        XCTAssertEqual(selfParent.status, .unprocessableEntity)

        // Deleting the parent removes the subtree including tasks.
        let del = try await t.json(.DELETE, "/v1/projects/\(rootID)", token: a)
        XCTAssertEqual(del.status, .noContent)
        let left = try await t.json(.GET, "/v1/tasks", token: a)
        XCTAssertEqual(left.list?.count, 0)
    }

    func testVersionConflictsAndValidation() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let a = try await t.register(token: "bootstrap-secret", name: "Alice").session
        let p = try await t.json(.POST, "/v1/projects", ["name": "P"], token: a)
        let pid = p.body!["id"] as! String
        let task = try await t.json(.POST, "/v1/tasks", ["projectID": pid, "title": "T"], token: a)
        let id = task.body!["id"] as! String

        let ok = try await t.json(.PATCH, "/v1/tasks/\(id)", ["version": 1, "status": "done"], token: a)
        XCTAssertEqual(ok.body?["version"] as? Int, 2)
        let stale = try await t.json(.PATCH, "/v1/tasks/\(id)", ["version": 1, "title": "lost update"], token: a)
        XCTAssertEqual(stale.status, .conflict)
        let badStatus = try await t.json(.PATCH, "/v1/tasks/\(id)", ["version": 2, "status": "bogus"], token: a)
        XCTAssertEqual(badStatus.status, .badRequest)
        let empty = try await t.json(.POST, "/v1/tasks", ["projectID": pid, "title": "  "], token: a)
        XCTAssertEqual(empty.status, .badRequest)
        let staleProject = try await t.json(.PATCH, "/v1/projects/\(pid)", ["version": 9, "name": "N"], token: a)
        XCTAssertEqual(staleProject.status, .conflict)
        let rename = try await t.json(.PATCH, "/v1/projects/\(pid)", ["version": 1, "name": "Renamed"], token: a)
        XCTAssertEqual(rename.body?["name"] as? String, "Renamed")
    }

    func testCookieSessionNeedsJsonAndAllowedOrigin() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let a = try await t.register(token: "bootstrap-secret", name: "Alice").session
        func post(contentType: HTTPMediaType?, origin: String?) async throws -> HTTPStatus {
            var status = HTTPStatus.ok
            try await t.app.test(.POST, "/v1/projects", beforeRequest: { req in
                req.headers.add(name: .cookie, value: "\(AuthSupport.cookieName)=\(a)")
                if let contentType { req.headers.contentType = contentType }
                if let origin { req.headers.replaceOrAdd(name: .origin, value: origin) }
                req.body = ByteBuffer(string: #"{"name":"X"}"#)
            }, afterResponse: { res async in status = res.status })
            return status
        }
        let form = try await post(contentType: .urlEncodedForm, origin: nil)
        XCTAssertEqual(form, .unsupportedMediaType)
        let evil = try await post(contentType: .json, origin: "https://evil.example")
        XCTAssertEqual(evil, .forbidden)
        let good = try await post(contentType: .json, origin: t.settings.relyingPartyOrigin)
        XCTAssertEqual(good, .created)
    }
}
