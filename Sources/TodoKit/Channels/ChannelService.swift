import Fluent
import Vapor

struct ChannelMessageDTO: Content, Equatable {
    let id: UUID
    let kind: String
    let author: String
    let text: String?
    let attachmentID: UUID?
    let clientUUID: UUID?
    let createdAt: Date
    init(_ m: ChannelMessage) throws {
        id = try m.requireID(); kind = m.kind; author = m.author; text = m.text
        attachmentID = m.attachmentID; clientUUID = m.clientUUID; createdAt = m.createdAt
    }
}

struct ChannelMessagePage: Content {
    /// Newest first.
    let items: [ChannelMessageDTO]
    /// Pass as `cursor` to get the next older page; nil on the last page.
    let nextCursor: String?
}

struct PostChannelMessageRequest: Content {
    let kind: String?
    let text: String?
    let attachmentID: UUID?
    let clientUUID: UUID?
}

/// Shared by REST and MCP. The account is the only access rule: every query filters on the owner.
struct ChannelService {
    static let brain = "brain"
    static let maxText = 4000
    static let defaultLimit = 50
    static let maxLimit = 100

    enum Author: String {
        case person, agent
        /// A person speaks into the app (text, voice_in); the brain side answers (text, voice_out, status).
        var kinds: Set<String> { self == .person ? ["text", "voice_in"] : ["text", "voice_out", "status"] }
    }

    let user: User
    let db: any Database

    // MARK: Channel

    private func existingChannel() async throws -> BrainChannel? {
        try await BrainChannel.query(on: db).filter(\.$ownerID == user.requireID()).filter(\.$kind == Self.brain).first()
    }

    /// Lazily created; a concurrent first use is settled by the unique key (owner, kind).
    private func channel() async throws -> BrainChannel {
        if let c = try await existingChannel() { return c }
        let c = BrainChannel(ownerID: try user.requireID(), kind: Self.brain)
        do { try await c.save(on: db); return c }
        catch { if let c = try await existingChannel() { return c }; throw error }
    }

    // MARK: Cursor

    static func cursor(for m: ChannelMessage) throws -> String {
        "\(Int64((m.createdAt.timeIntervalSince1970 * 1000).rounded())):\(try m.requireID().uuidString)"
    }

    static func parseCursor(_ raw: String) throws -> (Date, UUID) {
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let ms = Int64(parts[0]), ms >= 0, let id = UUID(uuidString: parts[1]) else {
            throw Abort(.badRequest, reason: "invalid_cursor")
        }
        return (date(milliseconds: ms), id)
    }

    static func date(milliseconds ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
    static func now() -> Date { date(milliseconds: Int64((Date().timeIntervalSince1970 * 1000).rounded())) }

    // MARK: System-side messages

    /// Brain-side message written by the server itself (voice job outcomes). `notBefore` keeps the message after the one
    /// it answers even when both fall into the same millisecond (the list order is created_at, then id).
    @discardableResult
    func appendBrainMessage(kind: String, text: String?, attachmentID: UUID? = nil, notBefore: Date? = nil) async throws -> ChannelMessage {
        let channel = try await channel()
        let m = ChannelMessage()
        m.channelID = try channel.requireID(); m.ownerID = try user.requireID(); m.kind = kind; m.author = Author.agent.rawValue
        m.text = text; m.attachmentID = attachmentID
        var at = Self.now()
        if let notBefore, at <= notBefore { at = notBefore.addingTimeInterval(0.001) }
        m.createdAt = Self.date(milliseconds: Int64((at.timeIntervalSince1970 * 1000).rounded()))
        try await m.save(on: db)
        return m
    }

    // MARK: List

    func list(limit: Int?, cursor: String?, since: Date?) async throws -> ChannelMessagePage {
        let limit = limit ?? Self.defaultLimit
        guard (1...Self.maxLimit).contains(limit) else { throw Abort(.badRequest, reason: "invalid_limit") }
        let parsed = try cursor.map(Self.parseCursor)
        // Jobs that ran out of time answer with a status message; whoever reads the channel notices first.
        try await VoiceService.expireDue(owner: try user.requireID(), db: db)
        // Nothing to read until the first message created the channel.
        guard let channel = try await existingChannel() else { return ChannelMessagePage(items: [], nextCursor: nil) }
        let channelID = try channel.requireID(), userID = try user.requireID()
        var query = ChannelMessage.query(on: db).filter(\.$channelID == channelID).filter(\.$ownerID == userID)
        if let since { query = query.filter(\.$createdAt > since) }
        if let (date, id) = parsed {
            query = query.group(.or) { or in
                or.filter(\.$createdAt < date)
                or.group(.and) { $0.filter(\.$createdAt == date).filter(\.$id < id) }
            }
        }
        let rows = try await query.sort(\.$createdAt, .descending).sort(\.$id, .descending).limit(limit + 1).all()
        let page = Array(rows.prefix(limit))
        let next = rows.count > limit ? try page.last.map(Self.cursor) : nil
        return ChannelMessagePage(items: try page.map(ChannelMessageDTO.init), nextCursor: next)
    }

    // MARK: Post

    /// Returns the message and whether it was newly created (false: replay of an earlier post with the same client UUID).
    func post(_ body: PostChannelMessageRequest, as author: Author) async throws -> (message: ChannelMessageDTO, created: Bool) {
        let kind = body.kind ?? "text"
        guard ["text", "voice_in", "voice_out", "status"].contains(kind), author.kinds.contains(kind) else {
            throw Abort(.badRequest, reason: "invalid_kind")
        }
        var text = body.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if text?.isEmpty == true { text = nil }
        if let text, text.count > Self.maxText { throw Abort(.badRequest, reason: "invalid_text") }
        let isVoice = kind.hasPrefix("voice")
        if isVoice {
            guard body.attachmentID != nil else { throw Abort(.badRequest, reason: "attachment_required") }
        } else {
            guard text != nil else { throw Abort(.badRequest, reason: "invalid_text") }
            guard body.attachmentID == nil else { throw Abort(.badRequest, reason: "attachment_not_allowed") }
        }
        let userID = try user.requireID()
        if let id = body.attachmentID {
            // Another account's attachment is indistinguishable from a missing one.
            guard let a = try await Attachment.find(id, on: db), a.ownerID == userID else { throw Abort(.notFound) }
            guard a.role == "voice", a.status == "complete" else { throw Abort(.unprocessableEntity, reason: "invalid_attachment") }
        }
        let channel = try await channel()
        let channelID = try channel.requireID()

        func replay() async throws -> ChannelMessageDTO? {
            guard let key = body.clientUUID,
                  let existing = try await ChannelMessage.query(on: db).filter(\.$channelID == channelID).filter(\.$clientUUID == key).first() else { return nil }
            // A transcript may have filled the text of a voice_in message since; a retry without text is still the same post.
            let sameText = existing.text == text || (kind == "voice_in" && text == nil)
            guard existing.kind == kind, existing.author == author.rawValue, sameText, existing.attachmentID == body.attachmentID else {
                throw Abort(.conflict, reason: "client_uuid_conflict")
            }
            return try ChannelMessageDTO(existing)
        }
        if let existing = try await replay() { return (existing, false) }

        let startsJob = kind == "voice_in"
        if startsJob, let id = body.attachmentID {
            try await VoiceService.expireDue(owner: userID, db: db)
            try await VoiceService.checkLimits(owner: userID, db: db)
            // One recording, one message: a failed or expired job deletes its recording.
            guard try await ChannelMessage.query(on: db).filter(\.$ownerID == userID).filter(\.$kind == "voice_in")
                .filter(\.$attachmentID == id).count() == 0 else { throw Abort(.conflict, reason: "attachment_in_use") }
        }

        let m = ChannelMessage()
        m.channelID = channelID; m.ownerID = userID; m.kind = kind; m.author = author.rawValue
        m.text = text; m.attachmentID = body.attachmentID; m.clientUUID = body.clientUUID
        m.createdAt = Self.now()
        do {
            try await db.transaction { tx in
                try await m.save(on: tx)
                if startsJob { try await VoiceService.enqueue(message: m, user: user, db: tx) }
            }
        } catch {
            // A parallel post with the same client UUID won the unique key: answer with that one.
            if let existing = try await replay() { return (existing, false) }
            throw error
        }
        return (try ChannelMessageDTO(m), true)
    }
}

struct ChannelController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let r = routes.grouped("v1", "channels", "brain", "messages")
        r.get(use: list)
        r.post(use: post)
    }

    @Sendable func list(_ req: Request) async throws -> ChannelMessagePage {
        let service = ChannelService(user: try await req.requireUser(), db: req.db)
        var limit: Int?
        if let raw = req.query[String.self, at: "limit"] {
            guard let value = Int(raw) else { throw Abort(.badRequest, reason: "invalid_limit") }
            limit = value
        }
        var since: Date?
        if let raw = req.query[String.self, at: "since"] {
            guard let date = SystemStatusService.parseDate(raw) else { throw Abort(.badRequest, reason: "invalid_since") }
            since = date
        }
        return try await service.list(limit: limit, cursor: req.query[String.self, at: "cursor"], since: since)
    }

    @Sendable func post(_ req: Request) async throws -> Response {
        let user = try await req.requireUser()
        let body: PostChannelMessageRequest
        do { body = try req.content.decode(PostChannelMessageRequest.self) }
        catch { throw Abort(.badRequest, reason: "invalid_message") }
        let result = try await ChannelService(user: user, db: req.db).post(body, as: .person)
        return try await result.message.encodeResponse(status: result.created ? .created : .ok, for: req)
    }
}
