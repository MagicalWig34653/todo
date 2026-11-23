import Fluent
import XCTVapor
@testable import TodoKit

/// ADR 0035: the three tables, their keys and cascades on SQLite and MariaDB.
final class WebhookMigrationTests: XCTestCase {
    private func endpoint(_ userID: UUID) -> WebhookEndpoint {
        let e = WebhookEndpoint()
        e.userID = userID; e.urlCiphertext = "v1.x"; e.keyID = "k"; e.urlMask = "https://hooks.example.test"
        e.enabled = true; e.consecutiveFailures = 0; e.createdAt = Date(); e.updatedAt = Date()
        return e
    }

    func testTablesKeysAndCascades() async throws {
        let test = try await TestApp.make()
        defer { Task { await test.shutdown() } }
        let db = test.app.db
        let user = User(displayName: "Lino", isAdmin: false); try await user.save(on: db)
        let project = Project(ownerID: try user.requireID(), parentID: nil, name: "P"); try await project.save(on: db)
        let userID = try user.requireID(), projectID = try project.requireID()

        // One endpoint per person.
        try await endpoint(userID).create(on: db)
        do { try await endpoint(userID).create(on: db); XCTFail("one webhook per person") } catch {}

        // One exclusion per person and project.
        try await WebhookExclusion(userID: userID, projectID: projectID).create(on: db)
        do { try await WebhookExclusion(userID: userID, projectID: projectID).create(on: db); XCTFail("exclusion is unique") } catch {}

        // Any number of closed rows, but only one open bundle per person.
        for _ in 0..<3 { try await WebhookDelivery(userID: userID, event: "person_action", anzahl: 1, kindsMask: 1, due: Date(), open: false).create(on: db) }
        try await WebhookDelivery(userID: userID, event: "person_action", anzahl: 1, kindsMask: 1, due: Date(), open: true).create(on: db)
        do { try await WebhookDelivery(userID: userID, event: "person_action", anzahl: 1, kindsMask: 1, due: Date(), open: true).create(on: db); XCTFail("one open bundle") } catch {}
        try await assertEqual(try await WebhookDelivery.query(on: db).count(), 4)

        // Round trip of the optional columns.
        let openRow = try await WebhookDelivery.query(on: db).filter(\.$openMarker == "open").first()
        let row = try XCTUnwrap(openRow)
        row.httpStatus = 503; row.errorCode = "http_503"; row.state = "failed"; row.openMarker = nil; row.finishedAt = Date()
        try await row.save(on: db)
        let found = try await WebhookDelivery.find(try row.requireID(), on: db)
        let reread = try XCTUnwrap(found)
        XCTAssertEqual(reread.httpStatus, 503); XCTAssertEqual(reread.errorCode, "http_503"); XCTAssertNil(reread.openMarker); XCTAssertNotNil(reread.finishedAt)
        // A closed bundle frees the slot.
        try await WebhookDelivery(userID: userID, event: "person_action", anzahl: 1, kindsMask: 1, due: Date(), open: true).create(on: db)

        // Deleting the project removes its exclusion only.
        try await project.delete(on: db)
        try await assertEqual(try await WebhookExclusion.query(on: db).count(), 0)
        try await assertEqual(try await WebhookEndpoint.query(on: db).count(), 1)

        // Deleting the person removes everything.
        try await user.delete(on: db)
        try await assertEqual(try await WebhookEndpoint.query(on: db).count(), 0)
        try await assertEqual(try await WebhookDelivery.query(on: db).count(), 0)
    }

    func testAtomicMergeAddsCountAndKindsInOneStatement() async throws {
        let test = try await TestApp.make()
        defer { Task { await test.shutdown() } }
        let db = test.app.db
        let user = User(displayName: "Lino", isAdmin: false); try await user.save(on: db)
        let userID = try user.requireID()
        let e = endpoint(userID); try await e.create(on: db)
        let now = Date()
        for kind in ["comment.created", "task.created", "comment.created", "review.accepted", "task.created"] {
            try await WebhookBundler.bundle(userID: userID, mask: try XCTUnwrap(WebhookKinds.mask(kind)), now: now, on: db)
        }
        let rows = try await WebhookDelivery.query(on: db).all()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.anzahl, 5)
        XCTAssertEqual(WebhookKinds.kinds(rows.first?.kindsMask ?? 0), ["comment.created", "review.accepted", "task.created"])
        // Whitelist: bits are stable and the list is the one of the ADR.
        XCTAssertEqual(Set(WebhookKinds.bits.keys), ["question.answered", "review.accepted", "review.changes_requested", "comment.created", "task.created", "task.moved", "task.status_changed"])
        XCTAssertEqual(Set(WebhookKinds.bits.values).count, WebhookKinds.bits.count)
    }

    func testMigrationRevertAndPrepareRoundTrip() async throws {
        let test = try await TestApp.make()
        defer { Task { await test.shutdown() } }
        let db = test.app.db
        try await CreateWebhookSchema().revert(on: db)
        try await CreateWebhookSchema().prepare(on: db)
        let user = User(displayName: "Lino", isAdmin: false); try await user.save(on: db)
        try await endpoint(try user.requireID()).create(on: db)
        try await assertEqual(try await WebhookEndpoint.query(on: db).count(), 1)
    }
}
