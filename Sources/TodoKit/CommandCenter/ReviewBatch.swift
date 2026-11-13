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

/// "Recommended by the brain": a comment in the chat of a review whose author kind is `agent` and whose label is
/// `brain` (case-insensitive, trimmed). No column and no migration: the marker is the comment itself, so it carries
/// the recommendation text (or Lino's quote) with it. The agent writes it through `add_comment {reviewID, agentName: "brain"}`.
/// A person can never set the marker (authorKind is server-assigned from the actor). The proxy-authority card builds on this.
enum ReviewBrain {
    static let label = "brain"

    static func isBrain(kind: String?, label: String?) -> Bool {
        kind == "agent" && label?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == Self.label
    }

    /// IDs of the reviews (of the given tasks) that carry a brain comment.
    static func reviewIDs(taskIDs: [UUID], on db: any Database) async throws -> Set<UUID> {
        guard !taskIDs.isEmpty else { return [] }
        let rows = try await TaskComment.query(on: db).filter(\.$taskID ~~ taskIDs).filter(\.$reviewID != .null)
            .filter(\.$authorKind == "agent").all()
        return Set(rows.compactMap { isBrain(kind: $0.authorKind, label: $0.authorLabel) ? $0.reviewID : nil })
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
            let dto = try await decideReview(review.taskID, decision: decision, note: note, actor: actor)
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
