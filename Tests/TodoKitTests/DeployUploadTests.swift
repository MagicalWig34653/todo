import Fluent
import Foundation
import SQLKit
import XCTVapor
@testable import TodoKit

/// Deploy targets, phase 3 "upload to test" (card 354ADE12, ADR 0044, contracts/deploy.yaml 1.4.0): a plan, a request, the
/// approval by a person, the drift lock, the backup and the way back. The transport is the recording double; the real SFTP and
/// FTPS servers are exercised in `scripts/deploy-upload-e2e.sh`.
extension DeployTargetTests {
    static func upload(_ path: String, _ text: String) -> Obj {
        var e = entry(path, text); e["content"] = Data(text.utf8).base64EncodedString(); return e
    }

    fileprivate func target(_ f: Fixture, _ body: Obj = [:]) async throws -> String {
        var b: Obj = ["protocol": "ftps", "port": 21]
        for (k, v) in body { b[k] = v }
        let made = try await f.created(b)
        return try XCTUnwrap(made["id"] as? String)
    }

    fileprivate func call(_ f: Fixture, _ method: HTTPMethod, _ path: String, _ body: Obj? = nil, session: String? = nil) async throws
        -> (status: HTTPStatus, body: Obj, text: String) {
        let r = try await f.test.json(method, path, body, token: session ?? f.session)
        let out = r.body ?? [:]
        return (r.status, out, String(decoding: try JSONSerialization.data(withJSONObject: out), as: UTF8.self))
    }

    /// A plan that must succeed.
    fileprivate func plan(_ f: Fixture, _ target: String, _ files: [Obj], file: StaticString = #filePath, line: UInt = #line) async throws -> Obj {
        let r = try await call(f, .POST, "/v1/deploy-targets/\(target)/plans", ["files": files])
        XCTAssertEqual(r.body["ok"] as? Bool, true, r.text, file: file, line: line)
        return try XCTUnwrap(r.body["plan"] as? Obj, r.text, file: file, line: line)
    }

    fileprivate func id(_ plan: Obj) -> String { plan["id"] as? String ?? "?" }

    @discardableResult
    fileprivate func requestAndApprove(_ f: Fixture, _ plan: Obj, override: Bool = false, file: StaticString = #filePath, line: UInt = #line) async throws -> Obj {
        let requested = try await call(f, .POST, "/v1/deploy-plans/\(id(plan))/request", [:])
        XCTAssertEqual(requested.status, .ok, requested.text, file: file, line: line)
        let approved = try await call(f, .POST, "/v1/deploy-plans/\(id(plan))/approve", ["overrideDrift": override])
        XCTAssertEqual(approved.status, .ok, approved.text, file: file, line: line)
        return approved.body
    }

    fileprivate func reasons(_ plan: Obj, _ key: String = "files") -> [String: String] {
        Dictionary((plan[key] as? [Obj] ?? []).map { ($0["serverPath"] as? String ?? "?", $0["reason"] as? String ?? "?") }, uniquingKeysWith: { a, _ in a })
    }

    fileprivate func text(_ f: Fixture) -> [String: String] { f.transport.files.mapValues { String(decoding: $0, as: UTF8.self) } }

    /// A target whose server state Todolino knows: one approved upload of `files` onto an empty server.
    fileprivate func baseline(_ f: Fixture, _ files: [String: String]) async throws -> String {
        let t = try await target(f)
        f.transport.files = [:]
        let made = try await plan(f, t, files.sorted { $0.key < $1.key }.map { Self.upload($0.key, $0.value) })
        let done = try await requestAndApprove(f, made)
        XCTAssertEqual(done["state"] as? String, "succeeded", "\(done)")
        return t
    }

    func testPlanNamesMissingContentThenListsUploadsAndLocksOnUnknownServerState() async throws {
        try await fixture { f in
            let t = try await target(f)
            f.transport.files = ["index.php": Data("alt vom Server\n".utf8), "same.txt": Data("x\r\ny\r\n".utf8), "designer.html": Data("<p>Design</p>\n".utf8)]
            let manifest = [Self.entry("index.php", "neu\n"), Self.entry("same.txt", "x\ny\n"), Self.entry("neu/seite.txt", "frisch\n")]
            let first = try await call(f, .POST, "/v1/deploy-targets/\(t)/plans", ["files": manifest])
            XCTAssertEqual(first.status, .ok, first.text)
            XCTAssertEqual(first.body["ok"] as? Bool, false)
            XCTAssertEqual(first.body["code"] as? String, "deploy_plan_content_missing")
            XCTAssertEqual(first.body["missing"] as? [String], ["index.php", "neu/seite.txt"])

            let made = try await plan(f, t, [Self.upload("index.php", "neu\n"), Self.entry("same.txt", "x\ny\n"), Self.upload("neu/seite.txt", "frisch\n")])
            XCTAssertEqual(made["state"] as? String, "planned")
            XCTAssertEqual(made["kind"] as? String, "upload")
            XCTAssertEqual(reasons(made), ["index.php": "drift", "neu/seite.txt": "new"])
            XCTAssertEqual(reasons(made, "blockers"), ["index.php": "unknown_server_state"])
            XCTAssertEqual(made["blocked"] as? Bool, true)
            XCTAssertEqual(made["overridable"] as? Bool, true)
            let summary = try XCTUnwrap(made["summary"] as? Obj)
            XCTAssertEqual(summary["upload"] as? Int, 2)
            XCTAssertEqual(summary["unchanged"] as? Int, 1)
            XCTAssertEqual(summary["serverOnly"] as? Int, 1)
            XCTAssertEqual(summary["delete"] as? Int, 0)
            XCTAssertEqual(f.transport.writes, [], "a plan never writes")
            let shown = String(decoding: try JSONSerialization.data(withJSONObject: made), as: UTF8.self)
            for secret in [Self.password, "test.example.com", "\"username\"", "basePath"] { XCTAssertFalse(shown.contains(secret), secret) }
        }
    }

    func testOnlyARequestedPlanIsApprovedByAManagingPersonAndTheLockNeedsAnOverride() async throws {
        try await fixture { f in
            let t = try await target(f)
            f.transport.files = ["index.php": Data("alt\n".utf8)]
            let made = try await plan(f, t, [Self.upload("index.php", "neu\n")])
            let early = try await call(f, .POST, "/v1/deploy-plans/\(id(made))/approve", ["overrideDrift": true])
            XCTAssertEqual(early.status, .conflict)
            XCTAssertEqual(early.body["reason"] as? String, "deploy_plan_not_requested")

            let requested = try await call(f, .POST, "/v1/deploy-plans/\(id(made))/request", ["note": "bitte hochladen"])
            XCTAssertEqual(requested.body["state"] as? String, "requested", requested.text)
            XCTAssertEqual(requested.body["note"] as? String, "bitte hochladen")

            // An agent token is no person session.
            let token = try await f.mcpToken()
            let agent = try await call(f, .POST, "/v1/deploy-plans/\(id(made))/approve", ["overrideDrift": true], session: token)
            XCTAssertEqual(agent.status, .unauthorized)
            // Edit rights are not enough to write to a server.
            let person = User(displayName: "Editor", isAdmin: false)
            try await person.save(on: f.app.db)
            let editor = try person.requireID().uuidString, editorSession = AuthSupport.randomToken()
            try await UserSession(userID: person.requireID(), tokenHash: AuthSupport.hash(editorSession),
                                  expiresAt: Date().addingTimeInterval(3600)).save(on: f.app.db)
            let grant = try await call(f, .PUT, "/v1/projects/\(f.projectID)/grants", ["principalType": "person", "principalID": editor, "role": "edit"])
            XCTAssertEqual(grant.status, .ok, grant.text)
            let asEditor = try await call(f, .POST, "/v1/deploy-plans/\(id(made))/approve", ["overrideDrift": true], session: editorSession)
            XCTAssertTrue([HTTPStatus.forbidden, .notFound].contains(asEditor.status), asEditor.text)

            let locked = try await call(f, .POST, "/v1/deploy-plans/\(id(made))/approve", ["overrideDrift": false])
            XCTAssertEqual(locked.status, .conflict)
            XCTAssertEqual(locked.body["reason"] as? String, "deploy_plan_blocked")
            XCTAssertEqual(f.transport.writes, [])
            XCTAssertEqual(text(f), ["index.php": "alt\n"])

            let done = try await call(f, .POST, "/v1/deploy-plans/\(id(made))/approve", ["overrideDrift": true])
            XCTAssertEqual(done.body["state"] as? String, "succeeded", done.text)
            XCTAssertEqual(done.body["overrideDrift"] as? Bool, true)
            XCTAssertEqual(done.body["written"] as? [String], ["index.php"])
            XCTAssertEqual(done.body["canRollback"] as? Bool, true)
            XCTAssertEqual(text(f), ["index.php": "neu\n"])

            let again = try await call(f, .POST, "/v1/deploy-plans/\(id(made))/approve", ["overrideDrift": true])
            XCTAssertEqual(again.status, .conflict)
            XCTAssertEqual(f.transport.writes.count, 1)
        }
    }

    func testRejectedAndExpiredPlansNeverWrite() async throws {
        try await fixture { f in
            let t = try await target(f)
            let made = try await plan(f, t, [Self.upload("a.txt", "a\n")])
            _ = try await call(f, .POST, "/v1/deploy-plans/\(id(made))/request", [:])
            let rejected = try await call(f, .POST, "/v1/deploy-plans/\(id(made))/reject", [:])
            XCTAssertEqual(rejected.body["state"] as? String, "rejected", rejected.text)
            let approve = try await call(f, .POST, "/v1/deploy-plans/\(id(made))/approve", ["overrideDrift": false])
            XCTAssertEqual(approve.status, .conflict)

            let old = try await plan(f, t, [Self.upload("b.txt", "b\n")])
            _ = try await call(f, .POST, "/v1/deploy-plans/\(id(old))/request", [:])
            let sql = try XCTUnwrap(f.app.db as? any SQLDatabase)
            try await sql.raw("UPDATE deploy_plans SET expires_at = \(bind: Date().addingTimeInterval(-10))").run()
            let late = try await call(f, .POST, "/v1/deploy-plans/\(id(old))/approve", ["overrideDrift": false])
            XCTAssertEqual(late.status, .gone, late.text)
            XCTAssertEqual(late.body["reason"] as? String, "deploy_plan_expired")
            XCTAssertEqual(f.transport.writes, [])
        }
    }

    func testChangesOnTheServerAfterAnUploadLockTheNextPlan() async throws {
        try await fixture { f in
            let t = try await baseline(f, ["index.php": "v1\n", "gone.txt": "bleibt\n", "dropped.txt": "weg aus dem Repo\n"])
            // Unchanged server: a new repo version is not locked.
            let clean = try await plan(f, t, [Self.upload("index.php", "v2\n"), Self.entry("gone.txt", "bleibt\n")])
            XCTAssertEqual(reasons(clean), ["index.php": "changed"])
            XCTAssertEqual(clean["blocked"] as? Bool, false)
            // Someone works on the server: edits, deletes, edits a file the repo no longer has.
            f.transport.files["index.php"] = Data("Designer\n".utf8)
            f.transport.files["gone.txt"] = nil
            f.transport.files["dropped.txt"] = Data("auch geändert\n".utf8)
            let locked = try await plan(f, t, [Self.upload("index.php", "v2\n"), Self.upload("gone.txt", "bleibt\n")])
            XCTAssertEqual(reasons(locked, "blockers"), ["index.php": "server_changed", "gone.txt": "server_deleted", "dropped.txt": "server_changed"])
            XCTAssertNil(reasons(locked)["dropped.txt"], "a file that is not in the repo is never written or deleted")
            _ = try await call(f, .POST, "/v1/deploy-plans/\(id(locked))/request", [:])
            let refused = try await call(f, .POST, "/v1/deploy-plans/\(id(locked))/approve", ["overrideDrift": false])
            XCTAssertEqual(refused.body["reason"] as? String, "deploy_plan_blocked", refused.text)
            XCTAssertEqual(text(f)["index.php"], "Designer\n")
            // Once the server change is part of the repo state, nothing is locked any more.
            let pulled = try await plan(f, t, [Self.entry("index.php", "Designer\n"), Self.upload("gone.txt", "bleibt\n"), Self.entry("dropped.txt", "auch geändert\n")])
            XCTAssertEqual(reasons(pulled, "blockers"), ["gone.txt": "server_deleted"])
        }
    }

    func testAChangeBetweenPlanAndApprovalStopsTheRunBeforeTheFirstWrite() async throws {
        try await fixture { f in
            let t = try await baseline(f, ["index.php": "v1\n", "other.txt": "o\n"])
            let writes = f.transport.writes.count
            let made = try await plan(f, t, [Self.upload("index.php", "v2\n"), Self.entry("other.txt", "o\n")])
            _ = try await call(f, .POST, "/v1/deploy-plans/\(id(made))/request", [:])
            f.transport.files["index.php"] = Data("kam dazwischen\n".utf8)
            // Even with the override: the person approved what the plan showed, not what happened afterwards.
            let run = try await call(f, .POST, "/v1/deploy-plans/\(id(made))/approve", ["overrideDrift": true])
            XCTAssertEqual(run.body["state"] as? String, "failed", run.text)
            XCTAssertEqual(run.body["code"] as? String, "deploy_plan_stale")
            XCTAssertEqual(f.transport.writes.count, writes)
            XCTAssertEqual(text(f)["index.php"], "kam dazwischen\n")

            // The target changed after the request: the plan is void.
            let second = try await plan(f, t, [Self.upload("index.php", "v3\n"), Self.entry("other.txt", "o\n")])
            _ = try await call(f, .POST, "/v1/deploy-plans/\(id(second))/request", [:])
            let moved = try await call(f, .PATCH, "/v1/deploy-targets/\(t)", ["basePath": "elsewhere"])
            XCTAssertEqual(moved.status, .ok, moved.text)
            let void = try await call(f, .POST, "/v1/deploy-plans/\(id(second))/approve", ["overrideDrift": true])
            XCTAssertEqual(void.status, .conflict)
            XCTAssertEqual(void.body["reason"] as? String, "deploy_plan_stale")
            XCTAssertEqual(f.transport.writes.count, writes)
            // And the knowledge about the old place does not carry over to the new one.
            f.transport.files = ["index.php": Data("fremd\n".utf8)]
            let fresh = try await plan(f, t, [Self.upload("index.php", "v3\n")])
            XCTAssertEqual(reasons(fresh, "blockers"), ["index.php": "unknown_server_state"])
        }
    }

    func testRollbackRestoresTheBackupAndRemovesOnlyFilesTheUploadCreated() async throws {
        try await fixture { f in
            let t = try await baseline(f, ["index.php": "v1\n"])
            f.transport.files["designer.html"] = Data("bleibt immer\n".utf8)
            let made = try await plan(f, t, [Self.upload("index.php", "v2\n"), Self.upload("neu.txt", "neu\n")])
            let done = try await requestAndApprove(f, made)
            XCTAssertEqual(text(f), ["index.php": "v2\n", "neu.txt": "neu\n", "designer.html": "bleibt immer\n"])

            let back = try await call(f, .POST, "/v1/deploy-plans/\(id(done))/rollback", [:])
            XCTAssertEqual(back.body["ok"] as? Bool, true, back.text)
            let rollback = try XCTUnwrap(back.body["plan"] as? Obj)
            XCTAssertEqual(rollback["kind"] as? String, "rollback")
            XCTAssertEqual(rollback["sourcePlanID"] as? String, id(done))
            XCTAssertEqual(reasons(rollback), ["index.php": "restore", "neu.txt": "remove"])
            XCTAssertEqual(rollback["blocked"] as? Bool, false)
            XCTAssertEqual(text(f)["index.php"], "v2\n", "the way back is a plan as well: nothing happens before the approval")
            let undone = try await requestAndApprove(f, rollback)
            XCTAssertEqual(undone["state"] as? String, "succeeded", "\(undone)")
            XCTAssertEqual(text(f), ["index.php": "v1\n", "designer.html": "bleibt immer\n"])
            // The restored state is the known state again: no lock.
            let next = try await plan(f, t, [Self.upload("index.php", "v3\n")])
            XCTAssertEqual(next["blocked"] as? Bool, false, "\(next)")

            let stale = try await call(f, .POST, "/v1/deploy-plans/\(id(done))/rollback", [:])
            XCTAssertEqual(stale.status, .conflict, "only the latest run can be undone")
            XCTAssertEqual(stale.body["reason"] as? String, "deploy_rollback_not_latest")
        }
    }

    func testRollbackIsLockedWhenTheServerChangedAfterTheUploadAndOverrideKeepsAnOverwrittenForeignFileRecoverable() async throws {
        try await fixture { f in
            let t = try await target(f)
            f.transport.files = ["index.php": Data("Arbeit des Designers\n".utf8)]
            let made = try await plan(f, t, [Self.upload("index.php", "v1\n")])
            let done = try await requestAndApprove(f, made, override: true)
            f.transport.files["index.php"] = Data("danach geändert\n".utf8)
            let back = try await call(f, .POST, "/v1/deploy-plans/\(id(done))/rollback", [:])
            let rollback = try XCTUnwrap(back.body["plan"] as? Obj, back.text)
            XCTAssertEqual(reasons(rollback, "blockers"), ["index.php": "server_changed"])
            let restored = try await requestAndApprove(f, rollback, override: true)
            XCTAssertEqual(restored["state"] as? String, "succeeded", "\(restored)")
            XCTAssertEqual(text(f)["index.php"], "Arbeit des Designers\n")
            // Todolino never wrote that state itself: the next upload is locked again.
            let next = try await plan(f, t, [Self.upload("index.php", "v2\n")])
            XCTAssertEqual(reasons(next, "blockers"), ["index.php": "unknown_server_state"])
        }
    }

    func testARunThatBreaksOffRecordsWhatWasWrittenAndCanBeUndone() async throws {
        try await fixture { f in
            let t = try await baseline(f, ["a.txt": "a1\n", "b.txt": "b1\n"])
            let made = try await plan(f, t, [Self.upload("a.txt", "a2\n"), Self.upload("b.txt", "b2\n")])
            f.transport.failAfterWrites = 1
            let run = try await requestAndApprove(f, made)
            XCTAssertEqual(run["state"] as? String, "failed", "\(run)")
            XCTAssertEqual(run["code"] as? String, "deploy_unreachable")
            XCTAssertEqual(run["written"] as? [String], ["a.txt"])
            XCTAssertEqual(text(f), ["a.txt": "a2\n", "b.txt": "b1\n"])
            f.transport.failAfterWrites = nil
            let back = try await call(f, .POST, "/v1/deploy-plans/\(id(run))/rollback", [:])
            let rollback = try XCTUnwrap(back.body["plan"] as? Obj, back.text)
            XCTAssertEqual(reasons(rollback), ["a.txt": "restore"])
            XCTAssertEqual(rollback["blocked"] as? Bool, false)
            try await requestAndApprove(f, rollback)
            XCTAssertEqual(text(f), ["a.txt": "a1\n", "b.txt": "b1\n"])
        }
    }

    func testProdIsRefusedAndSecretOrExcludedFilesNeverGoUp() async throws {
        try await fixture { f in
            let prod = try await target(f, ["name": "Prod", "stage": "prod"])
            let refused = try await call(f, .POST, "/v1/deploy-targets/\(prod)/plans", ["files": [Self.upload("a.txt", "a\n")]])
            XCTAssertEqual(refused.status, .badRequest, refused.text)
            XCTAssertEqual(refused.body["reason"] as? String, "deploy_stage_not_supported")

            let t = try await target(f, ["rules": ["excludes": ["*.log"]]])
            let made = try await plan(f, t, [Self.upload("a.txt", "a\n"), Self.upload("debug.log", "x\n"), Self.upload(".env", "PASSWORD=1\n"),
                                             Self.upload(".github/workflows/x.yml", "on: push\n"), Self.upload("keys/id_rsa", "k\n"),
                                             Self.upload("a.txt.1a2b3c4d.todolino.tmp", "t\n")])
            XCTAssertEqual(Array(reasons(made).keys), ["a.txt"], "\(made)")

            _ = try await call(f, .POST, "/v1/deploy-plans/\(id(made))/request", [:])
            _ = try await call(f, .PATCH, "/v1/deploy-targets/\(t)", ["stage": "prod"])
            let late = try await call(f, .POST, "/v1/deploy-plans/\(id(made))/approve", ["overrideDrift": false])
            XCTAssertEqual(late.status, .conflict, late.text)
            XCTAssertEqual(f.transport.writes, [])
        }
    }

    func testContentIsCheckedStoredEncryptedAndDroppedAfterTheRun() async throws {
        try await fixture { f in
            let t = try await target(f)
            f.transport.files = ["index.php": Data("SERVER-INHALT-4711\n".utf8)]
            var wrong = Self.upload("index.php", "neu\n"); wrong["content"] = Data("etwas anderes\n".utf8).base64EncodedString()
            let invalid = try await call(f, .POST, "/v1/deploy-targets/\(t)/plans", ["files": [wrong]])
            XCTAssertEqual(invalid.status, .badRequest, invalid.text)
            XCTAssertEqual(invalid.body["reason"] as? String, "deploy_plan_content_invalid")

            let made = try await plan(f, t, [Self.upload("index.php", "REPO-INHALT-0815\n")])
            let sql = try XCTUnwrap(f.app.db as? any SQLDatabase)
            func stored(_ table: String) async throws -> String {
                try await sql.raw("SELECT * FROM \(unsafeRaw: table)").all().map { row in
                    row.allColumns.map { c in
                        if let d = try? row.decode(column: c, as: Data.self) { return String(decoding: d, as: UTF8.self) }
                        return (try? row.decode(column: c, as: String?.self)).flatMap { $0 } ?? ""
                    }.joined(separator: "|")
                }.joined(separator: "\n")
            }
            let planned = try await stored("deploy_blobs")
            XCTAssertFalse(planned.isEmpty)
            XCTAssertFalse(planned.contains("REPO-INHALT-0815"))
            try await requestAndApprove(f, made, override: true)
            let after = try await stored("deploy_blobs"), plans = try await stored("deploy_plans")
            for secret in ["REPO-INHALT-0815", "SERVER-INHALT-4711", Self.password] {
                XCTAssertFalse(after.contains(secret), secret)
                XCTAssertFalse(plans.contains(secret), secret)
                XCTAssertFalse(f.capture.lines.joined(separator: "\n").contains(secret), secret)
            }
            let roles = try await sql.raw("SELECT DISTINCT role FROM deploy_blobs").all().map { try $0.decode(column: "role", as: String.self) }
            XCTAssertEqual(roles, ["backup"], "the staged content is gone, the backup stays")
        }
    }

    func testALinkOnTheWayCannotBeOverridden() async throws {
        try await fixture { f in
            let t = try await target(f)
            f.transport.links = ["assets"]
            let made = try await plan(f, t, [Self.upload("assets/x.txt", "x\n"), Self.upload("ok.txt", "ok\n")])
            XCTAssertEqual(reasons(made, "blockers"), ["assets/x.txt": "symlink"])
            XCTAssertEqual(made["overridable"] as? Bool, false)
            _ = try await call(f, .POST, "/v1/deploy-plans/\(id(made))/request", [:])
            let refused = try await call(f, .POST, "/v1/deploy-plans/\(id(made))/approve", ["overrideDrift": true])
            XCTAssertEqual(refused.body["reason"] as? String, "deploy_plan_blocked", refused.text)
            // A link that appears after the plan stops the run as well.
            f.transport.links = []
            let second = try await plan(f, t, [Self.upload("assets/x.txt", "x\n")])
            _ = try await call(f, .POST, "/v1/deploy-plans/\(id(second))/request", [:])
            f.transport.links = ["assets"]
            let run = try await call(f, .POST, "/v1/deploy-plans/\(id(second))/approve", ["overrideDrift": false])
            XCTAssertEqual(run.body["code"] as? String, "deploy_symlink_in_path", run.text)
            XCTAssertEqual(f.transport.writes, [])
        }
    }

    func testOnlyOneRunPerTargetAtATime() async throws {
        try await fixture { f in
            let t = try await target(f)
            let a = try await plan(f, t, [Self.upload("a.txt", "a\n")])
            let b = try await plan(f, t, [Self.upload("b.txt", "b\n")])
            for p in [a, b] { _ = try await call(f, .POST, "/v1/deploy-plans/\(id(p))/request", [:]) }
            let gate = DeployGate()
            f.transport.beforeWrite = { await gate.arrive() }
            let app = f.test, session = f.session, firstPath = "/v1/deploy-plans/\(id(a))/approve"
            let first = Task { try await app.rawReply(.POST, firstPath, body: Data("{\"overrideDrift\":false}".utf8), token: session) }
            await gate.waitForArrival()
            let second = try await call(f, .POST, "/v1/deploy-plans/\(id(b))/approve", ["overrideDrift": false])
            XCTAssertEqual(second.status, .conflict, second.text)
            XCTAssertEqual(second.body["reason"] as? String, "deploy_target_busy")
            f.transport.beforeWrite = nil
            await gate.open()
            let done = try await first.value
            XCTAssertTrue(done.text.contains("\"state\":\"succeeded\""), done.text)
            XCTAssertEqual(f.transport.writes.count, 1)
        }
    }

    func testAgentsPlanAndRequestOverMCPAndHaveNoWayToUpload() async throws {
        try await fixture { f in
            let t = try await target(f)
            // Without projects:write the planning tools are not offered.
            let reading = try await f.o.rpc("tools/list", [:], access: try await f.mcpToken())
            let offered = ((reading.body?["result"] as? Obj)?["tools"] as? [Obj] ?? []).compactMap { $0["name"] as? String }
            XCTAssertTrue(offered.contains("get_deploy"))
            XCTAssertFalse(offered.contains("plan_deploy") || offered.contains("request_deploy"))
            let token = try await f.o.tokens(scope: CommandCenterTests.scopes + " projects:write").access
            let listed = try await f.o.rpc("tools/list", [:], access: token)
            let names = ((listed.body?["result"] as? Obj)?["tools"] as? [Obj] ?? []).compactMap { $0["name"] as? String }
            for tool in ["plan_deploy", "request_deploy", "get_deploy", "plan_deploy_rollback"] { XCTAssertTrue(names.contains(tool), tool) }
            XCTAssertFalse(names.contains { $0.contains("deploy") && ($0.contains("approve") || $0.contains("execute") || $0.contains("upload") && !$0.hasPrefix("plan")) })

            let planned = try await f.mcp(token, "plan_deploy", ["targetID": t, "ref": "abc123", "files": [Self.upload("a.txt", "a\n")]])
            XCTAssertFalse(planned.isError, planned.text)
            let plan = try XCTUnwrap(planned.json?["plan"] as? Obj, planned.text)
            let requested = try await f.mcp(token, "request_deploy", ["planID": id(plan), "note": "Karte fertig"])
            XCTAssertEqual(requested.json?["state"] as? String, "requested", requested.text)
            XCTAssertNotNil(requested.json?["requestedBy"])
            let got = try await f.mcp(token, "get_deploy", ["planID": id(plan)])
            XCTAssertEqual(got.json?["ref"] as? String, "abc123", got.text)
            for secret in [Self.password, "test.example.com"] { XCTAssertFalse((planned.text + requested.text + got.text).contains(secret), secret) }
            XCTAssertEqual(f.transport.writes, [], "asking is not uploading")
            // The person sees the request in the list of the target.
            let list = try await call(f, .GET, "/v1/deploy-targets/\(t)/plans")
            XCTAssertEqual((list.body["items"] as? [Obj] ?? []).map { $0["state"] as? String }, ["requested"], list.text)
        }
    }
}

/// Holds a run inside its first write until the test has looked at the lock.

// MARK: - Findings of the security review of the write path (28.11.2026)

extension DeployTargetTests {
    /// H1: "/" merged into one grapheme with a neighbour must not hide a ".." segment.
    func testPathsThatHideSegmentsInsideGraphemesAreRefused() async throws {
        let escape = "p\u{600}/../../\u{301}q\u{600}/../escaped.txt"
        for bad in [escape, "a\u{600}/b.txt", "a/\u{301}b.txt", "a\\\u{301}b.txt", "/\u{301}x", "x\u{600}/.git/config"] {
            XCTAssertFalse(DeployPath.isSafeRelative(bad), String(reflecting: bad))
        }
        XCTAssertFalse(DeployPath.isSafeBase("/\u{301}x"))
        for good in ["u\u{308}ber/Ärger.txt", "über/ß straße.php", ".well-known/a", "a/..b/c.."] {
            XCTAssertTrue(DeployPath.isSafeRelative(good), good)
        }
        XCTAssertEqual(DeploySecretGuard.pathReason("x\u{600}/secrets.json"), "secret_name")
        XCTAssertEqual(DeploySecretGuard.pathReason("x\u{600}/.git/config"), "blocked_path")
        try await fixture { f in
            let t = try await target(f)
            let r = try await call(f, .POST, "/v1/deploy-targets/\(t)/plans", ["files": [Self.upload(escape, "x\n")]])
            XCTAssertEqual(r.status, .badRequest, r.text)
            XCTAssertEqual(r.body["reason"] as? String, "deploy_manifest_invalid", r.text)
        }
    }

    /// M1: a run that lost its lease (closed as interrupted) must not start to write any more.
    func testARunWhoseLeaseRanOutBeforeTheFirstWriteWritesNothing() async throws {
        try await fixture { f in
            let t = try await baseline(f, ["a.txt": "a1\n"])
            let made = try await plan(f, t, [Self.upload("a.txt", "a2\n")])
            _ = try await call(f, .POST, "/v1/deploy-plans/\(id(made))/request", [:])
            let writes = f.transport.writes.count
            let gate = DeployGate()
            f.transport.beforeLinkCheck = { await gate.arrive() }
            let app = f.test, session = f.session, path = "/v1/deploy-plans/\(id(made))/approve"
            let run = Task { try await app.rawReply(.POST, path, body: Data("{\"overrideDrift\":false}".utf8), token: session) }
            await gate.waitForArrival()
            f.transport.beforeLinkCheck = nil
            let found = try await DeployPlan.find(UUID(uuidString: id(made)), on: f.app.db)
            let row = try XCTUnwrap(found)
            row.lockUntil = Date().addingTimeInterval(-1)
            try await row.save(on: f.app.db)
            let seen = try await call(f, .GET, "/v1/deploy-plans/\(id(made))")
            XCTAssertEqual(seen.body["code"] as? String, "deploy_interrupted", seen.text)
            await gate.open()
            _ = try await run.value
            XCTAssertEqual(f.transport.writes.count, writes, "a closed run wrote to the server")
            let after = try await call(f, .GET, "/v1/deploy-plans/\(id(made))")
            XCTAssertEqual(after.body["state"] as? String, "failed", after.text)
            XCTAssertEqual(after.body["code"] as? String, "deploy_interrupted", after.text)
            let blobs = try await DeployBlob.query(on: f.app.db).filter(\.$planID == row.requireID()).count()
            XCTAssertEqual(blobs, 0, "an interrupted run that never wrote keeps no content and no backup")
        }
    }

    /// M1: while the process is alive the lease is renewed, however long the server takes.
    func testALongRunKeepsItsLease() async throws {
        try await fixture { f in
            f.app.deployLease = 0.6
            let t = try await target(f)
            let made = try await plan(f, t, [Self.upload("a.txt", "a\n")])
            _ = try await call(f, .POST, "/v1/deploy-plans/\(id(made))/request", [:])
            let gate = DeployGate()
            f.transport.beforeWrite = { await gate.arrive() }
            let app = f.test, session = f.session, path = "/v1/deploy-plans/\(id(made))/approve"
            let run = Task { try await app.rawReply(.POST, path, body: Data("{\"overrideDrift\":false}".utf8), token: session) }
            await gate.waitForArrival()
            f.transport.beforeWrite = nil
            try await Task.sleep(nanoseconds: 1_600_000_000)
            let during = try await call(f, .GET, "/v1/deploy-plans/\(id(made))")
            XCTAssertEqual(during.body["state"] as? String, "running", during.text)
            await gate.open()
            let done = try await run.value
            XCTAssertTrue(done.text.contains("\"state\":\"succeeded\""), done.text)
        }
    }

    /// M2: content that looks like a secret is named and never uploaded.
    func testUploadNeverSendsContentThatLooksLikeASecret() async throws {
        try await fixture { f in
            let t = try await target(f)
            let made = try await plan(f, t, [Self.upload("ok.php", "<?php echo 1;\n"),
                                             Self.upload("inc/config.php", "<?php return ['password' => 'Geheim-4711'];\n"),
                                             Self.upload("notes.txt", "-----BEGIN RSA PRIVATE KEY-----\nabc\n")])
            XCTAssertEqual(Array(reasons(made).keys), ["ok.php"], "\(made)")
            XCTAssertEqual(reasons(made, "findings"), ["inc/config.php": "secret_content", "notes.txt": "secret_content"])
            try await requestAndApprove(f, made)
            XCTAssertEqual(f.transport.writes, [["ok.php"]])
        }
    }

    /// M3: the way back removes only files the run really created.
    func testRollbackNeverDeletesAFileTheRunDidNotCreate() async throws {
        for (foreign, blockers) in [("fremd\n", [String: String]()), ("neu\n", ["neu.txt": "unknown_server_state"])] {
            try await fixture { f in
                let t = try await target(f)
                let made = try await plan(f, t, [Self.upload("a.txt", "a\n"), Self.upload("neu.txt", "neu\n")])
                f.transport.failAfterWrites = 1
                let run = try await requestAndApprove(f, made)
                XCTAssertEqual(run["written"] as? [String], ["a.txt"], "\(run)")
                f.transport.failAfterWrites = nil
                f.transport.files["neu.txt"] = Data(foreign.utf8)   // somebody else puts a file there afterwards
                let back = try await call(f, .POST, "/v1/deploy-plans/\(id(run))/rollback", [:])
                let rollback = try XCTUnwrap(back.body["plan"] as? Obj, back.text)
                XCTAssertEqual(reasons(rollback, "blockers"), blockers, foreign)
                if blockers.isEmpty {
                    XCTAssertEqual(reasons(rollback), ["a.txt": "remove"])
                    try await requestAndApprove(f, rollback)
                    XCTAssertEqual(text(f), ["neu.txt": foreign])
                }
            }
        }
    }

    /// M4: parallel planning cannot exceed the limit of waiting plans, and only a few plans are read from servers at once.
    func testTheLimitOfWaitingPlansHoldsUnderParallelCalls() async throws {
        try await fixture { f in
            let t = try await target(f)
            for i in 0..<9 { _ = try await plan(f, t, [Self.upload("f\(i).txt", "\(i)\n")]) }
            let gate = DeployGate()
            f.transport.beforeLinkCheck = { await gate.arrive() }
            let app = f.test, session = f.session, path = "/v1/deploy-targets/\(t)/plans"
            let body = try JSONSerialization.data(withJSONObject: ["files": [Self.upload("x.txt", "x\n")]])
            let calls = (0..<2).map { _ in Task { try await app.rawReply(.POST, path, body: body, token: session) } }
            while await gate.count < 2 { try await Task.sleep(nanoseconds: 20_000_000) }
            f.transport.beforeLinkCheck = nil
            let third = try await call(f, .POST, "/v1/deploy-targets/\(t)/plans", ["files": [Self.upload("y.txt", "y\n")]])
            XCTAssertEqual(third.body["reason"] as? String, "deploy_planning_busy", third.text)
            await gate.open()
            var texts: [String] = []
            for c in calls { texts.append(try await c.value.text) }
            XCTAssertEqual(texts.filter { $0.contains("deploy_plan_limit") }.count, 1, "\(texts)")
            let waiting = try await DeployPlan.query(on: f.app.db).filter(\.$state == "planned").count()
            XCTAssertEqual(waiting, 10)
        }
    }

    /// M4: closed plans that never ran do not pile up.
    func testClosedPlansThatNeverRanArePruned() async throws {
        try await fixture { f in
            let t = try await target(f)
            for i in 0..<24 {
                let made = try await plan(f, t, [Self.upload("a.txt", "\(i)\n")])
                _ = try await call(f, .POST, "/v1/deploy-plans/\(id(made))/reject", [:])
            }
            let rows = try await DeployPlan.query(on: f.app.db).count()
            XCTAssertLessThanOrEqual(rows, 21)
        }
    }

    /// Low: a broken upload leaves no half file with a temporary name in the web root.
    func testABrokenUploadRemovesItsTemporaryFiles() async throws {
        try await fixture { f in
            let t = try await target(f)
            f.transport.files = ["fremd.1a2b3c4d.todolino.tmp": Data("nicht von diesem Lauf\n".utf8)]
            let made = try await plan(f, t, [Self.upload("a.txt", "a\n")])
            f.transport.failAfterWrites = 0
            f.transport.leftoverSuffix = ".9f8e7d6c.todolino.tmp"
            let run = try await requestAndApprove(f, made)
            XCTAssertEqual(run["state"] as? String, "failed", "\(run)")
            XCTAssertEqual(Array(f.transport.files.keys), ["fremd.1a2b3c4d.todolino.tmp"])
        }
    }

    /// Re-check N4: rclone shortens a long name before it appends the temporary suffix.
    func testABrokenUploadRemovesTheTemporaryFileOfALongName() async throws {
        try await fixture { f in
            let t = try await target(f)
            f.transport.files = [:]
            let long = "ordner/" + String(repeating: "a", count: 130) + ".txt"
            let made = try await plan(f, t, [Self.upload(long, "x\n")])
            f.transport.failAfterWrites = 0
            f.transport.leftoverSuffix = ".9f8e7d6c.todolino.tmp"
            let run = try await requestAndApprove(f, made)
            XCTAssertEqual(run["state"] as? String, "failed", "\(run)")
            XCTAssertEqual(Array(f.transport.files.keys), [])
        }
    }

    /// Re-check N3: a way back has the same backup limit as an upload, and only one planned way back per run waits.
    func testAWayBackIsBoundedAndReplacesTheEarlierPlannedOne() async throws {
        try await fixture { f in
            let t = try await target(f)
            f.transport.files = [:]
            let paths = (0..<8).map { "f\($0).txt" }
            let made = try await plan(f, t, paths.map { Self.upload($0, "\($0)\n") })
            let done = try await requestAndApprove(f, made)
            let first = try await call(f, .POST, "/v1/deploy-plans/\(id(done))/rollback", [:])
            let second = try await call(f, .POST, "/v1/deploy-plans/\(id(done))/rollback", [:])
            XCTAssertEqual(second.body["ok"] as? Bool, true, second.text)
            let waiting = try await DeployPlan.query(on: f.app.db).filter(\.$state == "planned").all()
            XCTAssertEqual(waiting.map { $0.id?.uuidString }, [(second.body["plan"] as? Obj).map { id($0) }])
            XCTAssertNotEqual((first.body["plan"] as? Obj).map { id($0) }, (second.body["plan"] as? Obj).map { id($0) })
            // The files grew on the server far beyond what a run backs up.
            for path in paths { f.transport.files[path] = Data(count: 9 * 1024 * 1024) }
            let big = try await call(f, .POST, "/v1/deploy-plans/\(id(done))/rollback", [:])
            XCTAssertEqual(big.status, .badRequest, String(big.text.prefix(300)))
            XCTAssertEqual(big.body["reason"] as? String, "deploy_plan_too_large")
        }
    }

    /// M5: a listing that is not in the Unix format cannot be checked for links, so nothing is written below it.
    func testAnFTPListingThatCannotBeCheckedIsRefusedForWriting() throws {
        let unix = "total 4\r\ndrwxr-xr-x 2 u g 4096 Nov 28 10:00 css\r\n-rw-r--r-- 1 u g 3 Nov 28 10:00 a.txt\r\n"
        XCTAssertEqual(try RcloneDeployTransport.symlinkNames(inList: unix, strict: true), [])
        let dos = "11-28-26  10:00AM       <DIR>          site\r\n"
        XCTAssertThrowsError(try RcloneDeployTransport.symlinkNames(inList: dos, strict: true))
        // Re-check N5: nothing at all is no answer either (a server that takes `-a` for a file name).
        XCTAssertThrowsError(try RcloneDeployTransport.symlinkNames(inList: "", strict: true))
        XCTAssertEqual(try RcloneDeployTransport.symlinkNames(inList: dos), [])
    }
}

actor DeployGate {
    private var arrived = false, opened = false
    private(set) var count = 0
    private var arrivals: [CheckedContinuation<Void, Never>] = [], holds: [CheckedContinuation<Void, Never>] = []
    func arrive() async {
        arrived = true; count += 1; arrivals.forEach { $0.resume() }; arrivals = []
        if !opened { await withCheckedContinuation { holds.append($0) } }
    }
    func waitForArrival() async { if !arrived { await withCheckedContinuation { arrivals.append($0) } } }
    func open() { opened = true; holds.forEach { $0.resume() }; holds = [] }
}
