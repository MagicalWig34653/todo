import Fluent
import Vapor

/// Answer logic of the brain for spoken requests (ADR 0030 step 5, T1 minimum). Stub: not implemented yet.
enum BrainIntent: String, Codable, Sendable {
    case status, refused, forwarded
}

struct BrainReply: Content, Equatable {
    let intent: String
    let replyText: String
}

enum BrainResponder {
    static let maxText = 4000

    static func classify(_ text: String) -> BrainIntent { .forwarded }

    static func reply(to transcript: String, user: User, db: any Database) async throws -> BrainReply {
        BrainReply(intent: BrainIntent.forwarded.rawValue, replyText: "")
    }
}
