import Fluent
import FluentSQL
import SQLKit
import XCTVapor
@testable import TodoKit

/// ADR 0032 addendum: `brain_mandates` is unique on (user_id, grant_id) instead of user_id alone. The existing mandate must
/// survive the migration unchanged. The test brings the schema back to the old state (`revert`), inserts a mandate there and
/// migrates forward again.
final class BrainMandateMigrationTests: XCTestCase {
    private func grant(_ user: User, client: OAuthClient, name: String, on db: any Database) async throws -> OAuthGrant {
        let g = OAuthGrant(userID: try user.requireID(), clientID: try client.requireID(), resource: "r", scopes: [], projects: [], name: name)
        try await g.save(on: db)
        return g
    }

    func testMigrationKeepsTheExistingMandateAndAllowsOnePerGrant() async throws {
        let test = try await TestApp.make()
        defer { Task { await test.shutdown() } }
        let db = test.app.db
        let user = User(displayName: "Lino", isAdmin: true); try await user.save(on: db)
        let client = OAuthClient(name: "Client", redirects: []); try await client.save(on: db)
        let a = try await grant(user, client: client, name: "A", on: db), b = try await grant(user, client: client, name: "B", on: db)
        let project = UUID()

        // Old state: unique(user_id). A second mandate for the same person is rejected.
        try await BrainMandateGrantUnique().revert(on: db)
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let old = BrainMandate(userID: try user.requireID(), grantID: try a.requireID(), projects: [project], now: created)
        try await old.save(on: db)
        do {
            try await BrainMandate(userID: try user.requireID(), grantID: try b.requireID(), projects: [project]).save(on: db)
            XCTFail("the old schema allows one mandate per person")
        } catch {}

        // New state: the mandate is unchanged, a second connection may hold its own, the same connection not twice.
        try await BrainMandateGrantUnique().prepare(on: db)
        let rows = try await BrainMandate.query(on: db).all()
        XCTAssertEqual(rows.count, 1)
        let kept = try XCTUnwrap(rows.first)
        XCTAssertEqual(kept.id, old.id)
        XCTAssertEqual(kept.userID, try user.requireID())
        XCTAssertEqual(kept.grantID, try a.requireID())
        XCTAssertEqual(kept.explicitProjects, [project])
        XCTAssertNil(kept.revokedAt)
        XCTAssertEqual(kept.createdAt.timeIntervalSince1970, created.timeIntervalSince1970, accuracy: 1)
        try await BrainMandate(userID: try user.requireID(), grantID: try b.requireID(), projects: [project]).save(on: db)
        try await assertEqual(try await BrainMandate.query(on: db).count(), 2)
        do {
            try await BrainMandate(userID: try user.requireID(), grantID: try a.requireID(), projects: [project]).save(on: db)
            XCTFail("one mandate per connection")
        } catch {}
        // Deleting the person still removes the mandates (foreign keys survived the rebuild).
        try await user.delete(on: db)
        try await assertEqual(try await BrainMandate.query(on: db).count(), 0)
    }

    func testMigrationRunsAgainstARevokedMandateToo() async throws {
        let test = try await TestApp.make()
        defer { Task { await test.shutdown() } }
        let db = test.app.db
        let user = User(displayName: "Lino", isAdmin: true); try await user.save(on: db)
        let client = OAuthClient(name: "Client", redirects: []); try await client.save(on: db)
        let a = try await grant(user, client: client, name: "A", on: db)
        try await BrainMandateGrantUnique().revert(on: db)
        let m = BrainMandate(userID: try user.requireID(), grantID: try a.requireID(), projects: [UUID(), UUID()])
        m.revokedAt = Date(); try await m.save(on: db)
        try await BrainMandateGrantUnique().prepare(on: db)
        let first = try await BrainMandate.query(on: db).first()
        let kept = try XCTUnwrap(first)
        XCTAssertNotNil(kept.revokedAt)
        XCTAssertEqual(kept.explicitProjects, m.explicitProjects)
    }
}
