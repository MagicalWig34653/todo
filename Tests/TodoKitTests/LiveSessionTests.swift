import Fluent
import Logging
import XCTVapor
@testable import TodoKit

/// Live view per card (ADR 0031): compact agent-reported events, rights, limits, filter, retention.
final class LiveSessionTests: XCTestCase {
    private let scopes = "projects:read tasks:read tasks:write"
    private let secret = "ghp_1234567890abcdefghijklmnopqrstuvwxyzAB"

    private struct Called { let isError: Bool; let text: String; let json: Any? }
    private func call(_ f: OAuthFixture, _ name: String, _ args: [String: Any], _ access: String) async throws -> Called {
        let r = try await f.rpc("tools/call", ["name": name, "arguments": args], access: access)
        let result = try XCTUnwrap(r.body?["result"] as? [String: Any], String(describing: r.body))
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        return Called(isError: result["isError"] as? Bool ?? false, text: text, json: try? JSONSerialization.jsonObject(with: Data(text.utf8)))
    }
    private func obj(_ c: Called) -> [String: Any] { (c.json as? [String: Any]) ?? [:] }

    private func fixture(_ scope: String? = nil, _ run: (OAuthFixture, String) async throws -> Void) async throws {
        let f = try await OAuthFixture.make()
        do { let t = try await f.tokens(scope: scope ?? scopes); try await run(f, t.access) }
        catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }
    private func task(_ f: OAuthFixture, owner: User? = nil, project: Project? = nil) async throws -> TodoTask {
        let t = TodoTask(ownerID: try (owner ?? f.user).requireID(), projectID: try (project ?? f.project).requireID(), title: "Live card")
        try await t.save(on: f.test.app.db); return t
    }
    private func stranger(_ f: OAuthFixture) async throws -> (user: User, session: String) {
        let u = User(displayName: "Stranger", isAdmin: false)
        try await u.save(on: f.test.app.db)
        let s = AuthSupport.randomToken()
        try await UserSession(userID: u.requireID(), tokenHash: AuthSupport.hash(s), expiresAt: Date().addingTimeInterval(3600)).save(on: f.test.app.db)
        return (u, s)
    }
    private func step(_ f: OAuthFixture, _ t: TodoTask, _ text: String, session: String? = nil, _ access: String, extra: [String: Any] = [:]) async throws -> Called {
        var args: [String: Any] = ["taskID": try t.requireID().uuidString, "step": text]
        if let session { args["session"] = session }
        for (k, v) in extra { args[k] = v }
        return try await call(f, "report_session_step", args, access)
    }
    private func event(_ f: OAuthFixture, _ t: TodoTask, _ kind: String, _ text: String, _ access: String, extra: [String: Any] = [:]) async throws -> Called {
        var args: [String: Any] = ["taskID": try t.requireID().uuidString, "kind": kind, "text": text]
        for (k, v) in extra { args[k] = v }
        return try await call(f, "report_session_event", args, access)
    }
    private func live(_ f: OAuthFixture, _ t: TodoTask, _ query: String = "", token: String? = nil) async throws -> (status: HTTPStatus, body: [String: Any]?) {
        let r = try await f.test.json(.GET, "/v1/tasks/\(try t.requireID().uuidString)/live\(query)", token: token ?? f.session)
        return (r.status, r.body)
    }

    // MARK: Registration

    func testToolsAreRegisteredWithExistingScopes() {
        let byName = Dictionary(uniqueKeysWithValues: MCPController.tools.map { ($0.name, $0.scope) })
        XCTAssertEqual(byName["report_session_step"], "tasks:write")
        XCTAssertEqual(byName["report_session_event"], "tasks:write")
        XCTAssertEqual(byName["get_task_live"], "tasks:read")
    }

    // MARK: Ingest and read

    func testStepCreatesSessionAndEventsAndReadsBackOverRESTAndMCP() async throws {
        try await fixture { f, access in
            let t = try await task(f)
            let s1 = try await step(f, t, "Lese die Karte", session: "Mac Studio", access, extra: ["model": "claude-x", "agentName": "Claude Code"])
            XCTAssertFalse(s1.isError, s1.text)
            XCTAssertEqual(obj(s1)["name"] as? String, "Mac Studio")
            XCTAssertEqual(obj(s1)["currentStep"] as? String, "Lese die Karte")
            XCTAssertEqual(obj(s1)["status"] as? String, "active")
            XCTAssertEqual(obj(s1)["model"] as? String, "claude-x")
            let e1 = try await event(f, t, "tool", "swift test --filter LiveSessionTests", access, extra: ["session": "Mac Studio"])
            XCTAssertFalse(e1.isError, e1.text)
            let e2 = try await event(f, t, "question", "Soll der Filter auch Hex maskieren?", access, extra: ["session": "Mac Studio"])
            XCTAssertFalse(e2.isError, e2.text)

            let rest = try await live(f, t)
            XCTAssertEqual(rest.status, .ok)
            let sessions = try XCTUnwrap(rest.body?["sessions"] as? [[String: Any]])
            XCTAssertEqual(sessions.count, 1)
            XCTAssertEqual(sessions[0]["currentStep"] as? String, "Lese die Karte")
            XCTAssertEqual(sessions[0]["actorLabel"] as? String, "Claude Code")
            let items = try XCTUnwrap(rest.body?["items"] as? [[String: Any]])
            // newest first: question, tool, step (the step report writes a step event)
            XCTAssertEqual(items.compactMap { $0["kind"] as? String }, ["question", "tool", "step"])
            let created = try XCTUnwrap(items[0]["createdAt"] as? String)
            XCTAssertNotNil(created.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#, options: .regularExpression), created)

            let viaMCP = try await call(f, "get_task_live", ["taskID": try t.requireID().uuidString], access)
            XCTAssertFalse(viaMCP.isError, viaMCP.text)
            XCTAssertEqual((obj(viaMCP)["items"] as? [[String: Any]])?.count, 3)
        }
    }

    func testRepeatedSameStepIsHeartbeatOnlyAndChangedStepAddsEvent() async throws {
        try await fixture { f, access in
            let t = try await task(f)
            _ = try await step(f, t, "A", access)
            _ = try await step(f, t, "A", access)
            let count1 = try await TaskLiveEvent.query(on: f.test.app.db).count()
            XCTAssertEqual(count1, 1)
            _ = try await step(f, t, "B", access)
            let count2 = try await TaskLiveEvent.query(on: f.test.app.db).count()
            XCTAssertEqual(count2, 2)
            let sessions = try await TaskLiveSession.query(on: f.test.app.db).all()
            XCTAssertEqual(sessions.count, 1, "default session name")
            XCTAssertEqual(sessions[0].currentStep, "B")
        }
    }

    func testExplicitAgentNameSticksAndDefaultsToTheClientName() async throws {
        try await fixture { f, access in
            let t = try await task(f)
            let named = try await step(f, t, "A", session: "named", access, extra: ["agentName": "Claude Code"])
            XCTAssertEqual(obj(named)["actorLabel"] as? String, "Claude Code")
            let later = try await step(f, t, "B", session: "named", access)
            XCTAssertEqual(obj(later)["actorLabel"] as? String, "Claude Code", "a report without agentName must not rename the session")
            let plain = try await step(f, t, "A", session: "plain", access)
            XCTAssertEqual(obj(plain)["actorLabel"] as? String, "Test Client", "default is the OAuth client name")
            let viaEvent = try await event(f, t, "note", "x", access, extra: ["session": "fromEvent"])
            XCTAssertFalse(viaEvent.isError)
            let row = try await TaskLiveSession.query(on: f.test.app.db).filter(\.$name == "fromEvent").first()
            XCTAssertEqual(row?.actorLabel, "Test Client")
        }
    }

    func testCombiningCharacterBombIsRejectedByByteLength() async throws {
        try await fixture { f, access in
            let t = try await task(f)
            let bomb = "a" + String(repeating: "\u{0301}", count: 200_000)
            XCTAssertEqual(bomb.count, 1)
            for tool in ["event", "step"] {
                let r = tool == "event" ? try await event(f, t, "note", bomb, access) : try await step(f, t, bomb, access)
                XCTAssertTrue(r.isError, tool)
            }
            for extra in [["session": bomb], ["model": bomb], ["agentName": bomb]] as [[String: Any]] {
                let r = try await step(f, t, "x", access, extra: extra)
                XCTAssertTrue(r.isError, "\(extra.keys)")
            }
            let n = try await TaskLiveEvent.query(on: f.test.app.db).count()
            XCTAssertEqual(n, 0)
        }
    }

    func testTwoActorsCannotShareOrHijackASession() async throws {
        try await fixture { f, access in
            let t = try await task(f)
            let second = try await f.tokens(scope: scopes).access  // second connection of the same account = other grant
            _ = second
            let a = try await step(f, t, "A arbeitet", access)
            XCTAssertFalse(a.isError)
            // Same account, other grant: build a second actor through the service.
            let other = LiveSessionService(user: f.user, db: f.test.app.db, allowedProjects: nil, actor: .integration(grantID: UUID(), label: "Other"))
            do { _ = try await other.reportStep(t.requireID(), session: nil, step: "B übernimmt", model: nil, ended: true, agentName: "Evil"); XCTFail("expected conflict") }
            catch let e as Abort { XCTAssertEqual(e.status, .conflict); XCTAssertEqual(e.reason, "session_name_taken") }
            do { _ = try await other.reportEvent(t.requireID(), session: nil, kind: "note", text: "x", clientUUID: nil); XCTFail("expected conflict") }
            catch let e as Abort { XCTAssertEqual(e.status, .conflict) }
            let own = try await other.reportStep(t.requireID(), session: "other", step: "B eigene", model: nil, ended: nil, agentName: nil)
            XCTAssertEqual(own.name, "other")
            let rows = try await TaskLiveSession.query(on: f.test.app.db).filter(\.$name == "main").all()
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows[0].currentStep, "A arbeitet"); XCTAssertEqual(rows[0].status, "active"); XCTAssertNotEqual(rows[0].actorLabel, "Evil")
        }
    }

    func testSessionSlotsPerActorAreLimited() async throws {
        try await fixture { f, _ in
            let t = try await task(f)
            let svc = LiveSessionService(user: f.user, db: f.test.app.db, allowedProjects: nil, actor: .integration(grantID: UUID(), label: "T"),
                                         limits: LiveSessionLimits(sessionsPerTask: 10, sessionsPerActorPerTask: 3))
            for i in 0..<3 { _ = try await svc.reportStep(t.requireID(), session: "s\(i)", step: nil, model: nil, ended: nil, agentName: nil) }
            do { _ = try await svc.reportStep(t.requireID(), session: "s3", step: nil, model: nil, ended: nil, agentName: nil); XCTFail("cap") }
            catch let e as Abort { XCTAssertEqual(e.status, .tooManyRequests) }
        }
    }

    func testDoneCardRejectsReportsAndAccountRateLimitApplies() async throws {
        try await fixture { f, access in
            let t = try await task(f)
            let svc = LiveSessionService(user: f.user, db: f.test.app.db, allowedProjects: nil, actor: .integration(grantID: UUID(), label: "T"),
                                         limits: LiveSessionLimits(eventsPerMinutePerSession: 100, eventsPerMinutePerTask: 100, eventsPerMinutePerAccount: 3))
            let t2 = try await task(f)
            _ = try await svc.reportEvent(t.requireID(), session: "a", kind: "note", text: "1", clientUUID: nil)
            _ = try await svc.reportEvent(t.requireID(), session: "a", kind: "note", text: "2", clientUUID: nil)
            _ = try await svc.reportEvent(t2.requireID(), session: "a", kind: "note", text: "3", clientUUID: nil)
            do { _ = try await svc.reportEvent(t2.requireID(), session: "b", kind: "note", text: "4", clientUUID: nil); XCTFail("account limit") }
            catch let e as Abort { XCTAssertEqual(e.status, .tooManyRequests) }
            t.status = "done"; try await t.save(on: f.test.app.db)
            let r = try await event(f, t, "note", "late", access)
            XCTAssertTrue(r.isError); XCTAssertTrue(r.text.contains("task_done"), r.text)
            let s = try await step(f, t, "late", access)
            XCTAssertTrue(s.isError)
            let read = try await live(f, t)
            XCTAssertEqual(read.status, .ok, "reading a done card stays possible")
        }
    }

    func testEndedSessionAndResume() async throws {
        try await fixture { f, access in
            let t = try await task(f)
            _ = try await step(f, t, "Arbeite", access)
            let ended = try await call(f, "report_session_step", ["taskID": try t.requireID().uuidString, "ended": true], access)
            XCTAssertFalse(ended.isError, ended.text)
            XCTAssertEqual(obj(ended)["status"] as? String, "ended")
            XCTAssertNotNil(obj(ended)["endedAt"] as? String)
            let again = try await step(f, t, "Weiter", access)
            XCTAssertEqual(obj(again)["status"] as? String, "active")
            XCTAssertTrue(obj(again)["endedAt"] == nil || obj(again)["endedAt"] is NSNull)
        }
    }

    func testValidation() async throws {
        try await fixture { f, access in
            let t = try await task(f)
            let id = try t.requireID().uuidString
            for args in [["taskID": id, "kind": "bogus", "text": "x"], ["taskID": id, "kind": "step", "text": "x"],
                         ["taskID": id, "kind": "note", "text": "   "],
                         ["taskID": id, "kind": "note", "text": String(repeating: "a", count: 281)],
                         ["taskID": id, "kind": "note", "text": "x", "session": String(repeating: "s", count: 81)],
                         ["taskID": id, "kind": "note", "text": "x", "clientUUID": "nope"]] as [[String: Any]] {
                let r = try await call(f, "report_session_event", args, access)
                XCTAssertTrue(r.isError, "\(args)")
            }
            let longStep = try await call(f, "report_session_step", ["taskID": id, "step": String(repeating: "a", count: 281)], access)
            XCTAssertTrue(longStep.isError)
            let nothing = try await call(f, "report_session_step", ["taskID": id], access)
            XCTAssertFalse(nothing.isError, "heartbeat without a step is allowed")
            let ok = try await event(f, t, "note", String(repeating: "a", count: 280), access)
            XCTAssertFalse(ok.isError, ok.text)
            let count = try await TaskLiveEvent.query(on: f.test.app.db).count()
            XCTAssertEqual(count, 1)
        }
    }

    func testClientUUIDMakesEventsIdempotent() async throws {
        try await fixture { f, access in
            let t = try await task(f)
            let key = UUID().uuidString
            let first = try await event(f, t, "note", "einmal", access, extra: ["clientUUID": key])
            let again = try await event(f, t, "note", "einmal", access, extra: ["clientUUID": key])
            XCTAssertFalse(first.isError); XCTAssertFalse(again.isError)
            XCTAssertEqual(obj(first)["id"] as? String, obj(again)["id"] as? String)
            let clash = try await event(f, t, "note", "anders", access, extra: ["clientUUID": key])
            XCTAssertTrue(clash.isError)
            XCTAssertTrue(clash.text.contains("client_uuid_conflict"), clash.text)
            let count = try await TaskLiveEvent.query(on: f.test.app.db).count()
            XCTAssertEqual(count, 1)
        }
    }

    // MARK: Filter on write

    func testSecretIsFilteredBeforeStorageAndInEveryReadPath() async throws {
        try await fixture { f, access in
            let t = try await task(f)
            let e = try await event(f, t, "tool", "git push https://x:\(secret)@host/r.git, password=hunter2", access)
            XCTAssertFalse(e.isError, e.text)
            XCTAssertFalse(e.text.contains(secret)); XCTAssertFalse(e.text.contains("hunter2"))
            let s = try await step(f, t, "token=\(secret)", access)
            XCTAssertFalse(s.text.contains(secret))
            for row in try await TaskLiveEvent.query(on: f.test.app.db).all() {
                XCTAssertFalse(row.text.contains(secret)); XCTAssertFalse(row.text.contains("hunter2")); XCTAssertTrue(row.text.contains(SecretFilter.mask))
            }
            for row in try await TaskLiveSession.query(on: f.test.app.db).all() { XCTAssertFalse((row.currentStep ?? "").contains(secret)) }
            let r = try await live(f, t)
            XCTAssertFalse(String(describing: r.body).contains(secret))
            XCTAssertTrue(String(describing: r.body).contains(SecretFilter.mask))
            let m = try await call(f, "get_task_live", ["taskID": try t.requireID().uuidString], access)
            XCTAssertFalse(m.text.contains(secret))
        }
    }

    func testFilteredTextNeverReachesLogsOrErrors() async throws {
        try await fixture { f, access in
            let sink = LogSink()
            f.test.app.logger = Logger(label: "live-test") { _ in SinkHandler(sink) }
            f.test.app.logger.logLevel = .trace
            let t = try await task(f)
            _ = try await event(f, t, "note", "password=hunter2 \(secret)", access)
            _ = try await event(f, t, "note", "ungültig \(secret)", access, extra: ["kind": "bogus"])
            _ = try await event(f, t, "note", "\(secret) " + String(repeating: "x", count: 300), access)
            let other = try await call(f, "report_session_event", ["taskID": UUID().uuidString, "kind": "note", "text": secret], access)
            XCTAssertTrue(other.isError)
            XCTAssertFalse(other.text.contains(secret))
            let logged = sink.joined()
            XCTAssertFalse(logged.isEmpty, "the capture must see request logs, otherwise this test proves nothing")
            XCTAssertFalse(logged.contains(secret)); XCTAssertFalse(logged.contains("hunter2"))
        }
    }

    // MARK: Rights

    func testStrangerAndOutsideGrantGet404AndWriteNeedsScopeAndRole() async throws {
        try await fixture { f, access in
            let other = try await stranger(f)
            let mine = try await task(f)
            _ = try await step(f, mine, "privat", access)
            let denied = try await live(f, mine, token: other.session)
            XCTAssertEqual(denied.status, .notFound)
            let anon = try await f.test.json(.GET, "/v1/tasks/\(try mine.requireID().uuidString)/live")
            XCTAssertEqual(anon.status, .unauthorized)
            let missing = try await f.test.json(.GET, "/v1/tasks/\(UUID().uuidString)/live", token: f.session)
            XCTAssertEqual(missing.status, .notFound)

            // A task of another account that the connection never got access to.
            let foreignProject = Project(ownerID: try other.user.requireID(), parentID: nil, name: "Foreign")
            try await foreignProject.save(on: f.test.app.db)
            let foreign = try await task(f, owner: other.user, project: foreignProject)
            let w = try await step(f, foreign, "hack", access)
            XCTAssertTrue(w.isError); XCTAssertTrue(w.text.contains("not_found") || w.text.lowercased().contains("not found"), w.text)
            let r = try await call(f, "get_task_live", ["taskID": try foreign.requireID().uuidString], access)
            XCTAssertTrue(r.isError)
            // Outside the grant: own project that the connection did not get.
            let excluded = try await task(f, project: f.other)
            let o = try await step(f, excluded, "x", access)
            XCTAssertTrue(o.isError)
            let oRead = try await call(f, "get_task_live", ["taskID": try excluded.requireID().uuidString], access)
            XCTAssertTrue(oRead.isError)
            let count = try await TaskLiveSession.query(on: f.test.app.db).filter(\.$taskID ~~ [try foreign.requireID(), try excluded.requireID()]).count()
            XCTAssertEqual(count, 0)

            // A read-only connection can neither see nor call the write tools.
            let readOnly = try await f.tokens(scope: "projects:read tasks:read")
            let tools = try await f.rpc("tools/list", access: readOnly.access)
            let names = ((tools.body?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            XCTAssertTrue(names.contains("get_task_live"))
            XCTAssertFalse(names.contains("report_session_step")); XCTAssertFalse(names.contains("report_session_event"))
            let blocked = try await f.rpc("tools/call", ["name": "report_session_step", "arguments": ["taskID": try mine.requireID().uuidString, "step": "x"]], access: readOnly.access)
            let blockedText = ((blocked.body?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String
            XCTAssertEqual(blocked.status, .ok)
            XCTAssertEqual(blockedText, "insufficient_scope")
            let none = try await TaskLiveEvent.query(on: f.test.app.db).filter(\.$taskID == mine.requireID()).count()
            XCTAssertEqual(none, 1, "only the step event of the first report exists")
        }
    }

    func testReadRoleMemberReadsButCannotReport() async throws {
        try await fixture { f, access in
            let other = try await stranger(f)
            let p = Project(ownerID: try other.user.requireID(), parentID: nil, name: "Shared")
            try await p.save(on: f.test.app.db)
            try await ProjectGrant(projectID: try p.requireID(), principalType: "person", principalID: try f.user.requireID(), role: .read).save(on: f.test.app.db)
            let g = try await XCTUnwrapAsync(try await OAuthGrant.query(on: f.test.app.db).first())
            g.projects.append(try p.requireID()); try await g.save(on: f.test.app.db)
            let t = try await task(f, owner: other.user, project: p)
            let w = try await step(f, t, "nope", access)
            XCTAssertTrue(w.isError, "read role must not report")
            // The owner reports (session of the owner is not an MCP grant): seed directly, then the reader sees it.
            let s = TaskLiveSession(); s.taskID = try t.requireID(); s.userID = try other.user.requireID(); s.name = "main"
            s.actorType = "integration"; s.actorID = UUID(); s.status = "active"; s.startedAt = Date(); s.lastSeenAt = Date()
            try await s.save(on: f.test.app.db)
            let r = try await live(f, t)
            XCTAssertEqual(r.status, .ok)
            XCTAssertEqual((r.body?["sessions"] as? [Any])?.count, 1)
            let viaMCP = try await call(f, "get_task_live", ["taskID": try t.requireID().uuidString], access)
            XCTAssertFalse(viaMCP.isError, viaMCP.text)
        }
    }

    // MARK: Limits

    func testRateLimitPerSessionAndTaskCap() async throws {
        try await fixture { f, access in
            let t = try await task(f)
            let user = f.user
            let service = LiveSessionService(user: user, db: f.test.app.db, allowedProjects: nil,
                                             actor: .integration(grantID: UUID(), label: "T"),
                                             limits: LiveSessionLimits(eventsPerMinutePerSession: 3, eventsPerMinutePerTask: 5, eventsPerTask: 100, sessionsPerTask: 2))
            let id = try t.requireID()
            for i in 0..<3 { _ = try await service.reportEvent(id, session: "a", kind: "note", text: "n\(i)", clientUUID: nil) }
            do { _ = try await service.reportEvent(id, session: "a", kind: "note", text: "n3", clientUUID: nil); XCTFail("rate limit expected") }
            catch let e as Abort { XCTAssertEqual(e.status, .tooManyRequests); XCTAssertEqual(e.reason, "rate_limited") }
            // Another session still has budget, until the card-wide rate limit hits (5 per minute).
            _ = try await service.reportEvent(id, session: "b", kind: "note", text: "b0", clientUUID: nil)
            _ = try await service.reportEvent(id, session: "b", kind: "note", text: "b1", clientUUID: nil)
            do { _ = try await service.reportEvent(id, session: "b", kind: "note", text: "b2", clientUUID: nil); XCTFail("task rate limit expected") }
            catch let e as Abort { XCTAssertEqual(e.status, .tooManyRequests) }
            let left = try await TaskLiveEvent.query(on: f.test.app.db).filter(\.$taskID == id).count()
            XCTAssertEqual(left, 5)
            // Session cap.
            do { _ = try await service.reportStep(id, session: "c", step: "x", model: nil, ended: nil, agentName: nil); XCTFail("session cap expected") }
            catch let e as Abort { XCTAssertEqual(e.status, .tooManyRequests); XCTAssertEqual(e.reason, "too_many_sessions") }
        }
    }

    func testEventsPerTaskAreCappedToTheNewest() async throws {
        try await fixture { f, _ in
            let t = try await task(f)
            let service = LiveSessionService(user: f.user, db: f.test.app.db, allowedProjects: nil, actor: .integration(grantID: UUID(), label: "T"),
                                             limits: LiveSessionLimits(eventsPerMinutePerSession: 100, eventsPerMinutePerTask: 100, eventsPerTask: 4, sessionsPerTask: 2))
            let id = try t.requireID()
            for i in 0..<9 { _ = try await service.reportEvent(id, session: "a", kind: "note", text: "n\(i)", clientUUID: nil) }
            let events = try await TaskLiveEvent.query(on: f.test.app.db).filter(\.$taskID == id).sort(\.$createdAt).sort(\.$id).all()
            XCTAssertEqual(events.map(\.text), ["n5", "n6", "n7", "n8"])
        }
    }

    func testReadPaginationAndSince() async throws {
        try await fixture { f, access in
            let t = try await task(f)
            for i in 0..<7 { _ = try await event(f, t, "note", "e\(i)", access) }
            var seen: [String] = []
            var cursor: String?
            var pages = 0
            repeat {
                let r = try await live(f, t, "?limit=3" + (cursor.map { "&cursor=\($0)" } ?? ""))
                XCTAssertEqual(r.status, .ok)
                seen += (r.body?["items"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
                cursor = r.body?["nextCursor"] as? String
                pages += 1
            } while cursor != nil && pages < 10
            XCTAssertEqual(pages, 3)
            XCTAssertEqual(seen, (0..<7).reversed().map { "e\($0)" })
            let future = ISO8601DateFormatter().string(from: Date().addingTimeInterval(60))
            let none = try await live(f, t, "?since=\(future)")
            XCTAssertEqual((none.body?["items"] as? [Any])?.count, 0)
            for bad in ["limit=0", "limit=201", "limit=x", "cursor=garbage", "since=yesterday"] {
                let r = try await live(f, t, "?\(bad)")
                XCTAssertEqual(r.status, .badRequest, bad)
            }
        }
    }

    // MARK: Live refresh

    func testEventChangesTheLiveToken() async throws {
        try await fixture { f, access in
            let t = try await task(f)
            let before = try await LiveToken.current(on: f.test.app.db).token
            _ = try await event(f, t, "note", "hallo", access)
            let after = try await LiveToken.current(on: f.test.app.db).token
            XCTAssertNotEqual(before, after)
            // Hints for MCP wait_for_events stay free of the agent's own live reports.
            let hints = try await LiveToken.taskHints(after: LiveToken.maxEventID(of: before) ?? 0, on: f.test.app.db)
            XCTAssertFalse(hints.contains { $0.kind == TaskLiveEvent.schema || $0.kind == TaskLiveSession.schema })
        }
    }

    // MARK: Retention (3 days after done) and cascades

    private func seed(_ f: OAuthFixture, _ access: String, _ t: TodoTask) async throws {
        _ = try await step(f, t, "arbeite", access); _ = try await event(f, t, "note", "n", access)
    }
    private func backdate(_ f: OAuthFixture, _ t: TodoTask, days: Double) async throws {
        try await TodoTask.query(on: f.test.app.db).filter(\.$id == t.requireID())
            .set(\.$updatedAt, to: Date().addingTimeInterval(-days * 86_400)).update()
    }
    private func tasksWithSessions(_ f: OAuthFixture) async throws -> Set<UUID> {
        Set(try await TaskLiveSession.query(on: f.test.app.db).all().map(\.taskID))
    }

    func testRetentionDeletesThreeDaysAfterDoneAndReopenKeeps() async throws {
        try await fixture { f, access in
            let db = f.test.app.db
            let doneOld = try await task(f), doneFresh = try await task(f), stillOpen = try await task(f), reopened = try await task(f), again = try await task(f)
            for t in [doneOld, doneFresh, stillOpen, reopened, again] { try await seed(f, access, t) }
            for t in [doneOld, doneFresh, reopened, again] { t.status = "done"; try await t.save(on: db) }
            try await backdate(f, doneOld, days: 4); try await backdate(f, reopened, days: 4); try await backdate(f, again, days: 4)
            try await backdate(f, stillOpen, days: 30)
            // "reopened": back to open; "again": reopened and finished once more (extends the period).
            reopened.status = "open"; try await reopened.save(on: db)
            try await backdate(f, reopened, days: 4)
            again.status = "open"; try await again.save(on: db)
            again.status = "done"; try await again.save(on: db)

            let cleanup = ExpiredCleanup()
            let report = try await cleanup.run(on: db)
            XCTAssertEqual(report.liveSessions, 1, "\(report)")
            let left = try await tasksWithSessions(f)
            XCTAssertEqual(left, Set([doneFresh, stillOpen, reopened, again].map { $0.id! }))
            let events = try await TaskLiveEvent.query(on: db).all().map(\.taskID)
            XCTAssertFalse(events.contains(doneOld.id!))
            XCTAssertEqual(Set(events), left, "events of removed sessions are gone, the others stay")

            // Time shift instead of waiting: 3 days later the freshly finished cards go as well, the open ones never.
            let later = try await cleanup.run(on: db, now: Date().addingTimeInterval(3 * 86_400 + 120))
            XCTAssertEqual(later.liveSessions, 2, "\(later)")
            let remaining = try await tasksWithSessions(f)
            XCTAssertEqual(remaining, Set([stillOpen, reopened].map { $0.id! }))
            let third = try await cleanup.run(on: db, now: Date().addingTimeInterval(3 * 86_400 + 120))
            XCTAssertEqual(third.liveSessions, 0)
        }
    }

    func testRetentionBoundaryIsExactlyThreeDays() async throws {
        try await fixture { f, access in
            let db = f.test.app.db
            let t = try await task(f); try await seed(f, access, t)
            t.status = "done"; try await t.save(on: db)
            let reread = try await TodoTask.find(t.requireID(), on: db)
            let done = try XCTUnwrap(reread?.updatedAt)
            let cleanup = ExpiredCleanup()
            let before = try await cleanup.run(on: db, now: done.addingTimeInterval(3 * 86_400 - 60))
            XCTAssertEqual(before.liveSessions, 0)
            let after = try await cleanup.run(on: db, now: done.addingTimeInterval(3 * 86_400 + 60))
            XCTAssertEqual(after.liveSessions, 1)
        }
    }

    func testDeletingTaskProjectAndAccountDoesNotBlock() async throws {
        try await fixture { f, access in
            let db = f.test.app.db
            let viaTask = try await task(f)
            let p = Project(ownerID: try f.user.requireID(), parentID: nil, name: "Gone"); try await p.save(on: db)
            let g = try await XCTUnwrapAsync(try await OAuthGrant.query(on: db).first())
            g.projects.append(try p.requireID()); try await g.save(on: db)
            let viaProject = try await task(f, project: p)
            try await seed(f, access, viaTask); try await seed(f, access, viaProject)
            try await viaTask.delete(on: db)
            let afterTask = try await tasksWithSessions(f)
            XCTAssertEqual(afterTask, [viaProject.id!])
            try await TodoTask.query(on: db).filter(\.$projectID == p.requireID()).delete()
            try await p.delete(on: db)
            let sessions = try await TaskLiveSession.query(on: db).count()
            let events = try await TaskLiveEvent.query(on: db).count()
            XCTAssertEqual(sessions, 0); XCTAssertEqual(events, 0)
        }
    }

    func testDeletingTheReportingAccountRemovesItsSessions() async throws {
        try await fixture { f, _ in
            let db = f.test.app.db
            let other = try await stranger(f)
            let t = try await task(f)
            let s = TaskLiveSession(); s.taskID = try t.requireID(); s.userID = try other.user.requireID(); s.name = "main"
            s.actorType = "integration"; s.actorID = UUID(); s.status = "active"; s.startedAt = Date(); s.lastSeenAt = Date()
            try await s.save(on: db)
            let e = TaskLiveEvent(); e.taskID = try t.requireID(); e.sessionID = try s.requireID(); e.kind = "note"; e.text = "x"; e.createdAt = Date()
            try await e.save(on: db)
            // Account deletion with the card kept alive elsewhere: the reporter's sessions go with the account.
            try await UserSession.query(on: db).filter(\.$user.$id == other.user.requireID()).delete()
            try await other.user.delete(on: db)
            let sessions = try await TaskLiveSession.query(on: db).count()
            let events = try await TaskLiveEvent.query(on: db).count()
            XCTAssertEqual(sessions, 0); XCTAssertEqual(events, 0)
        }
    }
}

// MARK: Log capture

private final class LogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
    func joined() -> String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
}

private struct SinkHandler: LogHandler {
    let sink: LogSink
    init(_ sink: LogSink) { self.sink = sink }
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace
    subscript(metadataKey key: String) -> Logger.Metadata.Value? { get { metadata[key] } set { metadata[key] = newValue } }
    func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, source: String, file: String, function: String, line: UInt) {
        sink.add("\(message) \(metadata ?? [:]) \(self.metadata)")
    }
}
