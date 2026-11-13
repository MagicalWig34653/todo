import Fluent
import XCTVapor
@testable import TodoKit

/// Channel #brain (ADR 0030, step 2): one account-scoped channel with messages, REST and MCP.
final class ChannelTests: XCTestCase {
    private let scopes = "projects:read channels:read channels:write"

    private func run(_ f: OAuthFixture, _ body: () async throws -> Void) async throws {
        do { try await body() } catch { await f.test.shutdown(); throw error }
        await f.test.shutdown()
    }

    /// A second account with its own session.
    private func stranger(_ f: OAuthFixture) async throws -> (user: User, session: String) {
        let u = User(displayName: "Stranger", isAdmin: false)
        try await u.save(on: f.test.app.db)
        let s = AuthSupport.randomToken()
        try await UserSession(userID: u.requireID(), tokenHash: AuthSupport.hash(s), expiresAt: Date().addingTimeInterval(3600)).save(on: f.test.app.db)
        return (u, s)
    }

    private func voiceAttachment(_ f: OAuthFixture, owner: User, role: String = "voice", status: String = "complete") async throws -> UUID {
        let task = TodoTask(ownerID: try owner.requireID(), projectID: try f.project.requireID(), title: "Memo", details: "")
        try await task.save(on: f.test.app.db)
        let a = Attachment()
        _ = task; a.taskID = Attachment.noTask; a.ownerID = try owner.requireID(); a.filename = "memo.m4a"; a.role = role
        a.mediaType = "audio/mp4"; a.size = 10; a.checksum = "x"; a.status = status; a.objectKey = UUID().uuidString
        try await a.save(on: f.test.app.db)
        return try a.requireID()
    }

    private func post(_ f: OAuthFixture, _ body: [String: Any], token: String? = nil) async throws -> (status: HTTPStatus, body: [String: Any]?) {
        let r = try await f.test.json(.POST, "/v1/channels/brain/messages", body, token: token ?? f.session)
        return (r.status, r.body)
    }

    private struct Called { let isError: Bool; let text: String; let json: Any? }
    private func call(_ f: OAuthFixture, _ name: String, _ args: [String: Any], _ access: String) async throws -> Called {
        let r = try await f.rpc("tools/call", ["name": name, "arguments": args], access: access)
        let result = try XCTUnwrap(r.body?["result"] as? [String: Any], String(describing: r.body))
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        return Called(isError: result["isError"] as? Bool ?? false, text: text, json: try? JSONSerialization.jsonObject(with: Data(text.utf8)))
    }

    func testPostThenListRoundTripAndEmptyChannel() async throws {
        let f = try await OAuthFixture.make()
        try await run(f) {
            let empty = try await f.test.json(.GET, "/v1/channels/brain/messages", token: f.session)
            XCTAssertEqual(empty.status, .ok)
            XCTAssertEqual((empty.body?["items"] as? [Any])?.count, 0)
            XCTAssertTrue(empty.body?["nextCursor"] is NSNull || empty.body?["nextCursor"] == nil)

            let uuid = UUID().uuidString
            let created = try await post(f, ["kind": "text", "text": "Hallo Brain", "clientUUID": uuid])
            XCTAssertEqual(created.status, .created)
            XCTAssertEqual(created.body?["kind"] as? String, "text")
            XCTAssertEqual(created.body?["text"] as? String, "Hallo Brain")
            XCTAssertEqual(created.body?["author"] as? String, "person")
            XCTAssertEqual((created.body?["clientUUID"] as? String)?.lowercased(), uuid.lowercased())
            XCTAssertNotNil(created.body?["createdAt"])

            let list = try await f.test.json(.GET, "/v1/channels/brain/messages", token: f.session)
            let items = try XCTUnwrap(list.body?["items"] as? [[String: Any]])
            XCTAssertEqual(items.count, 1)
            XCTAssertEqual(items.first?["id"] as? String, created.body?["id"] as? String)

            let anonymous = try await f.test.json(.GET, "/v1/channels/brain/messages")
            XCTAssertEqual(anonymous.status, .unauthorized)
            let anonymousPost = try await f.test.json(.POST, "/v1/channels/brain/messages", ["kind": "text", "text": "x"])
            XCTAssertEqual(anonymousPost.status, .unauthorized)
        }
    }

    func testClientUUIDMakesPostIdempotentPerAccount() async throws {
        let f = try await OAuthFixture.make()
        try await run(f) {
            let other = try await stranger(f)
            let uuid = UUID().uuidString
            let first = try await post(f, ["kind": "text", "text": "once", "clientUUID": uuid])
            let again = try await post(f, ["kind": "text", "text": "once", "clientUUID": uuid])
            XCTAssertEqual(first.status, .created)
            XCTAssertEqual(again.status, .ok)
            XCTAssertEqual(again.body?["id"] as? String, first.body?["id"] as? String)
            let list = try await f.test.json(.GET, "/v1/channels/brain/messages", token: f.session)
            XCTAssertEqual((list.body?["items"] as? [Any])?.count, 1)

            // Same UUID with different content is a client bug, not a replay.
            let clash = try await post(f, ["kind": "text", "text": "different", "clientUUID": uuid])
            XCTAssertEqual(clash.status, .conflict)

            // The key is scoped to the account: another account may use the same UUID.
            let theirs = try await post(f, ["kind": "text", "text": "mine", "clientUUID": uuid], token: other.session)
            XCTAssertEqual(theirs.status, .created)
            XCTAssertNotEqual(theirs.body?["id"] as? String, first.body?["id"] as? String)

            let badUUID = try await post(f, ["kind": "text", "text": "x", "clientUUID": "not-a-uuid"])
            XCTAssertEqual(badUUID.status, .badRequest)
        }
    }

    func testPaginationWalksNewestFirstWithoutGapsOrDuplicates() async throws {
        let f = try await OAuthFixture.make()
        try await run(f) {
            var ids: [String] = []
            for i in 0..<7 {
                let r = try await post(f, ["kind": "text", "text": "m\(i)"])
                ids.append(try XCTUnwrap(r.body?["id"] as? String))
            }
            var seen: [String] = []
            var cursor: String?
            var pages = 0
            repeat {
                let path = "/v1/channels/brain/messages?limit=3" + (cursor.map { "&cursor=\($0)" } ?? "")
                let r = try await f.test.json(.GET, path, token: f.session)
                XCTAssertEqual(r.status, .ok)
                seen += (r.body?["items"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
                cursor = r.body?["nextCursor"] as? String
                pages += 1
            } while cursor != nil && pages < 10
            XCTAssertEqual(pages, 3)
            XCTAssertEqual(Set(seen), Set(ids))
            XCTAssertEqual(seen.count, 7)
            XCTAssertEqual(seen.first, ids.last, "newest first")

            for bad in ["limit=0", "limit=101", "limit=abc", "cursor=garbage", "since=yesterday"] {
                let r = try await f.test.json(.GET, "/v1/channels/brain/messages?\(bad)", token: f.session)
                XCTAssertEqual(r.status, .badRequest, bad)
            }
        }
    }

    func testValidationOfKindsTextAndAttachment() async throws {
        let f = try await OAuthFixture.make()
        try await run(f) {
            let other = try await stranger(f)
            for body in [["kind": "text", "text": "   "], ["kind": "text"], ["kind": "bogus", "text": "x"],
                         ["kind": "voice_out", "text": "x"], ["kind": "status", "text": "x"],
                         ["kind": "text", "text": String(repeating: "a", count: 4001)],
                         ["kind": "voice_in"]] as [[String: Any]] {
                let r = try await post(f, body)
                XCTAssertEqual(r.status, .badRequest, "\(body)")
            }
            let long = try await post(f, ["kind": "text", "text": String(repeating: "a", count: 4000)])
            XCTAssertEqual(long.status, .created)

            let mine = try await voiceAttachment(f, owner: f.user)
            let foreign = try await voiceAttachment(f, owner: other.user)
            let image = try await voiceAttachment(f, owner: f.user, role: "result")
            let pending = try await voiceAttachment(f, owner: f.user, status: "pending")
            let withText = try await post(f, ["kind": "text", "text": "x", "attachmentID": mine.uuidString])
            XCTAssertEqual(withText.status, .badRequest, "text messages carry no attachment")
            let missing = try await post(f, ["kind": "voice_in", "attachmentID": UUID().uuidString])
            XCTAssertEqual(missing.status, .notFound)
            let foreignRes = try await post(f, ["kind": "voice_in", "attachmentID": foreign.uuidString])
            XCTAssertEqual(foreignRes.status, .notFound, "another account's attachment is indistinguishable from a missing one")
            for bad in [image, pending] {
                let r = try await post(f, ["kind": "voice_in", "attachmentID": bad.uuidString])
                XCTAssertEqual(r.status, .unprocessableEntity)
            }
            let ok = try await post(f, ["kind": "voice_in", "attachmentID": mine.uuidString, "text": "transcript"])
            XCTAssertEqual(ok.status, .created)
            XCTAssertEqual(ok.body?["attachmentID"] as? String, mine.uuidString)
            XCTAssertEqual(ok.body?["kind"] as? String, "voice_in")
        }
    }

    func testChannelIsPrivateToItsOwner() async throws {
        let f = try await OAuthFixture.make()
        try await run(f) {
            let other = try await stranger(f)
            _ = try await post(f, ["kind": "text", "text": "secret of A"])
            let theirs = try await f.test.json(.GET, "/v1/channels/brain/messages", token: other.session)
            XCTAssertEqual(theirs.status, .ok)
            XCTAssertEqual((theirs.body?["items"] as? [Any])?.count, 0)
            _ = try await post(f, ["kind": "text", "text": "secret of B"], token: other.session)
            let mineAgain = try await f.test.json(.GET, "/v1/channels/brain/messages", token: f.session)
            let texts = (mineAgain.body?["items"] as? [[String: Any]])?.compactMap { $0["text"] as? String }
            XCTAssertEqual(texts, ["secret of A"])
            let channels = try await BrainChannel.query(on: f.test.app.db).all()
            XCTAssertEqual(channels.count, 2)
            XCTAssertEqual(Set(channels.map(\.kind)), ["brain"])
            XCTAssertEqual(Set(channels.map(\.ownerID)).count, 2, "exactly one brain channel per account")
        }
    }

    func testDeletingTheAccountRemovesChannelAndMessages() async throws {
        let f = try await OAuthFixture.make()
        try await run(f) {
            let other = try await stranger(f)
            _ = try await post(f, ["kind": "text", "text": "bye"], token: other.session)
            let count = try await ChannelMessage.query(on: f.test.app.db).count()
            XCTAssertEqual(count, 1)
            try await UserSession.query(on: f.test.app.db).filter(\.$user.$id == other.user.requireID()).delete()
            try await other.user.delete(on: f.test.app.db)
            let channels = try await BrainChannel.query(on: f.test.app.db).count()
            let messages = try await ChannelMessage.query(on: f.test.app.db).count()
            XCTAssertEqual(channels, 0); XCTAssertEqual(messages, 0)
        }
    }

    /// Contract (voice.yaml): createdAt carries milliseconds, so messages posted within one second stay ordered for
    /// clients, and the order matches the `<ms>:<uuid>` cursor. The global encoder only writes whole seconds.
    func testCreatedAtCarriesMillisecondsAndOrdersMessagesWithinOneSecond() async throws {
        let f = try await OAuthFixture.make()
        try await run(f) {
            let millis = try NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#)
            func isMillis(_ s: String) -> Bool { millis.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }

            var ids: [String] = []
            for i in 0..<6 {
                let r = try await post(f, ["kind": "text", "text": "fast \(i)"])
                XCTAssertTrue(isMillis(try XCTUnwrap(r.body?["createdAt"] as? String)), "POST createdAt: \(String(describing: r.body?["createdAt"]))")
                ids.append(try XCTUnwrap(r.body?["id"] as? String))
            }
            let tok = try await f.tokens(scope: scopes)
            let mcp = try await call(f, "list_channel_messages", ["limit": 100], tok.access)
            let mcpItems = try XCTUnwrap((mcp.json as? [String: Any])?["items"] as? [[String: Any]])
            let rest = try await f.test.json(.GET, "/v1/channels/brain/messages?limit=100", token: f.session)
            let restItems = try XCTUnwrap(rest.body?["items"] as? [[String: Any]])

            for items in [restItems, mcpItems] {
                let stamps = items.compactMap { $0["createdAt"] as? String }
                XCTAssertEqual(stamps.count, 6)
                XCTAssertTrue(stamps.allSatisfy(isMillis), "\(stamps)")
                XCTAssertEqual(items.compactMap { $0["id"] as? String }, ids.reversed(), "newest first")
                XCTAssertEqual(stamps, stamps.sorted(by: >), "createdAt non-increasing")
            }

            // The cursor milliseconds equal the createdAt milliseconds of the last item of the page.
            let page = try await f.test.json(.GET, "/v1/channels/brain/messages?limit=3", token: f.session)
            let last = try XCTUnwrap((page.body?["items"] as? [[String: Any]])?.last)
            let cursor = try XCTUnwrap(page.body?["nextCursor"] as? String)
            let parsed = ISO8601DateFormatter()
            parsed.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let date = try XCTUnwrap(parsed.date(from: try XCTUnwrap(last["createdAt"] as? String)))
            XCTAssertEqual(cursor.split(separator: ":").first.map(String.init), String(Int64((date.timeIntervalSince1970 * 1000).rounded())))
        }
    }

    func testMCPToolsNeedTheNewScopesAndShareTheRestRules() async throws {
        let f = try await OAuthFixture.make()
        try await run(f) {
            for s in ["channels:read", "channels:write"] { XCTAssertTrue(OAuthController.scopes.contains(s), s) }
            XCTAssertEqual(MCPController.tools.first { $0.name == "list_channel_messages" }?.scope, "channels:read")
            XCTAssertEqual(MCPController.tools.first { $0.name == "post_channel_message" }?.scope, "channels:write")

            // An existing connection keeps working with its old scopes and simply does not see the tools.
            let old = try await f.tokens(scope: "projects:read tasks:read")
            let listed = try await f.rpc("tools/list", access: old.access)
            let names = ((listed.body?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            XCTAssertTrue(names.contains("list_projects"))
            XCTAssertFalse(names.contains("list_channel_messages")); XCTAssertFalse(names.contains("post_channel_message"))
            let denied = try await call(f, "list_channel_messages", [:], old.access)
            XCTAssertEqual(denied.text, "insufficient_scope")

            let readOnly = try await f.tokens(scope: "projects:read channels:read")
            let noWrite = try await call(f, "post_channel_message", ["text": "x"], readOnly.access)
            XCTAssertEqual(noWrite.text, "insufficient_scope")

            let tok = try await f.tokens(scope: scopes)
            _ = try await post(f, ["kind": "text", "text": "from the app", "clientUUID": UUID().uuidString])
            let posted = try await call(f, "post_channel_message", ["text": "Antwort", "clientUUID": UUID().uuidString], tok.access)
            XCTAssertFalse(posted.isError, posted.text)
            XCTAssertEqual((posted.json as? [String: Any])?["author"] as? String, "agent")
            XCTAssertEqual((posted.json as? [String: Any])?["kind"] as? String, "text")
            let status = try await call(f, "post_channel_message", ["kind": "status", "text": "Mac offline"], tok.access)
            XCTAssertFalse(status.isError, status.text)
            for bad: [String: Any] in [["kind": "voice_in", "text": "x"], ["kind": "voice_out", "text": "x"], ["kind": "text"], ["text": "x", "clientUUID": "nope"]] {
                let r = try await call(f, "post_channel_message", bad, tok.access)
                XCTAssertTrue(r.isError, "\(bad)")
            }
            let foreignAttachment = try await call(f, "post_channel_message", ["kind": "voice_out", "attachmentID": UUID().uuidString], tok.access)
            XCTAssertEqual(foreignAttachment.text, "not_found")

            let list = try await call(f, "list_channel_messages", ["limit": 2], tok.access)
            XCTAssertFalse(list.isError, list.text)
            let obj = try XCTUnwrap(list.json as? [String: Any])
            XCTAssertEqual((obj["items"] as? [[String: Any]])?.count, 2)
            let cursor = try XCTUnwrap(obj["nextCursor"] as? String)
            let page2 = try await call(f, "list_channel_messages", ["limit": 2, "cursor": cursor], tok.access)
            XCTAssertEqual(((page2.json as? [String: Any])?["items"] as? [[String: Any]])?.count, 1)
            let badLimit = try await call(f, "list_channel_messages", ["limit": 0], tok.access)
            XCTAssertTrue(badLimit.isError)

            // Both surfaces see the same channel; another account sees none of it.
            let rest = try await f.test.json(.GET, "/v1/channels/brain/messages?limit=100", token: f.session)
            XCTAssertEqual((rest.body?["items"] as? [Any])?.count, 3)
            let other = try await stranger(f)
            let theirs = try await f.test.json(.GET, "/v1/channels/brain/messages", token: other.session)
            XCTAssertEqual((theirs.body?["items"] as? [Any])?.count, 0)
        }
    }
}
