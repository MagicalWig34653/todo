import XCTVapor
@testable import TodoKit

/// Run with TODO_TEST_MARIADB=1 against the dev stack (see scripts/test-mariadb.sh).
final class MariaDBTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(TestApp.useMariaDB, "needs MariaDB (TODO_TEST_MARIADB=1)")
    }

    func testChallengeStartedOnReplicaAIsFinishedOnReplicaB() async throws {
        let a = try await TestApp.make()
        let b = try await a.replica()
        defer { Task { await a.shutdown(); await b.shutdown() } }
        let user = try await a.register(token: "bootstrap-secret", name: "Alice")

        let begin = try await a.json(.POST, "/v1/auth/login/begin")
        let challenge = ((begin.body!["options"] as! [String: Any])["challenge"]) as! String
        let finish = try await b.json(.POST, "/v1/auth/login/finish", [
            "challengeID": begin.body!["challengeID"]!, "credential": try user.key.assertion(challenge: challenge),
        ])
        XCTAssertEqual(finish.status, .ok)
        let token = try XCTUnwrap(finish.body?["token"] as? String)
        // The session issued by B is valid on A.
        let me = try await a.json(.GET, "/v1/me", token: token)
        XCTAssertEqual(me.status, .ok)
    }

    func testConcurrentUpdatesWithSameVersionYieldExactlyOneWinner() async throws {
        let a = try await TestApp.make()
        let b = try await a.replica()
        defer { Task { await a.shutdown(); await b.shutdown() } }
        let session = try await a.register(token: "bootstrap-secret", name: "Alice").session
        let p = try await a.json(.POST, "/v1/projects", ["name": "P"], token: session)
        let t = try await a.json(.POST, "/v1/tasks", ["projectID": p.body!["id"]!, "title": "T"], token: session)
        let id = t.body!["id"] as! String

        let statuses = try await withThrowingTaskGroup(of: HTTPStatus.self) { group -> [HTTPStatus] in
            for i in 0..<8 {
                let app = i % 2 == 0 ? a : b
                let body = try JSONSerialization.data(withJSONObject: ["version": 1, "title": "w\(i)"])
                group.addTask {
                    try await app.rawStatus(.PATCH, "/v1/tasks/\(id)", body: body, token: session)
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(statuses.filter { $0 == .ok }.count, 1, "\(statuses)")
        XCTAssertEqual(statuses.filter { $0 == .conflict }.count, 7, "\(statuses)")
    }

    func testBootstrapRaceCreatesOnlyOneAdmin() async throws {
        let a = try await TestApp.make()
        let b = try await a.replica()
        defer { Task { await a.shutdown(); await b.shutdown() } }
        // Both begin while bootstrap is open, then finish concurrently.
        var prepared: [(TestApp, Data)] = []
        for (app, name) in [(a, "Alice"), (b, "Bob")] {
            let begin = try await app.json(.POST, "/v1/auth/register/begin", ["token": "bootstrap-secret", "displayName": name])
            let challenge = ((begin.body!["options"] as! [String: Any])["challenge"]) as! String
            let body: [String: Any] = [
                "challengeID": begin.body!["challengeID"]!,
                "credential": VirtualAuthenticator().registrationResponse(challenge: challenge),
            ]
            prepared.append((app, try JSONSerialization.data(withJSONObject: body)))
        }
        let results = try await withThrowingTaskGroup(of: HTTPStatus.self) { group -> [HTTPStatus] in
            for (app, body) in prepared {
                group.addTask { try await app.rawStatus(.POST, "/v1/auth/register/finish", body: body) }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(results.filter { $0 == .ok }.count, 1, "\(results)")
    }
}
