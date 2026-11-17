import Fluent
import XCTVapor
@testable import TodoKit

/// ADR 0030: voice memos of channel #brain have no task. They must not change anything for task attachments.
final class VoiceTasklessAttachmentTests: AttachmentTestBase {
    private func upload(_ t: TestApp, token: String, data: Data, role: String = "voice", media: String = "audio/mp4",
                        taskID: UUID? = nil) async throws -> (status: HTTPStatus, id: String?, body: [String: Any]?) {
        var body: [String: Any] = ["filename": "memo.m4a", "role": role, "mediaType": media, "size": data.count,
                                   "checksum": AttachmentChecksum.sha256(data)]
        if let taskID { body["taskID"] = taskID.uuidString }
        let b = try await t.json(.POST, "/v1/attachments/begin", body, token: token)
        guard b.status == .ok, let r = b.body else { return (b.status, nil, b.body) }
        let id = try XCTUnwrap(r["attachmentID"] as? String)
        var put = HTTPStatus.ok
        try await t.app.test(.PUT, try XCTUnwrap(r["uploadURL"] as? String), beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: r["token"] as! String)
            req.body = ByteBuffer(data: data)
        }, afterResponse: { res async in put = res.status })
        guard put == .noContent else { return (put, id, nil) }
        let done = try await t.json(.POST, "/v1/attachments/\(id)/complete", token: token)
        return (done.status, id, done.body)
    }

    func testVoiceMemoWithoutTaskIsOwnerOnlyAndSurvivesCleanup() async throws {
        let (t, _, _, _, a, b) = try await fixture()
        defer { Task { await t.shutdown() } }
        let audio = AudioFixtures.m4a(duration: 3000)
        let done = try await upload(t, token: a, data: audio)
        XCTAssertEqual(done.status, .ok, "\(done.body ?? [:])")
        let id = try XCTUnwrap(done.id)
        XCTAssertNil(done.body?["taskID"] as? String, "a task-less memo reports no task")

        let own = try await t.app.test(.GET, "/v1/attachments/\(id)/download", beforeRequest: { $0.headers.bearerAuthorization = .init(token: a) }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok); XCTAssertEqual(Data(res.body.readableBytesView), audio)
        })
        _ = own
        let foreign = try await t.json(.GET, "/v1/attachments/\(id)/download", token: b)
        XCTAssertEqual(foreign.status, .notFound)
        let anonymous = try await t.json(.GET, "/v1/attachments/\(id)/download")
        XCTAssertEqual(anonymous.status, .unauthorized)
        // Another account may not complete or abort it either.
        let foreignAbort = try await t.json(.DELETE, "/v1/attachments/\(id)", token: b)
        XCTAssertEqual(foreignAbort.status, .notFound)

        let removed = try await AttachmentService().cleanup(db: t.app.db)
        XCTAssertEqual(removed, 0, "cleanup must not treat the missing task as an orphan")
        let still = try await Attachment.find(UUID(uuidString: id), on: t.app.db)
        XCTAssertNotNil(still)
        XCTAssertEqual(still?.taskID, UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
    }

    /// Parallel begin requests must not push the account past the loose-voice limit (count and insert under one lock).
    func testParallelBeginRequestsCannotExceedTheLooseVoiceLimit() async throws {
        let (t, alice, _, _, a, _) = try await fixture()
        defer { Task { await t.shutdown() } }
        let limit = AttachmentService.maxLooseVoice
        for n in 0..<(limit - 1) {
            let row = Attachment()
            row.id = UUID(); row.taskID = Attachment.noTask; row.ownerID = try alice.requireID()
            row.filename = "m\(n).m4a"; row.role = "voice"; row.mediaType = "audio/mp4"; row.size = 10
            row.checksum = String(repeating: "a", count: 64); row.status = "pending"; row.createdAt = Date()
            row.objectKey = "attachments/\(row.id!.uuidString.lowercased())"
            try await row.create(on: t.app.db)
        }
        let audio = AudioFixtures.m4a(duration: 3000)
        let statuses = try await withThrowingTaskGroup(of: HTTPStatus.self) { group -> [HTTPStatus] in
            for _ in 0..<8 {
                group.addTask {
                    let body: [String: Any] = ["filename": "memo.m4a", "role": "voice", "mediaType": "audio/mp4", "size": audio.count,
                                               "checksum": AttachmentChecksum.sha256(audio)]
                    return try await t.json(.POST, "/v1/attachments/begin", body, token: a).status
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(statuses.filter { $0 == .ok }.count, 1, "\(statuses)")
        let loose = try await AttachmentService.looseVoiceAttachments(owner: try alice.requireID(), db: t.app.db).count
        XCTAssertEqual(loose, limit)
    }

    func testOtherRolesStillNeedATaskAndTaskBoundVoiceKeepsWorking() async throws {
        let (t, _, _, task, a, _) = try await fixture()
        defer { Task { await t.shutdown() } }
        let noTaskImage = try await upload(t, token: a, data: png, role: "result", media: "image/png")
        XCTAssertEqual(noTaskImage.status, .badRequest, "only voice may omit the task")
        let bound = try await upload(t, token: a, data: AudioFixtures.m4a(duration: 1000), taskID: task)
        XCTAssertEqual(bound.status, .ok)
        XCTAssertEqual((bound.body?["taskID"] as? String)?.lowercased(), task.uuidString.lowercased())
        let list = try await t.json(.GET, "/v1/tasks/\(task)/attachments", token: a)
        XCTAssertEqual(list.list?.count, 1, "the task listing only shows task attachments")
    }
}
