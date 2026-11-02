import Fluent
import FluentSQL
import XCTVapor
@testable import TodoKit

/// SharingSnapshot.visibility must give the same result as SharingAccess.visibility (or the same error) for every
/// project and viewer, including the negative cases (no access, stopped inheritance, hidden parent, cycle).
final class SharingSnapshotEquivalenceTests: XCTestCase {
    private func describe(_ v: EffectiveVisibility) -> String {
        "\(v.role?.rawValue ?? "none") transfer=\(v.canTransferOwnership) delete=\(v.canDelete) team=\(v.canManageTeam) inherits=\(v.inherits)"
    }
    private func outcome(_ block: () async throws -> EffectiveVisibility) async -> String {
        do { return describe(try await block()) } catch let e as Abort { return "abort \(e.status.code) \(e.reason)" } catch { return "error \(error)" }
    }

    func testSnapshotMatchesSingleCheckForManyConstellations() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let db = t.app.db
        func user(_ name: String) async throws -> User { let u = User(displayName: name, isAdmin: false); try await u.save(on: db); return u }
        let v = try await user("Viewer"), o = try await user("Other"), x = try await user("Stranger")
        let (vid, oid) = (try v.requireID(), try o.requireID())

        func team(_ name: String, members: [(User, Bool, Bool)]) async throws -> UUID {
            let team = Team(name: name, founderID: oid); try await team.save(on: db)
            for (u, admin, accepted) in members { try await TeamMembership(teamID: team.requireID(), userID: u.requireID(), isAdmin: admin, accepted: accepted).save(on: db) }
            return try team.requireID()
        }
        let tAdmin = try await team("V admin", members: [(o, true, true), (v, true, true)])
        let tMember = try await team("V member", members: [(o, true, true), (v, false, true)])
        let tForeign = try await team("V not in", members: [(o, true, true)])
        let tPending = try await team("V invited only", members: [(o, true, true), (v, false, false)])

        func project(_ name: String, owner: UUID, parent: Project? = nil) async throws -> Project {
            let p = Project(ownerID: owner, parentID: try parent?.requireID(), name: name); try await p.save(on: db); return p
        }
        func sharing(_ p: Project, ownerType: String? = nil, ownerID: UUID? = nil, inherits: Bool = true) async throws {
            let s = try ProjectSharing(project: p)
            if let ownerType { s.ownerType = ownerType }
            if let ownerID { s.ownerID = ownerID }
            s.inherits = inherits
            try await s.save(on: db)
        }
        func grant(_ p: Project, _ type: String, _ id: UUID, _ role: ProjectRole) async throws {
            try await ProjectGrant(projectID: p.requireID(), principalType: type, principalID: id, role: role).save(on: db)
        }

        // Owner and inherited ownership chain.
        let mine = try await project("mine", owner: vid)
        let mineChild = try await project("mine child", owner: vid, parent: mine)
        _ = try await project("mine grandchild", owner: oid, parent: mineChild)
        // Direct grant inherited downwards, stopped by inherits=false in the middle, re-granted below it.
        let shared = try await project("shared", owner: oid); try await grant(shared, "person", vid, .edit)
        let sharedKid = try await project("shared kid", owner: oid, parent: shared)
        let stopped = try await project("stopped", owner: oid, parent: shared); try await sharing(stopped, inherits: false)
        let belowStop = try await project("below stop", owner: oid, parent: stopped)
        let regranted = try await project("regranted", owner: oid, parent: stopped); try await grant(regranted, "person", vid, .read)
        // Hidden parent (no access) with an accessible child.
        let hidden = try await project("hidden", owner: oid)
        let visibleChild = try await project("visible child", owner: oid, parent: hidden); try await grant(visibleChild, "person", vid, .comment)
        let deepHidden = try await project("deep under visible", owner: oid, parent: visibleChild)
        // Team ownership and team grants.
        let ownedByAdminTeam = try await project("team admin", owner: oid); try await sharing(ownedByAdminTeam, ownerType: "team", ownerID: tAdmin)
        let ownedByMemberTeam = try await project("team member", owner: oid); try await sharing(ownedByMemberTeam, ownerType: "team", ownerID: tMember)
        let ownedByForeignTeam = try await project("team foreign", owner: oid); try await sharing(ownedByForeignTeam, ownerType: "team", ownerID: tForeign)
        let ownedByPendingTeam = try await project("team pending", owner: oid); try await sharing(ownedByPendingTeam, ownerType: "team", ownerID: tPending)
        let teamGranted = try await project("team grants", owner: oid)
        try await grant(teamGranted, "team", tMember, .comment); try await grant(teamGranted, "team", tForeign, .manage); try await grant(teamGranted, "team", tPending, .manage)
        let teamGrantKid = try await project("team grant kid", owner: oid, parent: teamGranted)
        // Both a person and a team grant: highest role wins.
        let both = try await project("both", owner: oid); try await grant(both, "person", vid, .read); try await grant(both, "team", tAdmin, .manage)
        // No access at all, and a grant for someone else.
        let none = try await project("none", owner: oid)
        let others = try await project("others", owner: oid); try await grant(others, "person", try x.requireID(), .manage)
        // Cycle a -> b -> a.
        let a = try await project("cycle a", owner: oid), b = try await project("cycle b", owner: oid, parent: a)
        // Raw update: the save path itself rejects cycles, the stored graph may still contain one.
        _ = try await (db as! any SQLDatabase).raw("UPDATE projects SET parent_id = \(bind: try b.requireID()) WHERE id = \(bind: try a.requireID())").all()

        let all = [mine, mineChild, shared, sharedKid, stopped, belowStop, regranted, hidden, visibleChild, deepHidden, ownedByAdminTeam,
                   ownedByMemberTeam, ownedByForeignTeam, ownedByPendingTeam, teamGranted, teamGrantKid, both, none, others, a, b]
        var roles = Set<String>()
        var errors = 0
        for viewer in [v, o, x] {
            let access = SharingAccess(user: viewer, db: db)
            let (snap, ordered) = try await access.snapshot()
            let everything = try await Project.query(on: db).all()
            XCTAssertGreaterThan(everything.count, all.count)
            XCTAssertEqual(Set(ordered.compactMap(\.id)), Set(snap.projects.keys))
            for p in everything {
                let single = await outcome { try await access.visibility(p) }
                if snap.projects[try p.requireID()] == nil {
                    // Not loaded: the account must have no role (or the project sits in a cycle it is not related to).
                    XCTAssertTrue(single.hasPrefix("none") || single.hasPrefix("abort"), "\(viewer.displayName) unloaded \(p.name): \(single)")
                    if single.hasPrefix("none") { XCTAssertNil(try snap.visibility(p).role) }
                    continue
                }
                let batch = await outcome { try snap.visibility(p) }
                XCTAssertEqual(batch, single, "\(viewer.displayName) on \(p.name)")
                if single.hasPrefix("abort") { errors += 1 } else { roles.insert(single.split(separator: " ").first.map(String.init) ?? "") }
            }
            // The reader computation agrees with the per-account check for every non-cyclic project.
            for p in everything {
                guard (try? await access.visibility(p)) != nil else { continue }
                let readers = Set(try await SyncRecorder.readers(of: p, on: db))
                let expected = try await access.visibility(p).role != nil
                XCTAssertEqual(readers.contains(try viewer.requireID()), expected, "readers \(viewer.displayName) on \(p.name)")
            }
        }
        // The constellations really cover grants, ownership and denials, and the cycle errors on both paths.
        XCTAssertTrue(roles.isSuperset(of: ["none", "read", "comment", "edit", "manage"]), "\(roles)")
        XCTAssertGreaterThanOrEqual(errors, 2, "cycle projects must error for each viewer on both paths")
    }

    /// Many foreign projects must not cost the viewer: the bounded snapshot loads only its own tree.
    /// "Before" is the former full load (all projects, sharing rows, grants), measured on the same data.
    func testSnapshotIgnoresForeignProjects() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let db = t.app.db
        let me = User(displayName: "Me", isAdmin: false), other = User(displayName: "Other", isAdmin: false)
        try await me.save(on: db); try await other.save(on: db)
        let (mid, oid) = (try me.requireID(), try other.requireID())
        for i in 0..<50 { try await Project(ownerID: mid, parentID: nil, name: "mine \(i)").save(on: db) }
        let foreign = (0..<3000).map { Project(ownerID: oid, parentID: nil, name: "foreign \($0)") }
        for p in foreign { try await p.save(on: db) }
        for p in foreign.prefix(300) { try await ProjectGrant(projectID: p.requireID(), principalType: "person", principalID: oid, role: .manage).save(on: db) }

        let access = SharingAccess(user: me, db: db)
        let started = Date()
        let (snap, ordered) = try await access.snapshot()
        let bounded = Date().timeIntervalSince(started)
        XCTAssertEqual(snap.projects.count, 50)
        XCTAssertEqual(try ordered.filter { try snap.visibility($0).role != nil }.count, 50)

        let fullStart = Date()
        let all = try await Project.query(on: db).sort(\.$createdAt).sort(\.$id).all()
        _ = try await ProjectSharing.query(on: db).all(); _ = try await ProjectGrant.query(on: db).all()
        let full = Date().timeIntervalSince(fullStart)
        XCTAssertEqual(all.count, 3050)
        print("snapshot with 3000 foreign + 50 own projects: bounded \(bounded) s, former full load \(full) s")
        XCTAssertLessThan(bounded, full)
    }
}
