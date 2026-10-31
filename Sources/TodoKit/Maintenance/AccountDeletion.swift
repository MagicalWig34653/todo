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

            for project in try await Project.query(on: db).filter(\.$ownerID == userID).sort(\.$id).all() {
                // A parent deleted earlier in this loop already removed its subtree.
                guard let current = try await Project.find(try project.requireID(), on: db) else { continue }
                try await current.delete(on: db)
                report.projects += 1
            }
            for task in try await TodoTask.query(on: db).filter(\.$ownerID == userID).sort(\.$id).all() {
                guard let current = try await TodoTask.find(try task.requireID(), on: db) else { continue }
                try await current.delete(on: db)
                report.tasks += 1
            }
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
