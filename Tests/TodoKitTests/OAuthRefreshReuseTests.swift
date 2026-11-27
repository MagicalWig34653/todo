import Fluent
import SQLKit
import XCTVapor
@testable import TodoKit

/// Card BEF08998 (ADR 0036), card FFF3C6AB (ADR 0040): a client that lost the answer of a rotation (log 26.11.: "Token persist
/// failed", the old refresh token sent again 58 s later; same evening: seven minutes later) keeps its connection and its brain
/// mandate. Real replay (a successor was already used) still revokes the whole connection.
final class OAuthRefreshReuseTests: XCTestCase {
    private typealias Reply = (status: HTTPStatus, body: [String: Any]?, list: [[String: Any]]?, cookie: String?)

    private struct Env {
        let f: OAuthFixture
        let access: String, refresh: String
        let grant: UUID
    }

    private func run(_ body: (Env) async throws -> Void) async throws {
        let f = try await OAuthFixture.make()
        do {
            let t = try await f.tokens()
            let found = try await OAuthGrant.query(on: f.test.app.db).first()
            let grant = try XCTUnwrap(found?.id)
            try await body(Env(f: f, access: t.access, refresh: t.refresh, grant: grant))
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    private func token(_ r: Reply, _ key: String = "refresh_token", file: StaticString = #filePath, line: UInt = #line) throws -> String {
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])", file: file, line: line)
        return try XCTUnwrap(r.body?[key] as? String, file: file, line: line)
    }

    private func alive(_ e: Env, file: StaticString = #filePath, line: UInt = #line) async throws {
        let g = try await OAuthGrant.find(e.grant, on: e.f.test.app.db)
        XCTAssertEqual(g?.revoked, false, "the connection must stay", file: file, line: line)
    }

    private func revoked(_ e: Env, reason: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let g = try await OAuthGrant.find(e.grant, on: e.f.test.app.db)
        XCTAssertEqual(g?.revoked, true, "the connection must be revoked", file: file, line: line)
        let stored = try await column("revoked_reason", table: "oauth_grants", id: e.grant, on: e.f.test.app.db)
        XCTAssertEqual(stored, reason, file: file, line: line)
    }

    private func column(_ name: String, table: String, id: UUID, on db: any Database) async throws -> String? {
        let sql = try XCTUnwrap(db as? any SQLDatabase)
        let row = try await sql.raw("SELECT \(ident: name) FROM \(ident: table) WHERE id = \(bind: id)").first()
        return try row?.decode(column: name, as: String?.self)
    }

    /// Moves the moment the refresh token was used into the past (the server clock cannot be moved in a test).
    private func age(_ e: Env, _ raw: String, seconds: TimeInterval) async throws {
        let found = try await OAuthSecret.query(on: e.f.test.app.db).filter(\.$hash == AuthSupport.hash(raw)).first()
        let id = try XCTUnwrap(found?.id)
        let sql = try XCTUnwrap(e.f.test.app.db as? any SQLDatabase)
        // `try?`: before ADR 0036 there is no such column; the behaviour assertions that follow are what must fail then.
        try? await sql.raw("UPDATE oauth_secrets SET consumed_at = \(bind: Date().addingTimeInterval(-seconds)) WHERE id = \(bind: id)").run()
    }

    private func mandate(_ e: Env) async throws -> [String: Any] {
        let r = try await e.f.test.json(.GET, "/v1/settings/brain-mandate", token: e.f.session)
        return try XCTUnwrap((r.body?["mandates"] as? [[String: Any]])?.first)
    }

    func testResendingTheJustRotatedTokenKeepsConnectionAndMandate() async throws {
        try await run { e in
            let put = try await e.f.test.json(.PUT, "/v1/settings/brain-mandate",
                ["grantID": e.grant.uuidString, "projectIDs": [try e.f.project.requireID().uuidString]], token: e.f.session)
            XCTAssertEqual(put.status, .ok)
            let lost = try token(try await e.f.refresh(e.refresh))
            try await age(e, e.refresh, seconds: 58)
            let again = try await e.f.refresh(e.refresh)
            let access = try token(again, "access_token"), refresh = try token(again)
            XCTAssertNotEqual(refresh, lost)
            try await alive(e)
            let list = try await e.f.rpc("tools/list", access: access)
            XCTAssertEqual(list.status, .ok)
            let m = try await mandate(e)
            XCTAssertEqual(m["active"] as? Bool, true)
            _ = try token(try await e.f.refresh(refresh))
            try await alive(e)
        }
    }

    /// Two processes share one stored sign-in: whichever answer was written last keeps working; the other branch dies as
    /// soon as one was used, and presenting it afterwards is a replay.
    func testWhicheverSiblingIsUsedWinsAndTheOtherOneIsAReplay() async throws {
        for winner in [0, 1] {
            try await run { e in
                let first = try token(try await e.f.refresh(e.refresh))
                let second = try token(try await e.f.refresh(e.refresh))
                let siblings = [first, second]
                let next = try await e.f.refresh(siblings[winner])
                let nextAccess = try token(next, "access_token"), nextRefresh = try token(next)
                try await alive(e)
                let loser = try await e.f.refresh(siblings[1 - winner])
                XCTAssertEqual(loser.status, .badRequest)
                try await revoked(e, reason: "replay")
                let after = try await e.f.refresh(nextRefresh)
                XCTAssertEqual(after.status, .badRequest)
                let list = try await e.f.rpc("tools/list", access: nextAccess)
                XCTAssertEqual(list.status, .unauthorized)
            }
        }
    }

    func testReuseAfterTheNewTokenWasUsedRevokesEverything() async throws {
        try await run { e in
            let second = try token(try await e.f.refresh(e.refresh))
            let third = try await e.f.refresh(second)
            let thirdAccess = try token(third, "access_token")
            let replay = try await e.f.refresh(e.refresh)
            XCTAssertEqual(replay.status, .badRequest)
            try await revoked(e, reason: "replay")
            let list = try await e.f.rpc("tools/list", access: thirdAccess)
            XCTAssertEqual(list.status, .unauthorized)
        }
    }

    /// Card FFF3C6AB, the failure of 26.11. (client logs): a process rotated the token and never stored the answer; the next
    /// session sent the stored (previous) token about seven minutes later. Nobody ever used the result of that rotation, so
    /// this is a lost answer, not a second holder: the connection and its mandate stay.
    func testALostRotationNoticedMinutesLaterKeepsConnectionAndMandate() async throws {
        try await run { e in
            let put = try await e.f.test.json(.PUT, "/v1/settings/brain-mandate",
                ["grantID": e.grant.uuidString, "projectIDs": [try e.f.project.requireID().uuidString]], token: e.f.session)
            XCTAssertEqual(put.status, .ok)
            _ = try token(try await e.f.refresh(e.refresh))
            try await age(e, e.refresh, seconds: 436)
            let again = try await e.f.refresh(e.refresh)
            let access = try token(again, "access_token"), refresh = try token(again)
            try await alive(e)
            let list = try await e.f.rpc("tools/list", access: access)
            XCTAssertEqual(list.status, .ok)
            let m = try await mandate(e)
            XCTAssertEqual(m["active"] as? Bool, true)
            _ = try token(try await e.f.refresh(refresh))
            try await alive(e)
        }
    }

    /// The same after the Mac slept for days: age alone never turns a lost answer into theft.
    func testALostRotationNoticedDaysLaterKeepsTheConnection() async throws {
        try await run { e in
            _ = try token(try await e.f.refresh(e.refresh))
            try await age(e, e.refresh, seconds: 10 * 86_400)
            let refresh = try token(try await e.f.refresh(e.refresh))
            try await alive(e)
            _ = try token(try await e.f.refresh(refresh))
        }
    }

    /// Many parallel sessions share one stored sign-in. While the store keeps the previous token, each of them sends it.
    func testManyParallelSessionsSendingTheStoredTokenKeepTheConnection() async throws {
        try await run { e in
            _ = try token(try await e.f.refresh(e.refresh))
            var last = ""
            for n in 1...12 { last = try token(try await e.f.refresh(e.refresh)); XCTAssertFalse(last.isEmpty, "session \(n)") }
            try await alive(e)
            _ = try token(try await e.f.refresh(last))
            try await alive(e)
        }
    }

    /// Theft detection stays: as soon as any successor was used, the old token revokes everything, however long ago.
    func testAnOldTokenAfterTheChainMovedOnStillRevokesEverything() async throws {
        try await run { e in
            let second = try token(try await e.f.refresh(e.refresh))
            try await age(e, e.refresh, seconds: 3 * 86_400)
            let third = try token(try await e.f.refresh(second))
            let replay = try await e.f.refresh(e.refresh)
            XCTAssertEqual(replay.status, .badRequest)
            try await revoked(e, reason: "replay")
            let after = try await e.f.refresh(third)
            XCTAssertEqual(after.status, .badRequest)
        }
    }

    /// And the branch that lost the race after a late repeat is a replay too: two holders of one sign-in cannot both go on.
    func testAfterALateRepeatTheLosingBranchIsAReplay() async throws {
        try await run { e in
            let lost = try token(try await e.f.refresh(e.refresh))
            try await age(e, e.refresh, seconds: 3600)
            let recovered = try token(try await e.f.refresh(e.refresh))
            _ = try token(try await e.f.refresh(recovered))
            let loser = try await e.f.refresh(lost)
            XCTAssertEqual(loser.status, .badRequest)
            try await revoked(e, reason: "replay")
        }
    }

    /// An idle connection stays signed in for 90 days after its last refresh (before: 30).
    func testRefreshTokensLastNinetyDaysFromTheLastRefresh() async throws {
        try await run { e in
            let next = try token(try await e.f.refresh(e.refresh))
            for raw in [e.refresh, next] {
                let stored = try await OAuthSecret.query(on: e.f.test.app.db).filter(\.$hash == AuthSupport.hash(raw)).first()
                XCTAssertEqual(try XCTUnwrap(stored?.expiresAt).timeIntervalSinceNow, 90 * 86_400, accuracy: 120)
            }
        }
    }

    /// A rotation recorded before the window existed (no `consumed_at`) gets no window.
    func testConsumedTokenWithoutTimestampIsAReplay() async throws {
        try await run { e in
            _ = try token(try await e.f.refresh(e.refresh))
            let sql = try XCTUnwrap(e.f.test.app.db as? any SQLDatabase)
            try await sql.raw("UPDATE oauth_secrets SET consumed_at = NULL").run()
            let replay = try await e.f.refresh(e.refresh)
            XCTAssertEqual(replay.status, .badRequest)
            try await revoked(e, reason: "replay")
        }
    }

    func testExpiredOldTokenGetsNoWindow() async throws {
        try await run { e in
            _ = try token(try await e.f.refresh(e.refresh))
            try await OAuthSecret.query(on: e.f.test.app.db).filter(\.$hash == AuthSupport.hash(e.refresh))
                .set(\.$expiresAt, to: Date().addingTimeInterval(-1)).update()
            let replay = try await e.f.refresh(e.refresh)
            XCTAssertEqual(replay.status, .badRequest)
            try await revoked(e, reason: "replay")
        }
    }

    func testForeignClientNeverUsesTheWindow() async throws {
        try await run { e in
            let second = try token(try await e.f.refresh(e.refresh))
            let other = try await e.f.test.json(.POST, "/oauth/register", ["client_name": "Test Client", "redirect_uris": [e.f.redirect]])
            let foreign = try await e.f.test.json(.POST, "/oauth/token", ["grant_type": "refresh_token",
                "client_id": try XCTUnwrap(other.body?["client_id"] as? String), "resource": e.f.test.settings.oauthResource, "refresh_token": e.refresh])
            XCTAssertEqual(foreign.status, .badRequest)
            XCTAssertNil(foreign.body?["access_token"])
            _ = try token(try await e.f.refresh(second))
        }
    }

    func testRevocationByThePersonEndsTheWindowAndStaysTheirDecision() async throws {
        try await run { e in
            _ = try token(try await e.f.refresh(e.refresh))
            let del = try await e.f.test.json(.DELETE, "/oauth/grants/\(e.grant)", token: e.f.session)
            XCTAssertEqual(del.status, .noContent)
            let after = try await e.f.refresh(e.refresh)
            XCTAssertEqual(after.status, .badRequest)
            try await revoked(e, reason: "person")
        }
    }

    func testAccountLockEndsTheWindow() async throws {
        try await run { e in
            _ = try token(try await e.f.refresh(e.refresh))
            try await AccountLock.apply(.disable, userID: try e.f.user.requireID(), actor: e.f.user, allowSelf: true, on: e.f.test.app.db)
            let after = try await e.f.refresh(e.refresh)
            XCTAssertEqual(after.status, .badRequest)
            try await revoked(e, reason: "account_locked")
        }
    }
}
