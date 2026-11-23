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

    /// Sub-projects of other accounts under a deleted project must not cascade away (card BCA27B3D).
    func testAccountDeletionKeepsForeignSubprojectsUnderDeletedProject() async throws {
        let t = try await TestApp.make(); defer { Task { await t.shutdown() } }
        let admin = try await MailTests.account(t, "Root", admin: true)
        let user = try await MailTests.account(t, "Anna Beispiel")
        let db = t.app.db
        // Departing account A: root project with a nested own project; B's sub-project sits below the nested one,
        // B's own grandchild below that. A second tree hangs below a project of B (the surviving ancestor).
        let rootA = Project(ownerID: user.id, parentID: nil, name: "A Wurzel")
        try await rootA.save(on: db)
        let nestedA = Project(ownerID: user.id, parentID: try rootA.requireID(), name: "A Mitte")
        try await nestedA.save(on: db)
        let foreignSub = Project(ownerID: admin.id, parentID: try nestedA.requireID(), name: "B Unterprojekt")
        try await foreignSub.save(on: db)
        let foreignGrandchild = Project(ownerID: admin.id, parentID: try foreignSub.requireID(), name: "B Enkel")
        try await foreignGrandchild.save(on: db)
        let foreignTask = TodoTask(ownerID: admin.id, projectID: try foreignSub.requireID(), title: "B Aufgabe")
        try await foreignTask.save(on: db)
        let rootB = Project(ownerID: admin.id, parentID: nil, name: "B Wurzel")
        try await rootB.save(on: db)
        let underB = Project(ownerID: user.id, parentID: try rootB.requireID(), name: "A unter B")
        try await underB.save(on: db)
        let foreignUnderB = Project(ownerID: admin.id, parentID: try underB.requireID(), name: "B unter A unter B")
        try await foreignUnderB.save(on: db)

        try await AccountDeletion.delete(userID: user.id, on: db)

        let v1 = try await Project.find(try rootA.requireID(), on: db)
        XCTAssertNil(v1)
        let v2 = try await Project.find(try nestedA.requireID(), on: db)
        XCTAssertNil(v2)
        let v3 = try await Project.find(try underB.requireID(), on: db)
        XCTAssertNil(v3)
        let keptSub = try await XCTUnwrapAsync(await Project.find(try foreignSub.requireID(), on: db))
        XCTAssertNil(keptSub.parentID, "no surviving ancestor: the sub-project moves to the top level")
        XCTAssertEqual(keptSub.ownerID, admin.id)
        let keptGrandchild = try await XCTUnwrapAsync(await Project.find(try foreignGrandchild.requireID(), on: db))
        XCTAssertEqual(keptGrandchild.parentID, try foreignSub.requireID(), "B's own subtree keeps its shape")
        let v4 = try await TodoTask.find(try foreignTask.requireID(), on: db)
        XCTAssertNotNil(v4)
        let keptUnderB = try await XCTUnwrapAsync(await Project.find(try foreignUnderB.requireID(), on: db))
        XCTAssertEqual(keptUnderB.parentID, try rootB.requireID(), "moves to the nearest surviving ancestor")
    }

    /// The founder reference (sharing_teams.founder_id -> users) must not block deleting the account (card 69439B31).
    func testAccountDeletionHandsFounderRoleToRemainingMember() async throws {
        let t = try await TestApp.make(); defer { Task { await t.shutdown() } }
        let root = try await MailTests.account(t, "Root", admin: true)
        let founder = try await MailTests.account(t, "Gruenderin")
        let member = try await MailTests.account(t, "Mitglied")
        let adminMember = try await MailTests.account(t, "Teamadmin")
        let invited = try await MailTests.account(t, "Eingeladen")
        let db = t.app.db
        // Team 1: founder, a plain member (lower id), an admin member and a pending invitation: the admin inherits.
        let team = Team(name: "Team Eins", founderID: founder.id)
        try await team.save(on: db)
        let teamID = try team.requireID()
        try await TeamMembership(teamID: teamID, userID: founder.id, isAdmin: true, accepted: true).save(on: db)
        try await TeamMembership(teamID: teamID, userID: member.id, isAdmin: false, accepted: true).save(on: db)
        try await TeamMembership(teamID: teamID, userID: adminMember.id, isAdmin: true, accepted: true).save(on: db)
        try await TeamMembership(teamID: teamID, userID: invited.id, isAdmin: true, accepted: false).save(on: db)
        // Team 2: only a plain member remains: they become founder and admin (a founder is always an admin).
        let team2 = Team(name: "Team Zwei", founderID: founder.id)
        try await team2.save(on: db)
        let team2ID = try team2.requireID()
        try await TeamMembership(teamID: team2ID, userID: founder.id, isAdmin: true, accepted: true).save(on: db)
        try await TeamMembership(teamID: team2ID, userID: member.id, isAdmin: false, accepted: true).save(on: db)
        // Team 3: nobody else accepted (only a pending invitation): the team goes away, including its grants.
        let team3 = Team(name: "Team Drei", founderID: founder.id)
        try await team3.save(on: db)
        let team3ID = try team3.requireID()
        try await TeamMembership(teamID: team3ID, userID: founder.id, isAdmin: true, accepted: true).save(on: db)
        try await TeamMembership(teamID: team3ID, userID: invited.id, isAdmin: false, accepted: false).save(on: db)
        let shared = Project(ownerID: root.id, parentID: nil, name: "Geteilt")
        try await shared.save(on: db)
        try await ProjectGrant(projectID: try shared.requireID(), principalType: "team", principalID: team3ID, role: .edit).save(on: db)
        // Team 4: founded by someone else; the departing account is only a member.
        let team4 = Team(name: "Team Vier", founderID: member.id)
        try await team4.save(on: db)
        let team4ID = try team4.requireID()
        try await TeamMembership(teamID: team4ID, userID: member.id, isAdmin: true, accepted: true).save(on: db)
        try await TeamMembership(teamID: team4ID, userID: founder.id, isAdmin: false, accepted: true).save(on: db)

        try await AccountDeletion.delete(userID: founder.id, on: db)

        let v5 = try await User.find(founder.id, on: db)
        XCTAssertNil(v5)
        let kept1 = try await XCTUnwrapAsync(await Team.find(teamID, on: db))
        XCTAssertEqual(kept1.founderID, adminMember.id, "accepted admins come first")
        let kept2 = try await XCTUnwrapAsync(await Team.find(team2ID, on: db))
        XCTAssertEqual(kept2.founderID, member.id)
        let promoted = try await XCTUnwrapAsync(
            await TeamMembership.query(on: db).filter(\.$teamID == team2ID).filter(\.$userID == member.id).first())
        XCTAssertTrue(promoted.isAdmin)
        let v6 = try await Team.find(team3ID, on: db)
        XCTAssertNil(v6)
        let v7 = try await TeamMembership.query(on: db).filter(\.$teamID == team3ID).count()
        XCTAssertEqual(v7, 0)
        let v8 = try await ProjectGrant.query(on: db).filter(\.$principalType == "team").filter(\.$principalID == team3ID).count()
        XCTAssertEqual(v8, 0)
        let kept4 = try await XCTUnwrapAsync(await Team.find(team4ID, on: db))
        XCTAssertEqual(kept4.founderID, member.id)
        let v9 = try await TeamMembership.query(on: db).filter(\.$userID == founder.id).count()
        XCTAssertEqual(v9, 0)
    }
}
