import Vapor

/// ADR 0023: one account-wide "Für dich" feed. All types are read models over existing tables; nothing is stored.

struct FeedActorDTO: Content {
    let type: ActivityActorType
    let id: UUID
    /// Person display name or the agent label the actor reported; nil when unknown (clients show "Agent").
    let name: String?
}

struct FeedImageDTO: Content {
    let attachmentID: UUID
    let buildArtifactID: UUID?
    let filename: String
    let mediaType: String
    /// Authenticated image endpoint (session cookie / bearer).
    let previewURL: String
    let buildID: String?
    let label: String?
    let platform: String?
}

struct FeedPostDTO: Content {
    /// Id of the activity event (the newest one when several screenshots of one build were merged).
    let id: UUID
    /// progress | build | done | review | question | comment | agent_run
    let kind: String
    /// Raw activity kind, e.g. `review.accepted`, `agent.claimed`.
    let event: String
    /// started | finished | stopped | failed (agent_run), accepted | changes_requested (review).
    let state: String?
    let projectID: UUID
    let projectName: String
    let taskID: UUID
    let taskTitle: String
    let actor: FeedActorDTO
    let text: String?
    /// Second text: the answer of a question, the build label of a screenshot post.
    let detail: String?
    let percent: Int?
    let images: [FeedImageDTO]
    let createdAt: Date?
}

/// A request the client can send as is. `requiresInput` actions need the user's text in `inputField`.
struct FeedActionDTO: Content {
    let key: String
    let label: String
    let method: String
    let path: String
    let body: FeedActionBody?
    let requiresInput: Bool
    let inputField: String?
}

struct FeedActionBody: Content {
    var answer: String?
    var decision: String?
    var note: String?
    var status: String?
    var version: Int?
}

struct FeedNeedsYouDTO: Content {
    /// Stable per object, e.g. `question:<uuid>`.
    let id: String
    /// question | review | blocked | overdue | due
    let kind: String
    let projectID: UUID
    let projectName: String
    let taskID: UUID
    let taskTitle: String
    let taskVersion: Int
    let title: String
    let detail: String?
    let options: [String]
    let blocking: Bool
    let questionID: UUID?
    let reviewID: UUID?
    let dueAt: Date?
    let actor: FeedActorDTO?
    let createdAt: Date?
    let actions: [FeedActionDTO]
}

struct FeedResponse: Content {
    let generatedAt: Date
    /// all | classic | management (all = management)
    let mode: String
    let projectID: UUID?
    let needsYou: [FeedNeedsYouDTO]
    /// Items that need you in total (needsYou is capped).
    let needsYouTotal: Int
    let posts: [FeedPostDTO]
    /// nil = end of the feed. Opaque; only valid together with the same filters.
    let nextCursor: String?
}
