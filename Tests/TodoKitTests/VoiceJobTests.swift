import Fluent
import XCTVapor
@testable import TodoKit

/// Voice jobs and the runner capability "sprache" (ADR 0030, step 3). Everything goes through HTTP like a real app and
/// runner; only time is moved by rewriting timestamps, never by sleeping.
final class VoiceJobTests: XCTestCase {
    private let audio = AudioFixtures.m4a(duration: 4000)

    struct Setup {
        let f: AgentFixture
        var t: TestApp { f.app }
        var human: String { f.human }
        var runner1: String { f.runner }
    }

    private func eq<T: Equatable>(_ actual: @autoclosure () async throws -> T, _ expected: T, _ message: String = "",
                                  file: StaticString = #filePath, line: UInt = #line) async throws {
        let value = try await actual()
        XCTAssertEqual(value, expected, message, file: file, line: line)
    }
    private func isNil<T>(_ actual: @autoclosure () async throws -> T?, _ message: String = "",
                          file: StaticString = #filePath, line: UInt = #line) async throws {
        let value = try await actual()
        XCTAssertNil(value, message, file: file, line: line)
    }
    private func unwrap<T>(_ actual: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
        let value = try await actual()
        return try XCTUnwrap(value, file: file, line: line)
    }

    private func make() async throws -> Setup { Setup(f: try await AgentFixture.make()) }

    private func run(_ s: Setup, _ body: () async throws -> Void) async throws {
        do { try await body() } catch { await s.t.shutdown(); throw error }
        await s.t.shutdown()
    }

    /// A second paired runner device of the same account.
    private func secondRunner(_ s: Setup) async throws -> (id: String, token: String) {
        let p = try await s.t.json(.POST, "/v1/agents/devices", ["label": "Mac 2"], token: s.human)
        let paired = try await s.t.json(.POST, "/v1/runner/pair", ["code": try XCTUnwrap(p.body?["code"] as? String)])
        return (try XCTUnwrap(p.body?["deviceID"] as? String), try XCTUnwrap(paired.body?["token"] as? String))
    }

    /// Another account with a session and its own paired runner.
    private func stranger(_ s: Setup) async throws -> (session: String, runner: String, id: UUID) {
        let u = User(displayName: "Stranger", isAdmin: false)
        try await u.save(on: s.t.app.db)
        let session = AuthSupport.randomToken()
        try await UserSession(userID: u.requireID(), tokenHash: AuthSupport.hash(session), expiresAt: Date().addingTimeInterval(3600)).save(on: s.t.app.db)
        let p = try await s.t.json(.POST, "/v1/agents/devices", ["label": "Other Mac"], token: session)
        let paired = try await s.t.json(.POST, "/v1/runner/pair", ["code": try XCTUnwrap(p.body?["code"] as? String)])
        return (session, try XCTUnwrap(paired.body?["token"] as? String), try u.requireID())
    }

    private func heartbeat(_ s: Setup, _ token: String, _ caps: [String] = ["sprache"]) async throws -> (status: HTTPStatus, body: [String: Any]?) {
        let r = try await s.t.json(.POST, "/v1/runner/voice/heartbeat", ["capabilities": caps], token: token)
        return (r.status, r.body)
    }

    /// Real upload flow without a task (ADR 0030 decision on task_id).
    private func uploadMemo(_ s: Setup, token: String? = nil, data: Data? = nil) async throws -> String {
        let data = data ?? audio
        let b = try await s.t.json(.POST, "/v1/attachments/begin", ["filename": "memo.m4a", "role": "voice", "mediaType": "audio/mp4",
            "size": data.count, "checksum": AttachmentChecksum.sha256(data)], token: token ?? s.human)
        let body = try XCTUnwrap(b.body, "\(b.status)")
        let id = try XCTUnwrap(body["attachmentID"] as? String)
        try await s.t.app.test(.PUT, try XCTUnwrap(body["uploadURL"] as? String), beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: body["token"] as! String)
            req.body = ByteBuffer(data: data)
        }, afterResponse: { res async in XCTAssertEqual(res.status, .noContent) })
        let done = try await s.t.json(.POST, "/v1/attachments/\(id)/complete", token: token ?? s.human)
        XCTAssertEqual(done.status, .ok)
        return id
    }

    private func speak(_ s: Setup, token: String? = nil, memo: String? = nil, clientUUID: String = UUID().uuidString)
        async throws -> (status: HTTPStatus, body: [String: Any]?) {
        let attachment: String
        if let memo { attachment = memo } else { attachment = try await uploadMemo(s, token: token) }
        let r = try await s.t.json(.POST, "/v1/channels/brain/messages", ["kind": "voice_in", "attachmentID": attachment, "clientUUID": clientUUID],
                                   token: token ?? s.human)
        return (r.status, r.body)
    }

    private func messages(_ s: Setup, token: String? = nil) async throws -> [[String: Any]] {
        let r = try await s.t.json(.GET, "/v1/channels/brain/messages?limit=100", token: token ?? s.human)
        XCTAssertEqual(r.status, .ok)
        return (r.body?["items"] as? [[String: Any]] ?? []).reversed()
    }

    private func claim(_ s: Setup, _ token: String, job: String? = nil) async throws -> (status: HTTPStatus, body: [String: Any]?) {
        try await Self.rawClaim(s.t, token, job: job)
    }

    /// Static so that two claims can run concurrently (`async let`) without capturing the test case.
    private static func rawClaim(_ t: TestApp, _ token: String, job: String? = nil) async throws -> (status: HTTPStatus, body: [String: Any]?) {
        let r = try await t.json(.POST, job.map { "/v1/runner/voice/jobs/\($0)/claim" } ?? "/v1/runner/voice/claim", token: token)
        return (r.status, r.body)
    }

    private func jobCommand(_ s: Setup, _ token: String, _ job: String, _ action: String, _ body: [String: Any]) async throws -> (status: HTTPStatus, body: [String: Any]?) {
        let r = try await s.t.json(.POST, "/v1/runner/voice/jobs/\(job)/\(action)", body, token: token)
        return (r.status, r.body)
    }

    private func download(_ s: Setup, _ token: String, _ job: String, generation: Int) async throws -> (status: HTTPStatus, data: Data) {
        var out: (HTTPStatus, Data) = (.ok, Data())
        try await s.t.app.test(.GET, "/v1/runner/voice/jobs/\(job)/audio?generation=\(generation)", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
        }, afterResponse: { res async in out = (res.status, Data(res.body.readableBytesView)) })
        return out
    }

    private func putReply(_ s: Setup, _ token: String, _ job: String, generation: Int, data: Data) async throws -> (status: HTTPStatus, body: [String: Any]?) {
        var out: (HTTPStatus, [String: Any]?) = (.ok, nil)
        try await s.t.app.test(.PUT, "/v1/runner/voice/jobs/\(job)/reply-audio?generation=\(generation)", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
            req.body = ByteBuffer(data: data)
        }, afterResponse: { res async in
            out = (res.status, (try? JSONSerialization.jsonObject(with: Data(res.body.readableBytesView))) as? [String: Any])
        })
        return out
    }

    /// Moves a job's clocks into the past instead of waiting.
    private func age(_ s: Setup, job: String, lease: Bool = false, expiry: Bool = false) async throws {
        let past = Date().addingTimeInterval(-5)
        let row = try await jobRow(s, job)
        if lease { row.leaseUntil = past }
        if expiry { row.expiresAt = past }
        try await row.save(on: s.t.app.db)
    }

    private func setLastSeen(_ s: Setup, _ date: Date) async throws {
        let device = try await unwrap(try await RunnerDevice.find(UUID(uuidString: s.f.deviceID), on: s.t.app.db))
        device.lastSeenAt = date
        try await device.save(on: s.t.app.db)
    }

    private func jobRow(_ s: Setup, _ id: String) async throws -> VoiceJob {
        try await unwrap(try await VoiceJob.find(UUID(uuidString: id), on: s.t.app.db))
    }

    // MARK: Capability

    func testHeartbeatReportsCapabilitiesAndOwnerCanSwitchThemOff() async throws {
        let s = try await make()
        try await run(s) {
            var device = try await s.t.json(.GET, "/v1/agents/devices", token: s.human)
            XCTAssertEqual((device.list?.first?["capabilities"] as? [String]) ?? [], [], "no capability before the first heartbeat")
            let anonymous = try await s.t.json(.POST, "/v1/runner/voice/heartbeat", ["capabilities": ["sprache"]])
            XCTAssertEqual(anonymous.status, .unauthorized)
            let human = try await s.t.json(.POST, "/v1/runner/voice/heartbeat", ["capabilities": ["sprache"]], token: s.human)
            XCTAssertEqual(human.status, .unauthorized, "a session is not a device")

            let hb = try await heartbeat(s, s.runner1, ["sprache", "sprache", "other"])
            XCTAssertEqual(hb.status, .ok, "\(hb.body ?? [:])")
            device = try await s.t.json(.GET, "/v1/agents/devices", token: s.human)
            let row = try XCTUnwrap(device.list?.first)
            XCTAssertEqual((row["capabilities"] as? [String])?.sorted(), ["other", "sprache"])
            XCTAssertEqual(row["disabledCapabilities"] as? [String] ?? [], [])
            XCTAssertNotNil(row["lastSeenAt"])
            let bad = try await heartbeat(s, s.runner1, ["Not Valid!"])
            XCTAssertEqual(bad.status, .badRequest)
            let many = try await heartbeat(s, s.runner1, (0..<11).map { "cap\($0)" })
            XCTAssertEqual(many.status, .badRequest)

            // The owner switch is checked on the server and only for own devices.
            let other = try await stranger(s)
            let foreign = try await s.t.json(.PUT, "/v1/agents/devices/\(s.f.deviceID)/capabilities", ["disabled": ["sprache"]], token: other.session)
            XCTAssertEqual(foreign.status, .notFound)
            let off = try await s.t.json(.PUT, "/v1/agents/devices/\(s.f.deviceID)/capabilities", ["disabled": ["sprache"]], token: s.human)
            XCTAssertEqual(off.status, .ok, "\(off.body ?? [:])")
            let after = try await heartbeat(s, s.runner1)
            XCTAssertEqual(after.body?["capabilities"] as? [String] ?? ["x"], [], "effective capabilities exclude what the owner switched off")
            XCTAssertEqual(after.body?["disabledCapabilities"] as? [String], ["sprache"])
            let status = try await speak(s)
            XCTAssertEqual(status.status, .created)
            let list = try await messages(s)
            XCTAssertEqual(list.last?["kind"] as? String, "status", "disabled capability counts as unreachable")
        }
    }

    // MARK: Reachability

    func testVoiceInWithoutDeviceAnswersTextOnlyAndCreatesNoJob() async throws {
        let s = try await make()
        try await run(s) {
            let r = try await speak(s)
            XCTAssertEqual(r.status, .created)
            let list = try await messages(s)
            XCTAssertEqual(list.map { $0["kind"] as? String }, ["voice_in", "status"])
            XCTAssertEqual(list.last?["author"] as? String, "agent")
            XCTAssertEqual(list.last?["text"] as? String, "Brain gerade nur per Text erreichbar.")
            let jobs = try await VoiceJob.query(on: s.t.app.db).count()
            XCTAssertEqual(jobs, 0)
            // A replay of the same post answers once, it does not add a second status message.
            let key = UUID().uuidString
            let memo = try await uploadMemo(s)
            _ = try await speak(s, memo: memo, clientUUID: key)
            let replay = try await speak(s, memo: memo, clientUUID: key)
            XCTAssertEqual(replay.status, .ok)
            let kinds = try await messages(s).map { $0["kind"] as? String }
            XCTAssertEqual(kinds.filter { $0 == "status" }.count, 2)
        }
    }

    func testStaleHeartbeatOrWrongCapabilityOrRevokedDeviceMeansNoJob() async throws {
        let s = try await make()
        try await run(s) {
            _ = try await heartbeat(s, s.runner1, ["other"])
            _ = try await speak(s)
            try await eq(try await VoiceJob.query(on: s.t.app.db).count(), 0, "device without sprache")

            _ = try await heartbeat(s, s.runner1)
            try await setLastSeen(s, Date().addingTimeInterval(-3600))
            _ = try await speak(s)
            try await eq(try await VoiceJob.query(on: s.t.app.db).count(), 0, "stale heartbeat")

            _ = try await heartbeat(s, s.runner1)
            let revoked = try await s.t.json(.DELETE, "/v1/agents/devices/\(s.f.deviceID)", token: s.human)
            XCTAssertEqual(revoked.status, .noContent)
            _ = try await speak(s)
            try await eq(try await VoiceJob.query(on: s.t.app.db).count(), 0, "revoked device")
            let afterRevoke = try await heartbeat(s, s.runner1)
            XCTAssertEqual(afterRevoke.status, .unauthorized)
        }
    }

    // MARK: Flow

    func testFullFlowClaimDownloadReplyResultAndIdempotentRetry() async throws {
        let s = try await make()
        try await run(s) {
            _ = try await heartbeat(s, s.runner1)
            let memo = try await uploadMemo(s)
            let said = try await speak(s, memo: memo)
            XCTAssertEqual(said.status, .created)
            try await eq(try await messages(s).map { $0["kind"] as? String }, ["voice_in"], "reachable: no status message")

            let queued = try await s.t.json(.GET, "/v1/runner/voice/jobs", token: s.runner1)
            XCTAssertEqual(queued.list?.count, 1)
            let claimed = try await claim(s, s.runner1)
            XCTAssertEqual(claimed.status, .ok, "\(claimed.body ?? [:])")
            let job = try XCTUnwrap(claimed.body?["id"] as? String)
            XCTAssertEqual(claimed.body?["generation"] as? Int, 1)
            XCTAssertEqual(claimed.body?["state"] as? String, "claimed")
            XCTAssertEqual((claimed.body?["attachmentID"] as? String)?.lowercased(), memo.lowercased())
            let info = try XCTUnwrap(claimed.body?["audio"] as? [String: Any])
            XCTAssertEqual(info["mediaType"] as? String, "audio/mp4")
            XCTAssertEqual(info["size"] as? Int, audio.count)
            XCTAssertEqual(info["checksum"] as? String, AttachmentChecksum.sha256(audio))
            let lease = try await jobRow(s, job)
            let seconds = try XCTUnwrap(lease.leaseUntil).timeIntervalSinceNow
            XCTAssertTrue((55...61).contains(seconds), "lease is 60 s, got \(seconds)")
            let noMore = try await claim(s, s.runner1)
            XCTAssertEqual(noMore.status, .noContent)

            let file = try await download(s, s.runner1, job, generation: 1)
            XCTAssertEqual(file.status, .ok)
            XCTAssertEqual(file.data, audio)
            let hb = try await jobCommand(s, s.runner1, job, "heartbeat", ["generation": 1])
            XCTAssertEqual(hb.status, .ok)

            let reply = AudioFixtures.m4a(duration: 2000)
            let up = try await putReply(s, s.runner1, job, generation: 1, data: reply)
            XCTAssertEqual(up.status, .ok, "\(up.body ?? [:])")
            let replyID = try XCTUnwrap(up.body?["attachmentID"] as? String)
            let result: [String: Any] = ["generation": 1, "transcript": "Wie ist die Lage?", "replyText": "Alles ruhig."]
            let done = try await jobCommand(s, s.runner1, job, "result", result)
            XCTAssertEqual(done.status, .ok, "\(done.body ?? [:])")
            XCTAssertEqual(done.body?["state"] as? String, "done")

            let list = try await messages(s)
            XCTAssertEqual(list.map { $0["kind"] as? String }, ["voice_in", "voice_out"])
            XCTAssertEqual(list[0]["text"] as? String, "Wie ist die Lage?", "the transcript lands on the voice_in message")
            XCTAssertEqual(list[1]["text"] as? String, "Alles ruhig.")
            XCTAssertEqual(list[1]["author"] as? String, "agent")
            XCTAssertEqual((list[1]["attachmentID"] as? String)?.lowercased(), replyID.lowercased())
            // The person can play the reply; it has no task.
            var played = Data()
            try await s.t.app.test(.GET, "/v1/attachments/\(replyID)/download", beforeRequest: { $0.headers.bearerAuthorization = .init(token: s.human) },
                                   afterResponse: { res async in XCTAssertEqual(res.status, .ok); played = Data(res.body.readableBytesView) })
            XCTAssertEqual(played, reply)

            // The runner did not see the answer arrive (network): the retry is answered, nothing is duplicated.
            let retry = try await jobCommand(s, s.runner1, job, "result", result)
            XCTAssertEqual(retry.status, .ok)
            try await eq(try await messages(s).count, 2)
            // A finished job cannot be changed any more.
            let late = try await jobCommand(s, s.runner1, job, "result", ["generation": 1, "transcript": "anders", "replyText": "anders"])
            XCTAssertEqual(late.status, .gone)
            let lateHeartbeat = try await jobCommand(s, s.runner1, job, "heartbeat", ["generation": 1])
            XCTAssertEqual(lateHeartbeat.status, .gone)
        }
    }

    func testFailureResultWritesStatusAndDeletesTheRecording() async throws {
        let s = try await make()
        try await run(s) {
            _ = try await heartbeat(s, s.runner1)
            let memo = try await uploadMemo(s)
            _ = try await speak(s, memo: memo)
            let job = try await unwrap(try await claim(s, s.runner1).body?["id"] as? String)
            let bad = try await jobCommand(s, s.runner1, job, "result", ["generation": 1, "errorCode": "Not A Code!"])
            XCTAssertEqual(bad.status, .badRequest)
            let empty = try await jobCommand(s, s.runner1, job, "result", ["generation": 1])
            XCTAssertEqual(empty.status, .badRequest, "neither an answer nor an error")
            let failed = try await jobCommand(s, s.runner1, job, "result", ["generation": 1, "errorCode": "stt_failed"])
            XCTAssertEqual(failed.status, .ok)
            XCTAssertEqual(failed.body?["state"] as? String, "failed")
            XCTAssertEqual(failed.body?["errorCode"] as? String, "stt_failed")
            let list = try await messages(s)
            XCTAssertEqual(list.last?["kind"] as? String, "status")
            XCTAssertEqual(list.last?["text"] as? String, "Die Sprachnachricht konnte nicht verarbeitet werden.")
            try await isNil(try await Attachment.find(UUID(uuidString: memo), on: s.t.app.db), "recording is deleted at once")
        }
    }

    // MARK: Claim, lease, generation

    func testRaceAndSecondRunnerCannotTakeOverAClaimedJob() async throws {
        let s = try await make()
        try await run(s) {
            let two = try await secondRunner(s)
            _ = try await heartbeat(s, s.runner1)
            _ = try await heartbeat(s, two.token)
            _ = try await speak(s)
            // Both race for the one queued job: exactly one wins.
            let app = s.t, first = s.runner1, second = two.token
            async let a = Self.rawClaim(app, first)
            async let b = Self.rawClaim(app, second)
            let results = try await [a, b]
            XCTAssertEqual(results.filter { $0.status == .ok }.count, 1, "\(results.map { $0.status })")
            // The loser is told "nothing" (204), "taken" (409) or, on the SQLite test database only, that the file is busy:
            // SQLite has no row locks and refuses a second concurrent writer. MariaDB serializes on the account row.
            let loser = try XCTUnwrap(results.first { $0.status != .ok })
            let busy = loser.status == .internalServerError && (loser.body?["reason"] as? String)?.contains("locked") == true
            XCTAssertTrue(loser.status == .noContent || loser.status == .conflict || (busy && !TestApp.useMariaDB), "\(loser)")
            let winner = results.first { $0.status == .ok }!
            let job = try XCTUnwrap(winner.body?["id"] as? String)
            let winnerToken = (try await jobRow(s, job).deviceID?.uuidString.lowercased() == s.f.deviceID.lowercased()) ? s.runner1 : two.token
            let loserToken = winnerToken == s.runner1 ? two.token : s.runner1

            let byID = try await claim(s, loserToken, job: job)
            XCTAssertEqual(byID.status, .conflict)
            XCTAssertEqual(byID.body?["reason"] as? String, "job_not_queued")
            // The loser can neither read nor answer the job, with its own or the winner's generation.
            let stolen = try await download(s, loserToken, job, generation: 1)
            XCTAssertEqual(stolen.status, .notFound)
            let hb = try await jobCommand(s, loserToken, job, "heartbeat", ["generation": 1])
            XCTAssertEqual(hb.status, .notFound)
            let result = try await jobCommand(s, loserToken, job, "result", ["generation": 1, "replyText": "stolen"])
            XCTAssertEqual(result.status, .notFound)
            try await eq(try await messages(s).count, 1, "nothing was written by the loser")
            let again = try await claim(s, winnerToken)
            XCTAssertEqual(again.status, .noContent)
        }
    }

    func testOneRunningJobPerAccountAtATime() async throws {
        let s = try await make()
        try await run(s) {
            let two = try await secondRunner(s)
            _ = try await heartbeat(s, s.runner1)
            _ = try await heartbeat(s, two.token)
            _ = try await speak(s)
            _ = try await speak(s)
            let first = try await unwrap(try await claim(s, s.runner1).body?["id"] as? String)
            let queued = try await s.t.json(.GET, "/v1/runner/voice/jobs", token: two.token)
            let secondID = try XCTUnwrap(queued.list?.first?["id"] as? String)
            XCTAssertNotEqual(first, secondID)
            let blocked = try await claim(s, two.token, job: secondID)
            XCTAssertEqual(blocked.status, .conflict)
            XCTAssertEqual(blocked.body?["reason"] as? String, "voice_job_running")
            let none = try await claim(s, two.token)
            XCTAssertEqual(none.status, .noContent)
            _ = try await jobCommand(s, s.runner1, first, "result", ["generation": 1, "replyText": "ok"])
            let next = try await claim(s, two.token)
            XCTAssertEqual(next.status, .ok, "free again once the first job is finished")
            XCTAssertEqual(next.body?["id"] as? String, secondID)
        }
    }

    func testExpiredLeaseHandsTheJobToAnotherRunnerAndFencesTheOldOne() async throws {
        let s = try await make()
        try await run(s) {
            let two = try await secondRunner(s)
            _ = try await heartbeat(s, s.runner1)
            _ = try await heartbeat(s, two.token)
            _ = try await speak(s)
            let job = try await unwrap(try await claim(s, s.runner1).body?["id"] as? String)
            let early = try await claim(s, two.token, job: job)
            XCTAssertEqual(early.status, .conflict, "a live lease cannot be taken over")

            try await age(s, job: job, lease: true)
            // Lease lost but nobody took over: the holder gets 410, not a silent extension.
            let lost = try await jobCommand(s, s.runner1, job, "heartbeat", ["generation": 1])
            XCTAssertEqual(lost.status, .gone)
            XCTAssertEqual(lost.body?["reason"] as? String, "lease_lost")
            let lostDownload = try await download(s, s.runner1, job, generation: 1)
            XCTAssertEqual(lostDownload.status, .gone)

            let taken = try await claim(s, two.token, job: job)
            XCTAssertEqual(taken.status, .ok, "\(taken.body ?? [:])")
            XCTAssertEqual(taken.body?["generation"] as? Int, 2)
            // The old holder is fenced with 409 for every call.
            for action in ["heartbeat", "result"] {
                let r = try await jobCommand(s, s.runner1, job, action, ["generation": 1, "replyText": "late"])
                XCTAssertEqual(r.status, .conflict, action)
                XCTAssertEqual(r.body?["reason"] as? String, "stale_generation")
            }
            let staleDownload = try await download(s, s.runner1, job, generation: 1)
            XCTAssertEqual(staleDownload.status, .conflict)
            let staleReply = try await putReply(s, s.runner1, job, generation: 1, data: AudioFixtures.m4a(duration: 1000))
            XCTAssertEqual(staleReply.status, .conflict)
            let fine = try await jobCommand(s, two.token, job, "result", ["generation": 2, "replyText": "Hallo"])
            XCTAssertEqual(fine.status, .ok)
            try await eq(try await messages(s).filter { $0["kind"] as? String == "text" }.count, 1)
        }
    }

    func testJobExpiresAfterTenMinutesWithStatusMessageAndRecordingGone() async throws {
        let s = try await make()
        try await run(s) {
            _ = try await heartbeat(s, s.runner1)
            let memo = try await uploadMemo(s)
            _ = try await speak(s, memo: memo)
            let job = try await unwrap(try await claim(s, s.runner1).body?["id"] as? String)
            let row = try await jobRow(s, job)
            let window = row.expiresAt.timeIntervalSince(row.createdAt)
            XCTAssertEqual(window, 600, accuracy: 1, "jobs live 10 minutes")

            try await age(s, job: job, expiry: true)
            // Whoever looks first notices: here the app reads the channel.
            let list = try await messages(s)
            XCTAssertEqual(list.last?["kind"] as? String, "status")
            XCTAssertEqual(list.last?["text"] as? String, "Die Sprachnachricht ist abgelaufen.")
            try await eq(try await jobRow(s, job).state, "expired")
            try await isNil(try await Attachment.find(UUID(uuidString: memo), on: s.t.app.db))
            let hb = try await jobCommand(s, s.runner1, job, "heartbeat", ["generation": 1])
            XCTAssertEqual(hb.status, .gone)
            XCTAssertEqual(hb.body?["reason"] as? String, "job_ended")
            try await eq(try await claim(s, s.runner1).status, .noContent)
            // Sweeping again does not add a second status message.
            try await eq(try await messages(s).filter { $0["kind"] as? String == "status" }.count, 1)
        }
    }

    func testQueuedJobAlsoExpiresWhenTheRunnerAsksFirst() async throws {
        let s = try await make()
        try await run(s) {
            _ = try await heartbeat(s, s.runner1)
            _ = try await speak(s)
            let id = try await unwrap(try await VoiceJob.query(on: s.t.app.db).first()?.id)
            try await age(s, job: id.uuidString, expiry: true)
            let queued = try await s.t.json(.GET, "/v1/runner/voice/jobs", token: s.runner1)
            XCTAssertEqual(queued.list?.count, 0)
            try await eq(try await VoiceJob.find(id, on: s.t.app.db)?.state, "expired")
            try await eq(try await messages(s).last?["kind"] as? String, "status")
        }
    }

    // MARK: Limits

    func testLimitsOpenJobsRatePerMinuteAndPayloads() async throws {
        let s = try await make()
        try await run(s) {
            _ = try await heartbeat(s, s.runner1)
            for _ in 0..<5 { let r = try await speak(s); XCTAssertEqual(r.status, .created) }
            let sixth = try await speak(s)
            XCTAssertEqual(sixth.status, .tooManyRequests)
            XCTAssertEqual(sixth.body?["reason"] as? String, "too_many_open_voice_jobs")
            try await eq(try await messages(s).filter { $0["kind"] as? String == "voice_in" }.count, 5, "a refused post leaves no message")

            // 10 per minute, counted over all voice_in messages, also those that found no device.
            let rate = try await make()
            try await run(rate) {
                for i in 0..<10 { let r = try await speak(rate); XCTAssertEqual(r.status, .created, "post \(i)") }
                let eleventh = try await speak(rate)
                XCTAssertEqual(eleventh.status, .tooManyRequests)
                XCTAssertEqual(eleventh.body?["reason"] as? String, "voice_rate_limited")
            }
        }
    }

    func testDailyLimitCountsVoiceInMessagesOfTheLastDay() async throws {
        let s = try await make()
        try await run(s) {
            let channel = BrainChannel(ownerID: try s.f.user.requireID(), kind: "brain")
            try await channel.save(on: s.t.app.db)
            let hourAgo = Date().addingTimeInterval(-3600)
            for _ in 0..<200 {
                let m = ChannelMessage()
                m.channelID = try channel.requireID(); m.ownerID = try s.f.user.requireID(); m.kind = "voice_in"; m.author = "person"
                m.attachmentID = UUID(); m.createdAt = hourAgo
                try await m.save(on: s.t.app.db)
            }
            let r = try await speak(s)
            XCTAssertEqual(r.status, .tooManyRequests)
            XCTAssertEqual(r.body?["reason"] as? String, "voice_rate_limited")
        }
    }

    func testResultAndReplyAudioLimits() async throws {
        let s = try await make()
        try await run(s) {
            _ = try await heartbeat(s, s.runner1)
            _ = try await speak(s)
            let job = try await unwrap(try await claim(s, s.runner1).body?["id"] as? String)
            let longText = String(repeating: "a", count: 4001)
            let a = try await jobCommand(s, s.runner1, job, "result", ["generation": 1, "replyText": longText])
            XCTAssertEqual(a.status, .badRequest)
            let b = try await jobCommand(s, s.runner1, job, "result", ["generation": 1, "transcript": longText, "replyText": "ok"])
            XCTAssertEqual(b.status, .badRequest)
            let ok = String(repeating: "a", count: 4000)
            let tooBig = AudioFixtures.m4a(duration: 1000, totalSize: VoiceLimits.maxBytes + 1)
            let big = try await putReply(s, s.runner1, job, generation: 1, data: tooBig)
            XCTAssertEqual(big.status, .payloadTooLarge)
            let tooLong = try await putReply(s, s.runner1, job, generation: 1, data: AudioFixtures.m4a(duration: 121_000))
            XCTAssertEqual(tooLong.status, .unprocessableEntity)
            let notAudio = try await putReply(s, s.runner1, job, generation: 1, data: Data("hello".utf8))
            XCTAssertEqual(notAudio.status, .unsupportedMediaType)
            let anonymous = try await s.t.json(.PUT, "/v1/runner/voice/jobs/\(job)/reply-audio?generation=1")
            XCTAssertEqual(anonymous.status, .unauthorized)
            let first = try await putReply(s, s.runner1, job, generation: 1, data: AudioFixtures.m4a(duration: 1000))
            XCTAssertEqual(first.status, .ok)
            let second = try await putReply(s, s.runner1, job, generation: 1, data: AudioFixtures.m4a(duration: 2000))
            XCTAssertEqual(second.status, .ok, "a retried upload replaces the earlier reply")
            try await eq(try await Attachment.query(on: s.t.app.db).filter(\.$role == "voice").count(), 2, "memo plus one reply")
            let max = try await jobCommand(s, s.runner1, job, "result", ["generation": 1, "transcript": ok, "replyText": ok])
            XCTAssertEqual(max.status, .ok)
        }
    }

    // MARK: Tenants

    func testAnotherAccountSeesAndTouchesNothing() async throws {
        let s = try await make()
        try await run(s) {
            let other = try await stranger(s)
            _ = try await heartbeat(s, s.runner1)
            _ = try await heartbeat(s, other.runner)
            _ = try await speak(s)
            let job = try await unwrap(try await VoiceJob.query(on: s.t.app.db).first()?.id?.uuidString)

            let listed = try await s.t.json(.GET, "/v1/runner/voice/jobs", token: other.runner)
            XCTAssertEqual(listed.list?.count, 0)
            try await eq(try await claim(s, other.runner).status, .noContent)
            try await eq(try await claim(s, other.runner, job: job).status, .notFound)
            try await eq(try await download(s, other.runner, job, generation: 1).status, .notFound)
            try await eq(try await jobCommand(s, other.runner, job, "result", ["generation": 1, "replyText": "x"]).status, .notFound)
            try await eq(try await messages(s, token: other.session).count, 0, "the other channel is empty")
            try await eq(try await jobRow(s, job).state, "queued")

            // The device of account A does not serve account B's recording either.
            _ = try await speak(s, token: other.session)
            try await eq(try await messages(s, token: other.session).map { $0["kind"] as? String }, ["voice_in"])
            let mine = try await claim(s, s.runner1)
            let ownJob = try XCTUnwrap(mine.body?["id"] as? String)
            XCTAssertEqual(ownJob.lowercased(), job.lowercased())
        }
    }

    // MARK: Schema

    func testMigrationIsAdditiveAndRepeatable() async throws {
        let s = try await make()
        try await run(s) {
            try await s.t.app.autoMigrate()
            try await eq(try await RunnerDevice.query(on: s.t.app.db).count(), 1, "existing devices keep working")
            let device = try await unwrap(try await RunnerDevice.find(UUID(uuidString: s.f.deviceID), on: s.t.app.db))
            XCTAssertNotNil(device.tokenHash)
            try await eq(try await VoiceJob.query(on: s.t.app.db).count(), 0)
        }
    }
}
