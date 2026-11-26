import Fluent
import XCTVapor
@testable import TodoKit

/// Card 0E5CCA05: security review of project groups (ADR 0037, merge 4a3f2ec). Each test pins one finding and is RED on
/// 4a3f2ec. No product code was changed by the review.
final class ProjectGroupSecurityReviewTests: XCTestCase {
    private static let scopes = "projects:read projects:write tasks:read tasks:write"

    /// Finding 2 (follow-up): `OAuthGrant.exclude` (share dialog, project managers of other people, `set_connection_projects`)
    /// appends to `excludedProjectIDs` without the limit `validate` enforces (500). Once a connection holds more exclusions, the
    /// PWA cannot save the connection with its own rule any more (`invalid_selection`); the only way out is dropping the rule,
    /// i.e. all exclusions, which widens the connection.
    func testExclusionsAddedOneByOneCanStillBeSavedBack() async throws {
        // The real limit is 500; a small one keeps the test fast (the original version took 100 s for 501 projects).
        SelectionLimits.maxExcluded = 3
        defer { SelectionLimits.maxExcluded = 500 }
        let f = try await OAuthFixture.make()
        do {
            let db = f.test.app.db
            _ = try await f.tokens(scope: Self.scopes)
            let first = try await OAuthGrant.query(on: db).first()
            let grant = try XCTUnwrap(first)
            let grantID = try grant.requireID()
            let userID = try f.user.requireID()
            let rule = ["mode": "all_except", "groupIDs": [String](), "excludedProjectIDs": [String](), "excludedGroupIDs": [String]()] as [String: Any]
            let put = try await f.test.json(.PUT, "/oauth/grants/\(grantID)/projects", ["project_ids": [String](), "selection": rule], token: f.session)
            XCTAssertEqual(put.status, .ok, "\(put.body ?? [:])")
            var owned: [UUID] = []
            for i in 0...SelectionLimits.maxExcluded {
                let p = Project(ownerID: userID, parentID: nil, name: "Own \(i)")
                try await p.save(on: db)
                owned.append(try p.requireID())
            }
            for id in owned { try await ConnectionService.remove(project: id, grantID: grantID, actor: f.user, db: db) }
            let listed = try await f.test.json(.GET, "/oauth/grants", token: f.session)
            let row = try XCTUnwrap(listed.list?.first { $0["id"] as? String == grantID.uuidString })
            let selection = try XCTUnwrap(row["selection"] as? [String: Any])
            XCTAssertGreaterThan((selection["excludedProjectIDs"] as? [String])?.count ?? 0, SelectionLimits.maxExcluded)
            // Saving back exactly what the server shows (e.g. after renaming nothing) must work.
            let again = try await f.test.json(.PUT, "/oauth/grants/\(grantID)/projects",
                ["project_ids": row["explicit_project_ids"] ?? [String](), "selection": selection], token: f.session)
            XCTAssertEqual(again.status, .ok, "rule with \((selection["excludedProjectIDs"] as? [String])?.count ?? 0) exclusions cannot be saved back: \(again.body ?? [:])")
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    /// Finding 1 (decision for Lino, ADR 0037 "bewusst offen"): another person who owns a project can hand it to the person
    /// without any consent (`PUT /v1/projects/{id}/owner` only checks that the recipient exists). With an "all except"
    /// brain mandate the project is covered at once: the brain agent may decide reviews and answer questions in a project
    /// written by someone else, and no mandate audit row says so. Expected here: a project that arrived by transfer is
    /// treated like an agent-created one (not automatically covered) until the person chooses it.
    func testProjectTransferredInByAnotherPersonIsNotCoveredByAllExceptMandate() async throws {
        let f = try await OAuthFixture.make()
        do {
            let db = f.test.app.db
            _ = try await f.tokens(scope: Self.scopes)
            let firstID = try await OAuthGrant.query(on: db).first()?.id
            let grantID = try XCTUnwrap(firstID)
            let rule = ["mode": "all_except", "groupIDs": [String](), "excludedProjectIDs": [String](), "excludedGroupIDs": [String]()] as [String: Any]
            let granted = try await f.test.json(.PUT, "/v1/settings/brain-mandate",
                ["grantID": grantID.uuidString, "projectIDs": [String](), "selection": rule], token: f.session)
            XCTAssertEqual(granted.status, .ok, "\(granted.body ?? [:])")

            // Another person creates a project and transfers it to the person (same steps as setOwner).
            let stranger = User(displayName: "Stranger", isAdmin: false)
            try await stranger.save(on: db)
            let foreign = Project(ownerID: try stranger.requireID(), parentID: nil, name: "Planted")
            try await foreign.save(on: db)
            let policy = try ProjectSharing(project: foreign)
            policy.ownerType = "person"; policy.ownerID = try f.user.requireID()
            try await policy.save(on: db)

            let found = try await BrainMandate.query(on: db).filter(\.$grantID == grantID).first()
            let mandate = try XCTUnwrap(found)
            var resolver = ProjectSelectionResolver(userID: try f.user.requireID(), db: db)
            let covered = try await resolver.projects(of: mandate)
            XCTAssertTrue(covered.contains(try f.project.requireID()), "own project must be covered")
            XCTAssertFalse(covered.contains(try foreign.requireID()), "a project pushed in by another person is covered by the mandate without the person's choice")
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    // MARK: Fixes (card 0E5CCA05)

    private static var allExcept: [String: Any] { ["mode": "all_except", "groupIDs": [String](), "excludedProjectIDs": [String](), "excludedGroupIDs": [String]()] }

    /// Counter-check to finding 1: transferring the person's own project to themselves (or back) keeps it covered; a
    /// handed-over project shows in the preview as left out and is covered once the person names it.
    func testOwnProjectTransferredToSelfStaysCoveredAndHandedOverOneNeedsChoice() async throws {
        let f = try await OAuthFixture.make()
        do {
            let db = f.test.app.db
            _ = try await f.tokens(scope: Self.scopes)
            let firstID = try await OAuthGrant.query(on: db).first()?.id
            let grantID = try XCTUnwrap(firstID)
            let userID = try f.user.requireID(), ownID = try f.project.requireID()
            let moved = try await f.test.json(.PUT, "/v1/projects/\(ownID)/owner",
                ["version": f.project.version, "ownerType": "person", "ownerID": userID.uuidString], token: f.session)
            XCTAssertEqual(moved.status, .ok, "\(moved.body ?? [:])")

            let stranger = User(displayName: "Stranger", isAdmin: false)
            try await stranger.save(on: db)
            let foreign = Project(ownerID: try stranger.requireID(), parentID: nil, name: "Handed over")
            try await foreign.save(on: db)
            let foreignID = try foreign.requireID()
            let policy = try ProjectSharing(project: foreign)
            policy.ownerType = "person"; policy.ownerID = userID
            try await policy.save(on: db)

            let preview = try await f.test.json(.POST, "/v1/project-selection/preview", ["projectIDs": [String](), "selection": Self.allExcept], token: f.session)
            XCTAssertEqual(preview.status, .ok, "\(preview.body ?? [:])")
            let reached = preview.body?["projectIDs"] as? [String] ?? []
            XCTAssertTrue(reached.contains(ownID.uuidString), "own project transferred to oneself must stay in \"all except\"")
            XCTAssertFalse(reached.contains(foreignID.uuidString))
            XCTAssertEqual(preview.body?["agentCreatedProjectIDs"] as? [String], [foreignID.uuidString], "the preview names the handed-over project")

            let chosen = try await f.test.json(.PUT, "/v1/settings/brain-mandate",
                ["grantID": grantID.uuidString, "projectIDs": [foreignID.uuidString], "selection": Self.allExcept], token: f.session)
            XCTAssertEqual(chosen.status, .ok, "\(chosen.body ?? [:])")
            let found = try await BrainMandate.query(on: db).filter(\.$grantID == grantID).first()
            var resolver = ProjectSelectionResolver(userID: userID, db: db)
            let covered = try await resolver.projects(of: try XCTUnwrap(found))
            XCTAssertTrue(covered.contains(ownID))
            XCTAssertTrue(covered.contains(foreignID), "named explicitly, the handed-over project is covered")
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    /// Finding 2: removing a project drops exclusions of deleted projects; a rule may not grow past the limit by saving.
    func testExcludeDropsDeletedProjectsAndSavingCannotGrowPastLimit() async throws {
        SelectionLimits.maxExcluded = 3
        defer { SelectionLimits.maxExcluded = 500 }
        let f = try await OAuthFixture.make()
        do {
            let db = f.test.app.db
            _ = try await f.tokens(scope: Self.scopes)
            let firstID = try await OAuthGrant.query(on: db).first()?.id
            let grantID = try XCTUnwrap(firstID)
            let userID = try f.user.requireID()
            let put = try await f.test.json(.PUT, "/oauth/grants/\(grantID)/projects", ["project_ids": [String](), "selection": Self.allExcept], token: f.session)
            XCTAssertEqual(put.status, .ok, "\(put.body ?? [:])")
            var owned: [Project] = []
            for i in 0..<5 {
                let p = Project(ownerID: userID, parentID: nil, name: "Own \(i)")
                try await p.save(on: db)
                owned.append(p)
            }
            for p in owned.prefix(4) { try await ConnectionService.remove(project: try p.requireID(), grantID: grantID, actor: f.user, db: db) }
            let gone = try owned[0].requireID()
            try await owned[0].delete(on: db)
            try await ConnectionService.remove(project: try owned[4].requireID(), grantID: grantID, actor: f.user, db: db)
            let stored = try await ProjectSelectionRow.find(grantID, on: db)
            let excluded = try XCTUnwrap(stored).excludedProjectIDs
            XCTAssertFalse(excluded.contains(gone), "a deleted project is dropped from the exclusions")
            XCTAssertEqual(Set(excluded), Set(try owned.dropFirst().map { try $0.requireID() }))

            // 4 stored exclusions: saving 4 works, saving 5 (growth past both limits) is refused.
            var rule = Self.allExcept
            rule["excludedProjectIDs"] = excluded.map(\.uuidString)
            let same = try await f.test.json(.PUT, "/oauth/grants/\(grantID)/projects", ["project_ids": [String](), "selection": rule], token: f.session)
            XCTAssertEqual(same.status, .ok, "\(same.body ?? [:])")
            rule["excludedProjectIDs"] = excluded.map(\.uuidString) + [f.other.id!.uuidString]
            let grown = try await f.test.json(.PUT, "/oauth/grants/\(grantID)/projects", ["project_ids": [String](), "selection": rule], token: f.session)
            XCTAssertEqual(grown.status, .badRequest)
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    /// Finding 3: the share dialog only considers connections of people who can read the project.
    func testShareDialogCandidatesSkipPeopleWithoutReadAccess() async throws {
        let f = try await OAuthFixture.make()
        do {
            let db = f.test.app.db
            _ = try await f.tokens(scope: Self.scopes)
            let firstID = try await OAuthGrant.query(on: db).first()?.id
            let grantID = try XCTUnwrap(firstID)
            let put = try await f.test.json(.PUT, "/oauth/grants/\(grantID)/projects", ["project_ids": [String](), "selection": Self.allExcept], token: f.session)
            XCTAssertEqual(put.status, .ok, "\(put.body ?? [:])")
            let stranger = User(displayName: "Stranger", isAdmin: false)
            try await stranger.save(on: db)
            let strangerID = try stranger.requireID()
            let firstClient = try await OAuthClient.query(on: db).first()
            let client = try XCTUnwrap(firstClient)
            let foreign = OAuthGrant(userID: strangerID, clientID: try client.requireID(), resource: "x", scopes: ["projects:read"], projects: [try f.project.requireID()])
            try await foreign.save(on: db)
            let row = ProjectSelectionRow()
            row.id = try foreign.requireID(); row.userID = strangerID; row.mode = "all_except"
            row.groupIDs = []; row.excludedProjectIDs = []; row.excludedGroupIDs = []
            try await row.save(on: db)

            let candidates = try await ConnectionService.candidateGrants(for: f.project, db: db).compactMap(\.id)
            XCTAssertEqual(candidates, [grantID])
            let listed = try await ConnectionService.list(project: f.project, actor: f.user, db: db).map(\.grantID)
            XCTAssertEqual(listed, [grantID])
        } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }
}
