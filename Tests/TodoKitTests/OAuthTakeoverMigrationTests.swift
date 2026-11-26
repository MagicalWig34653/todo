import Fluent
import SQLKit
import XCTVapor
@testable import TodoKit

/// Card BEF08998 part 2 (ADR 0036): the lineage columns are additive; old connections and mandates stay as they are.
final class OAuthTakeoverMigrationTests: XCTestCase {
    func testOldConnectionAndMandateSurviveWithoutLineage() async throws {
        let f = try await OAuthFixture.make()
        do {
            let db = f.test.app.db
            let sql = try XCTUnwrap(db as? any SQLDatabase)
            _ = try await f.tokens()
            let found = try await OAuthGrant.query(on: db).first()
            let grant = try XCTUnwrap(found)
            let project = try f.project.requireID()
            let put = try await f.test.json(.PUT, "/v1/settings/brain-mandate",
                ["grantID": try grant.requireID().uuidString, "projectIDs": [project.uuidString]], token: f.session)
            XCTAssertEqual(put.status, .ok)

            try await AddOAuthGrantLineage().revert(on: db)
            try await AddOAuthGrantLineage().prepare(on: db)

            let kept = try await sql.raw("SELECT predecessors, taken_over_at FROM oauth_grants WHERE id = \(bind: try grant.requireID())").first()
            let row = try XCTUnwrap(kept)
            XCTAssertNil(try row.decode(column: "predecessors", as: String?.self))
            XCTAssertNil(try row.decode(column: "taken_over_at", as: Date?.self))
            let after = try await OAuthGrant.find(grant.id, on: db)
            XCTAssertEqual(after?.projects, grant.projects)
            let list = try await f.test.json(.GET, "/v1/settings/brain-mandate", token: f.session)
            let mandate = try XCTUnwrap((list.body?["mandates"] as? [[String: Any]])?.first)
            XCTAssertEqual(mandate["active"] as? Bool, true)
            XCTAssertNil(mandate["takenOver"])
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }
}
