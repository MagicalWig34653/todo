import Fluent
import Vapor

/// Result of one review in a batch decision. `result` is one of the stable codes
/// `ok | forbidden | not_found | already_decided | invalid`; `reason` carries the single-decision reason where there is one.
struct ReviewBatchItemDTO: Content {
    let reviewID: String
    let result: String
    var reason: String?
    var review: ReviewDTO?
}

struct ReviewBatchSummaryDTO: Content {
    var ok = 0, forbidden = 0, notFound = 0, alreadyDecided = 0, invalid = 0
}

struct ReviewBatchResponse: Content {
    let decision: String
    let results: [ReviewBatchItemDTO]
    let summary: ReviewBatchSummaryDTO
}

/// "Recommended by the brain" (ADR 0032): a comment in the chat of a review that was written by the person's mandated
/// connection (OAuth grant with an active brain mandate that covers the project of the card). The label `brain` alone
/// no longer counts, any connection can set it. The author grant is taken from the `comment.created` activity event,
/// which the server writes from the authenticated actor. No column and no migration; the comment carries the recommendation text.
enum ReviewBrain {
    /// IDs of the reviews (of the given tasks) that carry a comment of the mandated connection.
    static func reviewIDs(taskIDs: [UUID], userID: UUID, on db: any Database) async throws -> Set<UUID> {
        guard !taskIDs.isEmpty,
              let mandate = try await BrainMandate.query(on: db).filter(\.$userID == userID).filter(\.$revokedAt == .null).first(),
              let grant = try await OAuthGrant.find(mandate.grantID, on: db), !grant.revoked, grant.userID == userID else { return [] }
        let covered = Set(try await TodoTask.query(on: db).filter(\.$id ~~ taskIDs).all()
            .filter { mandate.projects.contains($0.projectID) }.compactMap(\.id))
        guard !covered.isEmpty else { return [] }
        let comments = try await TaskComment.query(on: db).filter(\.$taskID ~~ Array(covered)).filter(\.$reviewID != .null)
            .filter(\.$authorKind == "agent").all()
        guard !comments.isEmpty else { return [] }
        let commentIDs = comments.compactMap(\.id)
        let authored = Set(try await ActivityEvent.query(on: db).filter(\.$kind == "comment.created").filter(\.$actorType == .integration)
            .filter(\.$actorID == mandate.grantID).filter(\.$subjectID ~~ commentIDs).all().compactMap(\.subjectID))
        // Only comments written since the mandate was (re-)granted count, and never on a review the mandated connection requested itself.
        let candidates = comments.filter { c in (c.id.map(authored.contains) ?? false) && (c.createdAt.map { $0 >= mandate.updatedAt } ?? false) }
        let reviewIDs = Set(candidates.compactMap(\.reviewID))
        guard !reviewIDs.isEmpty else { return [] }
        let own = Set(try await TaskReview.query(on: db).filter(\.$id ~~ Array(reviewIDs)).filter(\.$requestedByType == .integration)
            .filter(\.$requestedByID == mandate.grantID).all().compactMap(\.id))
        return reviewIDs.subtracting(own)
    }
}

extension WorkflowService {
    /// Decides many reviews, each through `decideReview` (same rights, same activity, same note handling). There is no
    /// overall rollback: every review gets its own result. Repeating a call is safe (`already_decided`). A review the user
    /// cannot see is `not_found`, exactly like an unknown ID.
    func decideReviews(_ rawIDs: [String], decision rawDecision: String, note rawNote: String?, actor: WorkflowActor) async throws -> ReviewBatchResponse {
        // `changes_requested` is the batch spelling; `request_changes` (single decision) is accepted as well.
        let decision: String
        switch rawDecision {
        case "accept": decision = "accept"
        case "changes_requested", "request_changes": decision = "request_changes"
        default: throw Abort(.badRequest, reason: "invalid_decision")
        }
        guard !rawIDs.isEmpty else { throw Abort(.badRequest, reason: "no_reviews") }
        guard rawIDs.count <= WorkflowLimits.reviewBatchMaxItems else { throw Abort(.badRequest, reason: "too_many_reviews") }
        let note = try Self.optionalLabel(rawNote, max: WorkflowLimits.maxText, reason: "invalid_note")

        var seen = Set<String>()
        var items: [ReviewBatchItemDTO] = []
        var summary = ReviewBatchSummaryDTO()
        for raw in rawIDs {
            let key = raw.lowercased()
            guard seen.insert(key).inserted else { continue }
            let item = try await decideOne(raw, decision: decision, note: note, actor: actor)
            switch item.result {
            case "ok": summary.ok += 1
            case "forbidden": summary.forbidden += 1
            case "not_found": summary.notFound += 1
            case "already_decided": summary.alreadyDecided += 1
            default: summary.invalid += 1
            }
            items.append(item)
        }
        return ReviewBatchResponse(decision: rawDecision, results: items, summary: summary)
    }

    private func decideOne(_ raw: String, decision: String, note: String?, actor: WorkflowActor) async throws -> ReviewBatchItemDTO {
        guard let id = UUID(uuidString: raw) else { return .init(reviewID: raw, result: "invalid", reason: "invalid_review_id") }
        let rid = id.uuidString
        // Visibility first (read right + grant): everything else must look like an unknown ID.
        guard let review = try await TaskReview.find(id, on: db) else { return .init(reviewID: rid, result: "not_found") }
        do { _ = try await readableTask(review.taskID) }
        catch let e as Abort where e.status == .notFound { return .init(reviewID: rid, result: "not_found") }
        guard review.state == "pending" else { return .init(reviewID: rid, result: "already_decided") }
        do {
            let dto = try await decideReview(review.taskID, decision: decision, note: note, actor: actor, expectedReviewID: id)
            return .init(reviewID: rid, result: "ok", review: dto)
        } catch let e as Abort {
            switch e.status {
            case .notFound: return .init(reviewID: rid, result: "not_found")
            case .forbidden: return .init(reviewID: rid, result: "forbidden", reason: e.reason)
            case .conflict where e.reason == "no_pending_review": return .init(reviewID: rid, result: "already_decided")
            default:
                guard (400..<500).contains(Int(e.status.code)) else { throw e }
                return .init(reviewID: rid, result: "invalid", reason: e.reason)
            }
        }
    }
}
