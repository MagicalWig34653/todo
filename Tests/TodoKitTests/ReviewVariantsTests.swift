import Fluent
import XCTVapor
@testable import TodoKit

private func unwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T { try XCTUnwrap(value, file: file, line: line) }

/// Review with variants (card 1D9C8B0C, step 1): a review can offer 2-4 named variants; accepting needs a choice.
final class ReviewVariantsTests: XCTestCase {
    struct Person { let id: String; let token: String }

    private func person(_ t: TestApp, _ name: String = "Person") async throws -> Person {
        let user = User(displayName: name, isAdmin: false)
        try await user.save(on: t.app.db)
        let token = AuthSupport.randomToken()
        try await UserSession(userID: user.requireID(), tokenHash: AuthSupport.hash(token),
            expiresAt: Date().addingTimeInterval(3600)).save(on: t.app.db)
        return Person(id: try user.requireID().uuidString, token: token)
    }

    private func project(_ t: TestApp, _ owner: Person) async throws -> String {
        let r = try await t.json(.POST, "/v1/projects", ["name": "Project"], token: owner.token)
        return try XCTUnwrap(r.body?["id"] as? String)
    }

    private func task(_ t: TestApp, _ owner: Person, _ project: String, _ title: String = "Task") async throws -> String {
        let r = try await t.json(.POST, "/v1/tasks", ["projectID": project, "title": title], token: owner.token)
        return try XCTUnwrap(r.body?["id"] as? String)
    }

    /// A stored attachment row of `task`; `status` defaults to a finished upload.
    private func attachment(_ t: TestApp, task: String, owner: Person, status: String = "complete") async throws -> String {
        let a = Attachment()
        a.taskID = try XCTUnwrap(UUID(uuidString: task)); a.ownerID = try XCTUnwrap(UUID(uuidString: owner.id))
        a.filename = "variant.png"; a.role = "result"; a.mediaType = "image/png"; a.size = 3; a.checksum = "x"
        a.status = status; a.objectKey = "k"
        try await a.save(on: t.app.db)
        return try a.requireID().uuidString
    }

    private func variants(_ attachmentA: String? = nil, _ attachmentB: String? = nil) -> [[String: Any]] {
        var a: [String: Any] = ["id": "a", "label": "Windkarte", "description": "Pfeile je Stunde"]
        if let attachmentA { a["attachmentID"] = attachmentA }
        var b: [String: Any] = ["id": "b", "label": "Radarkarte"]
        if let attachmentB { b["attachmentID"] = attachmentB }
        return [a, b]
    }

    private func requestReview(_ t: TestApp, _ owner: Person, _ task: String, variants: [[String: Any]]?, summary: String = "Zwei Karten zur Wahl")
        async throws -> (status: HTTPStatus, body: [String: Any]?) {
        var body: [String: Any] = ["summary": summary]
        if let variants { body["variants"] = variants }
        let r = try await t.json(.POST, "/v1/tasks/\(task)/review", body, token: owner.token)
        return (r.status, r.body)
    }

    private func decide(_ t: TestApp, _ p: Person, _ task: String, _ decision: String = "accept", variantID: String? = nil, note: String? = nil)
        async throws -> (status: HTTPStatus, body: [String: Any]?) {
        var body: [String: Any] = ["decision": decision]
        if let variantID { body["variantID"] = variantID }
        if let note { body["note"] = note }
        let r = try await t.json(.POST, "/v1/tasks/\(task)/review/decision", body, token: p.token)
        return (r.status, r.body)
    }

    private func status(_ t: TestApp, _ id: String) async throws -> String? {
        try await TodoTask.find(UUID(uuidString: id), on: t.app.db)?.status
    }

    private func listed(_ t: TestApp, _ p: Person, state: String) async throws -> [[String: Any]] {
        let r = try await t.json(.GET, "/v1/reviews?state=\(state)", token: p.token)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
        return r.list ?? []
    }

    private func make() async throws -> (t: TestApp, owner: Person, project: String) {
        let t = try await TestApp.make()
        let owner = try await person(t)
        return (t, owner, try await project(t, owner))
    }

    // MARK: Request

    func testRequestReviewStoresVariantsAndListsReturnThem() async throws {
        let (t, owner, pid) = try await make()
        defer { Task { await t.shutdown() } }
        let tid = try await task(t, owner, pid)
        let shot = try await attachment(t, task: tid, owner: owner)
        let r = try await requestReview(t, owner, tid, variants: variants(shot))
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
        let vs = try XCTUnwrap(r.body?["variants"] as? [[String: Any]])
        XCTAssertEqual(vs.map { $0["id"] as? String }, ["a", "b"])
        XCTAssertEqual(vs[0]["label"] as? String, "Windkarte")
        XCTAssertEqual(vs[0]["description"] as? String, "Pfeile je Stunde")
        XCTAssertEqual((vs[0]["attachmentID"] as? String)?.lowercased(), shot.lowercased())
        XCTAssertNil(vs[1]["attachmentID"])
        XCTAssertNil(r.body?["chosenVariantID"])
        try await assertEqual(try await status(t, tid), "in_review")

        let pending = try await listed(t, owner, state: "pending")
        XCTAssertEqual((pending.first?["variants"] as? [[String: Any]])?.count, 2)
        let context = try await t.json(.GET, "/v1/tasks/\(tid)/context", token: owner.token)
        XCTAssertEqual(((context.body?["review"] as? [String: Any])?["variants"] as? [[String: Any]])?.count, 2)
    }

    func testVariantValidationReturns422WithStableCodes() async throws {
        let (t, owner, pid) = try await make()
        defer { Task { await t.shutdown() } }
        let tid = try await task(t, owner, pid), otherTask = try await task(t, owner, pid, "Other")
        let foreign = try await attachment(t, task: otherTask, owner: owner)
        let unfinished = try await attachment(t, task: tid, owner: owner, status: "pending")
        func v(_ id: String, _ label: String = "Label", extra: [String: Any] = [:]) -> [String: Any] {
            var d: [String: Any] = ["id": id, "label": label]; d.merge(extra) { $1 }; return d
        }
        let structural: [(String, [[String: Any]])] = [
            ("one variant", [v("a")]),
            ("five variants", ["a", "b", "c", "d", "e"].map { v($0) }),
            ("empty list", []),
            ("uppercase id", [v("A"), v("b")]),
            ("id with space", [v("a b"), v("b")]),
            ("empty id", [v(""), v("b")]),
            ("id too long", [v(String(repeating: "a", count: 21)), v("b")]),
            ("duplicate id", [v("a"), v("a")]),
            ("empty label", [v("a", "  "), v("b")]),
            ("label too long", [v("a", String(repeating: "x", count: 61)), v("b")]),
            ("description too long", [v("a", extra: ["description": String(repeating: "x", count: 501)]), v("b")]),
        ]
        for (name, list) in structural {
            let r = try await requestReview(t, owner, tid, variants: list)
            XCTAssertEqual(r.status, .unprocessableEntity, name)
            XCTAssertEqual(r.body?["reason"] as? String, "invalid_variants", name)
        }
        let attachments: [(String, Any)] = [
            ("foreign task attachment", foreign), ("unfinished upload", unfinished),
            ("unknown attachment", UUID().uuidString), ("not a uuid", "nope"),
        ]
        for (name, id) in attachments {
            let r = try await requestReview(t, owner, tid, variants: [v("a", extra: ["attachmentID": id]), v("b")])
            XCTAssertEqual(r.status, .unprocessableEntity, name)
            XCTAssertEqual(r.body?["reason"] as? String, "invalid_variant_attachment", name)
        }
        // Nothing was written: no review, task untouched.
        let reviews = try await TaskReview.query(on: t.app.db).count()
        XCTAssertEqual(reviews, 0)
        let after = try await status(t, tid); XCTAssertNotEqual(after, "in_review")
        // Four variants and a slug id with digits and hyphens are fine.
        let ok = try await requestReview(t, owner, tid, variants: [v("a1"), v("map-2"), v("c"), v(String(repeating: "d", count: 20))])
        XCTAssertEqual(ok.status, .ok, "\(ok.body ?? [:])")
    }

    func testReRequestByTheSameRequesterReplacesVariants() async throws {
        let (t, owner, pid) = try await make()
        defer { Task { await t.shutdown() } }
        let tid = try await task(t, owner, pid)
        _ = try await requestReview(t, owner, tid, variants: variants())
        let again = try await requestReview(t, owner, tid, variants: [["id": "x", "label": "Nur X"], ["id": "y", "label": "Nur Y"], ["id": "z", "label": "Nur Z"]])
        XCTAssertEqual(again.status, .ok, "\(again.body ?? [:])")
        XCTAssertEqual((again.body?["variants"] as? [[String: Any]])?.map { $0["id"] as? String }, ["x", "y", "z"])
        let none = try await requestReview(t, owner, tid, variants: nil)
        XCTAssertNil(none.body?["variants"])
        let reviews = try await TaskReview.query(on: t.app.db).count()
        XCTAssertEqual(reviews, 1)
    }

    // MARK: Decision

    func testAcceptNeedsAKnownVariantAndStoresTheChoice() async throws {
        let (t, owner, pid) = try await make()
        defer { Task { await t.shutdown() } }
        let tid = try await task(t, owner, pid)
        _ = try await requestReview(t, owner, tid, variants: variants())

        let missing = try await decide(t, owner, tid)
        XCTAssertEqual(missing.status, .unprocessableEntity)
        XCTAssertEqual(missing.body?["reason"] as? String, "variant_required")
        let unknown = try await decide(t, owner, tid, variantID: "zzz")
        XCTAssertEqual(unknown.status, .unprocessableEntity)
        XCTAssertEqual(unknown.body?["reason"] as? String, "unknown_variant")
        try await assertEqual(try await status(t, tid), "in_review")
        let stillPending = try await listed(t, owner, state: "pending")
        XCTAssertEqual(stillPending.count, 1)

        let ok = try await decide(t, owner, tid, variantID: "b", note: "Radar bitte mit Legende")
        XCTAssertEqual(ok.status, .ok, "\(ok.body ?? [:])")
        XCTAssertEqual(ok.body?["state"] as? String, "accepted")
        XCTAssertEqual(ok.body?["chosenVariantID"] as? String, "b")
        XCTAssertEqual((ok.body?["variants"] as? [[String: Any]])?.count, 2)
        try await assertEqual(try await status(t, tid), "done")

        let accepted = try await listed(t, owner, state: "accepted")
        XCTAssertEqual(accepted.first?["chosenVariantID"] as? String, "b")
        let context = try await t.json(.GET, "/v1/tasks/\(tid)/context", token: owner.token)
        XCTAssertEqual((context.body?["review"] as? [String: Any])?["chosenVariantID"] as? String, "b")

        // History: a chat comment on the review names the choice.
        let comments = try await TaskComment.query(on: t.app.db).filter(\.$taskID == UUID(uuidString: tid)!).all()
        XCTAssertTrue(comments.contains { $0.body == "Variante B gewählt: Radarkarte" && $0.reviewID != nil }, "\(comments.map(\.body))")
        // Activity: the feed post of the decision names the choice (and keeps the note).
        let feed = try await t.json(.GET, "/v1/feed", token: owner.token)
        let posts = try XCTUnwrap(feed.body?["posts"] as? [[String: Any]])
        let text = posts.compactMap { $0["text"] as? String }.first { $0.contains("Variante B gewählt") }
        XCTAssertNotNil(text, "\(posts)")
        XCTAssertTrue(text?.contains("Radarkarte") ?? false)
        XCTAssertTrue(text?.contains("Radar bitte mit Legende") ?? false)
    }

    func testRequestChangesNeedsNoVariantAndRefusesOne() async throws {
        let (t, owner, pid) = try await make()
        defer { Task { await t.shutdown() } }
        let tid = try await task(t, owner, pid)
        _ = try await requestReview(t, owner, tid, variants: variants())
        let withVariant = try await decide(t, owner, tid, "request_changes", variantID: "a")
        XCTAssertEqual(withVariant.status, .unprocessableEntity)
        XCTAssertEqual(withVariant.body?["reason"] as? String, "unexpected_variant")
        let r = try await decide(t, owner, tid, "request_changes", note: "Beide zu klein")
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
        XCTAssertEqual(r.body?["state"] as? String, "changes_requested")
        XCTAssertNil(r.body?["chosenVariantID"])
        try await assertEqual(try await status(t, tid), "in_progress")
    }

    func testReviewWithoutVariantsIsUnchangedAndRefusesAVariantID() async throws {
        let (t, owner, pid) = try await make()
        defer { Task { await t.shutdown() } }
        let tid = try await task(t, owner, pid)
        let req = try await requestReview(t, owner, tid, variants: nil, summary: "Fertig")
        XCTAssertEqual(req.status, .ok)
        XCTAssertNil(req.body?["variants"])
        XCTAssertNil(req.body?["chosenVariantID"])
        let bad = try await decide(t, owner, tid, variantID: "a")
        XCTAssertEqual(bad.status, .unprocessableEntity)
        XCTAssertEqual(bad.body?["reason"] as? String, "unexpected_variant")
        try await assertEqual(try await status(t, tid), "in_review")
        let ok = try await decide(t, owner, tid, note: "Passt")
        XCTAssertEqual(ok.status, .ok, "\(ok.body ?? [:])")
        XCTAssertEqual(ok.body?["state"] as? String, "accepted")
        XCTAssertNil(ok.body?["chosenVariantID"])
        XCTAssertNil(ok.body?["variants"])
        try await assertEqual(try await status(t, tid), "done")
        let comments = try await TaskComment.query(on: t.app.db).filter(\.$taskID == UUID(uuidString: tid)!).all()
        XCTAssertFalse(comments.contains { $0.body.contains("gewählt") })
    }

    func testUndoClearsTheChoiceAndAllowsANewOne() async throws {
        let (t, owner, pid) = try await make()
        defer { Task { await t.shutdown() } }
        let tid = try await task(t, owner, pid)
        _ = try await requestReview(t, owner, tid, variants: variants())
        let first = try await decide(t, owner, tid, variantID: "a")
        XCTAssertEqual(first.status, .ok, "\(first.body ?? [:])")
        XCTAssertNotNil(first.body?["undoUntil"])
        let undo = try await t.json(.POST, "/v1/tasks/\(tid)/review/undo", token: owner.token)
        XCTAssertEqual(undo.status, .ok, "\(undo.body ?? [:])")
        XCTAssertEqual(undo.body?["state"] as? String, "pending")
        XCTAssertNil(undo.body?["chosenVariantID"])
        XCTAssertEqual((undo.body?["variants"] as? [[String: Any]])?.count, 2)
        try await assertEqual(try await status(t, tid), "in_review")
        let second = try await decide(t, owner, tid, variantID: "b")
        XCTAssertEqual(second.body?["chosenVariantID"] as? String, "b")
    }

    // MARK: Batch

    func testBatchLeavesVariantReviewsOutOnAcceptButStillAllowsChangeRequests() async throws {
        let (t, owner, pid) = try await make()
        defer { Task { await t.shutdown() } }
        let withVariants = try await task(t, owner, pid, "V"), plain = try await task(t, owner, pid, "P"), second = try await task(t, owner, pid, "V2")
        let vReview = try unwrap(try await requestReview(t, owner, withVariants, variants: variants()).body?["id"] as? String)
        let pReview = try unwrap(try await requestReview(t, owner, plain, variants: nil, summary: "Plain").body?["id"] as? String)
        let v2Review = try unwrap(try await requestReview(t, owner, second, variants: variants()).body?["id"] as? String)

        let r = try await t.json(.POST, "/v1/reviews/decisions",
            ["decisions": [["reviewID": vReview], ["reviewID": pReview]], "decision": "accept"], token: owner.token)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
        let items = try XCTUnwrap(r.body?["results"] as? [[String: Any]])
        XCTAssertEqual(items[0]["result"] as? String, "invalid")
        XCTAssertEqual(items[0]["reason"] as? String, "variant_required")
        XCTAssertEqual(items[1]["result"] as? String, "ok")
        try await assertEqual(try await status(t, withVariants), "in_review")
        try await assertEqual(try await status(t, plain), "done")
        let row = try unwrap(try await TaskReview.find(UUID(uuidString: vReview), on: t.app.db))
        XCTAssertEqual(row.state, "pending")

        let changes = try await t.json(.POST, "/v1/reviews/decisions",
            ["decisions": [["reviewID": v2Review]], "decision": "changes_requested", "note": "Neu"], token: owner.token)
        XCTAssertEqual((changes.body?["results"] as? [[String: Any]])?.first?["result"] as? String, "ok", "\(changes.body ?? [:])")
        try await assertEqual(try await status(t, second), "in_progress")
    }
}

/// MCP side: `request_review` with variants and `decide_review` under the brain mandate (ADR 0032) with a variant.
final class ReviewVariantsMCPTests: XCTestCase {
    private struct Env {
        let f: OAuthFixture
        let agent: String, brain: String
        let brainGrant: UUID
        var pid: String { f.project.id!.uuidString }
    }

    private func env() async throws -> Env {
        let f = try await OAuthFixture.make()
        let a = try await f.tokens(scope: CommandCenterTests.scopes)
        let gA = try unwrap(try await OAuthGrant.query(on: f.test.app.db).first()?.id)
        let b = try await f.tokens(scope: CommandCenterTests.scopes)
        let gB = try unwrap(try await OAuthGrant.query(on: f.test.app.db).filter(\.$id != gA).first()?.id)
        return Env(f: f, agent: a.access, brain: b.access, brainGrant: gB)
    }

    private func call(_ e: Env, _ token: String, _ name: String, _ args: [String: Any]) async throws -> (isError: Bool, text: String, json: [String: Any]?) {
        let r = try await e.f.rpc("tools/call", ["name": name, "arguments": args], access: token)
        let result = try XCTUnwrap(r.body?["result"] as? [String: Any])
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        return (result["isError"] as? Bool ?? false, text, (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any])
    }

    private func run(_ body: (Env) async throws -> Void) async throws {
        let e = try await env()
        do { try await body(e) } catch { await e.f.test.shutdown(); throw error }
        await e.f.test.shutdown()
    }

    private func newTask(_ e: Env) async throws -> String {
        let t = TodoTask(ownerID: try e.f.user.requireID(), projectID: try e.f.project.requireID(), title: "Task", details: "")
        try await t.save(on: e.f.test.app.db)
        return try t.requireID().uuidString
    }

    private let variants: [[String: Any]] = [["id": "a", "label": "Windkarte"], ["id": "b", "label": "Radarkarte", "description": "Mit Zeitachse"]]

    func testRequestReviewToolValidatesAndStoresVariantsAndTaskContextShowsThem() async throws {
        try await run { e in
            let task = try await newTask(e)
            let bad = try await call(e, e.agent, "request_review", ["taskID": task, "summary": "S", "variants": [["id": "a", "label": "Nur eine"]]])
            XCTAssertTrue(bad.isError)
            XCTAssertEqual(bad.text, "invalid_variants")
            let badAttachment = try await call(e, e.agent, "request_review", ["taskID": task, "summary": "S",
                "variants": [["id": "a", "label": "A", "attachmentID": UUID().uuidString], ["id": "b", "label": "B"]]])
            XCTAssertEqual(badAttachment.text, "invalid_variant_attachment")
            let ok = try await call(e, e.agent, "request_review", ["taskID": task, "summary": "S", "variants": variants])
            XCTAssertFalse(ok.isError, ok.text)
            XCTAssertEqual((ok.json?["variants"] as? [[String: Any]])?.count, 2)
            let context = try await call(e, e.agent, "get_task_context", ["taskID": task])
            XCTAssertEqual(((context.json?["review"] as? [String: Any])?["variants"] as? [[String: Any]])?.map { $0["id"] as? String }, ["a", "b"])
            let list = try await call(e, e.agent, "list_pending_reviews", ["projectID": e.pid])
            let items = try XCTUnwrap(list.json?["items"] as? [[String: Any]])
            XCTAssertEqual((items.first?["variants"] as? [[String: Any]])?.count, 2)
        }
    }

    func testToolSchemasAdvertiseVariants() async throws {
        try await run { e in
            let r = try await e.f.rpc("tools/list", access: e.agent)
            let tools = try XCTUnwrap((r.body?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
            func props(_ name: String) -> [String: Any] {
                ((tools.first { $0["name"] as? String == name }?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]) ?? [:]
            }
            XCTAssertNotNil(props("request_review")["variants"])
            XCTAssertNotNil(props("decide_review")["variantID"])
        }
    }

    func testDecideReviewWithMandateQuoteAndVariant() async throws {
        try await run { e in
            let put = try await e.f.test.json(.PUT, "/v1/settings/brain-mandate",
                ["grantID": e.brainGrant.uuidString, "projectIDs": [e.pid]], token: e.f.session)
            XCTAssertEqual(put.status, .ok, "\(put.body ?? [:])")
            let task = try await newTask(e)
            _ = try await call(e, e.agent, "request_review", ["taskID": task, "summary": "S", "variants": variants])

            // The existing checks keep their order: the quote is demanded before the variant.
            let noQuote = try await call(e, e.brain, "decide_review", ["taskID": task, "decision": "accept"])
            XCTAssertEqual(noQuote.text, "quote_required")
            let noVariant = try await call(e, e.brain, "decide_review", ["taskID": task, "decision": "accept", "quote": "Lino: Radar"])
            XCTAssertEqual(noVariant.text, "variant_required")
            let unknown = try await call(e, e.brain, "decide_review", ["taskID": task, "decision": "accept", "quote": "Lino: Radar", "variantID": "q"])
            XCTAssertEqual(unknown.text, "unknown_variant")
            // Without a mandate the connection that asked cannot decide, variant or not.
            let noMandate = try await call(e, e.agent, "decide_review", ["taskID": task, "decision": "accept", "quote": "ja", "variantID": "a"])
            XCTAssertEqual(noMandate.text, "brain_mandate_required")
            try await assertEqual(try await TodoTask.find(UUID(uuidString: task), on: e.f.test.app.db)?.status, "in_review")

            let ok = try await call(e, e.brain, "decide_review", ["taskID": task, "decision": "accept", "quote": "Lino: Radar", "variantID": "b"])
            XCTAssertFalse(ok.isError, ok.text)
            XCTAssertEqual(ok.json?["state"] as? String, "accepted")
            XCTAssertEqual(ok.json?["chosenVariantID"] as? String, "b")
            try await assertEqual(try await TodoTask.find(UUID(uuidString: task), on: e.f.test.app.db)?.status, "done")
            let audit = try await e.f.test.json(.GET, "/v1/settings/brain-mandate/audit", token: e.f.session)
            let rows = try XCTUnwrap(audit.body?["items"] as? [[String: Any]])
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows.first?["quote"] as? String, "Lino: Radar")
            let comments = try await TaskComment.query(on: e.f.test.app.db).filter(\.$taskID == UUID(uuidString: task)!).all()
            XCTAssertTrue(comments.contains { $0.body == "Variante B gewählt: Radarkarte" }, "\(comments.map(\.body))")
            XCTAssertTrue(comments.contains { $0.body.contains("Lino: Radar") })
        }
    }

    func testDecideReviewWithVariantIDOnAReviewWithoutVariants() async throws {
        try await run { e in
            _ = try await e.f.test.json(.PUT, "/v1/settings/brain-mandate",
                ["grantID": e.brainGrant.uuidString, "projectIDs": [e.pid]], token: e.f.session)
            let task = try await newTask(e)
            _ = try await call(e, e.agent, "request_review", ["taskID": task, "summary": "S"])
            let r = try await call(e, e.brain, "decide_review", ["taskID": task, "decision": "accept", "quote": "ja", "variantID": "a"])
            XCTAssertEqual(r.text, "unexpected_variant")
            let ok = try await call(e, e.brain, "decide_review", ["taskID": task, "decision": "accept", "quote": "ja"])
            XCTAssertFalse(ok.isError, ok.text)
            XCTAssertNil(ok.json?["chosenVariantID"])
        }
    }
}
