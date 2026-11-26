import Fluent
import SQLKit
import XCTVapor
@testable import TodoKit

/// Card BEF08998 (ADR 0036): the new columns are additive. Rows from the old schema keep their data, get no reuse window and
/// no revocation reason (so a connection revoked before can never be taken over).
final class OAuthReuseMigrationTests: XCTestCase {
    func testOldRowsSurviveAndStayStrict() async throws {
        let f = try await OAuthFixture.make()
        do {
            let db = f.test.app.db
            let sql = try XCTUnwrap(db as? any SQLDatabase)
            let tokens = try await f.tokens()
            let rotated = try await f.refresh(tokens.refresh)
            let next = try XCTUnwrap(rotated.body?["refresh_token"] as? String)
            let dead = OAuthGrant(userID: try f.user.requireID(), clientID: try XCTUnwrap(UUID(uuidString: f.clientID)),
                                  resource: f.test.settings.oauthResource, scopes: ["tasks:read"], projects: [try f.project.requireID()], name: "Old")
            dead.revoked = true; try await dead.save(on: db)

            // Back to the old schema and forward again.
            try await AddOAuthReuseAndRevocation().revert(on: db)
            try await AddOAuthReuseAndRevocation().prepare(on: db)

            let kept = try await sql.raw("SELECT revoked_reason, revoked_at, name FROM oauth_grants WHERE id = \(bind: try dead.requireID())").first()
            let row = try XCTUnwrap(kept)
            XCTAssertNil(try row.decode(column: "revoked_reason", as: String?.self))
            XCTAssertNil(try row.decode(column: "revoked_at", as: Date?.self))
            XCTAssertEqual(try row.decode(column: "name", as: String.self), "Old")
            let secrets = try await sql.raw("SELECT consumed_at, rotated_from FROM oauth_secrets").all()
            XCTAssertGreaterThanOrEqual(secrets.count, 5)
            for s in secrets {
                XCTAssertNil(try s.decode(column: "consumed_at", as: Date?.self))
                XCTAssertNil(try s.decode(column: "rotated_from", as: UUID?.self))
            }
            // The current refresh token keeps working; the one consumed under the old schema is a replay.
            let alive = try await f.refresh(next)
            XCTAssertEqual(alive.status, .ok)
            let replay = try await f.refresh(tokens.refresh)
            XCTAssertEqual(replay.status, .badRequest)
            let count = try await OAuthGrant.query(on: db).filter(\.$revoked == true).count()
            XCTAssertEqual(count, 2)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }
}
