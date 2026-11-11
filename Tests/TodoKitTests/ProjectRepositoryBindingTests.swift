import Fluent
import XCTVapor
@testable import TodoKit

/// Step 1 of the multi-repository plan: model, migration and service (REST/MCP contracts are unchanged).
final class ProjectRepositoryBindingTests: XCTestCase {
    private func account(_ t: TestApp, _ name: String = "Test") async throws -> (user: User, token: String) {
        let user = User(displayName: name, isAdmin: false)
        try await user.save(on: t.app.db)
        let token = AuthSupport.randomToken()
        try await UserSession(userID: user.requireID(), tokenHash: AuthSupport.hash(token),
            expiresAt: Date().addingTimeInterval(3600)).save(on: t.app.db)
        return (user, token)
    }

    private func project(_ t: TestApp, _ token: String, _ name: String = "P") async throws -> UUID {
        let r = try await t.json(.POST, "/v1/projects", ["name": name], token: token)
        XCTAssertEqual(r.status, .created, "\(r.body ?? [:])")
        return try XCTUnwrap(UUID(uuidString: try XCTUnwrap(r.body?["id"] as? String)))
    }

    private func service(_ t: TestApp, _ user: User) -> ProjectSyncService { ProjectSyncService(user: user, db: t.app.db) }

    private func rows(_ t: TestApp, _ project: UUID) async throws -> [ProjectRepositoryBinding] {
        try await ProjectRepositoryBinding.query(on: t.app.db).filter(\.$projectID == project).sort(\.$repoKey).all()
    }

    // MARK: Migration

    func testMigrationCopiesLegacyRowsKeepsIdsIsRepeatableAndRevertLeavesLegacyTable() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let (user, token) = try await account(t)
        let a = try await project(t, token, "A"), b = try await project(t, token, "B")
        let db = t.app.db
        let synced = Date(timeIntervalSince1970: 1_700_000_000)
        let legacyA = ProjectBinding(projectID: a, ownerID: try user.requireID(), repoKey: "github.com/acme/a", staleAfterDays: 5)
        legacyA.lastSyncedAt = synced; legacyA.lastSyncedByType = "Integration"; legacyA.lastSyncedByLabel = "claude"
        legacyA.lastRepoRef = "main@abc"; legacyA.lastSummary = "history"; legacyA.version = 4
        try await legacyA.save(on: db)
        try await ProjectBinding(projectID: b, ownerID: user.requireID(), repoKey: "github.com/acme/b", staleAfterDays: 3).save(on: db)

        try await AddProjectRepositoryBindings().prepare(on: db)
        try await AddProjectRepositoryBindings().prepare(on: db)  // repeat: no duplicates

        let all = try await ProjectRepositoryBinding.query(on: db).all()
        XCTAssertEqual(all.count, 2)
        let copy = try XCTUnwrap(all.first { $0.projectID == a })
        XCTAssertEqual(copy.id, a, "new id = legacy project id")
        XCTAssertEqual(copy.ownerID, try user.requireID())
        XCTAssertEqual(copy.repoKey, "github.com/acme/a"); XCTAssertEqual(copy.staleAfterDays, 5)
        XCTAssertEqual(copy.lastSyncedAt?.timeIntervalSince1970 ?? 0, synced.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(copy.lastSyncedByType, "Integration"); XCTAssertEqual(copy.lastSyncedByLabel, "claude")
        XCTAssertEqual(copy.lastRepoRef, "main@abc"); XCTAssertEqual(copy.lastSummary, "history"); XCTAssertEqual(copy.version, 4)
        XCTAssertEqual(all.first { $0.projectID == b }?.id, b)

        // Legacy data stays untouched; revert drops only the new table.
        try await AddProjectRepositoryBindings().revert(on: db)
        let legacy = try await ProjectBinding.query(on: db).all()
        XCTAssertEqual(legacy.count, 2)
        XCTAssertEqual(legacy.first { $0.id == a }?.lastSummary, "history")
        try await AddProjectRepositoryBindings().prepare(on: db)  // re-apply after revert copies again
        let again = try await ProjectRepositoryBinding.query(on: db).count()
        XCTAssertEqual(again, 2)
    }

    func testMigrationKeepsLegacyTimestampsAcrossRepeatAndRevert() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let (user, token) = try await account(t)
        let a = try await project(t, token, "A"), b = try await project(t, token, "B")
        let db = t.app.db
        try await ProjectBinding(projectID: a, ownerID: user.requireID(), repoKey: "github.com/acme/a", staleAfterDays: 5).save(on: db)
        try await ProjectBinding(projectID: b, ownerID: user.requireID(), repoKey: "github.com/acme/b", staleAfterDays: 3).save(on: db)
        // Fluent stamps timestamps on save; write the historical values with a query (no touch).
        let stamps: [UUID: (created: Date, updated: Date)] = [
            a: (Date(timeIntervalSince1970: 1_788_246_000), Date(timeIntervalSince1970: 1_790_848_800)),  // 2026-09-01 / 2026-10-01
            b: (Date(timeIntervalSince1970: 1_788_332_400), Date(timeIntervalSince1970: 1_788_332_400)),
        ]
        for (id, s) in stamps {
            try await ProjectBinding.query(on: db).filter(\.$id == id)
                .set(\.$createdAt, to: s.created).set(\.$updatedAt, to: s.updated).update()
        }
        try await ProjectRepositoryBinding.query(on: db).delete()  // the app migrated an empty legacy table before

        func assertStamps(_ context: String) async throws {
            let all = try await ProjectRepositoryBinding.query(on: db).all()
            XCTAssertEqual(all.count, 2, context)
            for (id, s) in stamps {
                let row = try XCTUnwrap(all.first { $0.id == id }, context)
                XCTAssertEqual(row.createdAt?.timeIntervalSince1970 ?? 0, s.created.timeIntervalSince1970, accuracy: 1, "created_at \(context)")
                XCTAssertEqual(row.updatedAt?.timeIntervalSince1970 ?? 0, s.updated.timeIntervalSince1970, accuracy: 1, "updated_at \(context)")
            }
        }
        try await AddProjectRepositoryBindings().prepare(on: db)
        try await assertStamps("after first run")
        try await AddProjectRepositoryBindings().prepare(on: db)
        try await assertStamps("after repeat")
        try await AddProjectRepositoryBindings().revert(on: db)
        try await AddProjectRepositoryBindings().prepare(on: db)
        try await assertStamps("after revert and re-apply")
    }

    // MARK: Service

    func testSecondBindingIsAddedWithSeparateHistoryAndDefaultIsOldest() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let (user, token) = try await account(t)
        let pid = try await project(t, token)
        let s = service(t, user)
        let unbound = try await s.status(pid)
        XCTAssertFalse(unbound.bound); XCTAssertEqual(unbound.state, "never")

        let first = try await s.bind(pid, repository: "https://github.com/acme/one.git", staleAfterDays: nil)
        XCTAssertEqual(first.repository, "github.com/acme/one"); XCTAssertEqual(first.staleAfterDays, 3)
        _ = try await s.recordSync(pid, summary: "first synced", repoRef: "main@1", actor: .person(user), agentName: nil)
        let second = try await s.bind(pid, repository: "github.com/acme/two", staleAfterDays: 9)
        XCTAssertEqual(second.repository, "github.com/acme/two")
        XCTAssertEqual(second.state, "never", "history of the new binding starts empty")
        var stored = try await rows(t, pid)
        XCTAssertEqual(stored.map(\.repoKey), ["github.com/acme/one", "github.com/acme/two"])
        XCTAssertEqual(stored[0].lastSummary, "first synced", "existing history is never reset")
        XCTAssertNil(stored[1].lastSummary)

        // Same repository again only changes the threshold.
        let tweak = try await s.bind(pid, repository: "github.com/acme/one", staleAfterDays: 7)
        XCTAssertEqual(tweak.staleAfterDays, 7); XCTAssertEqual(tweak.lastSummary, "first synced")
        stored = try await rows(t, pid)
        XCTAssertEqual(stored.count, 2)

        // Default binding = oldest (created_at, then id): make the second one older.
        stored[1].createdAt = Date().addingTimeInterval(-86_400 * 30); try await stored[1].save(on: t.app.db)
        let defaultBinding = ProjectRepositoryBinding.defaultBinding(of: try await rows(t, pid))
        XCTAssertEqual(defaultBinding?.repoKey, "github.com/acme/two")

        // Without repository and two bindings the target is ambiguous.
        await assertAbort("repository_required") { _ = try await s.bind(pid, repository: nil, staleAfterDays: 5) }
        await assertAbort("repository_required") {
            _ = try await s.recordSync(pid, summary: "x", repoRef: nil, actor: .person(user), agentName: nil)
        }
        // Recording against a named repository only touches that history.
        _ = try await s.recordSync(pid, summary: "second synced", repoRef: nil, actor: .person(user), agentName: nil, repository: "GitHub.com/Acme/Two")
        stored = try await rows(t, pid)
        XCTAssertEqual(stored.first { $0.repoKey == "github.com/acme/one" }?.lastSummary, "first synced")
        XCTAssertEqual(stored.first { $0.repoKey == "github.com/acme/two" }?.lastSummary, "second synced")
    }

    func testStalestBindingDeterminesStateAndEntries() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let (user, token) = try await account(t)
        let pid = try await project(t, token)
        let s = service(t, user)
        _ = try await s.bind(pid, repository: "github.com/acme/one", staleAfterDays: 3)
        _ = try await s.bind(pid, repository: "github.com/acme/two", staleAfterDays: 3)
        let one = try await rows(t, pid)[0], two = try await rows(t, pid)[1]
        one.lastSyncedAt = Date(); try await one.save(on: t.app.db)
        // two was never synced: never beats fresh.
        var st = try await s.status(pid)
        XCTAssertEqual(st.state, "never"); XCTAssertEqual(st.repository, "github.com/acme/two")
        var staleList = try await s.stale(projectID: pid, includeUnbound: false)
        XCTAssertEqual(staleList.count, 1)
        two.lastSyncedAt = Date().addingTimeInterval(-10 * 86_400); try await two.save(on: t.app.db)
        st = try await s.status(pid)
        XCTAssertEqual(st.state, "stale"); XCTAssertEqual(st.repository, "github.com/acme/two"); XCTAssertEqual(st.daysSince, 10)
        // Both stale: the larger daysSince wins.
        one.lastSyncedAt = Date().addingTimeInterval(-20 * 86_400); try await one.save(on: t.app.db)
        st = try await s.status(pid)
        XCTAssertEqual(st.repository, "github.com/acme/one"); XCTAssertEqual(st.daysSince, 20)
        // Both fresh: project is fresh.
        one.lastSyncedAt = Date(); two.lastSyncedAt = Date()
        try await one.save(on: t.app.db); try await two.save(on: t.app.db)
        st = try await s.status(pid)
        XCTAssertEqual(st.state, "fresh")
        staleList = try await s.stale(projectID: pid, includeUnbound: false)
        XCTAssertTrue(staleList.isEmpty)
        // Command center reports one entry per project (flat, stalest binding).
        one.lastSyncedAt = nil; try await one.save(on: t.app.db)
        let scope = try await CommandCenterScope.resolve(user: user, db: t.app.db, projectID: pid, includeSubprojects: true, allowed: nil)
        let entries = try await ProjectSyncService.entries(scope: scope, on: t.app.db)
        XCTAssertEqual(entries.count, 1); XCTAssertEqual(entries.first?.sync.state, "never")
    }

    func testUniquePerOwnerLimitAndFind() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let (user, token) = try await account(t)
        let a = try await project(t, token, "A"), b = try await project(t, token, "B")
        let s = service(t, user)
        _ = try await s.bind(a, repository: "github.com/acme/shared", staleAfterDays: nil)
        await assertAbort("repository_already_bound") { _ = try await s.bind(b, repository: "https://github.com/acme/shared.git", staleAfterDays: nil) }
        let other = try await account(t, "Other")
        let otherProject = try await project(t, other.token, "O")
        _ = try await service(t, other.user).bind(otherProject, repository: "github.com/acme/shared", staleAfterDays: nil)  // other owner: fine

        let found = try await s.find(repository: "github.com/acme/shared")
        XCTAssertEqual(found.matches.map(\.projectID), [a])
        // A second binding on the same project is found as well.
        _ = try await s.bind(a, repository: "github.com/acme/extra", staleAfterDays: nil)
        let extra = try await s.find(repository: "github.com/acme/extra")
        XCTAssertEqual(extra.matches.map(\.projectID), [a]); XCTAssertTrue(extra.found)

        for i in 3...10 { _ = try await s.bind(a, repository: "github.com/acme/r\(i)", staleAfterDays: nil) }
        let count = try await rows(t, a).count
        XCTAssertEqual(count, 10)
        await assertAbort("too_many_bindings") { _ = try await s.bind(a, repository: "github.com/acme/r11", staleAfterDays: nil) }
        // Existing keys can still be edited at the limit.
        let edited = try await s.bind(a, repository: "github.com/acme/r3", staleAfterDays: 2)
        XCTAssertEqual(edited.staleAfterDays, 2)
    }

    func testConstraintFailureMappingDistinguishesUniqueFromMissingProject() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let (user, token) = try await account(t)
        let pid = try await project(t, token)
        let s = service(t, user)
        _ = try await s.bind(pid, repository: "github.com/acme/one", staleAfterDays: nil)
        struct Boom: Error {}
        let unique = try await ProjectSyncService.mapConstraintFailure(Boom(), projectID: pid, key: "github.com/acme/one", on: t.app.db)
        XCTAssertEqual((unique as? Abort)?.reason, "repository_already_bound")
        let other = try await ProjectSyncService.mapConstraintFailure(Boom(), projectID: pid, key: "github.com/acme/none", on: t.app.db)
        XCTAssertTrue(other is Boom)
        let gone = try await ProjectSyncService.mapConstraintFailure(Boom(), projectID: UUID(), key: "github.com/acme/one", on: t.app.db)
        XCTAssertEqual((gone as? Abort)?.status, .notFound)
    }

    func testSingleBindingKeepsLegacyBehaviourAndAgentRelated() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let (user, token) = try await account(t)
        let pid = try await project(t, token)
        let plain = try await project(t, token, "Plain")
        let s = service(t, user)
        await assertAbort("repository_required") { _ = try await s.bind(pid, repository: nil, staleAfterDays: 5) }
        await assertAbort("not_bound") { _ = try await s.recordSync(pid, summary: "x", repoRef: nil, actor: .person(user), agentName: nil) }
        _ = try await s.bind(pid, repository: "github.com/acme/one", staleAfterDays: nil)
        let changed = try await s.bind(pid, repository: nil, staleAfterDays: 6)
        XCTAssertEqual(changed.staleAfterDays, 6); XCTAssertEqual(changed.repository, "github.com/acme/one")
        let rec = try await s.recordSync(pid, summary: "done", repoRef: "main", actor: .person(user), agentName: "agent")
        XCTAssertEqual(rec.state, "fresh"); XCTAssertEqual(rec.lastSyncedBy, "agent")
        let related = try await ProjectStateService(user: user, db: t.app.db).agentRelated([pid, plain])
        XCTAssertEqual(related, [pid])
    }

    func testBindNewInTransaction() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let (user, token) = try await account(t)
        let pid = try await project(t, token)
        let p = try await XCTUnwrapAsync(await Project.find(pid, on: t.app.db))
        let dto = try await ProjectSyncService.bindNew(p, repository: "GitHub.com/Acme/New", staleAfterDays: 4, on: t.app.db)
        XCTAssertEqual(dto.repository, "github.com/acme/new"); XCTAssertEqual(dto.staleAfterDays, 4)
        let row = try await XCTUnwrapAsync(await ProjectRepositoryBinding.query(on: t.app.db).filter(\.$projectID == pid).first())
        XCTAssertEqual(row.ownerID, try user.requireID())
    }
}

private func assertAbort(_ reason: String, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void) async {
    do { try await body(); XCTFail("expected \(reason)", file: file, line: line) } catch let e as Abort {
        XCTAssertEqual(e.reason, reason, file: file, line: line)
    } catch { XCTFail("unexpected \(error)", file: file, line: line) }
}
