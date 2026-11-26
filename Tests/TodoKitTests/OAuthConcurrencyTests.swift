import Fluent
import XCTVapor
@testable import TodoKit

/// MariaDB only: the grant row lock serialises rotations (ADR 0036).
final class OAuthConcurrencyTests: XCTestCase {
    private typealias Rotation = (status: HTTPStatus, refresh: String?)

    private func parallel(_ f: OAuthFixture, _ tokens: [String]) async throws -> [Rotation] {
        try await withThrowingTaskGroup(of: Rotation.self) { group in
            for raw in tokens {
                group.addTask {
                    let r = try await f.refresh(raw)
                    return (r.status, r.body?["refresh_token"] as? String)
                }
            }
            var out: [Rotation] = []
            for try await result in group { out.append(result) }
            return out
        }
    }

    private func run(_ body: (OAuthFixture, String, String) async throws -> Void) async throws {
        guard TestApp.useMariaDB else { throw XCTSkip("MariaDB row locks required") }
        let f = try await OAuthFixture.make()
        do {
            let tokens = try await f.tokens()
            try await body(f, tokens.access, tokens.refresh)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    /// Two processes with one stored sign-in refresh at the same moment: nobody is signed out; the first sibling that is
    /// used keeps the connection, the other one is a replay afterwards.
    func testConcurrentRefreshKeepsTheConnectionAndOneSiblingWins() async throws {
        try await run { f, access, refresh in
            let both = try await parallel(f, [refresh, refresh])
            XCTAssertEqual(both.map(\.status), [.ok, .ok])
            let still = try await f.rpc("tools/list", access: access)
            XCTAssertEqual(still.status, .ok)
            let siblings = both.compactMap(\.refresh)
            XCTAssertEqual(Set(siblings).count, 2)
            guard siblings.count == 2 else { return }
            let winner = try await f.refresh(siblings[0])
            XCTAssertEqual(winner.status, .ok)
            let loser = try await f.refresh(siblings[1])
            XCTAssertEqual(loser.status, .badRequest)
            let denied = try await f.rpc("tools/list", access: access)
            XCTAssertEqual(denied.status, .unauthorized)
        }
    }

    /// Security review 26.11.2026: rotations of DIFFERENT connections must not touch each other's rows. The sibling retirement
    /// used to be `UPDATE oauth_secrets ... WHERE rotated_from = ?` without an index; MariaDB then locks every scanned row of
    /// the table (ERROR 1213 deadlock, ERROR 1020 "record has changed" under snapshot isolation). Three connections hold
    /// sibling tokens (a repeat in the window), three rotate plainly; all six rotate at the same moment, round after round.
    func testRotationsOfDifferentConnectionsRunConcurrently() async throws {
        guard TestApp.useMariaDB else { throw XCTSkip("MariaDB row locks required") }
        let f = try await OAuthFixture.make()
        do {
            var current: [String] = []
            for _ in 0..<6 { current.append(try await f.tokens().refresh) }
            for round in 0..<12 {
                var batch = current
                for i in 0..<3 {
                    let used = try await f.refresh(current[i])
                    let repeated = try await f.refresh(current[i])
                    XCTAssertEqual([used.status, repeated.status], [.ok, .ok], "round \(round)")
                    batch[i] = try XCTUnwrap(used.body?["refresh_token"] as? String)
                }
                let results = try await withThrowingTaskGroup(of: (Int, HTTPStatus, String?).self) { group in
                    for (i, raw) in batch.enumerated() {
                        group.addTask { let r = try await f.refresh(raw); return (i, r.status, r.body?["refresh_token"] as? String) }
                    }
                    var out: [(Int, HTTPStatus, String?)] = []
                    for try await r in group { out.append(r) }
                    return out.sorted { $0.0 < $1.0 }
                }
                XCTAssertEqual(results.map(\.1), Array(repeating: HTTPStatus.ok, count: 6), "round \(round)")
                guard results.allSatisfy({ $0.1 == .ok }) else { break }
                current = results.compactMap(\.2)
            }
            let revoked = try await OAuthGrant.query(on: f.test.app.db).filter(\.$revoked == true).count()
            XCTAssertEqual(revoked, 0)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    /// Both branches used at the same moment (the shape of a stolen token): exactly one rotation succeeds and the connection
    /// is revoked.
    func testConcurrentUseOfTwoSiblingsRevokesTheConnection() async throws {
        try await run { f, access, refresh in
            let first = try await f.refresh(refresh), second = try await f.refresh(refresh)
            let siblings = [first, second].compactMap { $0.body?["refresh_token"] as? String }
            XCTAssertEqual(siblings.count, 2)
            let used = try await parallel(f, siblings)
            XCTAssertEqual(used.filter { $0.status == .ok }.count, 1)
            XCTAssertEqual(used.filter { $0.status == .badRequest }.count, 1)
            let denied = try await f.rpc("tools/list", access: access)
            XCTAssertEqual(denied.status, .unauthorized)
        }
    }
}
