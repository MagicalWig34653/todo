import Fluent
import Vapor

/// Channel #brain tools (ADR 0030): the brain side of the channel. Same service as REST (`ChannelService`); the channel
/// belongs to the account, so no project grant is involved, only the scopes `channels:read` / `channels:write`.
extension MCPController {
    static let channelTools: [Tool] = [
        Tool(name: "list_channel_messages", scope: "channels:read",
             description: "Read the account's #brain channel (voice and text messages between the person and the brain), newest first: {items:[{id, kind, author, text, attachmentID, clientUUID, createdAt}], nextCursor}. kind is text, voice_in (spoken by the person, text = transcript), voice_out or status; author is person or agent. Pass nextCursor as cursor for older messages, since for only newer ones.",
             properties: ["limit": Schema.integer("Maximum messages per page (default 50).", min: 1, max: 100),
                          "cursor": Schema.string("nextCursor of the previous page.", maxLength: 80),
                          "since": Schema.string("ISO 8601 date-time: only messages created after it.", maxLength: 40)]),
        Tool(name: "post_channel_message", scope: "channels:write",
             description: "Write to the account's #brain channel as the agent. kind text (default) and status need text (up to 4000 characters); voice_out needs attachmentID of a finished audio attachment (role voice) of this account, text is optional. Messages of kind voice_in are the person's own and cannot be written here. Retrying with the same clientUUID returns the original message instead of a duplicate.",
             properties: ["kind": Schema.string("text (default), voice_out or status.", values: ["text", "voice_out", "status"]),
                          "text": Schema.string("Message text, 1 to 4000 characters.", maxLength: 4000),
                          "attachmentID": Schema.uuid("Audio attachment (role voice) for kind voice_out."),
                          "clientUUID": Schema.uuid("Idempotency key chosen by the sender.")]),
    ]

    func callChannel(_ name: String, _ a: JSONValue, user: User, db: any Database) async throws -> JSONValue {
        let service = ChannelService(user: user, db: db)
        switch name {
        case "list_channel_messages":
            var since: Date?
            if let raw = try optionalString(a, "since") {
                guard let date = SystemStatusService.parseDate(raw) else { throw Abort(.badRequest, reason: "invalid_since") }
                since = date
            }
            return try .encoded(try await service.list(limit: intArgument(a["limit"], reason: "invalid_limit"),
                                                       cursor: optionalString(a, "cursor"), since: since))
        case "post_channel_message":
            let body = PostChannelMessageRequest(kind: try optionalString(a, "kind"), text: try optionalString(a, "text"),
                                                 attachmentID: try optionalUUID(a, "attachmentID"), clientUUID: try optionalUUID(a, "clientUUID"))
            return try .encoded(try await service.post(body, as: .agent).message)
        default:
            throw Abort(.badRequest, reason: "invalid_arguments")
        }
    }
}
