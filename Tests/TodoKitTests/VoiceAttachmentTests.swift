import Foundation
import Fluent
import XCTVapor
@testable import TodoKit

/// Synthetic but structurally valid containers: the server only reads boxes/chunks, it never decodes audio.
enum AudioFixtures {
    static let mib5 = 5 * 1024 * 1024

    private static func be32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> UInt32(24 - 8 * $0)) & 0xff) } }
    private static func be64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> UInt64(56 - 8 * $0)) & 0xff) } }
    private static func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> UInt32(8 * $0)) & 0xff) } }
    private static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8)] }
    private static func box(_ type: String, _ payload: [UInt8]) -> [UInt8] { be32(UInt32(8 + payload.count)) + Array(type.utf8) + payload }

    /// M4A with `duration`/`timescale` in mvhd (version 0, or 1 when `version1`), padded with mdat to `totalSize`.
    static func m4a(duration: UInt64, timescale: UInt32 = 1000, totalSize: Int? = nil, version1: Bool = false,
                    brand: String = "M4A ", fragmented: Bool = false) -> Data {
        let ftyp = box("ftyp", Array(brand.utf8) + be32(0) + Array(brand.utf8))
        var mvhd: [UInt8]
        if version1 {
            mvhd = [1, 0, 0, 0] + be64(0) + be64(0) + be32(timescale) + be64(duration)
        } else {
            mvhd = [0, 0, 0, 0] + be32(0) + be32(0) + be32(timescale) + be32(UInt32(duration))
        }
        mvhd += Array(repeating: 0, count: 100 + (version1 ? 12 : 0) - mvhd.count)
        let moov = box("moov", box("mvhd", mvhd))
        var out = ftyp + moov
        if fragmented { out += box("moof", [0, 0, 0, 0]) }
        let pad = max(8, (totalSize ?? (out.count + 8 + 64)) - out.count)
        out += box("mdat", Array(repeating: 7, count: pad - 8))
        return Data(out)
    }

    /// PCM WAV whose data chunk holds `dataBytes` bytes and whose fmt chunk declares `byteRate`.
    static func wav(dataBytes: Int, byteRate: UInt32 = 16000) -> Data {
        let fmt = le16(1) + le16(1) + le32(byteRate / 2) + le32(byteRate) + le16(2) + le16(16)
        let body = Array("WAVE".utf8) + Array("fmt ".utf8) + le32(16) + fmt + Array("data".utf8) + le32(UInt32(dataBytes))
            + Array(repeating: 3, count: dataBytes)
        return Data(Array("RIFF".utf8) + le32(UInt32(body.count)) + body)
    }
}

final class VoiceAttachmentTests: AttachmentTestBase {
    private func begin(_ t: TestApp, task: UUID, token: String, data: Data, media: String, role: String = "voice",
                       size: Int? = nil) async throws -> (status: HTTPStatus, body: [String: Any]?) {
        let r = try await t.json(.POST, "/v1/attachments/begin", [
            "taskID": task.uuidString, "filename": "memo.m4a", "role": role, "mediaType": media,
            "size": size ?? data.count, "checksum": AttachmentChecksum.sha256(data)
        ], token: token)
        return (r.status, r.body)
    }

    /// Full REST flow; returns the status of the first step that fails, `.ok` plus the id when everything succeeds.
    private func upload(_ t: TestApp, task: UUID, token: String, data: Data, media: String, role: String = "voice")
        async throws -> (status: HTTPStatus, id: String?) {
        let b = try await begin(t, task: task, token: token, data: data, media: media, role: role)
        guard b.status == .ok, let body = b.body else { return (b.status, nil) }
        let id = try XCTUnwrap(body["attachmentID"] as? String)
        var putStatus = HTTPStatus.ok
        try await t.app.test(.PUT, try XCTUnwrap(body["uploadURL"] as? String), beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: body["token"] as! String)
            req.body = ByteBuffer(data: data)
        }, afterResponse: { res async in putStatus = res.status })
        guard putStatus == .noContent else { return (putStatus, id) }
        let done = try await t.json(.POST, "/v1/attachments/\(id)/complete", token: token)
        return (done.status, id)
    }

    func testAudioMagicBytes() {
        XCTAssertEqual(AttachmentService.mediaType(AudioFixtures.m4a(duration: 1000)), "audio/mp4")
        XCTAssertEqual(AttachmentService.mediaType(AudioFixtures.m4a(duration: 1000, brand: "mp42")), "audio/mp4")
        XCTAssertEqual(AttachmentService.mediaType(AudioFixtures.wav(dataBytes: 100)), "audio/wav")
        XCTAssertNil(AttachmentService.mediaType(AudioFixtures.m4a(duration: 1000, brand: "heic")))
        XCTAssertNil(AttachmentService.mediaType(Data("ID3\u{3}\u{0}".utf8)))  // MP3
        XCTAssertNil(AttachmentService.mediaType(Data("OggS\u{0}\u{2}".utf8)))
        XCTAssertEqual(AttachmentService.mediaType(Data("RIFF1234WEBP".utf8)), "image/webp")  // unchanged
    }

    func testM4ADurationBoundary() async throws {
        let (t, _, _, task, token, _) = try await fixture()
        defer { Task { await t.shutdown() } }
        let ok = try await upload(t, task: task, token: token, data: AudioFixtures.m4a(duration: 120_000), media: "audio/mp4")
        XCTAssertEqual(ok.status, .ok)
        let v1 = try await upload(t, task: task, token: token, data: AudioFixtures.m4a(duration: 120_000, version1: true), media: "audio/mp4")
        XCTAssertEqual(v1.status, .ok)
        let other = try await upload(t, task: task, token: token, data: AudioFixtures.m4a(duration: 120 * 44100, timescale: 44100), media: "audio/mp4")
        XCTAssertEqual(other.status, .ok)
        let over = try await upload(t, task: task, token: token, data: AudioFixtures.m4a(duration: 120_001), media: "audio/mp4")
        XCTAssertEqual(over.status, .unprocessableEntity)
        let overV1 = try await upload(t, task: task, token: token, data: AudioFixtures.m4a(duration: 120 * 44100 + 1, timescale: 44100, version1: true), media: "audio/mp4")
        XCTAssertEqual(overV1.status, .unprocessableEntity)
        // Nothing of the rejected upload becomes visible.
        let list = try await t.json(.GET, "/v1/tasks/\(task)/attachments", token: token)
        XCTAssertEqual(list.list?.count, 3)
    }

    func testWavDurationBoundary() async throws {
        let (t, _, _, task, token, _) = try await fixture()
        defer { Task { await t.shutdown() } }
        let ok = try await upload(t, task: task, token: token, data: AudioFixtures.wav(dataBytes: 120 * 16000), media: "audio/wav")
        XCTAssertEqual(ok.status, .ok)
        let over = try await upload(t, task: task, token: token, data: AudioFixtures.wav(dataBytes: 120 * 16000 + 1), media: "audio/wav")
        XCTAssertEqual(over.status, .unprocessableEntity)
        // A data chunk that claims more than the file holds is measured by the bytes actually present.
        var lying = AudioFixtures.wav(dataBytes: 16000)
        lying.replaceSubrange(40..<44, with: [0xff, 0xff, 0xff, 0x7f])
        let truncated = try await upload(t, task: task, token: token, data: lying, media: "audio/wav")
        XCTAssertEqual(truncated.status, .ok)
    }

    func testSizeBoundaryFiveMiB() async throws {
        let (t, _, _, task, token, _) = try await fixture()
        defer { Task { await t.shutdown() } }
        let exact = AudioFixtures.m4a(duration: 1000, totalSize: AudioFixtures.mib5)
        XCTAssertEqual(exact.count, AudioFixtures.mib5)
        let ok = try await upload(t, task: task, token: token, data: exact, media: "audio/mp4")
        XCTAssertEqual(ok.status, .ok)
        let wavExact = AudioFixtures.wav(dataBytes: AudioFixtures.mib5 - 44, byteRate: 43_700)
        XCTAssertEqual(wavExact.count, AudioFixtures.mib5)
        let wavOk = try await upload(t, task: task, token: token, data: wavExact, media: "audio/wav")
        XCTAssertEqual(wavOk.status, .ok)
        let over = AudioFixtures.m4a(duration: 1000, totalSize: AudioFixtures.mib5 + 1)
        let rejected = try await upload(t, task: task, token: token, data: over, media: "audio/mp4")
        XCTAssertEqual(rejected.status, .payloadTooLarge)
        // The declared size cannot be understated: the real body decides.
        let understated = try await begin(t, task: task, token: token, data: over, media: "audio/mp4", size: exact.count)
        XCTAssertEqual(understated.status, .ok)
        var putStatus = HTTPStatus.ok
        try await t.app.test(.PUT, try XCTUnwrap(understated.body?["uploadURL"] as? String), beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: understated.body?["token"] as! String)
            req.body = ByteBuffer(data: over)
        }, afterResponse: { res async in putStatus = res.status })
        XCTAssertEqual(putStatus, .unprocessableEntity)
    }

    func testRejectedTypesRolesAndMagic() async throws {
        let (t, _, _, task, token, _) = try await fixture()
        defer { Task { await t.shutdown() } }
        let m4a = AudioFixtures.m4a(duration: 1000)
        for media in ["audio/mpeg", "audio/ogg", "audio/webm", "audio/aac", "audio/x-wav"] {
            let r = try await begin(t, task: task, token: token, data: m4a, media: media)
            XCTAssertEqual(r.status, .unsupportedMediaType, media)
        }
        // Audio only with role voice; role voice only with audio.
        let wrongRole = try await begin(t, task: task, token: token, data: m4a, media: "audio/mp4", role: "result")
        XCTAssertEqual(wrongRole.status, .badRequest)
        let pngVoice = try await begin(t, task: task, token: token, data: png, media: "image/png", role: "voice")
        XCTAssertEqual(pngVoice.status, .badRequest)
        // Declared M4A but WAV bytes (and the reverse, and a PNG): magic mismatch.
        let wavAsM4a = try await upload(t, task: task, token: token, data: AudioFixtures.wav(dataBytes: 100), media: "audio/mp4")
        XCTAssertEqual(wavAsM4a.status, .unsupportedMediaType)
        let m4aAsWav = try await upload(t, task: task, token: token, data: m4a, media: "audio/wav")
        XCTAssertEqual(m4aAsWav.status, .unsupportedMediaType)
        let pngAsM4a = try await upload(t, task: task, token: token, data: png, media: "audio/mp4")
        XCTAssertEqual(pngAsM4a.status, .unsupportedMediaType)
        // Structurally broken containers: no moov, zero duration, fragmented.
        let noMoov = Data(m4a.prefix(20)) + Data([0, 0, 0, 16]) + Data("mdat".utf8) + Data(repeating: 1, count: 8)
        let r1 = try await upload(t, task: task, token: token, data: noMoov, media: "audio/mp4")
        XCTAssertEqual(r1.status, .unprocessableEntity)
        let r2 = try await upload(t, task: task, token: token, data: AudioFixtures.m4a(duration: 0), media: "audio/mp4")
        XCTAssertEqual(r2.status, .unprocessableEntity)
        let r3 = try await upload(t, task: task, token: token, data: AudioFixtures.m4a(duration: 1000, fragmented: true), media: "audio/mp4")
        XCTAssertEqual(r3.status, .unprocessableEntity)
        // Existing roles and types keep working.
        for role in ["reference", "progress", "result"] {
            let r = try await upload(t, task: task, token: token, data: png, media: "image/png", role: role)
            XCTAssertEqual(r.status, .ok, role)
        }
    }

    func testDownloadIsPrivateNoStoreAndForeignAccountGets404() async throws {
        let (t, _, _, task, token, foreign) = try await fixture()
        defer { Task { await t.shutdown() } }
        let data = AudioFixtures.m4a(duration: 5000, totalSize: 4096)
        let up = try await upload(t, task: task, token: token, data: data, media: "audio/mp4")
        let id = try XCTUnwrap(up.id)
        try await t.app.test(.GET, "/v1/attachments/\(id)/download", beforeRequest: { $0.headers.bearerAuthorization = .init(token: token) }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(Data(res.body.readableBytesView), data)
            XCTAssertEqual(res.headers.first(name: .contentType), "audio/mp4")
            XCTAssertEqual(res.headers.first(name: .cacheControl), "private, no-store")
            XCTAssertEqual(res.headers.first(name: "X-Content-Type-Options"), "nosniff")
            XCTAssertEqual(res.headers.first(name: .acceptRanges), "bytes")
        })
        try await t.app.test(.GET, "/v1/attachments/\(id)/download", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token); req.headers.replaceOrAdd(name: .range, value: "bytes=0-99")
        }, afterResponse: { res async in XCTAssertEqual(res.status, .partialContent) })
        // Second account: download, preview, list and even starting an upload on the foreign task are 404.
        let dl = try await t.json(.GET, "/v1/attachments/\(id)/download", token: foreign)
        XCTAssertEqual(dl.status, .notFound)
        let pv = try await t.json(.GET, "/v1/attachments/\(id)/preview", token: foreign)
        XCTAssertEqual(pv.status, .notFound)
        let ls = try await t.json(.GET, "/v1/tasks/\(task)/attachments", token: foreign)
        XCTAssertEqual(ls.status, .notFound)
        let foreignBegin = try await begin(t, task: task, token: foreign, data: data, media: "audio/mp4")
        XCTAssertEqual(foreignBegin.status, .notFound)
        let anonymous = try await t.json(.GET, "/v1/attachments/\(id)/download")
        XCTAssertEqual(anonymous.status, .unauthorized)
        // Audio has no inline preview even for the owner.
        let own = try await t.json(.GET, "/v1/attachments/\(id)/preview", token: token)
        XCTAssertEqual(own.status, .unsupportedMediaType)
    }
}
