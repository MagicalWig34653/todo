import XCTVapor
@testable import TodoKit

/// The upload capability is checked before the body is collected, so unauthenticated callers cannot make the server buffer it.
final class AttachmentUploadAuthOrderTests: XCTestCase {
    func testInvalidTokenIsRejectedBeforeBodyLimitOrBuffering() async throws {
        let t = try await TestApp.make()
        defer { Task { await t.shutdown() } }
        let oversized = ByteBuffer(repeating: 0x41, count: t.app.settings.attachmentMaxBytes + 1024)
        let id = UUID().uuidString
        // Real HTTP server: the body limit is enforced by the HTTP layer only there.
        try await t.app.testable(method: .running(hostname: "127.0.0.1", port: 0)).test(.PUT, "/v1/attachments/\(id)/upload", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: "wrong")
            req.body = oversized
        }, afterResponse: { res async in XCTAssertEqual(res.status, .notFound, "real server") })
        // Bad token, no token: rejected by the capability check (404), not by the body limit (413).
        try await t.app.test(.PUT, "/v1/attachments/\(id)/upload", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: "wrong")
            req.body = oversized
        }, afterResponse: { res async in XCTAssertEqual(res.status, .notFound) })
        try await t.app.test(.PUT, "/v1/attachments/\(id)/upload", beforeRequest: { req in req.body = oversized },
                             afterResponse: { res async in XCTAssertEqual(res.status, .notFound) })
    }

    func testParallelUploadSlotsPerAccountAreBounded() async throws {
        let slots = UploadSlots(limit: 2)
        let owner = UUID()
        let a = await slots.acquire(owner), b = await slots.acquire(owner)
        let c = await slots.acquire(owner)
        XCTAssertTrue(a); XCTAssertTrue(b); XCTAssertFalse(c)
        let other = await slots.acquire(UUID())
        XCTAssertTrue(other)
        await slots.release(owner)
        let again = await slots.acquire(owner)
        XCTAssertTrue(again)
    }
}
