import Fluent
import Foundation
import XCTest
import XCTVapor
@testable import TodoKit

final class AccountDeletionTests: XCTestCase {
    /// Deleting an account must keep what was transferred to others and tasks it created in other people's projects.
    func testAccountDeletionKeepsTransferredProjectsAndForeignTasks() async throws {
        let t = try await TestApp.make(); defer { Task { await t.shutdown() } }
        let admin = try await MailTests.account(t, "Root", admin: true)
        let user = try await MailTests.account(t, "Anna Beispiel")
        let db = t.app.db
        let transferred = Project(ownerID: user.id, parentID: nil, name: "Uebertragen")
        try await transferred.save(on: db)
        let sharing = try ProjectSharing(project: transferred)
        sharing.ownerID = admin.id
        try await sharing.save(on: db)
        let newTask = TodoTask(ownerID: admin.id, projectID: try transferred.requireID(), title: "Neu von B")
        try await newTask.save(on: db)
        let foreign = Project(ownerID: admin.id, parentID: nil, name: "Fremd")
        try await foreign.save(on: db)
        let foreignTask = TodoTask(ownerID: user.id, projectID: try foreign.requireID(), title: "Von A in Fremd")
        try await foreignTask.save(on: db)
        try await TaskComment(taskID: try foreignTask.requireID(), authorID: user.id, body: "Kommentar von A").save(on: db)
        let mine = Project(ownerID: user.id, parentID: nil, name: "Eigen")
        try await mine.save(on: db)

        try await AccountDeletion.delete(userID: user.id, on: db)

        let keptProject = try await XCTUnwrapAsync(await Project.find(try transferred.requireID(), on: db))
        XCTAssertEqual(keptProject.ownerID, admin.id)
        let keptNew = try await TodoTask.find(try newTask.requireID(), on: db)
        XCTAssertNotNil(keptNew)
        let keptForeign = try await XCTUnwrapAsync(await TodoTask.find(try foreignTask.requireID(), on: db))
        XCTAssertEqual(keptForeign.ownerID, admin.id)
        let keptForeignProject = try await Project.find(try foreign.requireID(), on: db)
        XCTAssertNotNil(keptForeignProject)
        let deletedOwn = try await Project.find(try mine.requireID(), on: db)
        XCTAssertNil(deletedOwn)
        let gone = try await User.find(user.id, on: db)
        XCTAssertNil(gone)
    }
}
