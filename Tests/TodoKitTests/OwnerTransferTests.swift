import Fluent
import Foundation
import XCTest
import XCTVapor
@testable import TodoKit

/// Admin hands over the projects of a locked or anonymized account (docs/VERWALTUNG.md). SQLite only.
final class OwnerTransferTests: XCTestCase {
    struct Fixture {
        let t: TestApp
        let admin: MailTests.Account
        let old: MailTests.Account
        let target: MailTests.Account
        let other: MailTests.Account
        let parent: Project
        let child: Project
        let foreignChild: Project
    }

    func fixture() async throws -> Fixture {
        let t = try await TestApp.make()
        let admin = try await MailTests.account(t, "Root", admin: true)
        let old = try await MailTests.account(t, "Anna Alt")
        let target = try await MailTests.account(t, "Carl Neu")
        let other = try await MailTests.account(t, "Dora Fremd")
        let db = t.app.db
        let parent = Project(ownerID: old.id, parentID: nil, name: "Annas Projekt"); try await parent.save(on: db)
        let child = Project(ownerID: old.id, parentID: try parent.requireID(), name: "Annas Unterprojekt"); try await child.save(on: db)
        let foreign = Project(ownerID: other.id, parentID: try parent.requireID(), name: "Doras Kind"); try await foreign.save(on: db)
        try await TodoTask(ownerID: old.id, projectID: try parent.requireID(), title: "A").save(on: db)
        try await TodoTask(ownerID: old.id, projectID: try parent.requireID(), title: "B").save(on: db)
        return Fixture(t: t, admin: admin, old: old, target: target, other: other, parent: parent, child: child, foreignChild: foreign)
    }

    func lock(_ f: Fixture, _ action: String = "disable") async throws {
        let r = try await f.t.json(.POST, "/v1/admin/users/\(f.old.id)/\(action)", token: f.admin.token)
        XCTAssertEqual(r.status, .ok)
    }

    func transfer(_ f: Fixture, type: String, id: UUID, projectIDs: [UUID]? = nil, token: String? = nil) async throws
        -> (status: HTTPStatus, body: [String: Any]?, list: [[String: Any]]?, cookie: String?) {
        var body: [String: Any] = ["to": ["type": type, "id": id.uuidString]]
        if let projectIDs { body["projectIDs"] = projectIDs.map(\.uuidString) }
        return try await f.t.json(.POST, "/v1/admin/users/\(f.old.id)/transfer-projects", body, token: token ?? f.admin.token)
    }

    func owner(_ f: Fixture, _ project: Project) async throws -> (String, UUID) {
        let row = try await ProjectSharing.query(on: f.t.app.db).filter(\.$projectID == project.requireID()).first()
        return (row?.ownerType ?? "person", row?.ownerID ?? project.ownerID)
    }

    func testListShowsOwnedProjectsOnlyForLockedAccounts() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        let early = try await f.t.json(.GET, "/v1/admin/users/\(f.old.id)/projects", token: f.admin.token)
        XCTAssertEqual(early.status, .conflict); XCTAssertEqual(early.body?["reason"] as? String, "account_not_disabled")
        try await lock(f)
        let r = try await f.t.json(.GET, "/v1/admin/users/\(f.old.id)/projects", token: f.admin.token)
        XCTAssertEqual(r.status, .ok)
        let rows = try XCTUnwrap(r.list)
        XCTAssertEqual(Set(rows.compactMap { $0["id"] as? String }), [try f.parent.requireID().uuidString, try f.child.requireID().uuidString])
        let parentRow = try XCTUnwrap(rows.first { $0["id"] as? String == (try? f.parent.requireID().uuidString) })
        XCTAssertEqual(parentRow["name"] as? String, "Annas Projekt"); XCTAssertEqual(parentRow["taskCount"] as? Int, 2)
        let childRow = try XCTUnwrap(rows.first { $0["id"] as? String == (try? f.child.requireID().uuidString) })
        XCTAssertEqual(childRow["parentID"] as? String, try f.parent.requireID().uuidString)
        XCTAssertEqual(childRow["parentName"] as? String, "Annas Projekt")
        // The user list reports how many projects a locked account still owns.
        let users = try await f.t.json(.GET, "/v1/admin/users", token: f.admin.token)
        let anna = try XCTUnwrap(users.list?.first { $0["id"] as? String == f.old.id.uuidString })
        XCTAssertEqual(anna["ownedProjects"] as? Int, 2)
    }

    func testTransferToPersonKeepsGrantsAndForeignChildren() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        let db = f.t.app.db
        let grant = ProjectGrant(projectID: try f.parent.requireID(), principalType: "person", principalID: f.other.id, role: .read)
        try await grant.save(on: db)
        try await lock(f, "anonymize")
        let r = try await transfer(f, type: "person", id: f.target.id)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
        XCTAssertEqual(r.body?["transferred"] as? Int, 2)
        let p = try await owner(f, f.parent), c = try await owner(f, f.child), x = try await owner(f, f.foreignChild)
        XCTAssertTrue(p == ("person", f.target.id)); XCTAssertTrue(c == ("person", f.target.id))
        XCTAssertTrue(x == ("person", f.other.id))
        let grants = try await ProjectGrant.query(on: db).filter(\.$projectID == f.parent.requireID()).all()
        XCTAssertEqual(grants.count, 1); XCTAssertEqual(grants.first?.principalID, f.other.id); XCTAssertEqual(grants.first?.role, .read)
        // The new owner sees the project, the locked account stays locked.
        let vis = try await f.t.json(.GET, "/v1/projects/\(try f.parent.requireID())/visibility", token: f.target.token)
        XCTAssertEqual(vis.body?["canTransferOwnership"] as? Bool, true)
        let old = try await XCTUnwrapAsync(await User.find(f.old.id, on: db))
        XCTAssertNotNil(old.disabledAt)
        // Nothing left to transfer.
        let list = try await f.t.json(.GET, "/v1/admin/users/\(f.old.id)/projects", token: f.admin.token)
        XCTAssertEqual(list.list?.count, 0)
        // Audit entry.
        let audit = try await f.t.json(.GET, "/v1/admin/settings/audit?key=admin.transfer", token: f.admin.token)
        XCTAssertEqual(audit.list?.count, 1)
        XCTAssertTrue((audit.list?.first?["detail"] as? String ?? "").contains(f.old.id.uuidString.lowercased()))
    }

    func testChildIsTakenWithParentButSelectionCanLimit() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        try await lock(f)
        let onlyChild = try await transfer(f, type: "person", id: f.target.id, projectIDs: [try f.child.requireID()])
        XCTAssertEqual(onlyChild.status, .ok); XCTAssertEqual(onlyChild.body?["transferred"] as? Int, 1)
        let p = try await owner(f, f.parent), c = try await owner(f, f.child)
        XCTAssertTrue(p == ("person", f.old.id)); XCTAssertTrue(c == ("person", f.target.id))
        // Not owned by the locked account -> refused.
        let foreign = try await transfer(f, type: "person", id: f.target.id, projectIDs: [try f.foreignChild.requireID()])
        XCTAssertEqual(foreign.status, .conflict); XCTAssertEqual(foreign.body?["reason"] as? String, "project_not_owned")
        // Parent selected: its remaining owned children follow.
        let rest = try await transfer(f, type: "person", id: f.target.id, projectIDs: [try f.parent.requireID()])
        XCTAssertEqual(rest.status, .ok); XCTAssertEqual(rest.body?["transferred"] as? Int, 1)
        let after = try await owner(f, f.parent), foreignOwner = try await owner(f, f.foreignChild)
        XCTAssertTrue(after == ("person", f.target.id)); XCTAssertTrue(foreignOwner == ("person", f.other.id))
    }

    func testSelectedParentTakesOwnedChild() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        try await lock(f)
        let r = try await transfer(f, type: "person", id: f.target.id, projectIDs: [try f.parent.requireID()])
        XCTAssertEqual(r.status, .ok); XCTAssertEqual(r.body?["transferred"] as? Int, 2)
        let c = try await owner(f, f.child)
        XCTAssertTrue(c == ("person", f.target.id))
    }

    func testTransferToTeamNeedsActiveAdmin() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        let team = try await f.t.json(.POST, "/v1/teams", ["name": "Neues Team"], token: f.target.token)
        let teamID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(team.body?["id"] as? String)))
        // A team whose only administrator is the account that gets locked.
        let dead = try await f.t.json(.POST, "/v1/teams", ["name": "Altes Team"], token: f.old.token)
        let deadID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(dead.body?["id"] as? String)))
        try await lock(f)
        let refused = try await transfer(f, type: "team", id: deadID)
        XCTAssertEqual(refused.status, .conflict); XCTAssertEqual(refused.body?["reason"] as? String, "team_without_active_admin")
        let ok = try await transfer(f, type: "team", id: teamID)
        XCTAssertEqual(ok.status, .ok, "\(ok.body ?? [:])")
        let p = try await owner(f, f.parent)
        XCTAssertTrue(p == ("team", teamID))
        let teams = try await f.t.json(.GET, "/v1/admin/teams", token: f.admin.token)
        XCTAssertTrue((teams.list ?? []).contains { $0["id"] as? String == teamID.uuidString && $0["name"] as? String == "Neues Team" })
        XCTAssertFalse((teams.list ?? []).contains { $0["id"] as? String == deadID.uuidString })
    }

    func testRefusals() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        // Not locked -> 409.
        let early = try await transfer(f, type: "person", id: f.target.id)
        XCTAssertEqual(early.status, .conflict); XCTAssertEqual(early.body?["reason"] as? String, "account_not_disabled")
        try await lock(f)
        // Only administrators.
        let denied = try await transfer(f, type: "person", id: f.target.id, token: f.target.token)
        XCTAssertEqual(denied.status, .forbidden)
        let deniedList = try await f.t.json(.GET, "/v1/admin/users/\(f.old.id)/projects", token: f.target.token)
        XCTAssertEqual(deniedList.status, .forbidden)
        // Locked target.
        let locked = try await f.t.json(.POST, "/v1/admin/users/\(f.other.id)/disable", token: f.admin.token)
        XCTAssertEqual(locked.status, .ok)
        let toLocked = try await transfer(f, type: "person", id: f.other.id)
        XCTAssertEqual(toLocked.status, .conflict); XCTAssertEqual(toLocked.body?["reason"] as? String, "transfer_target_disabled")
        // Unknown target and invalid type.
        let unknown = try await transfer(f, type: "person", id: UUID())
        XCTAssertEqual(unknown.status, .notFound)
        let badType = try await transfer(f, type: "group", id: f.target.id)
        XCTAssertEqual(badType.status, .badRequest)
        let p = try await owner(f, f.parent)
        XCTAssertTrue(p == ("person", f.old.id))
    }

    func testRunnerBindingAndOpenJobsOfOldOwnerAreRevoked() async throws {
        let f = try await fixture(); defer { Task { await f.t.shutdown() } }
        let db = f.t.app.db
        let task = TodoTask(ownerID: f.old.id, projectID: try f.parent.requireID(), title: "Job"); try await task.save(on: db)
        let device = RunnerDevice(ownerID: f.old.id, label: "Mac", tokenHash: "h", revokedAt: nil); try await device.save(on: db)
        let binding = ProjectRunnerBinding(projectID: try f.parent.requireID(), deviceID: try device.requireID(), repositoryKey: "r", label: "l")
        try await binding.save(on: db)
        let job = AgentJob(taskID: try task.requireID(), projectID: try f.parent.requireID(), bindingID: try binding.requireID(),
                           requestedBy: f.old.id, taskRevision: 1, mode: "implement", scope: "task", state: "queued", progress: "", result: nil)
        try await job.save(on: db)
        // Directly assigned (locking would already cancel the job), so the transfer itself must do it.
        let old = try await XCTUnwrapAsync(await User.find(f.old.id, on: db))
        old.disabledAt = Date(); try await old.save(on: db)
        let r = try await transfer(f, type: "person", id: f.target.id)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
        let jobRow = try await AgentJob.find(try job.requireID(), on: db)
        XCTAssertEqual(jobRow?.state, "cancelled")
        let bindingRow = try await ProjectRunnerBinding.find(try binding.requireID(), on: db)
        XCTAssertNotNil(bindingRow) // history stays as an inert row
    }
}
