import Fluent
import XCTVapor
@testable import TodoKit

/// ADR 0037: `CreateProjectGroups` only adds tables. Connections and mandates from before keep their rows byte for byte and
/// reach exactly their explicit projects (no rule row means "explicit list only").
final class ProjectGroupMigrationTests: XCTestCase {
    func testExistingGrantsAndMandatesKeepTheirMeaning() async throws {
        let test = try await TestApp.make()
        defer { Task { await test.shutdown() } }
        let db = test.app.db
        try await CreateProjectGroups().revert(on: db)

        let user = User(displayName: "Lino", isAdmin: false); try await user.save(on: db)
        let a = Project(ownerID: try user.requireID(), parentID: nil, name: "A"); try await a.save(on: db)
        let b = Project(ownerID: try user.requireID(), parentID: nil, name: "B"); try await b.save(on: db)
        let client = OAuthClient(name: "Client", redirects: []); try await client.save(on: db)
        let grant = OAuthGrant(userID: try user.requireID(), clientID: try client.requireID(), resource: "r", scopes: ["projects:read"], projects: [try a.requireID()])
        try await grant.save(on: db)
        let mandate = BrainMandate(userID: try user.requireID(), grantID: try grant.requireID(), projects: [try a.requireID()])
        try await mandate.save(on: db)

        try await CreateProjectGroups().prepare(on: db)

        let foundGrant = try await OAuthGrant.find(grant.requireID(), on: db)
        let g = try XCTUnwrap(foundGrant)
        XCTAssertEqual(g.explicitProjects, [try a.requireID()])
        let reach = try await g.resolveProjects(on: db)
        XCTAssertEqual(reach, [try a.requireID()])
        let foundMandate = try await BrainMandate.find(mandate.requireID(), on: db)
        let m = try XCTUnwrap(foundMandate)
        XCTAssertEqual(m.explicitProjects, [try a.requireID()])
        var resolver = ProjectSelectionResolver(userID: try user.requireID(), db: db)
        let covered = try await resolver.projects(of: m)
        XCTAssertEqual(covered, [try a.requireID()])
        let rules = try await ProjectSelectionRow.query(on: db).count()
        XCTAssertEqual(rules, 0)
        // Deleting a project still cascades into memberships and the agent marker.
        let group = ProjectGroup(); group.userID = try user.requireID(); group.name = "G"; group.nameKey = "g"; group.createdAt = Date(); group.updatedAt = Date()
        try await group.save(on: db)
        try await ProjectGroupMember(groupID: try group.requireID(), projectID: try b.requireID()).save(on: db)
        try await AgentCreatedProject(projectID: try b.requireID(), grantID: try grant.requireID()).save(on: db)
        try await b.delete(on: db)
        let members = try await ProjectGroupMember.query(on: db).count()
        let marks = try await AgentCreatedProject.query(on: db).count()
        XCTAssertEqual(members, 0)
        XCTAssertEqual(marks, 0)
    }
}
