import Fluent
import XCTVapor
@testable import TodoKit

/// ADR 0033 stage C: per-card auto start permission, account switch, revocation, release idempotency and the scheduler origin.
final class AutoStartTests: XCTestCase {
    private let iso = ISO8601DateFormatter()

    struct Env {
        let f: OAuthFixture
        let agent: String
        let bobID: UUID
        let bob: String
        let task: UUID
        let device: RunnerDevice
        let binding: ProjectRunnerBinding
        var db: any Database { f.test.app.db }
    }

    private func env(planned: Date? = Date().addingTimeInterval(3600), bind: Bool = true) async throws -> Env {
        let f = try await OAuthFixture.make()
        let agent = try await f.tokens(scope: "projects:read tasks:read tasks:write runs:read runs:write").access
        let bobUser = User(displayName: "Bob", isAdmin: false); try await bobUser.save(on: f.test.app.db)
        let bob = AuthSupport.randomToken()
        try await UserSession(userID: bobUser.requireID(), tokenHash: AuthSupport.hash(bob), expiresAt: Date().addingTimeInterval(3600)).save(on: f.test.app.db)
        let grant = try await f.test.json(.PUT, "/v1/projects/\(try f.project.requireID())/grants",
            ["principalType": "person", "principalID": try bobUser.requireID().uuidString, "role": "edit"], token: f.session)
        XCTAssertEqual(grant.status, .ok)
        let task = TodoTask(ownerID: try f.user.requireID(), projectID: try f.project.requireID(), title: "Nightly", details: "body")
        try await task.save(on: f.test.app.db)
        if let planned {
            let p = TaskPlanning(taskID: try task.requireID()); p.plannedAt = Date(timeIntervalSince1970: planned.timeIntervalSince1970.rounded(.down)); p.plannedMinutes = 30
            try await p.save(on: f.test.app.db)
        }
        let device = RunnerDevice(ownerID: try f.user.requireID(), label: "Mac", tokenHash: "hash-\(UUID().uuidString)", revokedAt: nil)
        try await device.save(on: f.test.app.db)
        let binding = ProjectRunnerBinding(projectID: try f.project.requireID(), deviceID: try device.requireID(), repositoryKey: "repo-\(UUID().uuidString)", label: "repo")
        if bind { try await binding.save(on: f.test.app.db) }
        return Env(f: f, agent: agent, bobID: try bobUser.requireID(), bob: bob, task: try task.requireID(), device: device, binding: binding)
    }

    private func run(planned: Date? = Date().addingTimeInterval(3600), bind: Bool = true, _ body: (Env) async throws -> Void) async throws {
        let e = try await env(planned: planned, bind: bind)
        do { try await body(e) } catch { await e.f.test.shutdown(); throw error }
        await e.f.test.shutdown()
    }

    private func version(_ e: Env) async throws -> Int { try await XCTUnwrapAsync(try await TodoTask.find(e.task, on: e.db)).version }
    private func planning(_ e: Env) async throws -> TaskPlanning { try await XCTUnwrapAsync(try await TaskPlanning.find(e.task, on: e.db)) }

    @discardableResult
    private func enable(_ e: Env, _ on: Bool = true, token: String? = nil, extra: [String: Any] = [:]) async throws -> (status: HTTPStatus, body: [String: Any]?) {
        var body: [String: Any] = ["version": try await version(e), "enabled": on]
        for (k, v) in extra { body[k] = v }
        let r = try await e.f.test.json(.PUT, "/v1/tasks/\(e.task)/auto-start", body, token: token ?? e.f.session)
        return (r.status, r.body)
    }

    private func allowAccount(_ e: Env, _ on: Bool = true) async throws {
        let r = try await e.f.test.json(.PUT, "/v1/settings/auto-start", ["allowed": on], token: e.f.session)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
    }

    private func kinds(_ e: Env) async throws -> [String] {
        try await ActivityEvent.query(on: e.db).filter(\.$taskID == e.task).sort(\.$sequence).all().map(\.kind)
    }

    private func call(_ e: Env, _ name: String, _ args: [String: Any]) async throws -> (isError: Bool, text: String, json: [String: Any]?) {
        let r = try await e.f.rpc("tools/call", ["name": name, "arguments": args], access: e.agent)
        let result = try XCTUnwrap(r.body?["result"] as? [String: Any], "\(r.body ?? [:])")
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        return (result["isError"] as? Bool ?? false, text, (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any])
    }

    // MARK: enable / disable

    func testEnableNeedsOwnerSessionAndPreconditions() async throws {
        try await run { e in
            // OAuth and runner tokens are rejected with 403, a person without ownership too.
            let viaOAuth = try await enable(e, token: e.agent)
            XCTAssertEqual(viaOAuth.status, .forbidden)
            XCTAssertEqual(viaOAuth.body?["reason"] as? String, "session_required")
            let viaBob = try await enable(e, token: e.bob)
            XCTAssertEqual(viaBob.status, .forbidden)
            let anonymous = try await e.f.test.json(.PUT, "/v1/tasks/\(e.task)/auto-start", ["version": 1, "enabled": true])
            XCTAssertEqual(anonymous.status, .unauthorized)
            let v1 = try await planning(e).autoStart
            XCTAssertFalse(v1)

            let stale = try await e.f.test.json(.PUT, "/v1/tasks/\(e.task)/auto-start", ["version": 99, "enabled": true], token: e.f.session)
            XCTAssertEqual(stale.status, .conflict)
            XCTAssertEqual(stale.body?["reason"] as? String, "version_conflict")

            let ok = try await enable(e)
            XCTAssertEqual(ok.status, .ok, "\(ok.body ?? [:])")
            XCTAssertEqual(ok.body?["autoStart"] as? Bool, true)
            let v2 = try await planning(e).autoStart
            XCTAssertTrue(v2)
            let v3 = try await kinds(e).filter { $0 == "agent.auto_start_enabled" }.count
            XCTAssertEqual(v3, 1)
            // Enabling does not touch the job relevant fields; the version moves so clients refresh.
            let v4 = try await version(e)
            XCTAssertEqual(v4, 2)
        }
    }

    func testEnablePreconditionFailures() async throws {
        try await run(planned: nil) { e in
            let noStart = try await enable(e)
            XCTAssertEqual(noStart.status, .conflict)
            XCTAssertEqual(noStart.body?["reason"] as? String, "planned_start_required")
        }
        try await run { e in
            let p = try await planning(e); p.plannedAllDay = true; try await p.save(on: e.db)
            let allDay = try await enable(e)
            XCTAssertEqual(allDay.status, .conflict)
            XCTAssertEqual(allDay.body?["reason"] as? String, "all_day_not_allowed")
        }
        try await run { e in
            let t = try await XCTUnwrapAsync(try await TodoTask.find(e.task, on: e.db)); t.status = "done"; try await t.save(on: e.db)
            let done = try await enable(e)
            XCTAssertEqual(done.status, .conflict)
            XCTAssertEqual(done.body?["reason"] as? String, "task_done")
        }
        try await run(bind: false) { e in
            let none = try await enable(e)
            XCTAssertEqual(none.status, .conflict)
            XCTAssertEqual(none.body?["reason"] as? String, "no_binding")
        }
        try await run { e in
            // A second device bound to the same project makes the choice ambiguous until a device is named.
            let other = RunnerDevice(ownerID: try e.f.user.requireID(), label: "Mac 2", tokenHash: "hash2", revokedAt: nil); try await other.save(on: e.db)
            try await ProjectRunnerBinding(projectID: try e.f.project.requireID(), deviceID: try other.requireID(), repositoryKey: "second", label: "r2").save(on: e.db)
            let ambiguous = try await enable(e)
            XCTAssertEqual(ambiguous.status, .conflict)
            XCTAssertEqual(ambiguous.body?["reason"] as? String, "device_required")
            let chosen = try await enable(e, extra: ["deviceID": try e.device.requireID().uuidString])
            XCTAssertEqual(chosen.status, .ok, "\(chosen.body ?? [:])")
            let unknown = try await enable(e, extra: ["deviceID": UUID().uuidString])
            XCTAssertEqual(unknown.status, .conflict)
        }
    }

    func testDisableIsIdempotentAndAudited() async throws {
        try await run { e in
            try await enable(e)
            let off = try await enable(e, false)
            XCTAssertEqual(off.status, .ok)
            XCTAssertEqual(off.body?["autoStart"] as? Bool, false)
            let v5 = try await planning(e).autoStart
            XCTAssertFalse(v5)
            let again = try await enable(e, false)
            XCTAssertEqual(again.status, .ok)
            let v6 = try await kinds(e).filter { $0 == "agent.auto_start_disabled" }.count
            XCTAssertEqual(v6, 1)
            // Switching off is a right of the owner only.
            try await enable(e)
            let bobOff = try await enable(e, false, token: e.bob)
            XCTAssertEqual(bobOff.status, .forbidden)
            let v7 = try await planning(e).autoStart
            XCTAssertTrue(v7)
        }
    }

    func testScheduleWindowShowsRealAutoStartValues() async throws {
        try await run { e in
            try await enable(e)
            let from = iso.string(from: Date()), to = iso.string(from: Date().addingTimeInterval(7200))
            let r = try await e.f.test.json(.GET, "/v1/planning/schedule?from=\(from)&to=\(to)", token: e.f.session)
            let item = try XCTUnwrap((r.body?["items"] as? [[String: Any]])?.first)
            XCTAssertEqual(item["autoStart"] as? Bool, true)
            XCTAssertNil(item["autoStartedAt"] as? String)
            let p = try await planning(e); p.autoStart = false; p.autoStartedAt = Date(); try await p.save(on: e.db)
            let after = try await e.f.test.json(.GET, "/v1/planning/schedule?from=\(from)&to=\(to)", token: e.f.session)
            let started = try XCTUnwrap((after.body?["items"] as? [[String: Any]])?.first)
            XCTAssertEqual(started["autoStart"] as? Bool, false)
            XCTAssertNotNil(started["autoStartedAt"] as? String)
        }
    }

    // MARK: account switch and system status

    func testAccountSwitchDefaultsOffIsSessionOnlyAndShownInSystemStatus() async throws {
        try await run { e in
            let get = try await e.f.test.json(.GET, "/v1/settings/auto-start", token: e.f.session)
            XCTAssertEqual(get.body?["allowed"] as? Bool, false)
            let status = try await e.f.test.json(.GET, "/v1/system-status", token: e.f.session)
            XCTAssertEqual(status.body?["autoStartAllowed"] as? Bool, false)
            let viaOAuth = try await e.f.test.json(.PUT, "/v1/settings/auto-start", ["allowed": true], token: e.agent)
            XCTAssertEqual(viaOAuth.status, .forbidden)
            let bad = try await e.f.test.json(.PUT, "/v1/settings/auto-start", ["allowed": "yes"], token: e.f.session)
            XCTAssertEqual(bad.status, .badRequest)
            try await allowAccount(e)
            let on = try await e.f.test.json(.GET, "/v1/system-status", token: e.f.session)
            XCTAssertEqual(on.body?["autoStartAllowed"] as? Bool, true)
            // The switch belongs to the account: another person's switch stays off.
            let bobs = try await e.f.test.json(.GET, "/v1/settings/auto-start", token: e.bob)
            XCTAssertEqual(bobs.body?["allowed"] as? Bool, false)
            try await allowAccount(e, false)
            let v8 = try await e.f.test.json(.GET, "/v1/settings/auto-start", token: e.f.session).body?["allowed"] as? Bool
            XCTAssertEqual(v8, false)
        }
    }

    func testSystemStatusValidatesPerformanceFields() async throws {
        try await run { e in
            let ok = try await e.f.test.json(.PUT, "/v1/system-status", ["leistung_ampel": "gruen", "leistung_last_pct": 42.5, "x_unknown": 1], token: e.f.session)
            XCTAssertEqual(ok.status, .ok, "\(ok.body ?? [:])")
            let kept = (ok.body?["status"] as? [String: Any])
            XCTAssertEqual(kept?["leistung_ampel"] as? String, "gruen")
            XCTAssertEqual(kept?["x_unknown"] as? Int, 1)
            let bad = try await e.f.test.json(.PUT, "/v1/system-status", ["leistung_ampel": "blau"], token: e.f.session)
            XCTAssertEqual(bad.status, .badRequest)
            XCTAssertEqual(bad.body?["reason"] as? String, "invalid_leistung_ampel")
            let badPct = try await e.f.test.json(.PUT, "/v1/system-status", ["leistung_last_pct": "hoch"], token: e.f.session)
            XCTAssertEqual(badPct.body?["reason"] as? String, "invalid_leistung_last_pct")
        }
    }

    // MARK: revocation

    private func edit(_ e: Env, _ fields: [String: Any], token: String) async throws -> HTTPStatus {
        var body = fields; body["version"] = try await version(e)
        return try await e.f.test.json(.PATCH, "/v1/tasks/\(e.task)", body, token: token).status
    }

    func testForeignEditsRevokeAutoStart() async throws {
        let attempts: [(String, (Env) async throws -> HTTPStatus)] = [
            ("title", { try await self.edit($0, ["title": "Changed"], token: $0.bob) }),
            ("description", { try await self.edit($0, ["description": "Other text"], token: $0.bob) }),
            ("plannedAt", { e in
                try await e.f.test.json(.PATCH, "/v1/tasks/\(e.task)/schedule", ["version": try await self.version(e), "plannedAt": self.iso.string(from: Date().addingTimeInterval(9000))], token: e.bob).status }),
            ("plannedMinutes", { e in
                try await e.f.test.json(.PATCH, "/v1/tasks/\(e.task)/schedule", ["version": try await self.version(e), "plannedMinutes": 90], token: e.bob).status }),
            ("planning put", { e in
                try await e.f.test.json(.PUT, "/v1/planning/tasks/\(e.task)", ["plannedAt": self.iso.string(from: (try await self.planning(e)).plannedAt!), "plannedMinutes": 45, "priority": 0, "reminders": [String]()], token: e.bob).status }),
        ]
        for (name, act) in attempts {
            try await run { e in
                try await enable(e)
                let v9 = try await act(e)
                XCTAssertEqual(v9, .ok, name)
                let v10 = try await planning(e).autoStart
                XCTAssertFalse(v10, name)
                let v11 = try await kinds(e).contains("agent.auto_start_revoked")
                XCTAssertTrue(v11, name)
            }
        }
    }

    func testOwnerContentAndStartChangesRevokeButDurationKeeps() async throws {
        try await run { e in
            try await enable(e)
            // The owner may change the duration without losing the permission.
            let minutes = try await e.f.test.json(.PATCH, "/v1/tasks/\(e.task)/schedule", ["version": try await version(e), "plannedMinutes": 60], token: e.f.session)
            XCTAssertEqual(minutes.status, .ok)
            let v12 = try await planning(e).autoStart
            XCTAssertTrue(v12)
            // A write that changes nothing relevant keeps it, too.
            let same = try await e.f.test.json(.PUT, "/v1/planning/tasks/\(e.task)", ["plannedAt": iso.string(from: try await planning(e).plannedAt!), "plannedMinutes": 60, "priority": 2, "reminders": [String]()], token: e.f.session)
            XCTAssertEqual(same.status, .ok)
            let v13 = try await planning(e).autoStart
            XCTAssertTrue(v13)
            // Title change by the owner revokes.
            let v14 = try await edit(e, ["title": "Renamed"], token: e.f.session)
            XCTAssertEqual(v14, .ok)
            let v15 = try await planning(e).autoStart
            XCTAssertFalse(v15)
        }
        try await run { e in
            try await enable(e)
            let moved = try await e.f.test.json(.PATCH, "/v1/tasks/\(e.task)/schedule", ["version": try await version(e), "plannedAt": iso.string(from: Date().addingTimeInterval(7200))], token: e.f.session)
            XCTAssertEqual(moved.status, .ok)
            let v16 = try await planning(e).autoStart
            XCTAssertFalse(v16, "moving the start by the owner revokes")
        }
        try await run { e in
            try await enable(e)
            let v17 = try await edit(e, ["description": "New"], token: e.f.session)
            XCTAssertEqual(v17, .ok)
            let v18 = try await planning(e).autoStart
            XCTAssertFalse(v18)
        }
    }

    func testAgentWritesRevokeAutoStart() async throws {
        try await run { e in
            try await enable(e)
            // Even a duration change through MCP revokes: the connection is not the owner acting.
            let r = try await call(e, "update_task_planning", ["taskID": e.task.uuidString, "plannedMinutes": 15])
            XCTAssertFalse(r.isError, r.text)
            let v19 = try await planning(e).autoStart
            XCTAssertFalse(v19)
            let v20 = try await kinds(e).contains("agent.auto_start_revoked")
            XCTAssertTrue(v20)
        }
        try await run { e in
            try await enable(e)
            let r = try await call(e, "update_task", ["id": e.task.uuidString, "version": try await version(e), "title": "Agent edit"])
            XCTAssertFalse(r.isError, r.text)
            let v21 = try await planning(e).autoStart
            XCTAssertFalse(v21)
            let revoked = try await ActivityEvent.query(on: e.db).filter(\.$taskID == e.task).filter(\.$kind == "agent.auto_start_revoked").first()
            XCTAssertEqual(revoked?.actorType, .integration)
        }
        try await run { e in
            try await enable(e)
            let r = try await call(e, "update_task_planning", ["taskID": e.task.uuidString, "autoStart": true])
            XCTAssertTrue(r.isError)
        }
    }

    func testSyncTaskUpdateRevokes() async throws {
        try await run { e in
            try await enable(e)
            let r = try await e.f.test.json(.POST, "/v1/sync/mutations", ["mutationID": UUID().uuidString, "type": "task.update", "id": e.task.uuidString,
                "version": try await version(e), "title": "Via sync"], token: e.bob)
            XCTAssertTrue((200..<300).contains(Int(r.status.code)), "\(r.status) \(r.body ?? [:])")
            let v22 = try await planning(e).autoStart
            XCTAssertFalse(v22)
        }
    }

    func testRecurringSuccessorDoesNotInheritAutoStart() async throws {
        try await run { e in
            let p = try await planning(e)
            p.recurrence = RecurrenceRule(frequency: "daily", interval: 1, timeZone: "UTC", until: nil); try await p.save(on: e.db)
            try await enable(e)
            let v23 = try await edit(e, ["status": "done"], token: e.f.session)
            XCTAssertEqual(v23, .ok)
            let occurrence = try await XCTUnwrapAsync(try await PlanningOccurrence.find(e.task, on: e.db))
            let next = try await XCTUnwrapAsync(try await TaskPlanning.find(try XCTUnwrap(occurrence.nextTaskID), on: e.db))
            XCTAssertFalse(next.autoStart)
            XCTAssertNil(next.autoStartedAt)
        }
    }

    // MARK: start_agent_job: releaseID, origin, catch-up

    private func start(_ e: Env, _ extra: [String: Any] = [:]) async throws -> (isError: Bool, text: String, json: [String: Any]?) {
        var args: [String: Any] = ["taskID": e.task.uuidString, "version": try await version(e)]
        for (k, v) in extra { args[k] = v }
        return try await call(e, "start_agent_job", args)
    }

    func testReleaseIDIsIdempotentAndConflictsOnDifferentData() async throws {
        try await run { e in
            let id = UUID().uuidString
            let first = try await start(e, ["releaseID": id, "scope": "work"])
            XCTAssertFalse(first.isError, first.text)
            XCTAssertEqual(first.json?["id"] as? String, id.lowercased() == id ? id : first.json?["id"] as? String)
            let again = try await start(e, ["releaseID": id, "scope": "work"])
            XCTAssertFalse(again.isError, again.text)
            XCTAssertEqual((again.json?["id"] as? String)?.lowercased(), id.lowercased())
            let v24 = try await AgentJob.query(on: e.db).count()
            XCTAssertEqual(v24, 1)
            let different = try await start(e, ["releaseID": id, "scope": "other work"])
            XCTAssertTrue(different.isError)
            XCTAssertEqual(different.text, "release_id_conflict")
            let invalid = try await start(e, ["releaseID": "nope"])
            XCTAssertTrue(invalid.isError)
            XCTAssertEqual(invalid.text, "invalid_release_id")
            let origin = try await start(e, ["origin": "cron"])
            XCTAssertEqual(origin.text, "invalid_origin")
        }
    }

    func testSchedulerOriginGuards() async throws {
        try await run { e in
            let id = { UUID().uuidString }
            // Account switch off (default) and card permission missing.
            let off = try await start(e, ["releaseID": id(), "origin": "scheduler"])
            XCTAssertTrue(off.isError); XCTAssertEqual(off.text, "auto_start_disabled_for_account")
            try await allowAccount(e)
            let noCard = try await start(e, ["releaseID": id(), "origin": "scheduler"])
            XCTAssertEqual(noCard.text, "auto_start_not_enabled")
            try await enable(e)
            // Blocked by an open prerequisite.
            let prerequisite = TodoTask(ownerID: try e.f.user.requireID(), projectID: try e.f.project.requireID(), title: "Prereq")
            try await prerequisite.save(on: e.db)
            try await PlanningDependency(e.task, try prerequisite.requireID()).save(on: e.db)
            let blocked = try await start(e, ["releaseID": id(), "origin": "scheduler"])
            XCTAssertEqual(blocked.text, "task_blocked")
            try await PlanningDependency.query(on: e.db).delete()
            let v25 = try await AgentJob.query(on: e.db).count()
            XCTAssertEqual(v25, 0)
            // Done card.
            let t = try await XCTUnwrapAsync(try await TodoTask.find(e.task, on: e.db)); t.status = "done"; try await t.save(on: e.db)
            let done = try await start(e, ["releaseID": id(), "origin": "scheduler"])
            XCTAssertEqual(done.text, "task_done")
            let v26 = try await AgentJob.query(on: e.db).count()
            XCTAssertEqual(v26, 0)
            let v27 = try await planning(e).autoStart
            XCTAssertTrue(v27, "refused starts keep the permission")
        }
    }

    func testSchedulerStartConsumesPermissionAndIsIdempotent() async throws {
        try await run(planned: Date().addingTimeInterval(-120)) { e in
            try await allowAccount(e)
            try await enable(e)
            let id = UUID().uuidString
            let first = try await start(e, ["releaseID": id, "origin": "scheduler", "mode": "clarify"])
            XCTAssertFalse(first.isError, first.text)
            XCTAssertEqual(first.json?["state"] as? String, "queued")
            XCTAssertEqual(first.json?["mode"] as? String, "clarify")
            let p = try await planning(e)
            XCTAssertFalse(p.autoStart, "one-time permission")
            XCTAssertNotNil(p.autoStartedAt)
            // A retry with the same releaseID returns the same job and creates nothing new.
            let again = try await start(e, ["releaseID": id, "origin": "scheduler", "mode": "clarify"])
            XCTAssertFalse(again.isError, again.text)
            XCTAssertEqual(again.json?["id"] as? String, first.json?["id"] as? String)
            let v28 = try await AgentJob.query(on: e.db).count()
            XCTAssertEqual(v28, 1)
            // A new release id without a new permission is refused.
            let second = try await start(e, ["releaseID": UUID().uuidString, "origin": "scheduler"])
            XCTAssertEqual(second.text, "auto_start_not_enabled")
            // Audit: connection as actor, origin recorded, not a catch-up (2 minutes late).
            let released = try await ActivityEvent.query(on: e.db).filter(\.$taskID == e.task).filter(\.$kind == "agent.released").first()
            XCTAssertEqual(released?.actorType, .integration)
            let jobID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(first.json?["id"] as? String)))
            let event = try await XCTUnwrapAsync(try await AgentEvent.query(on: e.db).filter(\.$jobID == jobID).filter(\.$kind == "released").first())
            let detail = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(event.detail.utf8)) as? [String: Any])
            XCTAssertEqual(detail["origin"] as? String, "scheduler")
            XCTAssertEqual(detail["catchup"] as? Bool, false)
        }
    }

    func testCatchUpFlagWhenMoreThanFiveMinutesLate() async throws {
        try await run(planned: Date().addingTimeInterval(-3 * 3600)) { e in
            try await allowAccount(e)
            try await enable(e)
            let r = try await start(e, ["releaseID": UUID().uuidString, "origin": "scheduler"])
            XCTAssertFalse(r.isError, r.text)
            let jobID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(r.json?["id"] as? String)))
            let event = try await XCTUnwrapAsync(try await AgentEvent.query(on: e.db).filter(\.$jobID == jobID).filter(\.$kind == "released").first())
            let detail = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(event.detail.utf8)) as? [String: Any])
            XCTAssertEqual(detail["catchup"] as? Bool, true)
            XCTAssertGreaterThanOrEqual(detail["delayMinutes"] as? Int ?? 0, 179)
        }
    }

    func testManualStartClearsPermissionWithoutAutoStartedAt() async throws {
        try await run { e in
            try await enable(e)
            let r = try await start(e)
            XCTAssertFalse(r.isError, r.text)
            let p = try await planning(e)
            XCTAssertFalse(p.autoStart)
            XCTAssertNil(p.autoStartedAt)
            let released = try await ActivityEvent.query(on: e.db).filter(\.$taskID == e.task).filter(\.$kind == "agent.released").first()
            XCTAssertEqual(released?.actorType, .person)
        }
    }

    func testSchedulerCannotStartForeignProjectOrWithoutOwnership() async throws {
        try await run { e in
            try await allowAccount(e)
            try await enable(e)
            // Not granted project: the connection cannot see the card.
            let other = TodoTask(ownerID: try e.f.user.requireID(), projectID: try e.f.other.requireID(), title: "Outside")
            try await other.save(on: e.db)
            let r = try await call(e, "start_agent_job", ["taskID": try other.requireID().uuidString, "origin": "scheduler", "releaseID": UUID().uuidString])
            XCTAssertTrue(r.isError)
            let v29 = try await AgentJob.query(on: e.db).count()
            XCTAssertEqual(v29, 0)
        }
    }
}
