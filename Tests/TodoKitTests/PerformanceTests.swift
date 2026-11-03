import Fluent
import FluentSQL
import XCTVapor
@testable import TodoKit

/// Read-path performance fixes: label names inside the task list and the repeatable index migration.
final class PerformanceTests: XCTestCase {
    private func account(_ t: TestApp, _ name: String) async throws -> (User, String) {
        let user = User(displayName: name, isAdmin: false)
        try await user.save(on: t.app.db)
        let token = AuthSupport.randomToken()
        try await UserSession(userID: user.requireID(), tokenHash: AuthSupport.hash(token), expiresAt: .distantFuture).save(on: t.app.db)
        return (user, token)
    }

    func testTaskListCarriesOnlyOwnLabelNamesWhenAsked() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let (alice, a) = try await account(t, "Alice")
        let (bob, b) = try await account(t, "Bob")
        let project = Project(ownerID: try alice.requireID(), parentID: nil, name: "P")
        try await project.save(on: t.app.db)
        let pid = try project.requireID()
        // Bob may read the project, so he sees the tasks but must not see Alice's labels.
        try await ProjectGrant(projectID: pid, principalType: "person", principalID: try bob.requireID(), role: .read).save(on: t.app.db)
        let first = TodoTask(ownerID: try alice.requireID(), projectID: pid, title: "one", details: "")
        let second = TodoTask(ownerID: try alice.requireID(), projectID: pid, title: "two", details: "")
        try await first.save(on: t.app.db)
        try await second.save(on: t.app.db)
        var labelIDs: [String] = []
        for name in ["Zeta", "Alpha"] {
            let created = try await t.json(.POST, "/v1/labels", ["name": name], token: a)
            labelIDs.append(created.body!["id"] as! String)
        }
        for lid in labelIDs { _ = try await t.json(.PUT, "/v1/tasks/\(try first.requireID())/labels/\(lid)", token: a) }

        let plain = try await t.json(.GET, "/v1/tasks?projectID=\(pid)", token: a)
        XCTAssertEqual(plain.list?.count, 2)
        XCTAssertTrue(plain.list!.allSatisfy { $0["labels"] == nil }, "without includeLabels the field stays absent")

        let withLabels = try await t.json(.GET, "/v1/tasks?projectID=\(pid)&includeLabels=true", token: a)
        let byTitle = Dictionary(uniqueKeysWithValues: withLabels.list!.map { ($0["title"] as! String, $0["labels"] as? [String]) })
        XCTAssertEqual(byTitle["one"], ["Alpha", "Zeta"], "sorted names of the caller's labels")
        XCTAssertEqual(byTitle["two"], [])

        let foreign = try await t.json(.GET, "/v1/tasks?projectID=\(pid)&includeLabels=true", token: b)
        XCTAssertEqual(foreign.list?.count, 2)
        XCTAssertTrue(foreign.list!.allSatisfy { ($0["labels"] as? [String]) == [] }, "labels are private to their owner")
    }

    func testPerformanceIndexesExistAndMigrationIsRepeatable() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        guard let sql = t.app.db as? any SQLDatabase else { return XCTFail("SQL database expected") }
        try await AddPerformanceIndexes().prepare(on: t.app.db)  // second run: IF NOT EXISTS
        if sql.dialect.name == "sqlite" {
            let rows = try await sql.raw("SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'perf_%'").all()
            let names = Set(try rows.map { try $0.decode(column: "name", as: String.self) })
            XCTAssertEqual(names, Set(AddPerformanceIndexes.indexes.map(\.name)))
        }
    }
}
