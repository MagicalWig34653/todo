import Fluent
import SQLKit
import XCTVapor
@testable import TodoKit

final class MCPExtensionTests: XCTestCase {
    static let allScopes = "projects:read tasks:read tasks:write comments:write attachments:read agents:read"
    private func call(_ f: OAuthFixture, _ name: String, _ args: [String: Any], access: String) async throws -> (isError: Bool, text: String) {
        let r = try await f.rpc("tools/call", ["name": name, "arguments": args], access: access)
        let result = try XCTUnwrap(r.body?["result"] as? [String: Any])
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        return (result["isError"] as? Bool ?? false, text)
    }
    private func json(_ text: String) throws -> Any { try JSONSerialization.jsonObject(with: Data(text.utf8)) }

    private func attachment(_ task: UUID, owner: UUID, status: String, on db: any Database) async throws -> Attachment {
        let a = Attachment()
        a.id = UUID(); a.taskID = task; a.ownerID = owner; a.filename = "shot.png"; a.role = "progress"
        a.mediaType = "image/png"; a.size = 10; a.checksum = String(repeating: "a", count: 64); a.status = status
        a.objectKey = "attachments/\(a.id!.uuidString.lowercased())"
        try await a.create(on: db)
        return a
    }

    func testToolListFollowsScopes() async throws {
        let f = try await OAuthFixture.make()
        do {
            func names(_ scope: String) async throws -> Set<String> {
                let t = try await f.tokens(scope: scope)
                let r = try await f.rpc("tools/list", access: t.access)
                let tools = (r.body?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
                return Set(tools?.compactMap { $0["name"] as? String } ?? [])
            }
            let all = try await names("projects:read tasks:read tasks:write comments:write attachments:read agents:read")
            XCTAssertTrue(Set(["list_comments", "add_comment", "get_progress", "list_attachments", "get_attachment"]).isSubset(of: all))
            let readOnly = try await names("tasks:read")
            XCTAssertEqual(readOnly, Set(["list_tasks", "get_task", "list_comments"]))
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testCommentsShareRestRulesAndScopes() async throws {
        let f = try await OAuthFixture.make()
        do {
            let db = f.test.app.db
            let task = TodoTask(ownerID: try f.user.requireID(), projectID: try f.project.requireID(), title: "Commented", details: "")
            try await task.save(on: db)
            let tid = try task.requireID().uuidString
            let full = try await f.tokens(scope: Self.allScopes)

            let first = try await call(f, "add_comment", ["taskID": tid, "body": "  Hello from MCP  ", "idempotencyKey": "key-1"], access: full.access)
            XCTAssertFalse(first.isError)
            let comment = try XCTUnwrap(json(first.text) as? [String: Any])
            XCTAssertEqual(comment["body"] as? String, "Hello from MCP")
            let retry = try await call(f, "add_comment", ["taskID": tid, "body": "Hello from MCP", "idempotencyKey": "key-1"], access: full.access)
            XCTAssertEqual((try json(retry.text) as? [String: Any])?["id"] as? String, comment["id"] as? String)
            let conflict = try await call(f, "add_comment", ["taskID": tid, "body": "Different", "idempotencyKey": "key-1"], access: full.access)
            XCTAssertEqual(conflict.text, "idempotency_conflict")
            for bad in [["taskID": tid, "body": "   "], ["taskID": tid, "body": "x", "idempotencyKey": "bad key"]] {
                let r = try await call(f, "add_comment", bad, access: full.access)
                XCTAssertTrue(r.isError)
            }

            // REST sees the same comment; the activity names an integration, not a person.
            let rest = try await f.test.json(.GET, "/v1/tasks/\(tid)/comments", token: f.session)
            XCTAssertEqual(rest.list?.count, 1)
            let activity = try await f.test.json(.GET, "/v1/tasks/\(tid)/activity", token: f.session)
            let items = try XCTUnwrap(activity.body?["items"] as? [[String: Any]])
            XCTAssertEqual(items.last?["kind"] as? String, "comment.created")
            XCTAssertEqual(items.last?["actorType"] as? String, "Integration")

            let listed = try await call(f, "list_comments", ["taskID": tid], access: full.access)
            XCTAssertEqual((try json(listed.text) as? [[String: Any]])?.count, 1)

            // Scope: read-only tokens cannot comment, but can read.
            let readOnly = try await f.tokens(scope: "tasks:read")
            let denied = try await call(f, "add_comment", ["taskID": tid, "body": "No"], access: readOnly.access)
            XCTAssertEqual(denied.text, "insufficient_scope")
            let readable = try await call(f, "list_comments", ["taskID": tid], access: readOnly.access)
            XCTAssertFalse(readable.isError)
            let noAttachments = try await call(f, "list_attachments", ["taskID": tid], access: readOnly.access)
            XCTAssertEqual(noAttachments.text, "insufficient_scope")

            // Project outside the grant and unknown tasks look identical.
            let foreign = TodoTask(ownerID: try f.user.requireID(), projectID: try f.other.requireID(), title: "Excluded", details: "")
            try await foreign.save(on: db)
            for id in [try foreign.requireID(), UUID()] {
                let r = try await call(f, "add_comment", ["taskID": id.uuidString, "body": "x"], access: full.access)
                XCTAssertEqual(r.text, "not_found")
                let l = try await call(f, "list_comments", ["taskID": id.uuidString], access: full.access)
                XCTAssertEqual(l.text, "not_found")
            }

            // Live rights: a read-only share loses commenting but keeps reading; no share hides the task.
            let stranger = User(displayName: "New Owner", isAdmin: false); try await stranger.save(on: db)
            f.project.ownerID = try stranger.requireID(); try await f.project.save(on: db)
            try await ProjectGrant(projectID: f.project.requireID(), principalType: "person", principalID: f.user.requireID(), role: .read).save(on: db)
            let forbidden = try await call(f, "add_comment", ["taskID": tid, "body": "No"], access: full.access)
            XCTAssertTrue(forbidden.isError)
            XCTAssertNotEqual(forbidden.text, "not_found")
            let stillReadable = try await call(f, "list_comments", ["taskID": tid], access: full.access)
            XCTAssertFalse(stillReadable.isError)
            try await ProjectGrant.query(on: db).delete()
            let hidden = try await call(f, "list_comments", ["taskID": tid], access: full.access)
            XCTAssertEqual(hidden.text, "not_found")
            let count = try await TaskComment.query(on: db).count()
            XCTAssertEqual(count, 1)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testAttachmentMetadataOnlyCompleteAndAuthorized() async throws {
        let f = try await OAuthFixture.make()
        do {
            let db = f.test.app.db
            let uid = try f.user.requireID()
            let task = TodoTask(ownerID: uid, projectID: try f.project.requireID(), title: "Files", details: "")
            let foreign = TodoTask(ownerID: uid, projectID: try f.other.requireID(), title: "Excluded", details: "")
            try await task.save(on: db); try await foreign.save(on: db)
            let complete = try await attachment(task.requireID(), owner: uid, status: "complete", on: db)
            let pending = try await attachment(task.requireID(), owner: uid, status: "pending", on: db)
            let excluded = try await attachment(foreign.requireID(), owner: uid, status: "complete", on: db)
            let t = try await f.tokens(scope: Self.allScopes)

            let listed = try await call(f, "list_attachments", ["taskID": task.requireID().uuidString], access: t.access)
            let rows = try XCTUnwrap(json(listed.text) as? [[String: Any]])
            XCTAssertEqual(rows.compactMap { $0["id"] as? String }, [try complete.requireID().uuidString])
            XCTAssertNil(rows.first?["objectKey"])
            let one = try await call(f, "get_attachment", ["id": complete.requireID().uuidString], access: t.access)
            XCTAssertEqual((try json(one.text) as? [String: Any])?["mediaType"] as? String, "image/png")
            for id in [try pending.requireID(), try excluded.requireID(), UUID()] {
                let r = try await call(f, "get_attachment", ["id": id.uuidString], access: t.access)
                XCTAssertEqual(r.text, "not_found")
            }
            let rest = try await f.test.json(.GET, "/v1/tasks/\(try task.requireID())/attachments", token: f.session)
            XCTAssertEqual(rest.list?.compactMap { $0["id"] as? String }, rows.compactMap { $0["id"] as? String })

            // Losing project access hides the metadata immediately.
            let stranger = User(displayName: "New Owner", isAdmin: false); try await stranger.save(on: db)
            f.project.ownerID = try stranger.requireID(); try await f.project.save(on: db)
            let lost = try await call(f, "get_attachment", ["id": complete.requireID().uuidString], access: t.access)
            XCTAssertEqual(lost.text, "not_found")
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testProgressShowsJobsAndCheckpointsToProjectOwnerOnly() async throws {
        let f = try await OAuthFixture.make()
        do {
            let db = f.test.app.db
            let uid = try f.user.requireID(), pid = try f.project.requireID()
            let task = TodoTask(ownerID: uid, projectID: pid, title: "Agent work", details: "")
            try await task.save(on: db)
            let device = RunnerDevice(ownerID: uid, label: "Mac", tokenHash: "h", revokedAt: nil); try await device.save(on: db)
            let binding = ProjectRunnerBinding(projectID: pid, deviceID: try device.requireID(), repositoryKey: UUID().uuidString.lowercased(), label: "repo")
            try await binding.save(on: db)
            let job = AgentJob(taskID: try task.requireID(), projectID: pid, bindingID: try binding.requireID(), requestedBy: uid,
                               taskRevision: 1, mode: "implement", scope: "scope", state: "running", progress: "Step 2 of 3", result: nil)
            try await job.save(on: db)
            let run = AgentRun(jobID: try job.requireID(), bindingID: try binding.requireID(), deviceID: try device.requireID(),
                               generation: 1, leaseUntil: Date().addingTimeInterval(60), endedAt: nil)
            try await run.save(on: db)
            try await AgentCheckpoint(runID: try run.requireID(), contextRevision: 1, sessionReference: "session-abc", nextStep: "Write tests").save(on: db)
            let t = try await f.tokens(scope: Self.allScopes)

            let r = try await call(f, "get_progress", ["taskID": task.requireID().uuidString], access: t.access)
            let jobs = try XCTUnwrap(json(r.text) as? [[String: Any]])
            XCTAssertEqual(jobs.count, 1)
            XCTAssertEqual((jobs[0]["job"] as? [String: Any])?["progress"] as? String, "Step 2 of 3")
            let runs = try XCTUnwrap(jobs[0]["runs"] as? [[String: Any]])
            XCTAssertEqual((runs.first?["checkpoint"] as? [String: Any])?["nextStep"] as? String, "Write tests")

            let noScope = try await f.tokens(scope: "tasks:read")
            let denied = try await call(f, "get_progress", ["taskID": task.requireID().uuidString], access: noScope.access)
            XCTAssertEqual(denied.text, "insufficient_scope")

            // Editors may read tasks but not agent runs (startAgent is owner-only), same as the REST job detail.
            let stranger = User(displayName: "New Owner", isAdmin: false); try await stranger.save(on: db)
            f.project.ownerID = try stranger.requireID(); try await f.project.save(on: db)
            try await ProjectGrant(projectID: pid, principalType: "person", principalID: uid, role: .edit).save(on: db)
            let editor = try await call(f, "get_progress", ["taskID": task.requireID().uuidString], access: t.access)
            XCTAssertTrue(editor.isError)
            XCTAssertFalse(editor.text.contains("Write tests"))
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    // MARK: cleanup

    private func seedExpired(_ t: TestApp) async throws -> (expiredSession: UUID, liveSession: UUID, liveSecret: UUID) {
        let db = t.app.db
        let u = User(displayName: "Cleanup", isAdmin: false); try await u.save(on: db)
        let uid = try u.requireID()
        let past = Date().addingTimeInterval(-10 * 86_400), future = Date().addingTimeInterval(3600)
        let expiredSession = UserSession(userID: uid, tokenHash: AuthSupport.hash("a"), expiresAt: past); try await expiredSession.save(on: db)
        let liveSession = UserSession(userID: uid, tokenHash: AuthSupport.hash("b"), expiresAt: future); try await liveSession.save(on: db)
        try await AuthChallenge(kind: "authentication", challenge: "c", userID: nil, displayName: nil, invitationID: nil, expiresAt: past).save(on: db)
        try await AuthChallenge(kind: "authentication", challenge: "d", userID: nil, displayName: nil, invitationID: nil, expiresAt: future).save(on: db)
        try await Invitation(tokenHash: AuthSupport.hash("i1"), createdBy: uid, expiresAt: past).save(on: db)
        try await Invitation(tokenHash: AuthSupport.hash("i2"), createdBy: uid, expiresAt: future).save(on: db)
        try await RecoveryGrant(userID: uid, code: "old", expiresAt: past).save(on: db)
        let activeRecovery = RecoveryGrant(userID: uid, code: "active", expiresAt: past)
        activeRecovery.sessionHash = AuthSupport.hash("rs"); activeRecovery.sessionExpiresAt = future
        try await activeRecovery.save(on: db)
        let client = OAuthClient(name: "C", redirects: ["http://127.0.0.1/cb"]); try await client.save(on: db)
        let grant = OAuthGrant(userID: uid, clientID: try client.requireID(), resource: "r", scopes: [], projects: []); try await grant.save(on: db)
        let old = OAuthSecret(raw: "old-refresh", kind: "refresh", grantID: try grant.requireID(), lifetime: -10 * 86_400); old.consumed = true
        try await old.save(on: db)
        let live = OAuthSecret(raw: "live-access", kind: "access", grantID: try grant.requireID(), lifetime: 900); try await live.save(on: db)
        let device = RunnerDevice(ownerID: uid, label: "Mac", tokenHash: nil, revokedAt: nil); try await device.save(on: db)
        try await RunnerPairing(deviceID: try device.requireID(), codeHash: AuthSupport.hash("p1"), expiresAt: past, usedAt: nil).save(on: db)
        try await RunnerPairing(deviceID: try device.requireID(), codeHash: AuthSupport.hash("p2"), expiresAt: future, usedAt: nil).save(on: db)
        let sql = db as! any SQLDatabase
        try await sql.raw("INSERT INTO identity_rate_limits (id, attempts, expires_at) VALUES ('old', 3, 1)").run()
        try await sql.raw("INSERT INTO identity_rate_limits (id, attempts, expires_at) VALUES ('new', 3, 4000000000)").run()
        return (try expiredSession.requireID(), try liveSession.requireID(), try live.requireID())
    }

    private func assertCleaned(_ t: TestApp, _ ids: (expiredSession: UUID, liveSession: UUID, liveSecret: UUID), file: StaticString = #filePath, line: UInt = #line) async throws {
        let db = t.app.db
        let sessions = try await UserSession.query(on: db).all().compactMap(\.id)
        XCTAssertEqual(sessions, [ids.liveSession], file: file, line: line)
        let challenges = try await AuthChallenge.query(on: db).count()
        XCTAssertEqual(challenges, 1, file: file, line: line)
        let invitations = try await Invitation.query(on: db).count()
        XCTAssertEqual(invitations, 1, file: file, line: line)
        let recoveries = try await RecoveryGrant.query(on: db).all()
        XCTAssertEqual(recoveries.count, 1, file: file, line: line)
        XCTAssertNotNil(recoveries.first?.sessionHash, file: file, line: line)
        let secrets = try await OAuthSecret.query(on: db).all().compactMap(\.id)
        XCTAssertEqual(secrets, [ids.liveSecret], file: file, line: line)
        let pairings = try await RunnerPairing.query(on: db).count()
        XCTAssertEqual(pairings, 1, file: file, line: line)
        let limits = try await (db as! any SQLDatabase).raw("SELECT id FROM identity_rate_limits").all().map { try $0.decode(column: "id", as: String.self) }
        XCTAssertEqual(limits, ["new"], file: file, line: line)
    }

    func testCleanupRemovesOnlyExpiredRowsAndIsIdempotent() async throws {
        let t = try await TestApp.make()
        do {
            let ids = try await seedExpired(t)
            // Within the grace period nothing is removed except finished rate-limit windows.
            let kept = try await ExpiredCleanup(grace: 30 * 86_400).run(on: t.app.db)
            XCTAssertEqual(kept.total, 1)
            XCTAssertEqual(kept.rateLimits, 1)
            let sessionsKept = try await UserSession.query(on: t.app.db).count()
            XCTAssertEqual(sessionsKept, 2)
            // Re-seed the rate limit row removed above, then clean with a small batch size to exercise batching.
            try await (t.app.db as! any SQLDatabase).raw("INSERT INTO identity_rate_limits (id, attempts, expires_at) VALUES ('old', 3, 1)").run()
            let report = try await ExpiredCleanup(grace: 86_400, batchSize: 1).run(on: t.app.db)
            XCTAssertEqual(report.total, 7)
            try await assertCleaned(t, ids)
            let again = try await ExpiredCleanup().run(on: t.app.db)
            XCTAssertEqual(again.total, 0)
            try await assertCleaned(t, ids)
        } catch { await t.shutdown(); throw error }
        await t.shutdown()
    }

    func testCleanupCommandIsRegisteredAndRuns() async throws {
        let t = try await TestApp.make()
        do {
            let ids = try await seedExpired(t)
            XCTAssertNotNil(t.app.asyncCommands.commands["cleanup-expired"])
            let console = Terminal()
            let input = CommandInput(arguments: ["--grace-seconds", "0", "--batch-size", "2"])
            var context = CommandContext(console: console, input: input)
            context.application = t.app
            let signature = try CleanupExpiredCommand.Signature(from: &context.input)
            try await CleanupExpiredCommand().run(using: context, signature: signature)
            let secrets = try await OAuthSecret.query(on: t.app.db).all().compactMap(\.id)
            XCTAssertEqual(secrets, [ids.liveSecret])
        } catch { await t.shutdown(); throw error }
        await t.shutdown()
    }

    /// Two replicas (or schedulers) cleaning at once must neither fail nor remove live rows.
    func testConcurrentCleanupOnTwoReplicas() async throws {
        try XCTSkipUnless(TestApp.useMariaDB, "needs MariaDB (TODO_TEST_MARIADB=1)")
        let a = try await TestApp.make()
        let b = try await a.replica()
        do {
            let ids = try await seedExpired(a)
            for i in 0..<60 {
                let u = try await User.query(on: a.app.db).first()!
                try await UserSession(userID: u.requireID(), tokenHash: AuthSupport.hash("bulk\(i)"), expiresAt: Date().addingTimeInterval(-10 * 86_400)).save(on: a.app.db)
            }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for app in [a, b, a, b] {
                    group.addTask { _ = try await ExpiredCleanup(grace: 86_400, batchSize: 7).run(on: app.app.db) }
                }
                try await group.waitForAll()
            }
            try await assertCleaned(a, ids)
        } catch { await a.shutdown(); await b.shutdown(); throw error }
        await a.shutdown(); await b.shutdown()
    }
}
