import Fluent
import XCTVapor
@testable import TodoKit

/// Answer logic of the brain for spoken requests (ADR 0030 step 5, T1 minimum). Real HTTP like the app and the runner:
/// the runner sends the transcript, the server answers a status request from the command center and the open questions,
/// never runs a class C action from speech and leaves every other request for the brain session in the channel.
final class VoiceBrainReplyTests: XCTestCase {
    private let audio = AudioFixtures.m4a(duration: 4000)

    private func run(_ f: AgentFixture, _ body: () async throws -> Void) async throws {
        do { try await body() } catch { await f.app.shutdown(); throw error }
        await f.app.shutdown()
    }

    private func uploadMemo(_ f: AgentFixture) async throws -> String {
        let b = try await f.app.json(.POST, "/v1/attachments/begin", ["filename": "memo.m4a", "role": "voice", "mediaType": "audio/mp4",
            "size": audio.count, "checksum": AttachmentChecksum.sha256(audio)], token: f.human)
        let body = try XCTUnwrap(b.body, "\(b.status)")
        let id = try XCTUnwrap(body["attachmentID"] as? String)
        try await f.app.app.test(.PUT, try XCTUnwrap(body["uploadURL"] as? String), beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: body["token"] as! String)
            req.body = ByteBuffer(data: audio)
        }, afterResponse: { res async in XCTAssertEqual(res.status, .noContent) })
        let done = try await f.app.json(.POST, "/v1/attachments/\(id)/complete", token: f.human)
        XCTAssertEqual(done.status, .ok)
        return id
    }

    /// The person speaks, the runner claims the job. Returns the job id (generation 1).
    private func spokenJob(_ f: AgentFixture) async throws -> String {
        let hb = try await f.app.json(.POST, "/v1/runner/voice/heartbeat", ["capabilities": ["sprache"]], token: f.runner)
        XCTAssertEqual(hb.status, .ok)
        let memo = try await uploadMemo(f)
        let said = try await f.app.json(.POST, "/v1/channels/brain/messages", ["kind": "voice_in", "attachmentID": memo,
            "clientUUID": UUID().uuidString], token: f.human)
        XCTAssertEqual(said.status, .created)
        let claimed = try await f.app.json(.POST, "/v1/runner/voice/claim", token: f.runner)
        XCTAssertEqual(claimed.status, .ok, "\(claimed.body ?? [:])")
        return try XCTUnwrap(claimed.body?["id"] as? String)
    }

    private func transcript(_ f: AgentFixture, _ job: String, _ text: String, generation: Int = 1, token: String? = nil)
        async throws -> (status: HTTPStatus, body: [String: Any]?) {
        let r = try await f.app.json(.POST, "/v1/runner/voice/jobs/\(job)/transcript", ["generation": generation, "transcript": text],
                                     token: token ?? f.runner)
        return (r.status, r.body)
    }

    private func messages(_ f: AgentFixture) async throws -> [[String: Any]] {
        let r = try await f.app.json(.GET, "/v1/channels/brain/messages?limit=100", token: f.human)
        XCTAssertEqual(r.status, .ok)
        return (r.body?["items"] as? [[String: Any]] ?? []).reversed()
    }

    private func task(_ f: AgentFixture, _ title: String) async throws -> String {
        let r = try await f.app.json(.POST, "/v1/tasks", ["projectID": f.projectID, "title": title], token: f.human)
        return try XCTUnwrap(r.body?["id"] as? String, "\(r.status)")
    }

    // MARK: Status request

    func testStatusRequestIsAnsweredFromCommandCenterAndOpenQuestions() async throws {
        let f = try await AgentFixture.make()
        try await run(f) {
            let login = try await task(f, "Login bauen")
            let asked = try await f.app.json(.POST, "/v1/tasks/\(login)/questions", ["prompt": "Passkey oder Passwort zuerst?",
                "options": ["Passkey", "Passwort"], "blocking": true], token: f.human)
            XCTAssertTrue([.ok, .created].contains(asked.status), "\(asked.body ?? [:])")
            let design = try await task(f, "Startseite entwerfen")
            let review = try await f.app.json(.POST, "/v1/tasks/\(design)/review", ["summary": "Entwurf der Startseite fertig"], token: f.human)
            XCTAssertTrue([.ok, .created].contains(review.status), "\(review.body ?? [:])")
            let cc = try await f.app.json(.GET, "/v1/command-center", token: f.human)
            let summary = try XCTUnwrap(cc.body?["summary"] as? [String: Any])
            XCTAssertEqual(summary["openQuestions"] as? Int, 1)
            XCTAssertEqual(summary["pendingReviews"] as? Int, 1)

            let job = try await spokenJob(f)
            let r = try await transcript(f, job, "Wie steht es?")
            XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
            XCTAssertEqual(r.body?["intent"] as? String, "status")
            let text = try XCTUnwrap(r.body?["replyText"] as? String)
            XCTAssertLessThanOrEqual(text.count, 4000)
            for part in ["1 offene Frage", "1 Review", "Passkey oder Passwort zuerst?", "Login bauen", "Entwurf der Startseite fertig",
                         "Startseite entwerfen"] {
                XCTAssertTrue(text.contains(part), "missing \(part) in: \(text)")
            }

            // The transcript is in the channel at once (voice_in text), before the runner sends its result.
            let early = try await messages(f)
            XCTAssertEqual(early.map { $0["kind"] as? String }, ["voice_in"])
            XCTAssertEqual(early.first?["text"] as? String, "Wie steht es?")

            // A runner without TTS sends only the transcript: the server writes its answer as text into the channel.
            let done = try await f.app.json(.POST, "/v1/runner/voice/jobs/\(job)/result", ["generation": 1, "transcript": "Wie steht es?"],
                                            token: f.runner)
            XCTAssertEqual(done.status, .ok, "\(done.body ?? [:])")
            XCTAssertEqual(done.body?["state"] as? String, "done")
            let list = try await messages(f)
            XCTAssertEqual(list.map { $0["kind"] as? String }, ["voice_in", "text"])
            XCTAssertEqual(list[1]["author"] as? String, "agent")
            let answer = try XCTUnwrap(list[1]["text"] as? String)
            XCTAssertTrue(answer.contains("Passkey oder Passwort zuerst?"), answer)
            XCTAssertLessThanOrEqual(answer.count, 4000)
            // Repeating that result changes nothing.
            let again = try await f.app.json(.POST, "/v1/runner/voice/jobs/\(job)/result", ["generation": 1, "transcript": "Wie steht es?"],
                                             token: f.runner)
            XCTAssertEqual(again.status, .ok)
            let count = try await messages(f).count
            XCTAssertEqual(count, 2)
        }
    }

    func testStatusReplyNeverExceeds4000Characters() async throws {
        let f = try await AgentFixture.make()
        try await run(f) {
            let long = String(repeating: "Sehr lange Frage mit vielen Worten. ", count: 25)
            for i in 0..<25 {
                let id = try await task(f, "Aufgabe \(i) mit einem langen Titel, damit die Lage wirklich viel Text hat")
                let asked = try await f.app.json(.POST, "/v1/tasks/\(id)/questions", ["prompt": "\(i): \(long)"], token: f.human)
                XCTAssertTrue([.ok, .created].contains(asked.status), "\(asked.status)")
            }
            let job = try await spokenJob(f)
            let r = try await transcript(f, job, "Was ist die Lage?")
            XCTAssertEqual(r.body?["intent"] as? String, "status")
            let text = try XCTUnwrap(r.body?["replyText"] as? String)
            XCTAssertLessThanOrEqual(text.count, 4000)
            XCTAssertGreaterThan(text.count, 1000, "the answer uses the room it has")
            XCTAssertTrue(text.contains("25 offene Fragen"), text)
            let done = try await f.app.json(.POST, "/v1/runner/voice/jobs/\(job)/result", ["generation": 1, "transcript": "Was ist die Lage?"],
                                            token: f.runner)
            XCTAssertEqual(done.status, .ok, "\(done.body ?? [:])")
            let all = try await messages(f)
            let answer = try XCTUnwrap(all.last?["text"] as? String)
            XCTAssertLessThanOrEqual(answer.count, 4000)
        }
    }

    // MARK: Class C protection

    func testDeleteCommandNeverActsAndCreatesAtMostAConfirmationRequest() async throws {
        let f = try await AgentFixture.make()
        try await run(f) {
            let job = try await spokenJob(f)
            let r = try await transcript(f, job, "Lösche Projekt Project")
            XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
            XCTAssertEqual(r.body?["intent"] as? String, "refused")
            let text = try XCTUnwrap(r.body?["replyText"] as? String)
            XCTAssertTrue(text.contains("App"), text)
            let done = try await f.app.json(.POST, "/v1/runner/voice/jobs/\(job)/result", ["generation": 1, "transcript": "Lösche Projekt Project"],
                                            token: f.runner)
            XCTAssertEqual(done.status, .ok, "\(done.body ?? [:])")

            // Nothing happened: project and task are still there, at most a pending confirmation request exists.
            let project = try await f.app.json(.GET, "/v1/projects/\(f.projectID)", token: f.human)
            XCTAssertEqual(project.status, .ok)
            let task = try await f.app.json(.GET, "/v1/tasks/\(f.taskID)", token: f.human)
            XCTAssertEqual(task.status, .ok)
            let requests = try await ActionRequest.query(on: f.app.app.db).all()
            XCTAssertLessThanOrEqual(requests.count, 1)
            XCTAssertTrue(requests.allSatisfy { $0.state == "pending" }, "\(requests.map(\.state))")
            let list = try await messages(f)
            XCTAssertEqual(list.map { $0["kind"] as? String }, ["voice_in", "text"])
            XCTAssertEqual(list[1]["text"] as? String, text)
        }
    }

    func testClassCWordsWinOverStatusAndOrdinaryRequestsGoToTheBrain() {
        for phrase in ["Lösche Projekt Garten", "loesche die Aufgabe Einkauf", "Entferne alle erledigten Aufgaben",
                       "Bitte deploye den Server", "Übertrage das Projekt an Anna", "Entzieh Tom die Freigabe",
                       "Wie steht es, und lösch danach das Projekt"] {
            XCTAssertEqual(BrainResponder.classify(phrase), .refused, phrase)
        }
        for phrase in ["Wie steht es?", "wie stehts", "Was ist die Lage", "Gib mir einen Überblick", "Welche offenen Fragen gibt es?",
                       "Status bitte", "Was steht an?"] {
            XCTAssertEqual(BrainResponder.classify(phrase), .status, phrase)
        }
        for phrase in ["Plane morgen den Einkauf", "Erinnere mich an die Anlage", "Schreib eine Vorlage für den Bericht"] {
            XCTAssertEqual(BrainResponder.classify(phrase), .forwarded, phrase)
        }
    }

    // MARK: Requests for the brain session

    func testOtherRequestWaitsInTheChannelForTheBrainSession() async throws {
        let f = try await AgentFixture.make()
        try await run(f) {
            let job = try await spokenJob(f)
            let r = try await transcript(f, job, "Plane morgen den Einkauf")
            XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])")
            XCTAssertEqual(r.body?["intent"] as? String, "forwarded")
            let text = try XCTUnwrap(r.body?["replyText"] as? String)
            XCTAssertFalse(text.isEmpty)
            let list = try await messages(f)
            XCTAssertEqual(list.first?["text"] as? String, "Plane morgen den Einkauf")
            XCTAssertEqual(list.first?["author"] as? String, "person")
        }
    }

    // MARK: Fencing

    func testTranscriptCallIsFencedLikeTheOtherHolderCalls() async throws {
        let f = try await AgentFixture.make()
        try await run(f) {
            let job = try await spokenJob(f)
            let empty = try await transcript(f, job, "   ")
            XCTAssertEqual(empty.status, .badRequest)
            let tooLong = try await transcript(f, job, String(repeating: "a", count: 4001))
            XCTAssertEqual(tooLong.status, .badRequest)
            let stale = try await transcript(f, job, "Wie steht es?", generation: 7)
            XCTAssertEqual(stale.status, .conflict)
            XCTAssertNil(stale.body?["replyText"])

            // Another account's runner sees nothing.
            let u = User(displayName: "Stranger", isAdmin: false)
            try await u.save(on: f.app.app.db)
            let session = AuthSupport.randomToken()
            try await UserSession(userID: u.requireID(), tokenHash: AuthSupport.hash(session), expiresAt: Date().addingTimeInterval(3600)).save(on: f.app.app.db)
            let p = try await f.app.json(.POST, "/v1/agents/devices", ["label": "Other Mac"], token: session)
            let paired = try await f.app.json(.POST, "/v1/runner/pair", ["code": try XCTUnwrap(p.body?["code"] as? String)])
            let foreign = try await transcript(f, job, "Wie steht es?", token: try XCTUnwrap(paired.body?["token"] as? String))
            XCTAssertEqual(foreign.status, .notFound)
            XCTAssertNil(foreign.body?["replyText"])
            let unchanged = try await messages(f)
            XCTAssertTrue(unchanged.first?["text"] is NSNull || unchanged.first?["text"] == nil, "no transcript stored by refused calls")

            let ok = try await transcript(f, job, "Wie steht es?")
            XCTAssertEqual(ok.status, .ok)
            let done = try await f.app.json(.POST, "/v1/runner/voice/jobs/\(job)/result", ["generation": 1, "replyText": "Gut."], token: f.runner)
            XCTAssertEqual(done.status, .ok)
            let late = try await transcript(f, job, "Wie steht es?")
            XCTAssertEqual(late.status, .gone)
        }
    }
}
