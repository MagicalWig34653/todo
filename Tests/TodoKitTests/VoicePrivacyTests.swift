import Fluent
import XCTVapor
@testable import TodoKit

/// Data protection for channel #brain (ADR 0030 step 7): the account export contains the channel messages, anonymizing
/// removes audio and channel contents. Real HTTP; the data is seeded the way the voice flow stores it.
final class VoicePrivacyTests: XCTestCase {
    private let secretTranscript = "Geheimes-Transkript-Anna"
    private let secretReply = "Geheime-Antwort-Anna"
    private let foreignTranscript = "Fremdes-Transkript-Bernd"

    private struct Seeded { let recording: UUID, reply: UUID }

    private func seedVoice(_ t: TestApp, owner: UUID, transcript: String, reply: String) async throws -> Seeded {
        let db = t.app.db
        let channel = BrainChannel(ownerID: owner, kind: "brain")
        try await channel.save(on: db)
        func audio(_ name: String) async throws -> UUID {
            let data = AudioFixtures.m4a(duration: 1000)
            let a = Attachment()
            a.id = UUID(); a.taskID = Attachment.noTask; a.ownerID = owner; a.filename = name; a.role = "voice"; a.mediaType = "audio/mp4"
            a.size = data.count; a.checksum = AttachmentChecksum.sha256(data); a.status = "complete"; a.createdAt = Date()
            a.objectKey = "attachments/\(a.id!.uuidString.lowercased())"
            try await a.create(on: db)
            try await DatabaseStore().put(key: a.objectKey, data: data, db: db)
            return a.id!
        }
        let recording = try await audio("memo.m4a"), replyAudio = try await audio("reply.m4a")
        func message(_ kind: String, _ author: String, _ text: String?, _ attachment: UUID?, _ offset: TimeInterval) async throws {
            let m = ChannelMessage()
            m.channelID = try channel.requireID(); m.ownerID = owner; m.kind = kind; m.author = author; m.text = text
            m.attachmentID = attachment; m.createdAt = ChannelService.date(milliseconds: Int64((Date().timeIntervalSince1970 + offset) * 1000))
            try await m.save(on: db)
        }
        try await message("voice_in", "person", transcript, recording, 0)
        try await message("voice_out", "agent", reply, replyAudio, 1)
        return Seeded(recording: recording, reply: replyAudio)
    }

    private func export(_ t: TestApp, token: String) async throws -> String {
        var text = ""
        try await t.app.test(.GET, "/v1/me/export", beforeRequest: { $0.headers.bearerAuthorization = .init(token: token) }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
            text = String(decoding: res.body.readableBytesView, as: UTF8.self)
        })
        return text
    }

    func testExportContainsOwnChannelMessagesButNoAudioAndNothingOfOthers() async throws {
        let t = try await TestApp.make(); defer { Task { await t.shutdown() } }
        let anna = try await MailTests.account(t, "Anna Beispiel"), bernd = try await MailTests.account(t, "Bernd Fremd")
        _ = try await seedVoice(t, owner: anna.id, transcript: secretTranscript, reply: secretReply)
        _ = try await seedVoice(t, owner: bernd.id, transcript: foreignTranscript, reply: "Fremde-Antwort-Bernd")

        let text = try await export(t, token: anna.token)
        let doc = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let messages = try XCTUnwrap(doc["channelMessages"] as? [[String: Any]], "export has a channelMessages list")
        XCTAssertEqual(messages.map { $0["kind"] as? String }, ["voice_in", "voice_out"], "oldest first")
        XCTAssertEqual(messages.map { $0["text"] as? String }, [secretTranscript, secretReply])
        XCTAssertEqual(messages.map { $0["author"] as? String }, ["person", "agent"])
        XCTAssertEqual(messages.map { $0["hasAudio"] as? Bool }, [true, true], "the audio itself is not part of the export")
        XCTAssertNotNil(messages[0]["createdAt"])
        for forbidden in [foreignTranscript, "Fremde-Antwort-Bernd", "attachments/", "objectKey"] { XCTAssertFalse(text.contains(forbidden), forbidden) }
    }

    func testAnonymizeRemovesAudioAndChannelContentsOfThatAccountOnly() async throws {
        let t = try await TestApp.make(); defer { Task { await t.shutdown() } }
        let anna = try await MailTests.account(t, "Anna Beispiel"), bernd = try await MailTests.account(t, "Bernd Fremd")
        let mine = try await seedVoice(t, owner: anna.id, transcript: secretTranscript, reply: secretReply)
        let theirs = try await seedVoice(t, owner: bernd.id, transcript: foreignTranscript, reply: "Fremde-Antwort-Bernd")
        let db = t.app.db
        // A recording nobody posted yet and a job row of the account go as well.
        let loose = Attachment()
        loose.id = UUID(); loose.taskID = Attachment.noTask; loose.ownerID = anna.id; loose.filename = "loose.m4a"; loose.role = "voice"
        loose.mediaType = "audio/mp4"; loose.size = 1; loose.checksum = String(repeating: "a", count: 64); loose.status = "pending"
        loose.objectKey = "attachments/\(loose.id!.uuidString.lowercased())"; loose.createdAt = Date()
        try await loose.create(on: db)

        let r = try await t.json(.POST, "/v1/me/anonymize", ["confirm": "ANONYMIZE"], token: anna.token)
        XCTAssertEqual(r.status, .noContent)

        try await XCTAssertEqualAsync(try await ChannelMessage.query(on: db).filter(\.$ownerID == anna.id).count(), 0, "channel messages are gone")
        try await XCTAssertEqualAsync(try await BrainChannel.query(on: db).filter(\.$ownerID == anna.id).count(), 0)
        try await XCTAssertEqualAsync(try await VoiceJob.query(on: db).filter(\.$ownerID == anna.id).count(), 0)
        for id in [mine.recording, mine.reply, try loose.requireID()] {
            let gone = try await Attachment.find(id, on: db)
            XCTAssertNil(gone, "audio \(id) is gone")
            try await XCTAssertEqualAsync(try await AttachmentBlob.query(on: db).filter(\.$attachmentID == id).count(), 0, "its bytes are gone")
        }
        try await XCTAssertEqualAsync(try await Attachment.query(on: db).filter(\.$ownerID == anna.id).count(), 0)
        // Another account is untouched.
        try await XCTAssertEqualAsync(try await ChannelMessage.query(on: db).filter(\.$ownerID == bernd.id).count(), 2)
        let foreign = try await Attachment.find(theirs.recording, on: db)
        XCTAssertNotNil(foreign)
        try await XCTAssertEqualAsync(try await AttachmentBlob.query(on: db).filter(\.$attachmentID == theirs.recording).count() > 0, true)
    }

    private func XCTAssertEqualAsync<T: Equatable>(_ actual: @autoclosure () async throws -> T, _ expected: T, _ message: String = "",
                                                   file: StaticString = #filePath, line: UInt = #line) async throws {
        let value = try await actual()
        XCTAssertEqual(value, expected, message, file: file, line: line)
    }
}
