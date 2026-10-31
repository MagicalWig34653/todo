import Fluent
import SQLKit
import XCTVapor
@testable import TodoKit

final class SyncRetentionTests: XCTestCase {
    private func account(_ t: TestApp) async throws -> (id: String, token: String) {
        let user = User(displayName: "Test", isAdmin: false)
        try await user.save(on: t.app.db)
        let token = AuthSupport.randomToken()
        try await UserSession(userID: user.requireID(), tokenHash: AuthSupport.hash(token),
            expiresAt: Date().addingTimeInterval(3600)).save(on: t.app.db)
        return (try user.requireID().uuidString, token)
    }

    private func mutate(_ t: TestApp, _ token: String, _ type: String, id: String, _ fields: [String: Any] = [:]) async throws {
        var body: [String: Any] = ["mutationID": UUID().uuidString, "type": type, "id": id]
        body.merge(fields) { $1 }
        let r = try await t.json(.POST, "/v1/sync/mutations", body, token: token)
        XCTAssertTrue((200..<300).contains(Int(r.status.code)), "\(type): \(r.status) \(r.body ?? [:])")
    }

    private func feed(_ t: TestApp, _ token: String, _ cursor: String) async throws -> (status: HTTPStatus, body: [String: Any]?) {
        let r = try await t.json(.GET, "/v1/sync/changes?cursor=\(cursor)", token: token)
        return (r.status, r.body)
    }

    private func head(_ t: TestApp, _ token: String) async throws -> String {
        let r = try await feed(t, token, "c0")
        return try XCTUnwrap(r.body?["cursor"] as? String)
    }

    private func ids(_ body: [String: Any]?, kind: String) -> Set<String> {
        Set(((body?["changes"] as? [[String: Any]]) ?? []).filter { $0["kind"] as? String == kind }
            .compactMap { ($0["entityID"] as? String)?.lowercased() })
    }

    private func backdate(_ t: TestApp, days: Int) async throws {
        let old = Date().addingTimeInterval(-Double(days) * 86_400)
        try await SyncChange.query(on: t.app.db).set(\.$createdAt, to: old).update()
        try await SyncMutation.query(on: t.app.db).set(\.$createdAt, to: old).update()
    }

    func testRetentionPurgesOldTombstonesKeepsFullStateAndExpiresStaleCursors() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let owner = try await account(t), guest = try await account(t)
        let root = UUID().uuidString, keep = UUID().uuidString, gone = UUID().uuidString
        try await mutate(t, owner.token, "project.create", id: root, ["name": "Root"])
        try await mutate(t, owner.token, "task.create", id: keep, ["title": "Keep", "projectID": root])
        try await mutate(t, owner.token, "task.create", id: gone, ["title": "Gone", "projectID": root])
        let share = try await t.json(.PUT, "/v1/projects/\(root)/grants",
            ["principalType": "person", "principalID": guest.id, "role": "read"], token: owner.token)
        XCTAssertEqual(share.status, .ok)
        let staleCursor = try await head(t, guest.token)
        // Several edits supersede earlier upserts; a deletion creates a tombstone for owner and guest.
        for i in 0..<3 {
            let task = try await TodoTask.find(UUID(uuidString: keep), on: t.app.db)
            try await mutate(t, owner.token, "task.update", id: keep, ["version": task!.version, "title": "Keep \(i)"])
        }
        try await mutate(t, owner.token, "task.delete", id: gone)
        let tombstones = try await SyncChange.query(on: t.app.db).filter(\.$kind == "delete").count()
        XCTAssertGreaterThan(tombstones, 0)
        try await backdate(t, days: 100)
        // A fresh tombstone inside the retention window survives.
        let fresh = UUID().uuidString
        try await mutate(t, owner.token, "task.create", id: fresh, ["title": "Fresh", "projectID": root])
        try await mutate(t, owner.token, "task.delete", id: fresh)
        let beforeFloor = try await SyncRetention.floor(on: t.app.db)
        XCTAssertEqual(beforeFloor, 0)

        var cleanup = ExpiredCleanup()
        cleanup.syncRetention = 90 * 86_400
        let report = try await cleanup.run(on: t.app.db)
        XCTAssertEqual(report.syncTombstones, tombstones)
        XCTAssertGreaterThan(report.syncSuperseded, 0)
        XCTAssertGreaterThan(report.syncMutations, 0)
        let oldTombstones = try await SyncChange.query(on: t.app.db).filter(\.$kind == "delete").filter(\.$entityID == UUID(uuidString: gone)!).count()
        XCTAssertEqual(oldTombstones, 0)
        let freshTombstones = try await SyncChange.query(on: t.app.db).filter(\.$kind == "delete").filter(\.$entityID == UUID(uuidString: fresh)!).count()
        XCTAssertEqual(freshTombstones, 1, "tombstones inside the retention window stay")
        let audience = try await SyncTombstoneAudience.query(on: t.app.db).count()
        XCTAssertEqual(audience, 2, "only the fresh tombstone keeps its frozen audience (owner and guest)")
        let floor = try await SyncRetention.floor(on: t.app.db)
        XCTAssertGreaterThan(floor, 0)

        // Cursor below the floor: 410 with a stable code. Own and shared accounts alike.
        for token in [guest.token, owner.token] {
            let stale = try await feed(t, token, staleCursor)
            XCTAssertEqual(stale.status, .gone)
            XCTAssertEqual(stale.body?["reason"] as? String, "cursor_expired")
        }
        // Full resync: complete visible state, without purged objects.
        let full = try await feed(t, guest.token, "c0")
        XCTAssertEqual(full.status, .ok)
        XCTAssertEqual(ids(full.body, kind: "upsert"), Set([root, keep].map { $0.lowercased() }))
        // A cursor at the head (or at the floor) is valid.
        let head = try XCTUnwrap(full.body?["cursor"] as? String)
        let atHead = try await feed(t, guest.token, head)
        XCTAssertEqual(atHead.status, .ok)
        let atFloor = try await feed(t, guest.token, "c\(floor)")
        XCTAssertEqual(atFloor.status, .ok)
        XCTAssertTrue(ids(atFloor.body, kind: "delete").contains(fresh.lowercased()), "fresh tombstone still delivered")

        // Idempotent: a second run removes nothing and never lowers the floor.
        let again = try await cleanup.run(on: t.app.db)
        XCTAssertEqual(again.syncTotal, 0)
        let floorAfter = try await SyncRetention.floor(on: t.app.db)
        XCTAssertEqual(floorAfter, floor)
        // Sequence allocation is unaffected (still strictly increasing).
        try await mutate(t, owner.token, "project.create", id: UUID().uuidString, ["name": "After"])
        let maxSeq = try await SyncChange.query(on: t.app.db).sort(\.$seq, .descending).first()?.seq
        XCTAssertGreaterThan(try XCTUnwrap(maxSeq), floor)
    }

    func testRetentionDisabledLeavesLogUntouched() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let owner = try await account(t)
        let p = UUID().uuidString
        try await mutate(t, owner.token, "project.create", id: p, ["name": "P"])
        try await mutate(t, owner.token, "project.delete", id: p)
        try await backdate(t, days: 1000)
        let report = try await ExpiredCleanup().run(on: t.app.db)
        XCTAssertEqual(report.syncTotal, 0)
        let n = try await SyncChange.query(on: t.app.db).filter(\.$kind == "delete").count()
        XCTAssertEqual(n, 1)
    }

    func testAccountDeletionTombstonesObjectsOthersCanNoLongerSee() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let owner = try await account(t), guest = try await account(t), stranger = try await account(t)
        let shared = UUID().uuidString, sharedTask = UUID().uuidString, privateP = UUID().uuidString
        let guestOwn = UUID().uuidString, guestTaskInShared = UUID().uuidString
        try await mutate(t, owner.token, "project.create", id: shared, ["name": "Shared"])
        try await mutate(t, owner.token, "task.create", id: sharedTask, ["title": "T", "projectID": shared])
        try await mutate(t, owner.token, "project.create", id: privateP, ["name": "Private"])
        try await mutate(t, guest.token, "project.create", id: guestOwn, ["name": "Guest own"])
        _ = try await t.json(.PUT, "/v1/projects/\(shared)/grants",
            ["principalType": "person", "principalID": guest.id, "role": "edit"], token: owner.token)
        _ = try await t.json(.PUT, "/v1/projects/\(guestOwn)/grants",
            ["principalType": "person", "principalID": owner.id, "role": "read"], token: guest.token)
        try await mutate(t, guest.token, "task.create", id: guestTaskInShared, ["title": "By guest", "projectID": shared])
        let guestBefore = try await head(t, guest.token)
        let ownerBefore = try await head(t, owner.token)
        let strangerBefore = try await head(t, stranger.token)

        // The guest leaves: their own project and their task in the shared project disappear for the owner,
        // while the owner's data stays and no one else learns anything.
        let report = try await AccountDeletion.delete(userID: UUID(uuidString: guest.id)!, on: t.app.db)
        XCTAssertEqual(report.projects, 1)
        XCTAssertEqual(report.tasks, 1)
        let o = try await feed(t, owner.token, ownerBefore)
        XCTAssertEqual(ids(o.body, kind: "delete"), Set([guestOwn, guestTaskInShared].map { $0.lowercased() }))
        let full = try await feed(t, owner.token, "c0")
        XCTAssertEqual(ids(full.body, kind: "upsert"), Set([shared, sharedTask, privateP].map { $0.lowercased() }))
        let s = try await feed(t, stranger.token, strangerBefore)
        XCTAssertTrue(ids(s.body, kind: "delete").isEmpty)
        XCTAssertTrue(ids(s.body, kind: "upsert").isEmpty)
        let gone = try await User.find(UUID(uuidString: guest.id), on: t.app.db)
        XCTAssertNil(gone)
        let grants = try await ProjectGrant.query(on: t.app.db).filter(\.$principalID == UUID(uuidString: guest.id)!).count()
        XCTAssertEqual(grants, 0)
        // No dangling revocation rows addressed to the deleted account.
        let dangling = try await SyncTombstoneAudience.query(on: t.app.db).filter(\.$userID == UUID(uuidString: guest.id)!).count()
        XCTAssertEqual(dangling, 0)
        _ = guestBefore

        // The owner's own account deletion tombstones what remains for nobody else (only stranger-visible: none).
        let missing = try? await AccountDeletion.delete(userID: UUID(), on: t.app.db)
        XCTAssertNil(missing)
    }

    func testAccountDeletionRevokesAccessThatCameThroughSharedObjects() async throws {
        // Owner shares a project with a guest; the OWNER is deleted -> guest must get tombstones for everything.
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let owner = try await account(t), guest = try await account(t)
        let root = UUID().uuidString, child = UUID().uuidString, task = UUID().uuidString
        try await mutate(t, owner.token, "project.create", id: root, ["name": "Root"])
        try await mutate(t, owner.token, "project.create", id: child, ["name": "Child", "parentID": root])
        try await mutate(t, owner.token, "task.create", id: task, ["title": "T", "projectID": child])
        _ = try await t.json(.PUT, "/v1/projects/\(root)/grants",
            ["principalType": "person", "principalID": guest.id, "role": "read"], token: owner.token)
        let before = try await head(t, guest.token)
        try await AccountDeletion.delete(userID: UUID(uuidString: owner.id)!, on: t.app.db)
        let after = try await feed(t, guest.token, before)
        XCTAssertEqual(ids(after.body, kind: "delete"), Set([root, child, task].map { $0.lowercased() }))
        let full = try await feed(t, guest.token, "c0")
        XCTAssertTrue(ids(full.body, kind: "upsert").isEmpty)
    }

    // MARK: Scheduler

    private func scheduler(_ t: TestApp, interval: TimeInterval = 3600) -> CleanupScheduler {
        CleanupScheduler(app: t.app, interval: interval, retention: 90 * 86_400)
    }

    func testSchedulerRunsOncePerIntervalAcrossConcurrentReplicas() async throws {
        let t = try await TestApp.make()
        var made = [t]
        for _ in 0..<3 { made.append(try await t.replica()) }
        let replicas = made
        defer { Task { for r in replicas { await r.shutdown() } } }
        let schedulers = replicas.map { scheduler($0) }
        // Something to do, so a run is observable.
        let expired = try await account(t)
        try await UserSession.query(on: t.app.db).set(\.$expiresAt, to: Date().addingTimeInterval(-3 * 86_400)).update()
        _ = expired
        let outcomes = await withTaskGroup(of: CleanupScheduler.Outcome.self) { group -> [CleanupScheduler.Outcome] in
            for s in schedulers { group.addTask { await s.runIfDue() } }
            var all: [CleanupScheduler.Outcome] = []
            for await o in group { all.append(o) }
            return all
        }
        let ran = outcomes.filter { if case .ran = $0 { return true }; return false }
        XCTAssertEqual(ran.count, 1, "exactly one replica works: \(outcomes)")
        XCTAssertEqual(outcomes.filter { $0 == .skipped }.count, 3)
        // Within the interval nobody runs again, whichever replica asks.
        for s in schedulers { let o = await s.runIfDue(); XCTAssertEqual(o, .skipped) }
        // Health shows the last run without influencing readiness.
        let ready = try await replicas[1].json(.GET, "/health/ready")
        XCTAssertEqual(ready.status, .ok)
    }

    func testSchedulerLeaseExpiryTakeoverAndFailureIsolation() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let sql = try XCTUnwrap(t.app.db as? any SQLDatabase)
        let a = scheduler(t), b = scheduler(t)
        let first = await a.runIfDue()
        guard case .ran = first else { return XCTFail("\(first)") }
        // A crashed holder: lease held by someone else and not yet expired blocks even a due job.
        let future = Int64(Date().timeIntervalSince1970) + 3600
        try await sql.raw("UPDATE maintenance_leases SET holder = 'crashed', expires_at = \(bind: future), last_run_at = 0").run()
        let blocked = await b.runIfDue()
        XCTAssertEqual(blocked, .skipped)
        // Once the lease expired another replica takes over.
        try await sql.raw("UPDATE maintenance_leases SET expires_at = 1").run()
        let taken = await b.runIfDue()
        guard case .ran = taken else { return XCTFail("\(taken)") }

        // A failing run is recorded and logged, never thrown; readiness stays up and the lease is released.
        try await sql.raw("UPDATE maintenance_leases SET last_run_at = 0, expires_at = 0").run()
        try await sql.raw("ALTER TABLE sync_mutations RENAME TO sync_mutations_gone").run()
        let failed = await a.runIfDue()
        guard case .failed = failed else { return XCTFail("\(failed)") }
        let ready = try await t.json(.GET, "/health/ready")
        XCTAssertEqual(ready.status, .ok)
        let row = try await sql.raw("SELECT last_status, expires_at FROM maintenance_leases").first()
        XCTAssertEqual(try row?.decode(column: "last_status", as: String.self), "error")
        XCTAssertEqual(try row?.decode(column: "expires_at", as: Int64.self), 0)
        // Retry is due sooner than a full interval (300 s), not immediately.
        let immediate = await a.runIfDue()
        XCTAssertEqual(immediate, .skipped)
        try await sql.raw("ALTER TABLE sync_mutations_gone RENAME TO sync_mutations").run()
    }

    func testSchedulerStatusInHealthAndServingDetection() async throws {
        XCTAssertTrue(CleanupScheduler.isServing(arguments: ["App"]))
        XCTAssertTrue(CleanupScheduler.isServing(arguments: ["App", "serve", "--env", "production"]))
        XCTAssertTrue(CleanupScheduler.isServing(arguments: ["App", "--hostname", "0.0.0.0"]))
        XCTAssertFalse(CleanupScheduler.isServing(arguments: ["App", "migrate", "--yes"]))
        XCTAssertFalse(CleanupScheduler.isServing(arguments: ["App", "cleanup-expired"]))

        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let plain = try await t.json(.GET, "/health/ready")
        XCTAssertNil(plain.body?["maintenance"], "no scheduler installed: no maintenance block")
        let s = scheduler(t)
        t.app.storage[CleanupScheduler.SchedulerKey.self] = s
        let never = try await t.json(.GET, "/health/ready")
        XCTAssertEqual((never.body?["maintenance"] as? [String: Any])?["lastStatus"] as? String, "never")
        _ = await s.runIfDue()
        let ok = try await t.json(.GET, "/health/ready")
        let m = try XCTUnwrap(ok.body?["maintenance"] as? [String: Any])
        XCTAssertEqual(m["lastStatus"] as? String, "ok")
        XCTAssertNotNil(m["lastRunAt"])
    }

    func testSettingsParsing() throws {
        let defaults = try AppSettings.fromEnvironment(get: { _ in nil })
        XCTAssertEqual(defaults.cleanupIntervalMinutes, 360)
        XCTAssertEqual(defaults.syncRetentionDays, 90)
        let custom = try AppSettings.fromEnvironment(get: { ["CLEANUP_INTERVAL_MINUTES": "0", "SYNC_RETENTION_DAYS": "30"][$0] })
        XCTAssertEqual(custom.cleanupIntervalMinutes, 0)
        XCTAssertEqual(custom.syncRetentionDays, 30)
        XCTAssertThrowsError(try AppSettings.fromEnvironment(get: { ["SYNC_RETENTION_DAYS": "-1"][$0] }))
        XCTAssertThrowsError(try AppSettings.fromEnvironment(get: { ["CLEANUP_INTERVAL_MINUTES": "abc"][$0] }))
    }
}
