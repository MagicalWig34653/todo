import Fluent
import SQLKit
import XCTVapor
@testable import TodoKit

/// Card FFF3C6AB (ADR 0040): sessions of the PWA and the apps no longer end 30 days after the sign-in. They end after 90 days
/// without use; every use after a day moves the end. Signing out and ending a session by hand stay immediate.
final class SessionLifetimeTests: XCTestCase {
    private let day: TimeInterval = 86_400

    private func run(_ body: (TestApp, User) async throws -> Void) async throws {
        let t = try await TestApp.make()
        do {
            let user = User(displayName: "Session User", isAdmin: false); try await user.save(on: t.app.db)
            try await body(t, user)
        } catch { await t.shutdown(); throw error }
        await t.shutdown()
    }

    private func session(_ t: TestApp, _ user: User, endsIn seconds: TimeInterval) async throws -> String {
        let raw = AuthSupport.randomToken()
        try await UserSession(userID: user.requireID(), tokenHash: AuthSupport.hash(raw), expiresAt: Date().addingTimeInterval(seconds)).save(on: t.app.db)
        return raw
    }

    private func remaining(_ t: TestApp, _ raw: String) async throws -> TimeInterval? {
        try await UserSession.query(on: t.app.db).filter(\.$tokenHash == AuthSupport.hash(raw)).first()?.expiresAt.timeIntervalSinceNow
    }

    /// GET /v1/me/sessions with the cookie as the PWA sends it; returns status and the Set-Cookie of the session cookie.
    private func get(_ t: TestApp, cookie raw: String) async throws -> (HTTPStatus, HTTPCookies.Value?) {
        var out: (HTTPStatus, HTTPCookies.Value?) = (.ok, nil)
        try await t.app.test(.GET, "/v1/me/sessions", beforeRequest: { req in
            req.headers.cookie = HTTPCookies(dictionaryLiteral: (AuthSupport.cookieName, HTTPCookies.Value(string: raw)))
        }, afterResponse: { res async in out = (res.status, res.headers.setCookie?[AuthSupport.cookieName]) })
        return out
    }

    func testDefaultLifetimeIsNinetyDays() async throws {
        XCTAssertEqual(AppSettings().sessionLifetime, 90 * day)
    }

    func testUsingASessionMovesItsEndAndRenewsTheCookie() async throws {
        try await run { t, user in
            // A session from before the change: 3 days left of its 30.
            let raw = try await session(t, user, endsIn: 3 * day)
            let (status, cookie) = try await get(t, cookie: raw)
            XCTAssertEqual(status, .ok)
            let left = try await remaining(t, raw)
            XCTAssertEqual(try XCTUnwrap(left), 90 * day, accuracy: 120)
            XCTAssertEqual(cookie?.string, raw)
            XCTAssertEqual(try XCTUnwrap(cookie?.expires).timeIntervalSinceNow, 90 * day, accuracy: 120)
            XCTAssertEqual(cookie?.isHTTPOnly, true)
            XCTAssertEqual(cookie?.sameSite, .strict)
            XCTAssertEqual(cookie?.path, "/")
        }
    }

    func testBearerSessionsOfTheAppsMoveTooAndGetNoCookie() async throws {
        try await run { t, user in
            let raw = try await session(t, user, endsIn: 10 * day)
            let r = try await t.json(.GET, "/v1/me/sessions", token: raw)
            XCTAssertEqual(r.status, .ok)
            XCTAssertNil(r.cookie)
            let left = try await remaining(t, raw)
            XCTAssertEqual(try XCTUnwrap(left), 90 * day, accuracy: 120)
        }
    }

    func testRenewalHappensAtMostOnceADay() async throws {
        try await run { t, user in
            let raw = try await session(t, user, endsIn: 90 * day - 3600)
            let (status, cookie) = try await get(t, cookie: raw)
            XCTAssertEqual(status, .ok)
            XCTAssertNil(cookie)
            let left = try await remaining(t, raw)
            XCTAssertEqual(try XCTUnwrap(left), 90 * day - 3600, accuracy: 60)
        }
    }

    /// A long poll answers late: meanwhile another account may have signed in in this browser. It neither moves the end nor
    /// sets a cookie; the next ordinary request does.
    func testTheLiveLongPollNeverSetsTheCookie() async throws {
        try await run { t, user in
            t.app.liveSettings.enabled = true
            let raw = try await session(t, user, endsIn: 3 * day)
            var out: (HTTPStatus, HTTPCookies.Value?) = (.imATeapot, nil)
            try await t.app.test(.GET, "/v1/sync/wait", beforeRequest: { req in
                req.headers.cookie = HTTPCookies(dictionaryLiteral: (AuthSupport.cookieName, HTTPCookies.Value(string: raw)))
            }, afterResponse: { res async in out = (res.status, res.headers.setCookie?[AuthSupport.cookieName]) })
            XCTAssertEqual(out.0, .ok)
            XCTAssertNil(out.1)
            let left = try await remaining(t, raw)
            XCTAssertEqual(try XCTUnwrap(left), 3 * day, accuracy: 120)
        }
    }

    /// A renewal that cannot be written never fails the request, and the cookie is only moved after a successful write.
    func testAFailedRenewalKeepsTheRequestAndTheCookieAsTheyAre() async throws {
        try await run { t, user in
            let raw = try await session(t, user, endsIn: 3 * day)
            let sql = try XCTUnwrap(t.app.db as? any SQLDatabase)
            if sql.dialect.name == "sqlite" {
                try await sql.raw("CREATE TRIGGER no_renewal BEFORE UPDATE ON sessions BEGIN SELECT RAISE(ABORT, 'locked'); END").run()
            } else {
                try await sql.raw("CREATE TRIGGER no_renewal BEFORE UPDATE ON sessions FOR EACH ROW SIGNAL SQLSTATE '45000'").run()
            }
            let (status, cookie) = try await get(t, cookie: raw)
            XCTAssertEqual(status, .ok)
            XCTAssertNil(cookie)
        }
    }

    func testAnEndedSessionStaysEnded() async throws {
        try await run { t, user in
            let raw = try await session(t, user, endsIn: -60)
            let (status, cookie) = try await get(t, cookie: raw)
            XCTAssertEqual(status, .unauthorized)
            XCTAssertNil(cookie)
            let left = try await remaining(t, raw)
            XCTAssertLessThan(try XCTUnwrap(left), 0)
        }
    }

    func testSigningOutAndEndingByHandStayImmediate() async throws {
        try await run { t, user in
            let mine = try await session(t, user, endsIn: 10 * day), other = try await session(t, user, endsIn: 10 * day)
            let ended = try await t.json(.POST, "/v1/me/sessions/revoke-others", token: mine)
            XCTAssertEqual(ended.status, .noContent)
            let (afterOther, otherCookie) = try await get(t, cookie: other)
            XCTAssertEqual(afterOther, .unauthorized)
            XCTAssertNil(otherCookie)
            // Signing out answers with the cleared cookie, never with a renewed one.
            var cleared: HTTPCookies.Value?
            try await t.app.test(.POST, "/v1/auth/logout", beforeRequest: { req in
                req.headers.contentType = .json
                req.headers.cookie = HTTPCookies(dictionaryLiteral: (AuthSupport.cookieName, HTTPCookies.Value(string: mine)))
            }, afterResponse: { res async in cleared = res.headers.setCookie?[AuthSupport.cookieName] })
            XCTAssertEqual(cleared?.string, "")
            let (after, _) = try await get(t, cookie: mine)
            XCTAssertEqual(after, .unauthorized)
        }
    }
}
