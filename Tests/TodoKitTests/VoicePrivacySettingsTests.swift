import Fluent
import XCTVapor
@testable import TodoKit

/// Voice privacy settings (ADR 0030 step 7, rest): consent, "keep audio" (up to 30 days), "delete voice history", export.
/// Real HTTP; time is moved with the `now:` parameter of the sweep, never by waiting.
final class VoicePrivacySettingsTests: XCTestCase {
    private let day: TimeInterval = 86400

    // MARK: Helpers

    private func eq<T: Equatable>(_ actual: @autoclosure () async throws -> T, _ expected: T, _ message: String = "",
                                  file: StaticString = #filePath, line: UInt = #line) async throws {
        let value = try await actual()
        XCTAssertEqual(value, expected, message, file: file, line: line)
    }

    private func make() async throws -> (t: TestApp, anna: MailTests.Account, bernd: MailTests.Account) {
        let t = try await TestApp.make()
        return (t, try await MailTests.account(t, "Anna Beispiel"), try await MailTests.account(t, "Bernd Fremd"))
    }

    private func run(_ t: TestApp, _ body: () async throws -> Void) async throws {
        do { try await body() } catch { await t.shutdown(); throw error }
        await t.shutdown()
    }

    private func privacy(_ t: TestApp, _ token: String) async throws -> [String: Any] {
        let r = try await t.json(.GET, "/v1/me/voice-privacy", token: token)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
        return r.body ?? [:]
    }

    private func put(_ t: TestApp, _ token: String, _ body: [String: Any]) async throws -> (status: HTTPStatus, body: [String: Any]?) {
        let r = try await t.json(.PUT, "/v1/me/voice-privacy", body, token: token)
        return (r.status, r.body)
    }

    /// One recording (voice_in) or reply (voice_out) with its audio bytes, aged by `age` seconds.
    @discardableResult
    private func seed(_ t: TestApp, owner: UUID, kind: String, age: TimeInterval, text: String = "t", withAudio: Bool = true) async throws -> (message: UUID, attachment: UUID?) {
        let db = t.app.db
        let channel: BrainChannel
        if let existing = try await BrainChannel.query(on: db).filter(\.$ownerID == owner).first() { channel = existing }
        else { channel = BrainChannel(ownerID: owner, kind: "brain"); try await channel.save(on: db) }
        var attachmentID: UUID?
        if withAudio {
            let data = AudioFixtures.m4a(duration: 1000)
            let a = Attachment()
            a.id = UUID(); a.taskID = Attachment.noTask; a.ownerID = owner; a.filename = "a.m4a"; a.role = "voice"; a.mediaType = "audio/mp4"
            a.size = data.count; a.checksum = AttachmentChecksum.sha256(data); a.status = "complete"; a.createdAt = Date()
            a.objectKey = "attachments/\(a.id!.uuidString.lowercased())"
            try await a.create(on: db)
            try await DatabaseStore().put(key: a.objectKey, data: data, db: db)
            attachmentID = a.id
        }
        let m = ChannelMessage()
        m.channelID = try channel.requireID(); m.ownerID = owner; m.kind = kind; m.author = kind == "voice_in" ? "person" : "agent"; m.text = text
        m.attachmentID = attachmentID
        m.createdAt = ChannelService.date(milliseconds: Int64((Date().timeIntervalSince1970 - age) * 1000))
        try await m.save(on: db)
        return (try m.requireID(), attachmentID)
    }

    private func hasAudio(_ t: TestApp, _ id: UUID?) async throws -> Bool {
        guard let id else { return false }
        let found = try await Attachment.find(id, on: t.app.db)
        let row = found != nil
        let blobCount = try await AttachmentBlob.query(on: t.app.db).filter(\.$attachmentID == id).count()
        let bytes = blobCount > 0
        XCTAssertEqual(row, bytes, "row and bytes go together")
        return row
    }

    private func enableKeepAudio(_ t: TestApp, _ token: String) async throws {
        let r = try await put(t, token, ["consent": true, "keepAudio": true])
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
    }

    private func message(_ t: TestApp, _ id: UUID) async throws -> ChannelMessage {
        let found = try await ChannelMessage.find(id, on: t.app.db)
        return try XCTUnwrap(found)
    }

    // MARK: Read

    func testGetWithoutChannelReturnsDefaultsAndDoesNotCreateTheChannel() async throws {
        let (t, anna, _) = try await make()
        try await run(t) {
            let anonymous = try await t.json(.GET, "/v1/me/voice-privacy")
            XCTAssertEqual(anonymous.status, .unauthorized)
            let body = try await privacy(t, anna.token)
            XCTAssertEqual(body["consent"] as? Bool, false)
            XCTAssertNil(body["consentAt"] as? String)
            XCTAssertEqual(body["keepAudio"] as? Bool, false)
            XCTAssertEqual(body["messageCount"] as? Int, 0)
            XCTAssertEqual(body["audioCount"] as? Int, 0)
            let retention = try XCTUnwrap(body["retention"] as? [String: Any])
            XCTAssertEqual(retention["inputHours"] as? Int, 24)
            XCTAssertEqual(retention["replyDays"] as? Int, 7)
            XCTAssertEqual(retention["keepDays"] as? Int, 30)
            try await eq(try await BrainChannel.query(on: t.app.db).count(), 0, "reading does not create the channel")
        }
    }

    func testCountsOnlyOwnMessagesAndMessagesWithAudio() async throws {
        let (t, anna, bernd) = try await make()
        try await run(t) {
            try await seed(t, owner: anna.id, kind: "voice_in", age: 60)
            try await seed(t, owner: anna.id, kind: "text", age: 30, withAudio: false)
            try await seed(t, owner: bernd.id, kind: "voice_in", age: 60)
            let body = try await privacy(t, anna.token)
            XCTAssertEqual(body["messageCount"] as? Int, 2)
            XCTAssertEqual(body["audioCount"] as? Int, 1)
        }
    }

    // MARK: Write

    func testPutMatrix() async throws {
        let (t, anna, _) = try await make()
        try await run(t) {
            let anonymous = try await t.json(.PUT, "/v1/me/voice-privacy", ["consent": true])
            XCTAssertEqual(anonymous.status, .unauthorized)

            // Empty or unusable bodies change nothing and do not create the channel.
            for body: [String: Any] in [[:], ["other": 1], ["consent": "yes"]] {
                let r = try await put(t, anna.token, body)
                XCTAssertEqual(r.status, .badRequest, "\(body)")
                XCTAssertEqual(r.body?["reason"] as? String, "invalid_request")
            }
            try await eq(try await BrainChannel.query(on: t.app.db).count(), 0)

            // Keep audio needs consent: nothing is stored, not even the channel.
            let early = try await put(t, anna.token, ["keepAudio": true])
            XCTAssertEqual(early.status, .conflict)
            XCTAssertEqual(early.body?["reason"] as? String, "consent_required")
            let both = try await put(t, anna.token, ["consent": false, "keepAudio": true])
            XCTAssertEqual(both.status, .conflict, "withdrawing and keeping in one request is a contradiction")
            try await eq(try await BrainChannel.query(on: t.app.db).count(), 0)

            // Consent creates the channel lazily and sets consentAt once.
            let granted = try await put(t, anna.token, ["consent": true])
            XCTAssertEqual(granted.status, .ok, "\(granted.body ?? [:])")
            XCTAssertEqual(granted.body?["consent"] as? Bool, true)
            XCTAssertEqual(granted.body?["keepAudio"] as? Bool, false)
            XCTAssertNotNil(granted.body?["consentAt"] as? String)
            try await eq(try await BrainChannel.query(on: t.app.db).count(), 1)
            let stamp = granted.body?["consentAt"] as? String
            try await Task.sleep(nanoseconds: 1_100_000_000)  // the timestamp has whole-second resolution
            let again = try await put(t, anna.token, ["consent": true])
            XCTAssertEqual(again.status, .ok)
            XCTAssertEqual(again.body?["consentAt"] as? String, stamp, "a repeated grant keeps the first timestamp")

            // Partial update: keepAudio alone leaves consent as it is.
            let keep = try await put(t, anna.token, ["keepAudio": true])
            XCTAssertEqual(keep.status, .ok)
            XCTAssertEqual(keep.body?["consent"] as? Bool, true)
            XCTAssertEqual(keep.body?["keepAudio"] as? Bool, true)
            let off = try await put(t, anna.token, ["keepAudio": false])
            XCTAssertEqual(off.body?["keepAudio"] as? Bool, false)
            XCTAssertEqual(off.body?["consent"] as? Bool, true)
            _ = try await put(t, anna.token, ["keepAudio": true])

            // Withdrawing consent clears the timestamp and switches keepAudio off.
            let withdrawn = try await put(t, anna.token, ["consent": false])
            XCTAssertEqual(withdrawn.status, .ok)
            XCTAssertEqual(withdrawn.body?["consent"] as? Bool, false)
            XCTAssertEqual(withdrawn.body?["keepAudio"] as? Bool, false)
            XCTAssertNil(withdrawn.body?["consentAt"] as? String)
            let read = try await privacy(t, anna.token)
            XCTAssertEqual(read["consent"] as? Bool, false)
            XCTAssertEqual(read["keepAudio"] as? Bool, false)
            let blocked = try await put(t, anna.token, ["keepAudio": true])
            XCTAssertEqual(blocked.status, .conflict)
        }
    }

    func testSettingsAreAccountScoped() async throws {
        let (t, anna, bernd) = try await make()
        try await run(t) {
            try await enableKeepAudio(t, anna.token)
            let theirs = try await privacy(t, bernd.token)
            XCTAssertEqual(theirs["consent"] as? Bool, false)
            XCTAssertEqual(theirs["keepAudio"] as? Bool, false)
            let r = try await put(t, bernd.token, ["keepAudio": true])
            XCTAssertEqual(r.status, .conflict, "Anna's consent does not count for Bernd")
            let mine = try await privacy(t, anna.token)
            XCTAssertEqual(mine["keepAudio"] as? Bool, true)
        }
    }

    // MARK: Retention

    func testSweepKeepsAudioForThirtyDaysOnlyWithKeepAudio() async throws {
        let (t, anna, bernd) = try await make()
        try await run(t) {
            try await enableKeepAudio(t, anna.token)
            func set(_ owner: UUID) async throws -> [String: (message: UUID, attachment: UUID?)] {
                ["in25h": try await seed(t, owner: owner, kind: "voice_in", age: 25 * 3600),
                 "out8d": try await seed(t, owner: owner, kind: "voice_out", age: 8 * day),
                 "in29d": try await seed(t, owner: owner, kind: "voice_in", age: 29 * day),
                 "in31d": try await seed(t, owner: owner, kind: "voice_in", age: 31 * day),
                 "out31d": try await seed(t, owner: owner, kind: "voice_out", age: 31 * day),
                 "fresh": try await seed(t, owner: owner, kind: "voice_in", age: 3600)]
            }
            let mine = try await set(anna.id), theirs = try await set(bernd.id)

            try await VoiceRetention.sweep(db: t.app.db)
            for key in ["in25h", "out8d", "in29d", "fresh"] {
                let kept = try await hasAudio(t, mine[key]?.attachment)
                XCTAssertTrue(kept, "keepAudio: \(key) stays")
            }
            for key in ["in31d", "out31d"] {
                let kept = try await hasAudio(t, mine[key]?.attachment)
                XCTAssertFalse(kept, "keepAudio: \(key) is past 30 days")
            }
            for key in ["in25h", "out8d", "in29d", "in31d", "out31d"] {
                let kept = try await hasAudio(t, theirs[key]?.attachment)
                XCTAssertFalse(kept, "without keepAudio: \(key) goes with the short limits")
            }
            let freshOther = try await hasAudio(t, theirs["fresh"]?.attachment)
            XCTAssertTrue(freshOther)
            // The message keeps its text and loses the pointer once the audio is gone.
            let gone = try await message(t, try XCTUnwrap(mine["in31d"]).message)
            XCTAssertNil(gone.attachmentID)
            XCTAssertEqual(gone.text, "t")
            let keptMessage = try await message(t, try XCTUnwrap(mine["in25h"]).message)
            XCTAssertEqual(keptMessage.attachmentID, mine["in25h"]?.attachment)

            // 31 days later (time moved, not waited): everything is past the long limit.
            try await VoiceRetention.sweep(db: t.app.db, now: Date().addingTimeInterval(31 * day))
            for key in ["in25h", "out8d", "in29d", "fresh"] {
                let still = try await hasAudio(t, mine[key]?.attachment)
                XCTAssertFalse(still, "after 31 more days \(key) is gone")
            }
        }
    }

    func testSwitchingKeepAudioOffRestoresTheShortLimits() async throws {
        let (t, anna, _) = try await make()
        try await run(t) {
            try await enableKeepAudio(t, anna.token)
            let old = try await seed(t, owner: anna.id, kind: "voice_in", age: 2 * day)
            try await VoiceRetention.sweep(db: t.app.db)
            let before = try await hasAudio(t, old.attachment)
            XCTAssertTrue(before)
            _ = try await put(t, anna.token, ["keepAudio": false])
            try await VoiceRetention.sweep(db: t.app.db)
            let after = try await hasAudio(t, old.attachment)
            XCTAssertFalse(after, "keepAudio off: the 24 h limit applies again at the next sweep")
        }
    }

    // MARK: Result with keepAudio

    private func processOne(_ f: AgentFixture, errorCode: String? = nil) async throws -> (message: UUID, recording: UUID) {
        let t = f.app
        let audio = AudioFixtures.m4a(duration: 4000)
        let b = try await t.json(.POST, "/v1/attachments/begin", ["filename": "memo.m4a", "role": "voice", "mediaType": "audio/mp4",
            "size": audio.count, "checksum": AttachmentChecksum.sha256(audio)], token: f.human)
        let body = try XCTUnwrap(b.body)
        let recording = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(body["attachmentID"] as? String)))
        try await t.app.test(.PUT, try XCTUnwrap(body["uploadURL"] as? String), beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: body["token"] as! String)
            req.body = ByteBuffer(data: audio)
        }, afterResponse: { res async in XCTAssertEqual(res.status, .noContent) })
        _ = try await t.json(.POST, "/v1/attachments/\(recording)/complete", token: f.human)
        _ = try await t.json(.POST, "/v1/runner/voice/heartbeat", ["capabilities": ["sprache"]], token: f.runner)
        let posted = try await t.json(.POST, "/v1/channels/brain/messages", ["kind": "voice_in", "attachmentID": recording.uuidString], token: f.human)
        XCTAssertEqual(posted.status, .created, "\(posted.body ?? [:])")
        let messageID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(posted.body?["id"] as? String)))
        let claimed = try await t.json(.POST, "/v1/runner/voice/claim", token: f.runner)
        let job = try XCTUnwrap(claimed.body?["id"] as? String)
        var result: [String: Any] = ["generation": 1]
        if let errorCode { result["errorCode"] = errorCode } else { result["transcript"] = "Hallo"; result["replyText"] = "Hi" }
        let done = try await t.json(.POST, "/v1/runner/voice/jobs/\(job)/result", result, token: f.runner)
        XCTAssertEqual(done.status, .ok, "\(done.body ?? [:])")
        return (messageID, recording)
    }

    func testDoneJobKeepsTheRecordingWithKeepAudioButFailedOneDoesNot() async throws {
        let f = try await AgentFixture.make()
        let t = f.app
        try await run(t) {
            // Default: the recording goes at once.
            let plain = try await processOne(f)
            let plainKept = try await hasAudio(t, plain.recording)
            XCTAssertFalse(plainKept)
            let plainMessage = try await message(t, plain.message)
            XCTAssertNil(plainMessage.attachmentID)

            try await enableKeepAudio(t, f.human)
            let kept = try await processOne(f)
            let keptAudio = try await hasAudio(t, kept.recording)
            XCTAssertTrue(keptAudio, "done + keepAudio: the recording stays")
            let keptMessage = try await message(t, kept.message)
            XCTAssertEqual(keptMessage.attachmentID, kept.recording)
            XCTAssertEqual(keptMessage.text, "Hallo", "the transcript is filled as usual")

            // It stays for 30 days and is then swept like any other.
            try await VoiceRetention.sweep(db: t.app.db, now: Date().addingTimeInterval(2 * day))
            let stillThere = try await hasAudio(t, kept.recording)
            XCTAssertTrue(stillThere)
            try await VoiceRetention.sweep(db: t.app.db, now: Date().addingTimeInterval(31 * day))
            let goneAfter = try await hasAudio(t, kept.recording)
            XCTAssertFalse(goneAfter)

            // A failed job deletes the recording at once, keepAudio or not.
            let failed = try await processOne(f, errorCode: "stt_failed")
            let failedKept = try await hasAudio(t, failed.recording)
            XCTAssertFalse(failedKept)
            let failedMessage = try await message(t, failed.message)
            XCTAssertNil(failedMessage.attachmentID)
        }
    }

    // MARK: Delete voice history

    private func insertJob(_ t: TestApp, owner: UUID, message: UUID, attachment: UUID) async throws {
        let now = Date()
        let job = VoiceJob()
        job.id = UUID(); job.ownerID = owner; job.messageID = message; job.attachmentID = attachment; job.requiredCapability = "sprache"
        job.state = "queued"; job.generation = 0; job.createdAt = now; job.expiresAt = now.addingTimeInterval(600)
        try await job.save(on: t.app.db)
    }

    func testDeleteVoiceHistoryRemovesOwnMessagesJobsAndAudioButKeepsSettingsAndOthers() async throws {
        let (t, anna, bernd) = try await make()
        try await run(t) {
            try await enableKeepAudio(t, anna.token)
            let a1 = try await seed(t, owner: anna.id, kind: "voice_in", age: 600)
            let a2 = try await seed(t, owner: anna.id, kind: "voice_out", age: 500)
            try await seed(t, owner: anna.id, kind: "text", age: 400, withAudio: false)
            let b1 = try await seed(t, owner: bernd.id, kind: "voice_in", age: 600)
            try await seed(t, owner: bernd.id, kind: "text", age: 100, withAudio: false)
            let channelRow = try await BrainChannel.query(on: t.app.db).filter(\.$ownerID == anna.id).first()
            let channel = try XCTUnwrap(channelRow)
            try await insertJob(t, owner: anna.id, message: a1.message, attachment: try XCTUnwrap(a1.attachment))
            try await insertJob(t, owner: bernd.id, message: b1.message, attachment: try XCTUnwrap(b1.attachment))
            // A loose voice recording of Anna that nobody posted.
            let loose = Attachment()
            loose.id = UUID(); loose.taskID = Attachment.noTask; loose.ownerID = anna.id; loose.filename = "loose.m4a"; loose.role = "voice"
            loose.mediaType = "audio/mp4"; loose.size = 1; loose.checksum = String(repeating: "a", count: 64); loose.status = "pending"
            loose.objectKey = "attachments/\(loose.id!.uuidString.lowercased())"; loose.createdAt = Date()
            try await loose.create(on: t.app.db)

            let anonymous = try await t.json(.DELETE, "/v1/channels/brain/messages")
            XCTAssertEqual(anonymous.status, .unauthorized)
            let r = try await t.json(.DELETE, "/v1/channels/brain/messages", token: anna.token)
            XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
            XCTAssertEqual(r.body?["deletedMessages"] as? Int, 3)
            XCTAssertEqual(r.body?["deletedAudio"] as? Int, 3, "recording, reply and the loose recording")

            try await eq(try await ChannelMessage.query(on: t.app.db).filter(\.$ownerID == anna.id).count(), 0)
            try await eq(try await VoiceJob.query(on: t.app.db).filter(\.$ownerID == anna.id).count(), 0)
            try await eq(try await Attachment.query(on: t.app.db).filter(\.$ownerID == anna.id).count(), 0)
            for id in [a1.attachment, a2.attachment, loose.id] {
                let still = try await hasAudio(t, id)
                XCTAssertFalse(still)
            }
            // Channel and settings stay.
            let after = try await BrainChannel.find(channel.id, on: t.app.db)
            XCTAssertNotNil(after)
            let settings = try await privacy(t, anna.token)
            XCTAssertEqual(settings["consent"] as? Bool, true)
            XCTAssertEqual(settings["keepAudio"] as? Bool, true)
            XCTAssertEqual(settings["messageCount"] as? Int, 0)
            XCTAssertEqual(settings["audioCount"] as? Int, 0)

            // The other account is untouched.
            try await eq(try await ChannelMessage.query(on: t.app.db).filter(\.$ownerID == bernd.id).count(), 2)
            try await eq(try await VoiceJob.query(on: t.app.db).filter(\.$ownerID == bernd.id).count(), 1)
            let theirs = try await hasAudio(t, b1.attachment)
            XCTAssertTrue(theirs)

            // Repeating is harmless.
            let again = try await t.json(.DELETE, "/v1/channels/brain/messages", token: anna.token)
            XCTAssertEqual(again.status, .ok)
            XCTAssertEqual(again.body?["deletedMessages"] as? Int, 0)
            XCTAssertEqual(again.body?["deletedAudio"] as? Int, 0)
            // An account without a channel gets zeros and no channel.
            let carla = try await MailTests.account(t, "Carla Neu")
            let none = try await t.json(.DELETE, "/v1/channels/brain/messages", token: carla.token)
            XCTAssertEqual(none.status, .ok)
            XCTAssertEqual(none.body?["deletedMessages"] as? Int, 0)
            try await eq(try await BrainChannel.query(on: t.app.db).filter(\.$ownerID == carla.id).count(), 0)
        }
    }

    // MARK: Export

    func testExportContainsVoicePrivacy() async throws {
        let (t, anna, _) = try await make()
        try await run(t) {
            func exported() async throws -> [String: Any] {
                var doc: [String: Any] = [:]
                try await t.app.test(.GET, "/v1/me/export", beforeRequest: { $0.headers.bearerAuthorization = .init(token: anna.token) }, afterResponse: { res async in
                    XCTAssertEqual(res.status, .ok)
                    doc = (try? JSONSerialization.jsonObject(with: Data(res.body.readableBytesView))) as? [String: Any] ?? [:]
                })
                return doc
            }
            let first = try await exported()
            var settings = try XCTUnwrap(first["voicePrivacy"] as? [String: Any], "export has voicePrivacy even without a channel")
            XCTAssertEqual(settings["consent"] as? Bool, false)
            XCTAssertEqual(settings["keepAudio"] as? Bool, false)
            XCTAssertNil(settings["consentAt"] as? String)
            try await enableKeepAudio(t, anna.token)
            let second = try await exported()
            settings = try XCTUnwrap(second["voicePrivacy"] as? [String: Any])
            XCTAssertEqual(settings["consent"] as? Bool, true)
            XCTAssertEqual(settings["keepAudio"] as? Bool, true)
            XCTAssertNotNil(settings["consentAt"] as? String)
        }
    }
}
