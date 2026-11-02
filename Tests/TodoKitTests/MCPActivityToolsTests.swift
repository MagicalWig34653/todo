import Crypto
import Fluent
import XCTVapor
@testable import TodoKit

/// Stapel 4 (docs/MCP-PARITAET.md): comments, activity, attachment reading, register_build, upload roles, class C deletes.
final class MCPActivityToolsTests: XCTestCase {
    private struct Called { let isError: Bool; let json: Any?; let text: String
        var object: [String: Any]? { json as? [String: Any] } }

    private func call(_ f: OAuthFixture, _ name: String, _ args: [String: Any], _ access: String) async throws -> Called {
        let r = try await f.rpc("tools/call", ["name": name, "arguments": args], access: access)
        let result = try XCTUnwrap(r.body?["result"] as? [String: Any], String(describing: r.body))
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        return Called(isError: result["isError"] as? Bool ?? false, json: try? JSONSerialization.jsonObject(with: Data(text.utf8)), text: text)
    }

    private static let scopes = "projects:read tasks:read tasks:write comments:write attachments:read attachments:write"

    private func fixture(scope: String = scopes, _ run: (OAuthFixture, String) async throws -> Void) async throws {
        let f = try await OAuthFixture.make()
        do { let t = try await f.tokens(scope: scope); try await run(f, t.access) }
        catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    private func makeTask(_ f: OAuthFixture, project: Project? = nil) async throws -> TodoTask {
        let t = TodoTask(ownerID: try f.user.requireID(), projectID: try (project ?? f.project).requireID(), title: "Task", details: "")
        try await t.save(on: f.test.app.db)
        return t
    }

    private let png = Data([137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3, 4])

    func testRegistrationAndScopes() async throws {
        let names = ["update_comment", "delete_comment", "list_project_comments", "add_project_comment", "update_project_comment", "delete_project_comment",
                     "list_activity", "read_attachment", "register_build", "begin_task_upload", "complete_task_upload", "delete_attachment"]
        for n in names { XCTAssertTrue(MCPController.tools.contains { $0.name == n }, n) }
        let f = try await OAuthFixture.make()
        do {
            let old = try await f.tokens(scope: "projects:write")
            for tool in MCPController.activityTools {
                let r = try await call(f, tool.name, [:], old.access); XCTAssertEqual(r.text, "insufficient_scope", tool.name)
            }
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    func testUpdateCommentOnlyOwnAgentMessagesWithVersion() async throws {
        try await fixture { f, access in
            let t = try await makeTask(f); let tid = try t.requireID().uuidString
            let added = try await call(f, "add_comment", ["taskID": tid, "body": "first"], access)
            let cid = try XCTUnwrap(added.object?["id"] as? String)
            let ok = try await call(f, "update_comment", ["taskID": tid, "commentID": cid, "version": 1, "body": "second"], access)
            XCTAssertFalse(ok.isError, ok.text)
            XCTAssertEqual(ok.object?["body"] as? String, "second"); XCTAssertEqual(ok.object?["version"] as? Int, 2)
            let stale = try await call(f, "update_comment", ["taskID": tid, "commentID": cid, "version": 1, "body": "lost"], access)
            XCTAssertEqual(stale.text, "version_conflict")
            // A message written by a person (same account, via the app) is not editable by the agent.
            let human = TaskComment(taskID: try t.requireID(), authorID: try f.user.requireID(), body: "human"); try await human.save(on: f.test.app.db)
            let denied = try await call(f, "update_comment", ["taskID": tid, "commentID": human.requireID().uuidString, "version": 1, "body": "x"], access)
            XCTAssertEqual(denied.text, "not_agent_comment")
            let kinds = try await ActivityEvent.query(on: f.test.app.db).filter(\.$taskID == t.requireID()).all().map(\.kind)
            XCTAssertTrue(kinds.contains("comment.updated"))
            // Outside the grant, bad input.
            let out = try await makeTask(f, project: f.other)
            let hidden = try await call(f, "update_comment", ["taskID": try out.requireID().uuidString, "commentID": cid, "version": 1, "body": "x"], access)
            XCTAssertEqual(hidden.text, "not_found")
            for args: [String: Any] in [["taskID": tid, "commentID": cid, "version": 1.5, "body": "x"], ["taskID": tid, "commentID": cid, "version": 1, "body": ""],
                                         ["taskID": tid, "commentID": "bad", "version": 1, "body": "x"], ["taskID": tid, "commentID": cid, "version": 1e40, "body": "x"]] {
                let r = try await call(f, "update_comment", args, access); XCTAssertTrue(r.isError, r.text)
            }
        }
    }

    func testDeleteCommentIsConfirmationRequest() async throws {
        try await fixture { f, access in
            let t = try await makeTask(f); let tid = try t.requireID().uuidString
            let added = try await call(f, "add_comment", ["taskID": tid, "body": "bye"], access)
            let cid = try XCTUnwrap(added.object?["id"] as? String)
            let r = try await call(f, "delete_comment", ["taskID": tid, "commentID": cid], access)
            XCTAssertEqual(r.object?["error"] as? String, "confirmation_required")
            let rid = try XCTUnwrap(r.object?["actionRequestID"] as? String)
            let stillThere = try await TaskComment.find(UUID(uuidString: cid), on: f.test.app.db); XCTAssertNotNil(stillThere)
            let confirmed = try await f.test.json(.POST, "/v1/action-requests/\(rid)/confirm", token: f.session)
            XCTAssertEqual(confirmed.body?["state"] as? String, "executed", String(describing: confirmed.body))
            let gone = try await TaskComment.find(UUID(uuidString: cid), on: f.test.app.db); XCTAssertNil(gone)
            // Stale version at request time, outside the grant, missing scope.
            let again = try await call(f, "add_comment", ["taskID": tid, "body": "v"], access)
            let stale = try await call(f, "delete_comment", ["taskID": tid, "commentID": XCTUnwrap(again.object?["id"] as? String), "version": 5], access)
            XCTAssertEqual(stale.text, "version_conflict")
            let out = try await makeTask(f, project: f.other)
            let hidden = try await call(f, "delete_comment", ["taskID": try out.requireID().uuidString, "commentID": cid], access); XCTAssertEqual(hidden.text, "not_found")
            let noScope = try await f.tokens(scope: "tasks:read")
            let denied = try await call(f, "delete_comment", ["taskID": tid, "commentID": cid], noScope.access); XCTAssertEqual(denied.text, "insufficient_scope")
        }
    }

    func testProjectCommentsLifecycle() async throws {
        try await fixture { f, access in
            let pid = try f.project.requireID().uuidString
            let added = try await call(f, "add_project_comment", ["projectID": pid, "body": "hello", "idempotencyKey": "k1"], access)
            XCTAssertFalse(added.isError, added.text)
            let cid = try XCTUnwrap(added.object?["id"] as? String)
            let replay = try await call(f, "add_project_comment", ["projectID": pid, "body": "hello", "idempotencyKey": "k1"], access)
            XCTAssertEqual(replay.object?["id"] as? String, cid)
            let clash = try await call(f, "add_project_comment", ["projectID": pid, "body": "other", "idempotencyKey": "k1"], access)
            XCTAssertEqual(clash.text, "idempotency_conflict")
            let updated = try await call(f, "update_project_comment", ["projectID": pid, "commentID": cid, "version": 1, "body": "edited"], access)
            XCTAssertEqual(updated.object?["version"] as? Int, 2)
            let stale = try await call(f, "update_project_comment", ["projectID": pid, "commentID": cid, "version": 1, "body": "x"], access)
            XCTAssertEqual(stale.text, "version_conflict")
            for i in 0..<3 { _ = try await call(f, "add_project_comment", ["projectID": pid, "body": "n\(i)"], access) }
            let listed = try await call(f, "list_project_comments", ["projectID": pid, "limit": 2], access)
            XCTAssertEqual((listed.json as? [[String: Any]])?.count, 2)
            XCTAssertEqual((listed.json as? [[String: Any]])?.last?["body"] as? String, "n2")
            let events = try await ProjectActivityEvent.query(on: f.test.app.db).all()
            XCTAssertTrue(events.contains { $0.kind == "comment.updated" && $0.actorType == .integration })
            // Delete = request, then the REST path runs.
            let del = try await call(f, "delete_project_comment", ["projectID": pid, "commentID": cid], access)
            let rid = try XCTUnwrap(del.object?["actionRequestID"] as? String)
            let kept = try await ProjectComment.find(UUID(uuidString: cid), on: f.test.app.db); XCTAssertNotNil(kept)
            let confirmed = try await f.test.json(.POST, "/v1/action-requests/\(rid)/confirm", token: f.session)
            XCTAssertEqual(confirmed.body?["state"] as? String, "executed", String(describing: confirmed.body))
            let gone = try await ProjectComment.find(UUID(uuidString: cid), on: f.test.app.db); XCTAssertNil(gone)
            // Outside the grant and malformed input.
            let other = try f.other.requireID().uuidString
            for (name, args) in [("list_project_comments", ["projectID": other]), ("add_project_comment", ["projectID": other, "body": "x"])] as [(String, [String: Any])] {
                let r = try await call(f, name, args, access); XCTAssertEqual(r.text, "not_found", name)
            }
            for args: [String: Any] in [["projectID": pid, "limit": 0], ["projectID": pid, "limit": 201], ["projectID": pid, "limit": 1e40]] {
                let r = try await call(f, "list_project_comments", args, access); XCTAssertTrue(r.isError)
            }
            let empty = try await call(f, "add_project_comment", ["projectID": pid, "body": " "], access); XCTAssertTrue(empty.isError)
        }
    }

    func testListActivityIsGrantFilteredAndPaged() async throws {
        try await fixture { f, access in
            let inside = try await makeTask(f), outside = try await makeTask(f, project: f.other)
            for t in [inside, outside] {
                for i in 0..<3 { try await ActivityEvent.append(t, kind: "task.updated", sequence: i + 1, on: f.test.app.db) }
            }
            let first = try await call(f, "list_activity", ["limit": 2], access)
            XCTAssertFalse(first.isError, first.text)
            let items = try XCTUnwrap(first.object?["items"] as? [[String: Any]])
            XCTAssertEqual(items.count, 2)
            let cursor = try XCTUnwrap(first.object?["nextCursor"] as? String)
            let second = try await call(f, "list_activity", ["limit": 10, "before": cursor], access)
            let rest = try XCTUnwrap(second.object?["items"] as? [[String: Any]])
            let all = items + rest
            XCTAssertEqual(all.count, 3)
            XCTAssertTrue(all.allSatisfy { $0["projectID"] as? String == f.project.id?.uuidString })
            XCTAssertFalse(second.text.contains("Excluded"))
            let denied = try await call(f, "list_activity", ["projectID": try f.other.requireID().uuidString], access); XCTAssertEqual(denied.text, "not_found")
            for args: [String: Any] in [["limit": 0], ["limit": 101], ["limit": 1.5], ["before": "garbage"], ["projectID": "bad"]] {
                let r = try await call(f, "list_activity", args, access); XCTAssertTrue(r.isError, "\(args)")
            }
        }
    }

    func testUploadRolesReadAttachmentRegisterBuildAndDelete() async throws {
        try await fixture { f, access in
            let t = try await makeTask(f); let tid = try t.requireID().uuidString
            let sha = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
            let base: [String: Any] = ["taskID": tid, "filename": "ref.png", "mediaType": "image/png", "size": png.count, "checksum": sha]
            let bad = try await call(f, "begin_task_upload", base.merging(["role": "other"]) { $1 }, access); XCTAssertTrue(bad.isError)
            let begin = try await call(f, "begin_task_upload", base.merging(["role": "reference"]) { $1 }, access)
            XCTAssertFalse(begin.isError, begin.text)
            let aid = try XCTUnwrap(begin.object?["attachmentID"] as? String), token = try XCTUnwrap(begin.object?["token"] as? String)
            let pendingRow = try await Attachment.find(UUID(uuidString: aid), on: f.test.app.db)
            XCTAssertEqual(pendingRow?.role, "reference")
            // Not visible before completion.
            let early = try await call(f, "read_attachment", ["id": aid], access); XCTAssertEqual(early.text, "not_found")
            try await AttachmentService(settings: f.test.settings).upload(UUID(uuidString: aid)!, token: token, data: png, db: f.test.app.db)
            let done = try await call(f, "complete_task_upload", ["attachmentID": aid], access); XCTAssertFalse(done.isError, done.text)
            let read = try await call(f, "read_attachment", ["id": aid, "preview": true], access)
            XCTAssertEqual((read.object?["preview"] as? [String: Any])?["dataBase64"] as? String, png.base64EncodedString())
            XCTAssertNil(read.object?["build"])
            let meta = try await call(f, "read_attachment", ["id": aid], access); XCTAssertNil(meta.object?["preview"])
            // register_build is idempotent and announces once.
            let reg = try await call(f, "register_build", ["attachmentID": aid, "buildID": "b1", "platform": "web"], access)
            XCTAssertFalse(reg.isError, reg.text); XCTAssertEqual(reg.object?["buildID"] as? String, "b1")
            let reg2 = try await call(f, "register_build", ["attachmentID": aid, "buildID": "b2"], access)
            XCTAssertEqual(reg2.object?["buildID"] as? String, "b1")
            let announced = try await ActivityEvent.query(on: f.test.app.db).filter(\.$kind == "build.added").count(); XCTAssertEqual(announced, 1)
            let withBuild = try await call(f, "read_attachment", ["id": aid], access)
            XCTAssertEqual((withBuild.object?["build"] as? [String: Any])?["buildID"] as? String, "b1")
            // Delete is a request; confirming hides the file and its build.
            let del = try await call(f, "delete_attachment", ["attachmentID": aid], access)
            let rid = try XCTUnwrap(del.object?["actionRequestID"] as? String)
            let stillThere = try await call(f, "read_attachment", ["id": aid], access); XCTAssertFalse(stillThere.isError)
            let confirmed = try await f.test.json(.POST, "/v1/action-requests/\(rid)/confirm", token: f.session)
            XCTAssertEqual(confirmed.body?["state"] as? String, "executed", String(describing: confirmed.body))
            let hidden = try await call(f, "read_attachment", ["id": aid], access); XCTAssertEqual(hidden.text, "not_found")
            let builds = try await call(f, "list_builds", ["taskID": tid], access); XCTAssertEqual((builds.json as? [Any])?.count, 0)
            let listed = try await call(f, "list_attachments", ["taskID": tid], access); XCTAssertEqual((listed.json as? [Any])?.count, 0)
            // Cleanup removes the bytes and the row.
            _ = try await AttachmentService(settings: f.test.settings).cleanup(db: f.test.app.db)
            let row = try await Attachment.find(UUID(uuidString: aid), on: f.test.app.db); XCTAssertNil(row)
        }
    }

    func testAttachmentToolsRespectGrantRoleAndMalformedInput() async throws {
        try await fixture { f, access in
            let out = try await makeTask(f, project: f.other)
            let sha = String(repeating: "a", count: 64)
            let begin = try await call(f, "begin_task_upload", ["taskID": try out.requireID().uuidString, "filename": "a.png", "role": "result", "mediaType": "image/png", "size": 4, "checksum": sha], access)
            XCTAssertEqual(begin.text, "not_found")
            let foreign = Attachment(); foreign.id = UUID(); foreign.taskID = try out.requireID(); foreign.ownerID = try f.user.requireID()
            foreign.filename = "x.png"; foreign.role = "result"; foreign.mediaType = "image/png"; foreign.size = 12; foreign.checksum = sha
            foreign.status = "complete"; foreign.objectKey = "k"
            try await foreign.save(on: f.test.app.db)
            let fid = try foreign.requireID().uuidString
            for (name, args) in [("read_attachment", ["id": fid]), ("delete_attachment", ["attachmentID": fid]), ("complete_task_upload", ["attachmentID": fid]),
                                 ("register_build", ["attachmentID": fid, "buildID": "b"])] as [(String, [String: Any])] {
                let r = try await call(f, name, args, access); XCTAssertEqual(r.text, "not_found", name)
            }
            let t = try await makeTask(f); let tid = try t.requireID().uuidString
            let cases: [(String, [String: Any])] = [
                ("begin_task_upload", ["taskID": tid, "filename": "a/b.png", "role": "result", "mediaType": "image/png", "size": 4, "checksum": sha]),
                ("begin_task_upload", ["taskID": tid, "filename": "a.png", "role": "result", "mediaType": "image/png", "size": 1e40, "checksum": sha]),
                ("begin_task_upload", ["taskID": tid, "filename": "a.png", "role": "result", "mediaType": "image/png", "size": 4, "checksum": "zz"]),
                ("read_attachment", ["id": "bad"]), ("read_attachment", ["id": fid, "preview": "yes"]),
                ("register_build", ["attachmentID": fid, "buildID": ""]), ("complete_task_upload", ["attachmentID": 5]), ("delete_attachment", [:])]
            for (name, args) in cases { let r = try await call(f, name, args, access); XCTAssertTrue(r.isError, name) }
            // Read-only role: the account's current role limits writes even with the scope.
            let viewer = User(displayName: "Viewer", isAdmin: false); try await viewer.save(on: f.test.app.db)
            let own = Project(ownerID: try viewer.requireID(), parentID: nil, name: "Theirs"); try await own.save(on: f.test.app.db)
            let g = try await XCTUnwrapAsync(try await OAuthGrant.query(on: f.test.app.db).first())
            g.projects.append(try own.requireID()); try await g.save(on: f.test.app.db)
            let theirs = try await makeTask(f, project: own)
            let r = try await call(f, "add_project_comment", ["projectID": try own.requireID().uuidString, "body": "x"], access); XCTAssertEqual(r.text, "not_found")
            let u = try await call(f, "begin_task_upload", ["taskID": try theirs.requireID().uuidString, "filename": "a.png", "role": "result", "mediaType": "image/png", "size": 4, "checksum": sha], access)
            XCTAssertEqual(u.text, "not_found")
        }
    }
}

private extension ActivityEvent {
    static func append(_ task: TodoTask, kind: String, sequence: Int, on db: any Database) async throws {
        let e = ActivityEvent()
        e.taskID = try task.requireID(); e.sequence = sequence; e.actorType = .person; e.actorID = task.ownerID; e.kind = kind
        try await e.save(on: db)
    }
}
