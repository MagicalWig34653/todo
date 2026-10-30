import Fluent
import XCTVapor
@testable import TodoKit

func assertEqual<T: Equatable>(_ a: @autoclosure () async throws -> T, _ b: @autoclosure () throws -> T,
                               file: StaticString = #filePath, line: UInt = #line) async throws {
    let x = try await a(), y = try b()
    XCTAssertEqual(x, y, file: file, line: line)
}

final class AgentManualTests: XCTestCase {
    func testEmbeddedManualIsCurrent() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = try String(contentsOf: root.appendingPathComponent("docs/agent-manual.md"), encoding: .utf8)
        XCTAssertEqual(file.trimmingCharacters(in: .whitespacesAndNewlines), AgentManual.markdown.trimmingCharacters(in: .whitespacesAndNewlines),
                       "docs/agent-manual.md changed: run scripts/embed-agent-manual.sh")
        XCTAssertEqual(AgentManual.version, "1.0.0")
    }

    func testManualDocumentsEveryRegisteredToolAndEveryFieldIsDescribed() {
        for tool in MCPController.tools {
            XCTAssertTrue(AgentManual.markdown.contains("`\(tool.name)`"), "manual does not mention tool \(tool.name)")
            XCTAssertGreaterThanOrEqual(tool.description.count, 40, "tool \(tool.name) needs a precise description")
            for (field, schema) in tool.properties {
                XCTAssertNotNil(schema["description"].string, "\(tool.name).\(field) has no description")
            }
            XCTAssertTrue(Set(tool.required).isSubset(of: Set(tool.properties.keys)), tool.name)
        }
        XCTAssertEqual(Set(MCPController.tools.map(\.name)).count, MCPController.tools.count, "duplicate tool names")
        for section in AgentManual.sections { XCTAssertNoThrow(try AgentManual.response(section: section.id)) }
        XCTAssertThrowsError(try AgentManual.response(section: "nope"))
    }

    func testManualOverMCPAndRESTAndInitializeInstructions() async throws {
        let f = try await OAuthFixture.make()
        do {
            // A grant with a single unrelated scope still reads the manual.
            let t = try await f.tokens(scope: "tasks:read")
            let list = try await f.rpc("tools/list", access: t.access)
            let names = ((list.body?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            XCTAssertTrue(names.contains("get_manual"))
            let call = try await f.rpc("tools/call", ["name": "get_manual", "arguments": ["section": "board-columns"]], access: t.access)
            let text = try XCTUnwrap(((call.body?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String)
            let manual = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            XCTAssertEqual(manual["version"] as? String, "1.0.0")
            XCTAssertTrue((manual["content"] as? String ?? "").contains("Frage offen"))
            XCTAssertNotNil((manual["conventions"] as? [String: Any])?["lanes"])
            // No arguments at all.
            let bare = try await f.rpc("tools/call", ["name": "get_manual"], access: t.access)
            XCTAssertEqual((bare.body?["result"] as? [String: Any])?["isError"] as? Bool, false)
            let initialize = try await f.rpc("initialize", ["protocolVersion": "2025-11-25"], access: t.access)
            let result = try XCTUnwrap(initialize.body?["result"] as? [String: Any])
            XCTAssertTrue((result["instructions"] as? String ?? "").contains("get_manual"))
            let resources = try await f.rpc("resources/list", access: t.access)
            XCTAssertEqual(((resources.body?["result"] as? [String: Any])?["resources"] as? [[String: Any]])?.count, 2)
            let read = try await f.rpc("resources/read", ["uri": "todo://manual"], access: t.access)
            let contents = ((read.body?["result"] as? [String: Any])?["contents"] as? [[String: Any]])?.first
            XCTAssertTrue((contents?["text"] as? String ?? "").hasPrefix("<!-- manual-version"))
            let missing = try await f.rpc("resources/read", ["uri": "todo://nope"], access: t.access)
            XCTAssertEqual((missing.body?["error"] as? [String: Any])?["code"] as? Int, -32002)
            // REST is public.
            let rest = try await f.test.json(.GET, "/v1/manual")
            XCTAssertEqual(rest.status, .ok)
            XCTAssertEqual(rest.body?["version"] as? String, "1.0.0")
            let unknown = try await f.test.json(.GET, "/v1/manual?section=nope")
            XCTAssertEqual(unknown.status, .notFound)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }
}

final class CommandCenterTests: XCTestCase {
    static let scopes = "projects:read tasks:read tasks:write comments:write attachments:read attachments:write agents:read"

    private func call(_ f: OAuthFixture, _ name: String, _ args: [String: Any], access: String) async throws -> (isError: Bool, text: String, json: Any?) {
        let r = try await f.rpc("tools/call", ["name": name, "arguments": args], access: access)
        let result = try XCTUnwrap(r.body?["result"] as? [String: Any])
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        return (result["isError"] as? Bool ?? false, text, try? JSONSerialization.jsonObject(with: Data(text.utf8)))
    }

    private func lane(_ body: [String: Any]?, _ key: String) -> [String: Any]? {
        (body?["lanes"] as? [[String: Any]])?.first { $0["key"] as? String == key }
    }
    private func cards(_ body: [String: Any]?, _ key: String) -> [[String: Any]] {
        lane(body, key)?["cards"] as? [[String: Any]] ?? []
    }

    func testAgentWorkflowThroughBoardEndToEnd() async throws {
        let f = try await OAuthFixture.make()
        do {
            let db = f.test.app.db
            let pid = try f.project.requireID().uuidString
            let t = try await f.tokens(scope: Self.scopes)
            // Standard columns on an empty board; a second call is refused.
            let applied = try await call(f, "apply_agent_workflow_columns", ["projectID": pid], access: t.access)
            XCTAssertFalse(applied.isError, applied.text)
            XCTAssertEqual((applied.json as? [[String: Any]])?.map { $0["name"] as? String }, ["Backlog", "Bereit", "In Arbeit", "Frage offen", "Review", "Erledigt"])
            let again = try await call(f, "apply_agent_workflow_columns", ["projectID": pid], access: t.access)
            XCTAssertEqual(again.text, "columns_exist")
            let structure = try await call(f, "get_project_structure", ["projectID": pid], access: t.access)
            XCTAssertEqual(((structure.json as? [String: Any])?["template"] as? [String: Any])?["complete"] as? Bool, true)

            // Feature with two subtasks.
            let feature = try await call(f, "create_task", ["projectID": pid, "title": "Login feature"], access: t.access)
            let featureID = try XCTUnwrap((feature.json as? [String: Any])?["id"] as? String)
            let sub1Result = try await call(f, "create_task", ["projectID": pid, "title": "Sub 1"], access: t.access)
            let sub1 = try XCTUnwrap((sub1Result.json as? [String: Any])?["id"] as? String)
            let sub2Result = try await call(f, "create_task", ["projectID": pid, "title": "Sub 2"], access: t.access)
            let sub2 = try XCTUnwrap((sub2Result.json as? [String: Any])?["id"] as? String)
            for sub in [sub1, sub2] {
                let r = try await call(f, "set_task_structure", ["taskID": sub, "parentTaskID": featureID], access: t.access)
                XCTAssertFalse(r.isError, r.text)
            }
            let deep = try await call(f, "set_task_structure", ["taskID": featureID, "parentTaskID": sub1], access: t.access)
            XCTAssertTrue(deep.isError)
            // Claim: status, column, claimed label; competing claim refused.
            let claim = try await call(f, "claim_task", ["taskID": sub1, "agentName": "agent-a"], access: t.access)
            XCTAssertFalse(claim.isError, claim.text)
            let rival = try await call(f, "claim_task", ["taskID": sub1, "agentName": "agent-b"], access: t.access)
            XCTAssertEqual(rival.text, "already_claimed")
            let takeover = try await call(f, "claim_task", ["taskID": sub1, "agentName": "agent-b", "takeOver": true], access: t.access)
            XCTAssertFalse(takeover.isError)
            let claimed = try await TodoTask.find(UUID(uuidString: sub1), on: db)
            XCTAssertEqual(claimed?.status, "in_progress")
            let column = try await ProjectColumn.find(claimed?.columnID, on: db)
            XCTAssertEqual(column?.name, "In Arbeit")

            // Question: lane, column, aggregate, guards.
            let ask = try await call(f, "ask_question", ["taskID": sub1, "prompt": "Passkeys only?", "options": ["Yes", "No"], "idempotencyKey": "k1"], access: t.access)
            XCTAssertFalse(ask.isError, ask.text)
            let qid = try XCTUnwrap((ask.json as? [String: Any])?["id"] as? String)
            let retry = try await call(f, "ask_question", ["taskID": sub1, "prompt": "Passkeys only?", "options": ["Yes", "No"], "idempotencyKey": "k1"], access: t.access)
            XCTAssertEqual((retry.json as? [String: Any])?["id"] as? String, qid)
            let idemConflict = try await call(f, "ask_question", ["taskID": sub1, "prompt": "Other?", "idempotencyKey": "k1"], access: t.access)
            XCTAssertEqual(idemConflict.text, "idempotency_conflict")
            let moved = try await TodoTask.find(UUID(uuidString: sub1), on: db)
            try await assertEqual(try await ProjectColumn.find(moved?.columnID, on: db)?.name, "Frage offen")
            var center = try await f.test.json(.GET, "/v1/command-center", token: f.session)
            XCTAssertEqual(center.status, .ok)
            XCTAssertEqual((center.body?["summary"] as? [String: Any])?["openQuestions"] as? Int, 1)
            // The feature card carries the subtask's question and lands in the question lane.
            let featureCard = try XCTUnwrap(cards(center.body, "question").first { ($0["task"] as? [String: Any])?["id"] as? String == featureID })
            XCTAssertEqual(featureCard["openQuestionCount"] as? Int, 1)
            XCTAssertEqual(featureCard["isFeature"] as? Bool, true)
            XCTAssertEqual((featureCard["subtasks"] as? [[String: Any]])?.count, 2)
            let open = try await call(f, "list_open_questions", [:], access: t.access)
            XCTAssertEqual((open.json as? [[String: Any]])?.count, 1)
            let own = try await call(f, "answer_question", ["questionID": qid, "answer": "Yes"], access: t.access)
            XCTAssertEqual(own.text, "cannot_answer_own_question")
            let invalid = try await f.test.json(.POST, "/v1/questions/\(qid)/answer", ["answer": "Maybe"], token: f.session)
            XCTAssertEqual(invalid.status, .badRequest)
            let answered = try await f.test.json(.POST, "/v1/questions/\(qid)/answer", ["answer": "Yes"], token: f.session)
            XCTAssertEqual(answered.status, .ok)
            XCTAssertEqual(answered.body?["state"] as? String, "answered")
            XCTAssertEqual(answered.body?["answeredVia"] as? String, "rest")
            let repeated = try await f.test.json(.POST, "/v1/questions/\(qid)/answer", ["answer": "Yes"], token: f.session)
            XCTAssertEqual(repeated.status, .ok)
            let different = try await f.test.json(.POST, "/v1/questions/\(qid)/answer", ["answer": "No"], token: f.session)
            XCTAssertEqual(different.status, .conflict)
            let read = try await call(f, "get_question", ["questionID": qid], access: t.access)
            XCTAssertEqual((read.json as? [String: Any])?["answer"] as? String, "Yes")
            try await assertEqual(try await ProjectColumn.find(try await TodoTask.find(UUID(uuidString: sub1), on: db)?.columnID, on: db)?.name, "In Arbeit")

            // Progress: notes and percent from subtasks.
            let note = try await call(f, "post_progress", ["taskID": sub1, "note": "Login view done", "percent": 40, "agentName": "agent-b"], access: t.access)
            XCTAssertFalse(note.isError, note.text)
            let badPercent = try await call(f, "post_progress", ["taskID": sub1, "note": "x", "percent": 140], access: t.access)
            XCTAssertTrue(badPercent.isError)
            // Review: request, listing, guards, human decision completes the task and the feature rolls up.
            let review = try await call(f, "request_review", ["taskID": sub1, "summary": "Implemented and tested"], access: t.access)
            XCTAssertFalse(review.isError, review.text)
            try await assertEqual(try await TodoTask.find(UUID(uuidString: sub1), on: db)?.status, "in_review")
            let pending = try await call(f, "list_pending_reviews", [:], access: t.access)
            XCTAssertEqual((pending.json as? [[String: Any]])?.count, 1)
            let selfDecide = try await call(f, "decide_review", ["taskID": sub1, "decision": "accept"], access: t.access)
            XCTAssertEqual(selfDecide.text, "cannot_decide_own_review")
            center = try await f.test.json(.GET, "/v1/command-center?scope=project&projectID=\(pid)", token: f.session)
            XCTAssertEqual((center.body?["summary"] as? [String: Any])?["pendingReviews"] as? Int, 1)
            XCTAssertEqual(cards(center.body, "review").count, 1)
            let changes = try await f.test.json(.POST, "/v1/tasks/\(sub1)/review/decision", ["decision": "request_changes", "note": "Add a test"], token: f.session)
            XCTAssertEqual(changes.body?["state"] as? String, "changes_requested")
            try await assertEqual(try await TodoTask.find(UUID(uuidString: sub1), on: db)?.status, "in_progress")
            _ = try await call(f, "request_review", ["taskID": sub1, "summary": "Test added"], access: t.access)
            let accepted = try await f.test.json(.POST, "/v1/tasks/\(sub1)/review/decision", ["decision": "accept"], token: f.session)
            XCTAssertEqual(accepted.body?["state"] as? String, "accepted")
            try await assertEqual(try await TodoTask.find(UUID(uuidString: sub1), on: db)?.status, "done")
            let noPending = try await f.test.json(.POST, "/v1/tasks/\(sub1)/review/decision", ["decision": "accept"], token: f.session)
            XCTAssertEqual(noPending.status, .conflict)

            let context = try await call(f, "get_task_context", ["taskID": featureID], access: t.access)
            let progress = try XCTUnwrap((context.json as? [String: Any])?["progress"] as? [String: Any])
            XCTAssertEqual(progress["percent"] as? Int, 50)
            XCTAssertEqual(progress["source"] as? String, "subtasks")
            // Updates feed names the milestones, with text.
            center = try await f.test.json(.GET, "/v1/command-center?updatesLimit=50", token: f.session)
            let updates = try XCTUnwrap(center.body?["updates"] as? [[String: Any]])
            let kinds = Set(updates.compactMap { $0["kind"] as? String })
            XCTAssertTrue(["progress.posted", "question.asked", "question.answered", "review.requested", "review.accepted"].allSatisfy(kinds.contains), "\(kinds)")
            XCTAssertEqual(updates.first { $0["kind"] as? String == "progress.posted" }?["text"] as? String, "Login view done")
            // List view: flat, filtered, sorted.
            let list = try await f.test.json(.GET, "/v1/command-center?view=list&includeSubtasks=true&sort=title&lane=done", token: f.session)
            XCTAssertEqual(list.status, .ok)
            XCTAssertEqual((list.body?["items"] as? [[String: Any]])?.count, 1)
            XCTAssertNil(list.body?["lanes"])
            let badLane = try await f.test.json(.GET, "/v1/command-center?lane=nope", token: f.session)
            XCTAssertEqual(badLane.status, .badRequest)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testPermissionsAndGrantBoundaries() async throws {
        let f = try await OAuthFixture.make()
        do {
            let db = f.test.app.db
            let task = TodoTask(ownerID: try f.user.requireID(), projectID: try f.project.requireID(), title: "T", details: "")
            try await task.save(on: db)
            let tid = try task.requireID().uuidString
            let foreign = TodoTask(ownerID: try f.user.requireID(), projectID: try f.other.requireID(), title: "Outside", details: "")
            try await foreign.save(on: db)
            let t = try await f.tokens(scope: Self.scopes)
            // Outside the grant: identical to unknown.
            for tool in [("claim_task", ["taskID": foreign.id!.uuidString]), ("ask_question", ["taskID": foreign.id!.uuidString, "prompt": "x"]),
                         ("get_task_context", ["taskID": foreign.id!.uuidString]), ("get_project_structure", ["projectID": try f.other.requireID().uuidString])] {
                let r = try await call(f, tool.0, tool.1, access: t.access)
                XCTAssertEqual(r.text, "not_found", tool.0)
            }
            // Scopes: read-only token cannot write or upload.
            let ro = try await f.tokens(scope: "tasks:read")
            let denied = try await call(f, "claim_task", ["taskID": tid], access: ro.access)
            XCTAssertEqual(denied.text, "insufficient_scope")
            let noUpload = try await call(f, "add_attachment", ["taskID": tid, "filename": "a.png", "mediaType": "image/png", "dataBase64": "AA==", "buildID": "b"], access: ro.access)
            XCTAssertEqual(noUpload.text, "insufficient_scope")
            // The command center of a grant only contains granted projects.
            _ = try await call(f, "create_task", ["projectID": try f.project.requireID().uuidString, "title": "Inside"], access: t.access)
            let mcpCenter = try await call(f, "get_command_center", ["view": "list"], access: t.access)
            let titles = ((mcpCenter.json as? [String: Any])?["items"] as? [[String: Any]])?.compactMap { ($0["task"] as? [String: Any])?["title"] as? String } ?? []
            XCTAssertTrue(titles.contains("Inside")); XCTAssertFalse(titles.contains("Outside"))
            let restTitles = ((try await f.test.json(.GET, "/v1/command-center?view=list", token: f.session)).body?["items"] as? [[String: Any]])?.compactMap { ($0["task"] as? [String: Any])?["title"] as? String } ?? []
            XCTAssertTrue(restTitles.contains("Outside"))

            // A stranger sees nothing and cannot touch anything.
            let stranger = User(displayName: "Stranger", isAdmin: false); try await stranger.save(on: db)
            let token = AuthSupport.randomToken()
            try await UserSession(userID: stranger.requireID(), tokenHash: AuthSupport.hash(token), expiresAt: Date().addingTimeInterval(3600)).save(on: db)
            let pid = try f.project.requireID().uuidString
            for (method, path) in [(HTTPMethod.GET, "/v1/tasks/\(tid)/context"), (.POST, "/v1/tasks/\(tid)/claim"), (.GET, "/v1/projects/\(pid)/structure"),
                                   (.GET, "/v1/projects/\(pid)/agent-brief"), (.GET, "/v1/command-center?projectID=\(pid)")] {
                let r = try await f.test.json(method, path, [:], token: token)
                XCTAssertEqual(r.status, .notFound, path)
            }
            let none = try await f.test.json(.GET, "/v1/command-center", token: token)
            XCTAssertEqual((none.body?["summary"] as? [String: Any])?["ready"] as? Int, 0)
            try await assertEqual((try await f.test.json(.GET, "/v1/questions", token: token)).list?.count, 0)

            // Brief: owner writes with optimistic version; MCP sees it through the structure.
            var brief = try await f.test.json(.GET, "/v1/projects/\(pid)/agent-brief", token: f.session)
            XCTAssertEqual(brief.body?["version"] as? Int, 0)
            brief = try await f.test.json(.PUT, "/v1/projects/\(pid)/agent-brief", ["text": "## Goals\nShip login", "version": 0], token: f.session)
            XCTAssertEqual(brief.status, .ok)
            XCTAssertEqual(brief.body?["version"] as? Int, 1)
            let stale = try await f.test.json(.PUT, "/v1/projects/\(pid)/agent-brief", ["text": "x", "version": 0], token: f.session)
            XCTAssertEqual(stale.status, .conflict)
            let strangerWrite = try await f.test.json(.PUT, "/v1/projects/\(pid)/agent-brief", ["text": "x", "version": 1], token: token)
            XCTAssertEqual(strangerWrite.status, .notFound)
            let structure = try await call(f, "get_project_structure", ["projectID": pid], access: t.access)
            XCTAssertEqual((((structure.json as? [String: Any])?["brief"]) as? [String: Any])?["text"] as? String, "## Goals\nShip login")
            let resource = try await f.rpc("resources/read", ["uri": "todo://projects/\(pid)/structure"], access: t.access)
            XCTAssertNotNil(((resource.body?["result"] as? [String: Any])?["contents"] as? [[String: Any]])?.first?["text"])
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testConcurrentClaimsAndAnswers() async throws {
        let f = try await OAuthFixture.make()
        do {
            let db = f.test.app.db
            let task = TodoTask(ownerID: try f.user.requireID(), projectID: try f.project.requireID(), title: "Race", details: "")
            try await task.save(on: db)
            let tid = try task.requireID().uuidString
            let test = f.test, session = f.session
            // Two agents claim at once: exactly one wins.
            let claimStatuses = try await withThrowingTaskGroup(of: HTTPStatus.self) { group in
                for name in ["a", "b"] {
                    let body = try JSONSerialization.data(withJSONObject: ["agentName": name])
                    group.addTask { try await test.rawStatus(.POST, "/v1/tasks/\(tid)/claim", body: body, token: session) }
                }
                return try await group.reduce(into: []) { $0.append($1) }
            }
            XCTAssertEqual(claimStatuses.filter { $0 == .ok }.count, 1, "\(claimStatuses)")
            XCTAssertEqual(claimStatuses.filter { $0 == .conflict }.count, 1, "\(claimStatuses)")
            // Two askers with the same idempotency key create one question.
            let askBody = try JSONSerialization.data(withJSONObject: ["prompt": "Which?", "idempotencyKey": "same"])
            let asks = try await withThrowingTaskGroup(of: HTTPStatus.self) { group in
                for _ in 0..<2 { group.addTask { try await test.rawStatus(.POST, "/v1/tasks/\(tid)/questions", body: askBody, token: session) } }
                return try await group.reduce(into: []) { $0.append($1) }
            }
            XCTAssertTrue(asks.allSatisfy { $0 == .created }, "\(asks)")
            try await assertEqual(try await TaskQuestion.query(on: db).count(), 1)
            let firstQuestion = try await TaskQuestion.query(on: db).first()
            let qid = try XCTUnwrap(firstQuestion?.id).uuidString
            // Two different answers at once: exactly one is stored.
            let answers = try await withThrowingTaskGroup(of: HTTPStatus.self) { group in
                for value in ["one", "two"] {
                    let body = try JSONSerialization.data(withJSONObject: ["answer": value])
                    group.addTask { try await test.rawStatus(.POST, "/v1/questions/\(qid)/answer", body: body, token: session) }
                }
                return try await group.reduce(into: []) { $0.append($1) }
            }
            XCTAssertEqual(answers.filter { $0 == .ok }.count, 1, "\(answers)")
            XCTAssertEqual(answers.filter { $0 == .conflict }.count, 1, "\(answers)")
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testRunnerQuestionsAndReviewsAreMirrored() async throws {
        let f = try await AgentFixture.make()
        defer { Task { await f.app.shutdown() } }
        let job = try await f.release()
        let run = try await f.claim(job)
        var status = try await f.command(run, "question", ["generation": 1, "prompt": "Which option?", "options": ["A", "B"]])
        XCTAssertEqual(status, .ok)
        let open = try await f.app.json(.GET, "/v1/questions?projectID=\(f.projectID)", token: f.human)
        let question = try XCTUnwrap(open.list?.first)
        XCTAssertEqual(question["askedByType"] as? String, "Run")
        XCTAssertNotNil(question["agentQuestionID"] as? String)
        let center = try await f.app.json(.GET, "/v1/command-center", token: f.human)
        XCTAssertEqual((center.body?["summary"] as? [String: Any])?["openQuestions"] as? Int, 1)
        // Answering through the new API delegates to the runner flow.
        let qid = try XCTUnwrap(question["id"] as? String)
        let answered = try await f.app.json(.POST, "/v1/questions/\(qid)/answer", ["answer": "A"], token: f.human)
        XCTAssertEqual(answered.status, .ok, "\(answered.body ?? [:])")
        XCTAssertEqual(answered.body?["state"] as? String, "answered")
        let detail = try await f.app.json(.GET, "/v1/runner/jobs/\(job)", token: f.runner)
        XCTAssertEqual((detail.body?["questions"] as? [[String: Any]])?.first?["answer"] as? String, "A")
        status = try await f.command(run, "resume")
        XCTAssertEqual(status, .ok)
        status = try await f.command(run, "submit", ["generation": 1, "result": ["summary": "Done", "references": [String](), "checks": [String](), "limitations": [String]()]])
        XCTAssertEqual(status, .ok)
        let reviews = try await f.app.json(.GET, "/v1/reviews", token: f.human)
        XCTAssertEqual(reviews.list?.count, 1)
        XCTAssertEqual(reviews.list?.first?["agentJobID"] as? String, job.lowercased() == job ? job : job)
        let decided = try await f.app.json(.POST, "/v1/tasks/\(f.taskID)/review/decision", ["decision": "accept"], token: f.human)
        XCTAssertEqual(decided.status, .ok, "\(decided.body ?? [:])")
        XCTAssertEqual(decided.body?["state"] as? String, "accepted")
        let jobState = try await f.app.json(.GET, "/v1/agents/jobs/\(job)", token: f.human)
        XCTAssertEqual((jobState.body?["job"] as? [String: Any])?["state"] as? String, "succeeded")
        try await assertEqual((try await f.app.json(.GET, "/v1/reviews", token: f.human)).list?.count, 0)
        // A stopped job withdraws open mirrors.
        let job2 = try await f.release(revision: 1)
        let run2 = try await f.claim(job2)
        status = try await f.command(run2, "question", ["generation": 1, "prompt": "Again?"])
        XCTAssertEqual(status, .ok)
        _ = try await f.app.json(.POST, "/v1/agents/jobs/\(job2)/stop", token: f.human)
        try await assertEqual((try await f.app.json(.GET, "/v1/questions", token: f.human)).list?.count, 0)
        let all = try await f.app.json(.GET, "/v1/questions?state=all", token: f.human)
        XCTAssertTrue((all.list ?? []).contains { $0["state"] as? String == "withdrawn" })
    }

    func testBuildScreenshotsRegisterAndGroup() async throws {
        let f = try await OAuthFixture.make()
        do {
            let db = f.test.app.db
            let task = TodoTask(ownerID: try f.user.requireID(), projectID: try f.project.requireID(), title: "Shots", details: "")
            try await task.save(on: db)
            let tid = try task.requireID().uuidString
            let t = try await f.tokens(scope: Self.scopes)
            let png = Data([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 0])
            let add = try await call(f, "add_attachment", ["taskID": tid, "filename": "login.png", "mediaType": "image/png",
                "dataBase64": png.base64EncodedString(), "buildID": "web-1", "label": "Login", "platform": "web"], access: t.access)
            XCTAssertFalse(add.isError, add.text)
            let builds = try await call(f, "list_builds", ["taskID": tid], access: t.access)
            XCTAssertEqual((builds.json as? [[String: Any]])?.first?["buildID"] as? String, "web-1")
            let center = try await f.test.json(.GET, "/v1/command-center", token: f.session)
            XCTAssertEqual((center.body?["builds"] as? [[String: Any]])?.first?["buildID"] as? String, "web-1")
            let bad = try await call(f, "add_attachment", ["taskID": tid, "filename": "x.png", "mediaType": "image/png", "dataBase64": "!!!", "buildID": "b"], access: t.access)
            XCTAssertEqual(bad.text, "invalid_base64")
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }
}
