import Fluent
import Foundation
import XCTest
import XCTVapor
@testable import TodoKit

/// Disable and anonymize accounts instead of deleting them (docs/VERWALTUNG.md). SQLite only.
final class AccountLockTests: XCTestCase {
    struct Fixture {
        let t: TestApp
        let admin: MailTests.Account
        let user: MailTests.Account
    }

    func fixture() async throws -> Fixture {
        let t = try await TestApp.make()
        return Fixture(t: t, admin: try await MailTests.account(t, "Root", admin: true), user: try await MailTests.account(t, "Anna Beispiel"))
    }

    func lockPath(_ id: UUID, _ action: String) -> String { "/v1/admin/users/\(id)/\(action)" }

    // MARK: Disable

    func testDisableEndsSessionsGrantsAndDevices() async throws {
        let o = try await OAuthFixture.make()
        defer { Task { await o.test.shutdown() } }
        let uid = try o.user.requireID()
        let admin = try await MailTests.account(o.test, "Root", admin: true)
        let tokens = try await o.tokens()
        let db = o.test.app.db
        let ok = try await o.rpc("tools/list", access: tokens.access)
        XCTAssertEqual(ok.status, .ok)
        let me = try await o.test.json(.GET, "/v1/me", token: o.session)
        XCTAssertEqual(me.status, .ok)

        let push = PushDevice()
        push.userID = uid; push.platform = "ios"; push.token = "tok"; push.tokenHash = "h"; push.environment = "sandbox"
        push.bundleID = "x"; push.lastSeenAt = Date()
        try await push.save(on: db)
        let device = RunnerDevice(ownerID: uid, label: "Mac", tokenHash: "dev-hash", revokedAt: nil)
        try await device.save(on: db)
        let task = TodoTask(ownerID: uid, projectID: try o.project.requireID(), title: "T")
        try await task.save(on: db)
        let binding = ProjectRunnerBinding(projectID: try o.project.requireID(), deviceID: try device.requireID(), repositoryKey: "r", label: "l")
        try await binding.save(on: db)
        let job = AgentJob(taskID: try task.requireID(), projectID: try o.project.requireID(), bindingID: try binding.requireID(),
                           requestedBy: uid, taskRevision: 1, mode: "implement", scope: "task", state: "queued", progress: "", result: nil)
        try await job.save(on: db)
        let invitation = Invitation(tokenHash: "inv", createdBy: uid, expiresAt: Date().addingTimeInterval(3600))
        try await invitation.save(on: db)

        let r = try await o.test.json(.POST, lockPath(uid, "disable"), token: admin.token)
        XCTAssertEqual(r.status, .ok)
        XCTAssertEqual(r.body?["status"] as? String, "disabled")

        let after = try await o.test.json(.GET, "/v1/me", token: o.session)
        XCTAssertEqual(after.status, .unauthorized)
        let mcp = try await o.rpc("tools/list", access: tokens.access)
        XCTAssertEqual(mcp.status, .unauthorized)
        let refreshed = try await o.refresh(tokens.refresh)
        XCTAssertNotEqual(refreshed.status, .ok)
        let sessions = try await UserSession.query(on: db).filter(\.$user.$id == uid).count()
        XCTAssertEqual(sessions, 0)
        let grants = try await OAuthGrant.query(on: db).filter(\.$userID == uid).all()
        XCTAssertFalse(grants.isEmpty); XCTAssertTrue(grants.allSatisfy(\.revoked))
        let pushRow = try await PushDevice.find(try push.requireID(), on: db)
        XCTAssertNotNil(pushRow?.revokedAt)
        let deviceRow = try await RunnerDevice.find(try device.requireID(), on: db)
        XCTAssertNotNil(deviceRow?.revokedAt)
        let jobRow = try await AgentJob.find(try job.requireID(), on: db)
        XCTAssertEqual(jobRow?.state, "cancelled")
        let invitations = try await Invitation.query(on: db).filter(\.$createdBy == uid).count()
        XCTAssertEqual(invitations, 0)

        // The data stays.
        let kept = try await TodoTask.find(try task.requireID(), on: db)
        XCTAssertEqual(kept?.title, "T")
        // Audit entry (key admin.account) without the name.
        let audit = try await o.test.json(.GET, "/v1/admin/settings/audit?key=admin.account", token: admin.token)
        XCTAssertEqual(audit.list?.count, 1)
        XCTAssertEqual(audit.list?.first?["detail"] as? String, "disabled:\(uid.uuidString.lowercased())")
    }

    func testDisabledAccountCannotSignInAndEnableRestoresIt() async throws {
        let t = try await TestApp.make(password: true)
        defer { Task { await t.shutdown() } }
        let root = try await t.register(token: "bootstrap-secret", name: "Root")
        let invite = try await t.json(.POST, "/v1/invitations", token: root.session)
        let code = try XCTUnwrap(invite.body?["token"] as? String)
        let anna = try await t.register(token: code, name: "Anna")
        let setPw = try await t.json(.POST, "/v1/me/password", ["username": "anna", "password": "correct horse battery"], token: anna.session)
        XCTAssertEqual(setPw.status, .noContent)

        let off = try await t.json(.POST, lockPath(UUID(uuidString: anna.userID)!, "disable"), token: root.session)
        XCTAssertEqual(off.status, .ok)
        let passkey = try await t.login(anna.key)
        XCTAssertEqual(passkey.status, .forbidden)
        let password = try await t.json(.POST, "/v1/auth/password/login", ["username": "anna", "password": "correct horse battery"])
        XCTAssertEqual(password.status, .forbidden); XCTAssertEqual(password.body?["reason"] as? String, "account_disabled")
        // Recovery is refused as well.
        let recovery = try await t.json(.POST, "/v1/identity/accounts/\(anna.userID)/recovery", token: root.session)
        XCTAssertEqual(recovery.status, .conflict); XCTAssertEqual(recovery.body?["reason"] as? String, "account_disabled")
        let grant = RecoveryGrant(userID: UUID(uuidString: anna.userID)!, code: "code-1", expiresAt: Date().addingTimeInterval(600))
        try await grant.save(on: t.app.db)
        let redeem = try await t.json(.POST, "/v1/identity/recovery/redeem", ["code": "code-1"])
        XCTAssertEqual(redeem.status, .forbidden); XCTAssertEqual(redeem.body?["reason"] as? String, "account_disabled")

        let on = try await t.json(.POST, lockPath(UUID(uuidString: anna.userID)!, "enable"), token: root.session)
        XCTAssertEqual(on.status, .ok); XCTAssertEqual(on.body?["status"] as? String, "active")
        let back = try await t.login(anna.key)
        XCTAssertEqual(back.status, .ok)
    }

    // MARK: Anonymize

    func testAnonymizeRemovesPersonalDataButKeepsWork() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        let db = f.t.app.db
        let uid = f.user.id
        let user = try await XCTUnwrapAsync(await User.find(uid, on: db))
        user.username = "anna"; user.passwordHash = "hash"
        try await user.save(on: db)
        try await PasskeyCredential(userID: uid, credentialID: "c1", publicKey: "k", signCount: 0, name: "Laptop").save(on: db)
        let mail = UserEmail(); mail.userID = uid; mail.email = "anna@example.org"; mail.verifiedAt = Date()
        try await mail.save(on: db)

        // Shared project owned by Anna with a task and a comment; Root is a team member next to her.
        let project = Project(ownerID: uid, parentID: nil, name: "Annas Projekt")
        try await project.save(on: db)
        let task = TodoTask(ownerID: uid, projectID: try project.requireID(), title: "Bleibt")
        try await task.save(on: db)
        let comment = TaskComment(taskID: try task.requireID(), authorID: uid, body: "Kommentar bleibt")
        try await comment.save(on: db)
        let team = try await f.t.json(.POST, "/v1/teams", ["name": "Team"], token: f.user.token)
        let teamID = try XCTUnwrap(team.body?["id"] as? String)
        _ = try await f.t.json(.PUT, "/v1/teams/\(teamID)/members", ["userID": f.admin.id.uuidString, "isAdmin": false], token: f.user.token)
        let accepted = try await f.t.json(.POST, "/v1/teams/\(teamID)/accept", token: f.admin.token)
        XCTAssertEqual(accepted.status, .noContent)
        let shared = try await f.t.json(.PUT, "/v1/projects/\(try project.requireID())/grants",
            ["principalType": "person", "principalID": f.admin.id.uuidString, "role": "read"], token: f.user.token)
        XCTAssertEqual(shared.status, .ok)

        let r = try await f.t.json(.POST, lockPath(uid, "anonymize"), token: f.admin.token)
        XCTAssertEqual(r.status, .ok)
        XCTAssertEqual(r.body?["status"] as? String, "anonymized")
        XCTAssertEqual(r.body?["displayName"] as? String, "Ehemaliges Mitglied")
        XCTAssertNil(r.body?["username"] as? String)

        let row = try await XCTUnwrapAsync(await User.find(uid, on: db))
        XCTAssertEqual(row.displayName, AccountLock.placeholderName)
        XCTAssertNil(row.username); XCTAssertNil(row.passwordHash); XCTAssertNotNil(row.anonymizedAt); XCTAssertNotNil(row.disabledAt)
        let passkeys = try await PasskeyCredential.query(on: db).filter(\.$user.$id == uid).count()
        XCTAssertEqual(passkeys, 0)
        let emails = try await UserEmail.query(on: db).filter(\.$userID == uid).count()
        XCTAssertEqual(emails, 0)
        // Work stays.
        let keptProject = try await Project.find(try project.requireID(), on: db)
        XCTAssertEqual(keptProject?.name, "Annas Projekt")
        let keptTask = try await TodoTask.find(try task.requireID(), on: db)
        XCTAssertEqual(keptTask?.title, "Bleibt")
        // Lists show the placeholder, never the old name.
        let comments = try await f.t.json(.GET, "/v1/tasks/\(try task.requireID())/comments", token: f.admin.token)
        let text = String(decoding: try JSONSerialization.data(withJSONObject: comments.list ?? comments.body ?? [:]), as: UTF8.self)
        XCTAssertTrue(text.contains("Kommentar bleibt"))
        XCTAssertFalse(text.contains("Anna"))
        let members = try await f.t.json(.GET, "/v1/teams/\(teamID)/members", token: f.admin.token)
        let membersText = String(decoding: try JSONSerialization.data(withJSONObject: members.list ?? []), as: UTF8.self)
        XCTAssertTrue(membersText.contains("Ehemaliges Mitglied")); XCTAssertFalse(membersText.contains("Anna"))
        let users = try await f.t.json(.GET, "/v1/admin/users", token: f.admin.token)
        let usersText = String(decoding: try JSONSerialization.data(withJSONObject: users.list ?? []), as: UTF8.self)
        XCTAssertFalse(usersText.contains("Anna")); XCTAssertFalse(usersText.contains("\"anna\""))
        let search = try await f.t.json(.GET, "/v1/users/search?q=ehemalig", token: f.admin.token)
        XCTAssertEqual(search.list?.count, 0)

        // Irreversible, idempotent, and the account can no longer be granted anything.
        let enable = try await f.t.json(.POST, lockPath(uid, "enable"), token: f.admin.token)
        XCTAssertEqual(enable.status, .conflict); XCTAssertEqual(enable.body?["reason"] as? String, "account_anonymized")
        let again = try await f.t.json(.POST, lockPath(uid, "anonymize"), token: f.admin.token)
        XCTAssertEqual(again.status, .ok)
        let invite = try await f.t.json(.PUT, "/v1/teams/\(teamID)/members", ["userID": uid.uuidString, "isAdmin": false], token: f.admin.token)
        XCTAssertNotEqual(invite.status, .ok)
    }

    // MARK: Protection and rights

    func testLastAdminAndSelfAreProtected() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        for action in ["disable", "anonymize"] {
            let own = try await f.t.json(.POST, lockPath(f.admin.id, action), token: f.admin.token)
            XCTAssertEqual(own.status, .conflict, action); XCTAssertEqual(own.body?["reason"] as? String, "cannot_lock_self")
        }
        // A second admin may lock the first; then the second is the last one and is protected.
        let promote = try await f.t.json(.PUT, "/v1/admin/users/\(f.user.id)/admin", ["isAdmin": true], token: f.admin.token)
        XCTAssertEqual(promote.status, .ok)
        let lockFirst = try await f.t.json(.POST, lockPath(f.admin.id, "disable"), token: f.user.token)
        XCTAssertEqual(lockFirst.status, .ok)
        // The self-service route refuses the last administrator too.
        let selfLock = try await f.t.json(.POST, "/v1/me/anonymize", ["confirm": "ANONYMIZE"], token: f.user.token)
        XCTAssertEqual(selfLock.status, .conflict); XCTAssertEqual(selfLock.body?["reason"] as? String, "last_admin_required")
        // Demoting is also impossible for the last active admin.
        let demote = try await f.t.json(.PUT, "/v1/admin/users/\(f.user.id)/admin", ["isAdmin": false], token: f.user.token)
        XCTAssertEqual(demote.status, .conflict)
        // Enabling the first restores the choice.
        let enable = try await f.t.json(.POST, lockPath(f.admin.id, "enable"), token: f.user.token)
        XCTAssertEqual(enable.status, .ok)
        let ok = try await f.t.json(.POST, "/v1/me/anonymize", ["confirm": "ANONYMIZE"], token: f.user.token)
        XCTAssertEqual(ok.status, .noContent)
    }

    func testOnlyAdminsMayLockAccounts() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        for action in ["disable", "enable", "anonymize"] {
            let anon = try await f.t.json(.POST, lockPath(f.admin.id, action))
            XCTAssertEqual(anon.status, .unauthorized, action)
            let user = try await f.t.json(.POST, lockPath(f.admin.id, action), token: f.user.token)
            XCTAssertEqual(user.status, .forbidden, action)
        }
        let unknown = try await f.t.json(.POST, lockPath(UUID(), "disable"), token: f.admin.token)
        XCTAssertEqual(unknown.status, .notFound)
        let still = try await User.find(f.admin.id, on: f.t.app.db)
        XCTAssertNil(still?.disabledAt)
    }

    // MARK: Self service and export

    func testSelfServiceNeedsExplicitConfirmation() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        for body in [nil, [:], ["confirm": "yes"], ["confirm": "anonymize"]] as [[String: Any]?] {
            let r = try await f.t.json(.POST, "/v1/me/anonymize", body, token: f.user.token)
            XCTAssertEqual(r.status, .badRequest, "\(String(describing: body))")
        }
        let untouched = try await User.find(f.user.id, on: f.t.app.db)
        XCTAssertNil(untouched?.disabledAt)
        let anon = try await f.t.json(.POST, "/v1/me/anonymize", ["confirm": "ANONYMIZE"])
        XCTAssertEqual(anon.status, .unauthorized)
        let done = try await f.t.json(.POST, "/v1/me/anonymize", ["confirm": "ANONYMIZE"], token: f.user.token)
        XCTAssertEqual(done.status, .noContent)
        let session = try await f.t.json(.GET, "/v1/me", token: f.user.token)
        XCTAssertEqual(session.status, .unauthorized)
        let row = try await User.find(f.user.id, on: f.t.app.db)
        XCTAssertEqual(row?.displayName, "Ehemaliges Mitglied"); XCTAssertNotNil(row?.anonymizedAt)
    }

    func testExportContainsOnlyOwnDataAndNoSecrets() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        let db = f.t.app.db
        let user = try await XCTUnwrapAsync(await User.find(f.user.id, on: db))
        user.passwordHash = "SECRET-HASH"; try await user.save(on: db)
        let mine = Project(ownerID: f.user.id, parentID: nil, name: "Meins")
        let theirs = Project(ownerID: f.admin.id, parentID: nil, name: "Fremd")
        try await mine.save(on: db); try await theirs.save(on: db)
        let myTask = TodoTask(ownerID: f.user.id, projectID: try mine.requireID(), title: "Meine Aufgabe")
        let foreignTask = TodoTask(ownerID: f.admin.id, projectID: try theirs.requireID(), title: "Fremde Aufgabe")
        try await myTask.save(on: db); try await foreignTask.save(on: db)
        try await TaskComment(taskID: try foreignTask.requireID(), authorID: f.user.id, body: "Mein Kommentar").save(on: db)
        try await TaskComment(taskID: try foreignTask.requireID(), authorID: f.admin.id, body: "Fremder Kommentar").save(on: db)
        try await DiscoveryLabel(ownerID: f.user.id, name: "mein-label").save(on: db)
        try await DiscoveryLabel(ownerID: f.admin.id, name: "fremd-label").save(on: db)
        try await PasskeyCredential(userID: f.user.id, credentialID: "CRED-ID", publicKey: "PUB-KEY", signCount: 0, name: "x").save(on: db)

        let anon = try await f.t.json(.GET, "/v1/me/export")
        XCTAssertEqual(anon.status, .unauthorized)
        try await f.t.app.test(.GET, "/v1/me/export", beforeRequest: { $0.headers.bearerAuthorization = .init(token: f.user.token) }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
            XCTAssertTrue(res.headers.first(name: .contentDisposition)?.contains("todolino-export.json") == true)
            let text = String(decoding: res.body.readableBytesView, as: UTF8.self)
            for expected in ["Meins", "Meine Aufgabe", "Mein Kommentar", "mein-label", "Anna Beispiel"] { XCTAssertTrue(text.contains(expected), expected) }
            for forbidden in ["Fremd", "Fremder", "fremd-label", "SECRET-HASH", "CRED-ID", "PUB-KEY", "Root", "passwordHash", f.user.token] {
                XCTAssertFalse(text.contains(forbidden), forbidden)
            }
        })
    }
}

func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let v = try await value()
    return try XCTUnwrap(v, file: file, line: line)
}
