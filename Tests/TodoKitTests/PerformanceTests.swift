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
        try await AddSignOfLifeIndexes().prepare(on: t.app.db)
        if sql.dialect.name == "sqlite" {
            let rows = try await sql.raw("SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'perf_%'").all()
            let names = Set(try rows.map { try $0.decode(column: "name", as: String.self) })
            XCTAssertEqual(names, Set((AddPerformanceIndexes.indexes + AddSignOfLifeIndexes.indexes).map(\.name)))
        }
    }

    /// Responsibility in the command center (ADR 0043) must not read the sharing graph once per person and project.
    func testCommandCenterResponsibilityReadsEachAccountAndProjectOnce() async throws {
        let f = try await AssignmentFixture.make(); defer { Task { await f.t.shutdown() } }
        let history = QueryHistory()
        let db = try XCTUnwrap(f.t.app.databases.database(logger: f.t.app.logger, on: f.t.app.eventLoopGroup.next(), history: history))
        let owner = try await XCTUnwrapAsync(try await User.find(f.owner.id, on: f.t.app.db))
        let people = [f.designer, f.editor]
        func addProject(_ index: Int, for people: [AssignmentFixture.Account]) async throws {
            let r = try await f.t.json(.POST, "/v1/projects", ["name": "Child \(index)", "parentID": f.project], token: f.owner.token)
            let child = try XCTUnwrap(r.body?["id"] as? String, "\(r.body ?? [:])")
            for who in people {
                let card = try await f.task("Card \(index)", in: child)
                let asked = try await f.ask(card, assignee: who.id)
                XCTAssertEqual(asked.status, .created, "\(asked.body ?? [:])")
                let requested = try await f.review(card, assignee: who.id)
                XCTAssertEqual(requested.status, .ok, "\(requested.body ?? [:])")
            }
        }
        func measure() async throws -> (queries: Int, response: CommandCenterResponse) {
            history.queries = []
            var query = CommandCenterQuery()
            query.laneLimit = 100
            let response = try await CommandCenterService(user: owner, db: db).build(query)
            return (history.queries.count, response)
        }

        try await addProject(0, for: people)
        let small = try await measure()
        for index in 1...6 { try await addProject(index, for: people) }
        let manyProjects = try await measure()
        try await addProject(7, for: people + [f.owner])
        let oneMorePerson = try await measure()
        print("Responsibility query counts: 2 persons x 1 project=\(small.queries), 2 x 7=\(manyProjects.queries), 3 x 8=\(oneMorePerson.queries)")

        XCTAssertEqual(manyProjects.queries, small.queries, "projects, sharing rows and grants are read in batches")
        XCTAssertLessThanOrEqual(oneMorePerson.queries - manyProjects.queries, 2, "one more person costs the account and its teams only")
        XCTAssertEqual(manyProjects.response.summary.openQuestions, 14)
        let briefs = (manyProjects.response.lanes ?? []).flatMap(\.cards).flatMap(\.questions)
        XCTAssertEqual(briefs.count, 14)
        XCTAssertEqual(Set(briefs.compactMap(\.assigneeName)), ["Designer", "Editor"])
        XCTAssertEqual(manyProjects.response.summary.concerningQuestions, 0, "all of them are named for somebody else")
    }

    /// The cached evaluation of the resolver must answer exactly like the normal visibility rule.
    func testResponsibilityRolesMatchTheNormalVisibilityRule() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let db = t.app.db
        var users: [User] = []
        for name in ["Owner", "Admin", "Member", "Invited", "Granted", "Stranger", "Locked"] {
            let user = User(displayName: name, isAdmin: false)
            try await user.save(on: db)
            users.append(user)
        }
        let ids = try users.map { try $0.requireID() }
        users[6].disabledAt = Date(); try await users[6].save(on: db)
        let team = Team(name: "Team", founderID: ids[1]); try await team.save(on: db)
        let teamID = try team.requireID()
        for (index, admin, accepted) in [(1, true, true), (2, false, true), (3, false, false)] {
            try await TeamMembership(teamID: teamID, userID: ids[index], isAdmin: admin, accepted: accepted).save(on: db)
        }
        func project(_ name: String, parent: Project?, teamOwned: Bool = false, inherits: Bool = true) async throws -> Project {
            let p = Project(ownerID: ids[0], parentID: try parent?.requireID(), name: name)
            try await p.save(on: db)
            if teamOwned || !inherits {
                let row = try ProjectSharing(project: p)
                row.ownerType = teamOwned ? "team" : "person"; row.ownerID = teamOwned ? teamID : ids[0]; row.inherits = inherits
                try await row.save(on: db)
            }
            return p
        }
        let root = try await project("Root", parent: nil)
        let child = try await project("Child", parent: root)
        let leaf = try await project("Leaf", parent: child)
        let closed = try await project("Closed", parent: child, inherits: false)
        let below = try await project("Below closed", parent: closed)
        let teamProject = try await project("Team project", parent: root, teamOwned: true)
        let underTeam = try await project("Under team", parent: teamProject)
        try await ProjectGrant(projectID: try root.requireID(), principalType: "person", principalID: ids[4], role: .comment).save(on: db)
        try await ProjectGrant(projectID: try root.requireID(), principalType: "person", principalID: ids[6], role: .manage).save(on: db)
        try await ProjectGrant(projectID: try child.requireID(), principalType: "team", principalID: teamID, role: .edit).save(on: db)
        try await ProjectGrant(projectID: try closed.requireID(), principalType: "person", principalID: ids[2], role: .read).save(on: db)
        let all = [leaf, root, below, child, underTeam, closed, teamProject]

        // One resolver for everything, asked deepest first and then again: cached parts must not change an answer.
        let resolver = ResponsibilityResolver(db: db)
        var granted = 0
        for _ in 0..<2 {
            for user in users {
                for p in all {
                    let expected = user.isLocked ? nil : try await SharingAccess(user: user, db: db).visibility(p).role
                    let actual = try await resolver.role(of: try user.requireID(), projectID: try p.requireID())
                    XCTAssertEqual(actual, expected, "\(user.displayName) in \(p.name)")
                    if actual != nil { granted += 1 }
                }
            }
        }
        XCTAssertGreaterThan(granted, 20, "the fixture covers real rights, not only refusals")
        let unknownProject = try await resolver.role(of: ids[0], projectID: UUID())
        XCTAssertNil(unknownProject)
        let unknownUser = try await resolver.role(of: UUID(), projectID: try root.requireID())
        XCTAssertNil(unknownUser)
    }
}
