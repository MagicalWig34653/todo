import Fluent
import XCTVapor
@testable import TodoKit

/// Card B926E7D8, stage 2, section 5: a plan that waits for approval reaches "Für dich" (needsYou), the command center,
/// the update posts and push. Rights, switches, de-duplication and the re-check before sending are covered here.
final class PipelineStage2NotificationTests: XCTestCase {
    struct World {
        let f: OAuthFixture
        let task: String
        var pid: String { f.project.id!.uuidString }
        var db: any Database { f.test.app.db }
    }

    private func world(title: String = "Quarterly tax filing", _ body: (World) async throws -> Void) async throws {
        let f = try await OAuthFixture.make()
        do {
            let t = TodoTask(ownerID: try f.user.requireID(), projectID: try f.project.requireID(), title: title, details: "")
            try await t.save(on: f.test.app.db)
            try await body(World(f: f, task: try t.requireID().uuidString))
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    private func json(_ w: World, _ method: HTTPMethod, _ path: String, _ body: [String: Any]? = nil, token: String? = nil) async throws -> (status: HTTPStatus, body: [String: Any]?) {
        let r = try await w.f.test.json(method, path, body, token: token ?? w.f.session)
        return (r.status, r.body)
    }

    private func person(_ w: World, _ name: String, role: ProjectRole?) async throws -> (user: User, token: String) {
        let user = User(displayName: name, isAdmin: false)
        try await user.save(on: w.db)
        let token = AuthSupport.randomToken()
        try await UserSession(userID: user.requireID(), tokenHash: AuthSupport.hash(token), expiresAt: Date().addingTimeInterval(3600)).save(on: w.db)
        if let role {
            try await ProjectGrant(projectID: w.f.project.requireID(), principalType: "person", principalID: user.requireID(), role: role).save(on: w.db)
        }
        return (user, token)
    }

    private func write(_ w: World, _ text: String = "# Plan\nSecond line", token: String? = nil) async throws {
        let r = try await json(w, .PUT, "/v1/tasks/\(w.task)/plan", ["body": text], token: token)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
    }

    private func decide(_ w: World, _ decision: String, version: Int, comment: String? = nil) async throws {
        var body: [String: Any] = ["decision": decision, "version": version]
        if let comment { body["comment"] = comment }
        let r = try await json(w, .POST, "/v1/tasks/\(w.task)/plan/decision", body)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
    }

    private func setSettings(_ w: World, revision: Int, _ change: [String: Any]) async throws {
        var body = change; body["revision"] = revision
        let r = try await json(w, .PATCH, "/v1/projects/\(w.pid)/pipeline-settings", body)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
    }

    private func needs(_ w: World, _ query: String = "", token: String? = nil) async throws -> [[String: Any]] {
        let r = try await json(w, .GET, "/v1/feed" + query, token: token)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
        return r.body?["needsYou"] as? [[String: Any]] ?? []
    }

    private func planItems(_ items: [[String: Any]]) -> [[String: Any]] { items.filter { $0["kind"] as? String == "plan" } }

    // MARK: Feed: needsYou

    func testWaitingPlanIsAnActionableNeedsYouItemForEditors() async throws {
        try await world { w in
            let none = try await needs(w)
            XCTAssertTrue(planItems(none).isEmpty)
            try await write(w)
            let items = planItems(try await needs(w))
            XCTAssertEqual(items.count, 1)
            let item = try XCTUnwrap(items.first)
            XCTAssertEqual(item["id"] as? String, "plan:\(w.task):1")
            XCTAssertEqual(item["taskID"] as? String, w.task)
            XCTAssertEqual(item["projectID"] as? String, w.pid)
            XCTAssertEqual(item["taskTitle"] as? String, "Quarterly tax filing")
            let title = item["title"] as? String ?? ""
            XCTAssertTrue(title.contains("Quarterly tax filing") && title.contains("Plan v1 wartet auf Freigabe"), title)
            XCTAssertEqual(item["detail"] as? String, "# Plan", "first line of the plan")
            XCTAssertEqual(item["blocking"] as? Bool, false)
            XCTAssertNotNil(item["createdAt"])
            let actions = item["actions"] as? [[String: Any]] ?? []
            XCTAssertEqual(actions.map { $0["key"] as? String ?? "?" }, ["approve", "request_changes"])
            let approve = try XCTUnwrap(actions.first)
            XCTAssertEqual(approve["label"] as? String, "Plan freigeben")
            XCTAssertEqual(approve["method"] as? String, "POST")
            XCTAssertEqual(approve["path"] as? String, "/v1/tasks/\(w.task)/plan/decision")
            XCTAssertEqual(approve["body"] as? [String: AnyHashable], ["decision": "approve", "version": 1])
            XCTAssertEqual(approve["requiresInput"] as? Bool, false)
            let changes = try XCTUnwrap(actions.last)
            XCTAssertEqual(changes["label"] as? String, "Änderungen")
            XCTAssertEqual(changes["requiresInput"] as? Bool, true)
            XCTAssertEqual(changes["inputField"] as? String, "comment")
            XCTAssertEqual(changes["body"] as? [String: AnyHashable], ["decision": "request_changes", "version": 1])
            // The action can be sent as it is.
            let done = try await json(w, .POST, approve["path"] as? String ?? "", approve["body"] as? [String: Any])
            XCTAssertEqual(done.status, .ok, "\(done.body ?? [:])")
            let hoisted1 = try await needs(w)
            XCTAssertTrue(planItems(hoisted1).isEmpty, "a decided plan is gone")
            // Changes requested: the same shape with a comment, then gone as well; a new version is a new item.
            try await write(w, "Second plan")
            let hoisted2 = try await needs(w)
            XCTAssertEqual(planItems(hoisted2).first?["id"] as? String, "plan:\(w.task):2")
            let rework = try await json(w, .POST, changes["path"] as? String ?? "", ["decision": "request_changes", "version": 2, "comment": "Mehr Details"])
            XCTAssertEqual(rework.status, .ok)
            let hoisted3 = try await needs(w)
            XCTAssertTrue(planItems(hoisted3).isEmpty)
        }
    }

    func testOnlyEditorsSeeItAndSwitchesTurnItOff() async throws {
        try await world { w in
            try await write(w)
            for role in [ProjectRole.read, .comment] {
                let p = try await person(w, "R \(role.rawValue)", role: role)
                let hoisted4 = try await needs(w, token: p.token)
                XCTAssertTrue(planItems(hoisted4).isEmpty, role.rawValue)
            }
            let stranger = try await person(w, "Stranger", role: nil)
            let hoisted5 = try await needs(w, token: stranger.token)
            XCTAssertTrue(planItems(hoisted5).isEmpty)
            let editor = try await person(w, "Editor", role: .edit)
            let hoisted6 = try await needs(w, token: editor.token)
            XCTAssertEqual(planItems(hoisted6).count, 1)
            let hoisted7 = try await needs(w, "?mode=management", token: editor.token)
            XCTAssertEqual(planItems(hoisted7).count, 1)
            let hoisted8 = try await needs(w, "?mode=classic")
            XCTAssertTrue(planItems(hoisted8).isEmpty, "classic mode has no agent items")
            let hoisted9 = try await needs(w, "?projectID=\(w.pid)")
            XCTAssertEqual(planItems(hoisted9).count, 1)
            let total = try await json(w, .GET, "/v1/feed")
            XCTAssertGreaterThanOrEqual(total.body?["needsYouTotal"] as? Int ?? 0, 1)
            // Switched off: notifications, then the approval step itself.
            try await setSettings(w, revision: 0, ["notifyOnWaitingApproval": false])
            let hoisted10 = try await needs(w)
            XCTAssertTrue(planItems(hoisted10).isEmpty)
            let hoisted11 = try await needs(w, token: editor.token)
            XCTAssertTrue(planItems(hoisted11).isEmpty)
            try await setSettings(w, revision: 1, ["notifyOnWaitingApproval": true])
            let hoisted12 = try await needs(w)
            XCTAssertEqual(planItems(hoisted12).count, 1)
            try await setSettings(w, revision: 2, ["steps": ["approval": false]])
            let hoisted13 = try await needs(w)
            XCTAssertTrue(planItems(hoisted13).isEmpty)
        }
    }

    func testPlanItemsSortWithReviewsBeforeBlockedTasksAndDoNotCrowdQuestions() async throws {
        try await world { w in
            try await write(w)
            let q = TaskQuestion()
            q.taskID = try XCTUnwrap(UUID(uuidString: w.task)); q.askedByType = .integration; q.askedByID = UUID(); q.prompt = "Which?"
            q.options = []; q.blocking = true; q.state = "open"; q.version = 1
            try await q.save(on: w.db)
            let blocked = TodoTask(ownerID: try w.f.user.requireID(), projectID: try w.f.project.requireID(), title: "Blocked one", details: "")
            try await blocked.save(on: w.db)
            let wf = TaskWorkflow(); wf.id = blocked.id; wf.kind = "task"; wf.blockedReason = "waiting for key"
            try await wf.save(on: w.db)
            let kinds = try await needs(w).map { $0["kind"] as? String ?? "?" }
            let order = kinds.filter { ["question", "plan", "blocked"].contains($0) }
            XCTAssertEqual(order, ["question", "plan", "blocked"], "\(kinds)")
        }
    }

    // MARK: Feed: posts and updates

    func testPlanPostsAppearInTheFeedAndTheUpdates() async throws {
        try await world { w in
            try await write(w)
            try await decide(w, "request_changes", version: 1, comment: "Bitte Tests ergänzen")
            try await write(w, "Better plan")
            try await decide(w, "approve", version: 2)
            let step = try await json(w, .PUT, "/v1/tasks/\(w.task)/pipeline/steps/developer", ["state": "running"])
            XCTAssertEqual(step.status, .ok)
            let feed = try await json(w, .GET, "/v1/feed")
            let posts = (feed.body?["posts"] as? [[String: Any]] ?? []).filter { $0["kind"] as? String == "plan" }
            XCTAssertEqual(posts.map { $0["event"] as? String ?? "?" },
                           ["plan.approved", "plan.written", "plan.changes_requested", "plan.written"], "newest first")
            XCTAssertEqual(posts.map { $0["text"] as? String ?? "?" }, ["Plan v2", "Plan v2", "Bitte Tests ergänzen", "Plan v1"])
            XCTAssertEqual(posts.first?["taskTitle"] as? String, "Quarterly tax filing")
            XCTAssertEqual(posts.first?["state"] as? String, "approved")
            let allEvents = (feed.body?["posts"] as? [[String: Any]] ?? []).compactMap { $0["event"] as? String }
            XCTAssertFalse(allEvents.contains("pipeline.step"), "step changes stay out of the feed")
            let classic = try await json(w, .GET, "/v1/feed?mode=classic")
            XCTAssertTrue((classic.body?["posts"] as? [[String: Any]] ?? []).allSatisfy { $0["kind"] as? String != "plan" })
            // The stranger sees none of it.
            let stranger = try await person(w, "Stranger", role: nil)
            let hidden = try await json(w, .GET, "/v1/feed", token: stranger.token)
            XCTAssertEqual((hidden.body?["posts"] as? [Any])?.count, 0)

            let center = try await json(w, .GET, "/v1/command-center?updatesLimit=50")
            let updates = (center.body?["updates"] as? [[String: Any]] ?? []).filter { ($0["kind"] as? String ?? "").hasPrefix("plan.") }
            XCTAssertEqual(updates.map { $0["kind"] as? String ?? "?" }, ["plan.approved", "plan.written", "plan.changes_requested", "plan.written"])
            XCTAssertEqual(updates.map { $0["text"] as? String ?? "?" }, ["Plan v2", "Plan v2", "Bitte Tests ergänzen", "Plan v1"])
            XCTAssertFalse((center.body?["updates"] as? [[String: Any]] ?? []).contains { $0["kind"] as? String == "pipeline.step" })
        }
    }

    // MARK: Command center

    func testCommandCenterFlagsCardsAndCountsWaitingPlans() async throws {
        try await world { w in
            func card(_ body: [String: Any]?) -> [String: Any]? {
                (body?["items"] as? [[String: Any]])?.first { ($0["task"] as? [String: Any])?["id"] as? String == w.task }
            }
            let before = try await json(w, .GET, "/v1/command-center?view=list")
            XCTAssertNil(card(before.body)?["planWaiting"], "absent without a waiting plan")
            XCTAssertEqual((before.body?["summary"] as? [String: Any])?["plansWaiting"] as? Int, 0)
            try await write(w)
            let waiting = try await json(w, .GET, "/v1/command-center?view=list")
            XCTAssertEqual(card(waiting.body)?["planWaiting"] as? Bool, true)
            XCTAssertEqual((waiting.body?["summary"] as? [String: Any])?["plansWaiting"] as? Int, 1)
            // The lanes of the board stay as they are.
            let lanes = try await json(w, .GET, "/v1/command-center")
            let cards = (lanes.body?["lanes"] as? [[String: Any]] ?? []).flatMap { $0["cards"] as? [[String: Any]] ?? [] }
            XCTAssertEqual(cards.filter { $0["planWaiting"] as? Bool == true }.count, 1)
            try await setSettings(w, revision: 0, ["notifyOnWaitingApproval": false])
            let off = try await json(w, .GET, "/v1/command-center?view=list")
            XCTAssertNil(card(off.body)?["planWaiting"])
            XCTAssertEqual((off.body?["summary"] as? [String: Any])?["plansWaiting"] as? Int, 0)
            try await setSettings(w, revision: 1, ["notifyOnWaitingApproval": true])
            try await decide(w, "approve", version: 1)
            let decided = try await json(w, .GET, "/v1/command-center?view=list")
            XCTAssertNil(card(decided.body)?["planWaiting"])
            XCTAssertEqual((decided.body?["summary"] as? [String: Any])?["plansWaiting"] as? Int, 0)
            // Account scope and project scope agree; a stranger's center has none.
            try await write(w, "Again")
            let project = try await json(w, .GET, "/v1/command-center?scope=project&projectID=\(w.pid)")
            XCTAssertEqual((project.body?["summary"] as? [String: Any])?["plansWaiting"] as? Int, 1)
            let stranger = try await person(w, "Stranger", role: nil)
            let hidden = try await json(w, .GET, "/v1/command-center?view=list", token: stranger.token)
            XCTAssertEqual((hidden.body?["summary"] as? [String: Any])?["plansWaiting"] as? Int, 0)
        }
    }
}

/// Push trigger `plan` (category `agent_reviews`), with the re-check before sending.
final class PipelineStage2PushTests: XCTestCase {
    struct Fixture {
        let t: TestApp
        let mock: MockAPNs
        let sender: APNsSender
        let owner: PushTests.Account
        let guest: PushTests.Account
        let project: String
        let task: String
        var worker: PushWorker { PushWorker(app: t.app, sender: sender, interval: 0) }
    }

    private func fixture(guestRole: String? = "edit") async throws -> Fixture {
        let t = try await TestApp.make()
        let owner = try await PushTests.account(t, "Owner"), guest = try await PushTests.account(t, "Guest")
        let cfg = PushTests.config()
        t.app.settings.apns = cfg
        let mock = MockAPNs()
        let sender = try APNsSender(config: cfg, transport: mock)
        let p = try await t.json(.POST, "/v1/projects", ["name": "Secret project"], token: owner.token)
        let pid = try XCTUnwrap(p.body?["id"] as? String)
        let task = try await t.json(.POST, "/v1/tasks", ["projectID": pid, "title": "Quarterly tax filing"], token: owner.token)
        let tid = try XCTUnwrap(task.body?["id"] as? String)
        if let guestRole {
            let g = try await t.json(.PUT, "/v1/projects/\(pid)/grants", ["principalType": "person", "principalID": guest.id.uuidString, "role": guestRole], token: owner.token)
            XCTAssertEqual(g.status, .ok)
        }
        return Fixture(t: t, mock: mock, sender: sender, owner: owner, guest: guest, project: pid, task: tid)
    }

    private func register(_ f: Fixture, _ a: PushTests.Account, token: String, locale: String = "de-DE") async throws {
        let r = try await f.t.json(.POST, "/v1/push/devices", ["token": token, "platform": "ios", "bundleId": "de.linolaske.todo",
            "appVersion": "1.0", "environment": "sandbox", "locale": locale], token: a.token)
        XCTAssertTrue([.ok, .created].contains(r.status), "\(r.status) \(r.body ?? [:])")
    }

    private func writePlan(_ f: Fixture, _ text: String, token: String? = nil) async throws {
        let r = try await f.t.json(.PUT, "/v1/tasks/\(f.task)/plan", ["body": text], token: token ?? f.owner.token)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
    }

    private func payload(_ r: APNsRequest) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: r.body) as? [String: Any]) }

    private func enqueue(_ f: Fixture) async throws -> Int {
        try await PushTriggers(db: f.t.app.db, candidates: try await Candidate.load(on: f.t.app.db), since: Date().addingTimeInterval(-3600), now: Date()).run()
    }

    func testWaitingPlanReachesEditorsExceptTheWriterWithDedupe() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        try await register(f, f.owner, token: String(repeating: "01", count: 32))
        try await register(f, f.guest, token: String(repeating: "02", count: 32), locale: "en-US")
        try await writePlan(f, "# Plan\nsecret details of the plan")
        let first = try await f.worker.tick()
        XCTAssertEqual(first.enqueued, 1, "the person who wrote the plan gets none")
        XCTAssertEqual(first.sent, 1)
        let request = try XCTUnwrap(f.mock.requests.first)
        XCTAssertEqual(request.deviceToken, String(repeating: "02", count: 32))
        let body = try payload(request)
        XCTAssertEqual(body["kind"] as? String, "plan")
        XCTAssertEqual(body["taskID"] as? String, f.task); XCTAssertEqual(body["projectID"] as? String, f.project)
        XCTAssertNotNil(body["subjectID"] as? String)
        let alert = try XCTUnwrap((body["aps"] as? [String: Any])?["alert"] as? [String: Any])
        XCTAssertEqual(alert["body"] as? String, "A plan is waiting for your approval.")
        let wire = String(decoding: request.body, as: UTF8.self)
        XCTAssertFalse(wire.contains("Quarterly") || wire.contains("secret details"), "generic unless the account opted in")
        // Dedupe: same plan, nothing new; another replica does not duplicate it either.
        let second = try await f.worker.tick()
        XCTAssertEqual(second.enqueued, 0); XCTAssertEqual(f.mock.requests.count, 1)
        // A new version is a new notification; content opt-in shows the card title (never the plan text).
        _ = try await f.t.json(.POST, "/v1/me/push-prefs", ["showContent": true], token: f.guest.token)
        try await writePlan(f, "Version two with more secret details")
        let third = try await f.worker.tick()
        XCTAssertEqual(third.enqueued, 1); XCTAssertEqual(third.sent, 1)
        let text = String(decoding: try XCTUnwrap(f.mock.requests.last).body, as: UTF8.self)
        XCTAssertTrue(text.contains("Quarterly tax filing"))
        XCTAssertFalse(text.contains("secret details"))
        let keys = try await PushOutbox.query(on: f.t.app.db).all().map(\.dedupeKey)
        XCTAssertEqual(keys.filter { $0.hasPrefix("plan:") }.count, 2)
        XCTAssertTrue(keys.allSatisfy { !$0.hasPrefix("plan:") || $0.split(separator: ":").count == 3 }, "plan:<planID>:<version>")
        XCTAssertTrue(keys.contains { $0.hasSuffix(":1") } && keys.contains { $0.hasSuffix(":2") })
        let categories = Set(try await PushOutbox.query(on: f.t.app.db).all().map(\.category))
        XCTAssertEqual(categories, ["agent_reviews"])
    }

    func testGermanTextAndConnectionAuthorsReachEveryEditor() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        try await register(f, f.owner, token: String(repeating: "01", count: 32))
        // The plan is written by a connection of the owner (author type integration): every editor is told, the owner too.
        let plan = TaskPlan()
        plan.taskID = try XCTUnwrap(UUID(uuidString: f.task)); plan.version = 1; plan.body = "Plan"; plan.state = "proposed"
        plan.authorType = .integration; plan.authorID = UUID(); plan.authorLabel = "agent"; plan.writtenAt = Date()
        try await plan.save(on: f.t.app.db)
        let report = try await f.worker.tick()
        XCTAssertEqual(report.enqueued, 1); XCTAssertEqual(report.sent, 1)
        let alert = try XCTUnwrap(((try payload(try XCTUnwrap(f.mock.requests.first)))["aps"] as? [String: Any])?["alert"] as? [String: Any])
        XCTAssertEqual(alert["body"] as? String, "Ein Plan wartet auf deine Freigabe.")
    }

    func testNoPushWithoutRightsSwitchesOrCategory() async throws {
        let f = try await fixture(guestRole: "comment"); defer { Task { await f.t.shutdown() } }
        try await register(f, f.guest, token: String(repeating: "02", count: 32))
        try await writePlan(f, "Plan")
        let v0 = try await enqueue(f)
        XCTAssertEqual(v0, 0, "comment is not enough")
        _ = try await f.t.json(.PUT, "/v1/projects/\(f.project)/grants", ["principalType": "person", "principalID": f.guest.id.uuidString, "role": "edit"], token: f.owner.token)
        // The category of reviews is the switch.
        _ = try await f.t.json(.POST, "/v1/me/push-prefs", ["categories": ["agent_reviews": false]], token: f.guest.token)
        let v1 = try await enqueue(f)
        XCTAssertEqual(v1, 0)
        _ = try await f.t.json(.POST, "/v1/me/push-prefs", ["categories": ["agent_reviews": true]], token: f.guest.token)
        // Notification off in the project, or no approval step: nothing.
        let off = try await f.t.json(.PATCH, "/v1/projects/\(f.project)/pipeline-settings", ["revision": 0, "notifyOnWaitingApproval": false], token: f.owner.token)
        XCTAssertEqual(off.status, .ok, "\(off.body ?? [:])")
        let v2 = try await enqueue(f)
        XCTAssertEqual(v2, 0)
        let noApproval = try await f.t.json(.PATCH, "/v1/projects/\(f.project)/pipeline-settings", ["revision": 1, "notifyOnWaitingApproval": true, "steps": ["approval": false]], token: f.owner.token)
        XCTAssertEqual(noApproval.status, .ok)
        let v3 = try await enqueue(f)
        XCTAssertEqual(v3, 0)
        _ = try await f.t.json(.PATCH, "/v1/projects/\(f.project)/pipeline-settings", ["revision": 2, "steps": ["approval": true]], token: f.owner.token)
        let v4 = try await enqueue(f)
        XCTAssertEqual(v4, 1)
        XCTAssertTrue(f.mock.requests.isEmpty)
    }

    func testQueuedPushIsSkippedWhenTheStateChangedBeforeSending() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        try await register(f, f.guest, token: String(repeating: "02", count: 32))
        // 1. Decided.
        try await writePlan(f, "Plan one")
        let queued = try await enqueue(f)
        XCTAssertEqual(queued, 1)
        let decision = try await f.t.json(.POST, "/v1/tasks/\(f.task)/plan/decision", ["decision": "approve", "version": 1], token: f.owner.token)
        XCTAssertEqual(decision.status, .ok)
        let late = try await f.worker.tick()
        XCTAssertEqual(late.skipped, 1); XCTAssertEqual(late.sent, 0)
        XCTAssertTrue(f.mock.requests.isEmpty)
        let reason = try await PushOutbox.query(on: f.t.app.db).first()?.lastError
        XCTAssertEqual(reason, "no_longer_relevant")
        // 2. Replaced by a newer version: the old one is skipped, the new one is sent.
        try await writePlan(f, "Plan two")
        let v2 = try await enqueue(f)
        XCTAssertEqual(v2, 1)
        try await writePlan(f, "Plan three")
        let after = try await f.worker.tick()
        XCTAssertEqual(after.skipped, 1, "version 2 is gone")
        XCTAssertEqual(after.enqueued, 1); XCTAssertEqual(after.sent, 1)
        XCTAssertEqual(f.mock.requests.count, 1)
        // 3. Notification switched off after queueing.
        try await writePlan(f, "Plan four")
        let v4 = try await enqueue(f)
        XCTAssertEqual(v4, 1)
        let off = try await f.t.json(.PATCH, "/v1/projects/\(f.project)/pipeline-settings", ["revision": 0, "notifyOnWaitingApproval": false], token: f.owner.token)
        XCTAssertEqual(off.status, .ok)
        let before = f.mock.requests.count
        let skipped = try await f.worker.tick()
        XCTAssertEqual(skipped.skipped, 1); XCTAssertEqual(f.mock.requests.count, before)
        // 4. Rights lost after queueing.
        _ = try await f.t.json(.PATCH, "/v1/projects/\(f.project)/pipeline-settings", ["revision": 1, "notifyOnWaitingApproval": true], token: f.owner.token)
        try await writePlan(f, "Plan five")
        let v5 = try await enqueue(f)
        XCTAssertEqual(v5, 1)
        let grants = try await f.t.json(.GET, "/v1/projects/\(f.project)/grants", token: f.owner.token)
        let gid = try XCTUnwrap(grants.list?.first { $0["principalID"] as? String == f.guest.id.uuidString }?["id"] as? String)
        _ = try await f.t.json(.DELETE, "/v1/projects/\(f.project)/grants/\(gid)", token: f.owner.token)
        let sent = f.mock.requests.count
        let lost = try await f.worker.tick()
        XCTAssertEqual(lost.skipped, 1); XCTAssertEqual(f.mock.requests.count, sent)
    }
}
