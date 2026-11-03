import Crypto
import Foundation
import Fluent
import XCTVapor
@testable import TodoKit

/// Agents must be able to see what people attach: chat entry, signed short-lived download link.
final class AttachmentVisionTests: XCTestCase {
    let helper = AttachmentTests()

    private func completed(_ t: TestApp, _ alice: User, _ task: UUID, token: String, body: [String: Any] = [:]) async throws -> UUID {
        let service = AttachmentService()
        let cap = try await service.begin(helper.input(task), user: alice, db: t.app.db)
        try await service.upload(cap.attachmentID, token: cap.token, data: helper.png, db: t.app.db)
        let done = try await t.json(.POST, "/v1/attachments/\(cap.attachmentID)/complete", body, token: token)
        XCTAssertEqual(done.status, .ok)
        return cap.attachmentID
    }

    private func download(_ t: TestApp, _ path: String, method: HTTPMethod = .GET) async throws -> (HTTPStatus, HTTPHeaders, Data) {
        var out: (HTTPStatus, HTTPHeaders, Data) = (.ok, [:], Data())
        try await t.app.test(method, path, afterResponse: { res async in out = (res.status, res.headers, Data(res.body.readableBytesView)) })
        return out
    }

    func testPersonUploadAppearsInChatOnceWithAttachmentRef() async throws {
        let (t, alice, _, task, a, _) = try await helper.fixture()
        defer { Task { await t.shutdown() } }
        let id = try await completed(t, alice, task, token: a)
        // Completing again does not add a second entry.
        let again = try await t.json(.POST, "/v1/attachments/\(id)/complete", [:], token: a)
        XCTAssertEqual(again.status, .ok)
        let chat = try await t.json(.GET, "/v1/tasks/\(task)/comments", token: a)
        let entries = try XCTUnwrap(chat.list)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0]["kind"] as? String, "attachment")
        XCTAssertEqual(entries[0]["authorKind"] as? String, "person")
        let refs = try XCTUnwrap(entries[0]["attachments"] as? [[String: Any]])
        XCTAssertEqual(refs.first?["id"] as? String, id.uuidString)
        XCTAssertEqual(refs.first?["filename"] as? String, "screenshot.png")
        XCTAssertEqual(refs.first?["mediaType"] as? String, "image/png")
        XCTAssertEqual(refs.first?["size"] as? Int, helper.png.count)
    }

    func testUploadIntoQuestionChatAndForeignThreadRejected() async throws {
        let (t, alice, _, task, a, _) = try await helper.fixture()
        defer { Task { await t.shutdown() } }
        let service = AttachmentService()
        let cap = try await service.begin(helper.input(task), user: alice, db: t.app.db)
        try await service.upload(cap.attachmentID, token: cap.token, data: helper.png, db: t.app.db)
        // Unknown question: refused before completion, no entry, the file stays pending.
        let bad = try await t.json(.POST, "/v1/attachments/\(cap.attachmentID)/complete", ["questionID": UUID().uuidString], token: a)
        XCTAssertEqual(bad.status, .notFound)
        let row = try await Attachment.find(cap.attachmentID, on: t.app.db)
        XCTAssertEqual(row?.status, "pending")
        let entries = try await TaskComment.query(on: t.app.db).filter(\.$attachmentID == cap.attachmentID).count()
        XCTAssertEqual(entries, 0)

    }

    func testSignedLinkSecurity() async throws {
        let (t, alice, _, task, a, _) = try await helper.fixture()
        defer { Task { await t.shutdown() } }
        let id = try await completed(t, alice, task, token: a)
        let second = try await completed(t, alice, task, token: a)
        let link = AttachmentLink.path(for: id)

        // Works without a session, with safe headers.
        let ok = try await download(t, link.path)
        XCTAssertEqual(ok.0, .ok); XCTAssertEqual(ok.2, helper.png)
        XCTAssertEqual(ok.1.first(name: .cacheControl), "no-store")
        XCTAssertEqual(ok.1.first(name: "X-Content-Type-Options"), "nosniff")
        XCTAssertTrue(ok.1.first(name: .contentDisposition)?.hasPrefix("attachment;") == true)

        // Signature tampering (flip last hex digit), missing or short signature, different exp.
        let sig = String(link.path.suffix(64))
        let flipped = String(sig.dropLast()) + (sig.last == "0" ? "1" : "0")
        let tampered = try await download(t, link.path.replacingOccurrences(of: sig, with: flipped))
        XCTAssertEqual(tampered.0, .notFound)
        let short = try await download(t, "/v1/attachments/\(id)/download?exp=9999999999&sig=abc")
        XCTAssertEqual(short.0, .notFound)
        let exp = Int(link.expiresAt.timeIntervalSince1970)
        let moved = try await download(t, link.path.replacingOccurrences(of: "exp=\(exp)", with: "exp=\(exp + 3600)"))
        XCTAssertEqual(moved.0, .notFound)
        // Wrong attachment id with a valid signature of another one.
        let swapped = try await download(t, link.path.replacingOccurrences(of: id.uuidString, with: second.uuidString))
        XCTAssertEqual(swapped.0, .notFound)
        // Other methods never pass through the signature.
        let post = try await download(t, link.path, method: .POST)
        XCTAssertNotEqual(post.0, .ok)

        // Expiry (verified without waiting): valid now, invalid after the five minutes.
        let now = Date()
        XCTAssertTrue(AttachmentLink.verify(id: id, exp: String(exp), sig: sig, now: now))
        XCTAssertFalse(AttachmentLink.verify(id: id, exp: String(exp), sig: sig, now: now.addingTimeInterval(AttachmentLink.lifetime + 1)))
        // A far-future expiry cannot be forged into a long-lived link even with a matching signature.
        XCTAssertFalse(AttachmentLink.verify(id: id, exp: String(exp + 86_400), sig: sig, now: now))

        // The session-less route is a no-op for preview.
        let preview = try await download(t, "/v1/attachments/\(id)/preview?exp=\(exp)&sig=\(sig)")
        XCTAssertEqual(preview.0, .unauthorized)

        // Replay after delete: the same link no longer works.
        let found = try await Attachment.find(id, on: t.app.db)
        let row = try XCTUnwrap(found)
        row.status = "deleted"; try await row.save(on: t.app.db)
        let gone = try await download(t, link.path)
        XCTAssertEqual(gone.0, .notFound)
    }

    func testUnannouncedAttachmentsGetANoteButOnlyOnce() async throws {
        let (t, alice, _, task, _, _) = try await helper.fixture()
        defer { Task { await t.shutdown() } }
        let service = AttachmentService()
        let cap = try await service.begin(helper.input(task), user: alice, db: t.app.db)
        try await service.upload(cap.attachmentID, token: cap.token, data: helper.png, db: t.app.db)
        _ = try await service.complete(cap.attachmentID, user: alice, db: t.app.db)
        let note = try await AttachmentChat.unannounced(taskID: task, on: t.app.db)
        XCTAssertEqual(note?.kind, "attachments_note")
        XCTAssertEqual(note?.attachments?.count, 1)
        let stored = try await Attachment.find(cap.attachmentID, on: t.app.db)
        let a = try XCTUnwrap(stored)
        try await AttachmentChat.record(a, user: alice, target: .init(), on: t.app.db)
        let after = try await AttachmentChat.unannounced(taskID: task, on: t.app.db)
        XCTAssertNil(after)
    }
}
