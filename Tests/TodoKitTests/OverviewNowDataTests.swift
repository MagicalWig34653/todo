import Fluent
import XCTVapor
@testable import TodoKit

/// Card B0CF5F73: "/now" showed a 500 error page. The page keyed its build list by `buildID`, but screenshots of one build
/// share that id (per card and across the cards of a project), so the list had duplicate keys. The full answer therefore
/// carries the id of every artifact (`projects[].builds[].id`, contract session-status 1.5.0), unique per entry.
final class OverviewNowDataTests: XCTestCase {
    private func artifact(_ db: any Database, task: UUID, build: String, label: String?, platform: String?, status: String?, ago: TimeInterval, owner: UUID) async throws -> UUID {
        let a = BuildArtifact()
        a.attachmentID = UUID(); a.taskID = task; a.buildID = build; a.label = label; a.platform = platform; a.status = status
        a.createdByType = .person; a.createdByID = owner
        try await a.save(on: db)
        a.createdAt = Date().addingTimeInterval(-ago); try await a.save(on: db)
        return try a.requireID()
    }

    func testRepeatedBuildsAnswer200AndEveryEntryHasItsOwnID() async throws {
        let f = try await OAuthFixture.make()
        do {
            let db = f.test.app.db
            let owner = try f.user.requireID()
            let child = Project(ownerID: owner, parentID: try f.project.requireID(), name: "Sub")
            try await child.save(on: db)
            func card(_ project: Project, _ title: String) async throws -> UUID {
                let t = TodoTask(ownerID: owner, projectID: try project.requireID(), title: title); try await t.save(on: db); return try t.requireID()
            }
            let a = try await card(f.project, "Jetzt-Seite"), b = try await card(f.project, "Aufgabenbaum"), c = try await card(child, "Screenshots")
            var expected: [UUID: Set<UUID>] = [try f.project.requireID(): [], try child.requireID(): []]
            // Three screenshots of one build on one card, a fourth on another card, plus a second build.
            for (i, name) in ["hell", "dunkel", "schmal"].enumerated() {
                _ = name
                expected[try f.project.requireID(), default: []].insert(try await artifact(db, task: a, build: "564a6b4", label: "Web 564a6b4", platform: "web", status: i == 0 ? "succeeded" : nil, ago: Double(10 + i), owner: owner))
            }
            expected[try f.project.requireID(), default: []].insert(try await artifact(db, task: b, build: "564a6b4", label: "Web 564a6b4", platform: "web", status: "failed", ago: 20, owner: owner))
            expected[try f.project.requireID(), default: []].insert(try await artifact(db, task: b, build: "ios-42", label: "iOS 42", platform: "ios", status: nil, ago: 30, owner: owner))
            for i in 0..<2 {
                expected[try child.requireID(), default: []].insert(try await artifact(db, task: c, build: "564a6b4", label: "Web 564a6b4", platform: "web", status: "building", ago: Double(40 + i), owner: owner))
            }

            let r = try await f.test.json(.GET, "/v1/overview/now", token: f.session)
            XCTAssertEqual(r.status, .ok, String(describing: r.body))
            let projects = try XCTUnwrap(r.body?["projects"] as? [[String: Any]])
            for (projectID, ids) in expected {
                let entry = try XCTUnwrap(projects.first { ($0["projectID"] as? String)?.lowercased() == projectID.uuidString.lowercased() }, "project \(projectID) missing")
                let builds = try XCTUnwrap(entry["builds"] as? [[String: Any]])
                XCTAssertEqual(builds.count, ids.count, "all repeated builds are in the answer")
                XCTAssertEqual(Set(builds.compactMap { $0["buildID"] as? String }).count, ids == expected[try child.requireID()] ? 1 : 2, "the build ids repeat")
                let got = builds.compactMap { ($0["id"] as? String).flatMap(UUID.init(uuidString:)) }
                XCTAssertEqual(got.count, builds.count, "every build carries an id")
                XCTAssertEqual(Set(got).count, got.count, "the ids are unique")
                XCTAssertEqual(Set(got), ids, "the id is the id of the artifact")
            }
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }
}
