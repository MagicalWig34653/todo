import Fluent
import SQLKit
import Vapor

/// Deletes an account without leaving other clients' caches behind (ADR 0019).
///
/// The foreign keys cascade owned projects and tasks without model events, which would drop them from other
/// accounts' views silently. So everything the account owns is deleted through the models first (tombstones with
/// the readers frozen at that moment, exactly like a normal delete), the account's own grants are removed, and the
/// visibility diff of the whole sharing graph is recorded (e.g. access that only existed through the account's
/// team memberships). All in one transaction under the sharing-graph lock.
struct AccountDeletion: Sendable {
    struct Report: Sendable, Equatable { var projects = 0, tasks = 0, grants = 0 }

    @discardableResult static func delete(userID: UUID, on database: any Database) async throws -> Report {
        try await database.transaction { db in
            try await lockSharingGraph(on: db)
            guard let user = try await User.find(userID, on: db) else { throw Abort(.notFound, reason: "user_not_found") }
            var report = Report()
            let before = try await SyncRecorder.visibility(on: db)
            // The departing account will not be around to receive tombstones.
            let snapshot = SyncRecorder.VisibilitySnapshot(
                readers: before.readers.mapValues { $0.subtracting([userID]) }, parents: before.parents)

            // Effective ownership is the sharing overlay; projects.owner_id is only the creator (and a cascading FK).
            let overlays = Dictionary(uniqueKeysWithValues: try await ProjectSharing.query(on: db).all().map { ($0.projectID, $0) })
            func ownedByDeparting(_ p: Project) throws -> Bool {
                guard let row = overlays[try p.requireID()] else { return p.ownerID == userID }
                return row.ownerType == "person" && row.ownerID == userID
            }
            /// A surviving account that takes over the creator reference of content that stays.
            func successor(of p: Project) async throws -> UUID? {
                guard let row = overlays[try p.requireID()] else { return nil }
                if row.ownerType == "person" { return row.ownerID == userID ? nil : row.ownerID }
                let members = try await TeamMembership.query(on: db).filter(\.$teamID == row.ownerID)
                    .filter(\.$accepted == true).filter(\.$userID != userID).sort(\.$isAdmin, .descending).sort(\.$id).all()
                return members.first?.userID
            }
            var keptSuccessors: [UUID: UUID] = [:]
            let overlayOwned = overlays.values.filter { $0.ownerType == "person" && $0.ownerID == userID }.map(\.projectID)
            var candidates = try await Project.query(on: db).filter(\.$ownerID == userID).all()
            if !overlayOwned.isEmpty { candidates += try await Project.query(on: db).filter(\.$id ~~ overlayOwned).all() }
            var seen = Set<UUID>()
            for project in candidates.sorted(by: { ($0.id?.uuidString ?? "") < ($1.id?.uuidString ?? "") }) where seen.insert(try project.requireID()).inserted {
                // A parent deleted earlier in this loop already removed its subtree.
                guard let current = try await Project.find(try project.requireID(), on: db) else { continue }
                if try ownedByDeparting(current) {
                    try await current.delete(on: db)
                    report.projects += 1
                } else if let next = try await successor(of: current) {
                    // Transferred away: keep it and only detach the creator reference.
                    current.ownerID = next
                    try await current.save(on: db)
                    keptSuccessors[try current.requireID()] = next
                } else {
                    try await current.delete(on: db)
                    report.projects += 1
                }
            }
            // Tasks the account created in projects that stay belong to someone else's project now: keep them.
            for task in try await TodoTask.query(on: db).filter(\.$ownerID == userID).sort(\.$id).all() {
                guard let project = try await Project.find(task.projectID, on: db) else { continue }
                let heir: UUID?
                if let kept = keptSuccessors[task.projectID] { heir = kept } else { heir = try await effectiveOwner(of: project, departing: userID, overlays: overlays, on: db) }
                guard let heir else {
                    try await task.delete(on: db); report.tasks += 1; continue
                }
                task.ownerID = heir
                try await task.save(on: db)
            }
            try await TaskComment.query(on: db).filter(\.$authorID == userID).delete()
            try await ProjectComment.query(on: db).filter(\.$authorID == userID).delete()
            let grants = try await ProjectGrant.query(on: db).filter(\.$principalType == "person")
                .filter(\.$principalID == userID).all()
            for grant in grants { try await grant.delete(on: db) }
            report.grants = grants.count

            try await user.delete(on: db)
            try await SyncRecorder.recordVisibilityChanges(from: snapshot, on: db)
            // Frozen audiences naming the departed account (their own deletions) are useless now.
            try await SyncTombstoneAudience.query(on: db).filter(\.$userID == userID).delete()
            return report
        }
    }
}

private func effectiveOwner(of project: Project, departing: UUID, overlays: [UUID: ProjectSharing], on db: any Database) async throws -> UUID? {
    guard let row = overlays[try project.requireID()] else { return project.ownerID == departing ? nil : project.ownerID }
    if row.ownerType == "person" { return row.ownerID == departing ? nil : row.ownerID }
    return try await TeamMembership.query(on: db).filter(\.$teamID == row.ownerID).filter(\.$accepted == true)
        .filter(\.$userID != departing).sort(\.$isAdmin, .descending).sort(\.$id).first()?.userID
}

struct DeleteAccountCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Argument(name: "user-id") var userID: String
        @Flag(name: "yes", help: "Confirm the irreversible deletion.")
        var yes: Bool
    }
    let help = "Delete an account including everything it owns; other accounts receive sync tombstones for objects they lose."
    func run(using context: CommandContext, signature: Signature) async throws {
        guard let id = UUID(uuidString: signature.userID) else { throw Abort(.badRequest, reason: "invalid_user_id") }
        guard signature.yes else { throw Abort(.badRequest, reason: "confirmation_required: pass --yes") }
        let r = try await AccountDeletion.delete(userID: id, on: context.application.db)
        context.console.print("Deleted account \(id): \(r.projects) owned projects, \(r.tasks) remaining owned tasks, \(r.grants) grants.")
    }
}
