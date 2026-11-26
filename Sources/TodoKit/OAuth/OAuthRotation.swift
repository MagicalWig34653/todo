import Fluent
import Foundation

/// ADR 0036: refresh token rotation with a short reuse window. A client that lost the answer of a rotation (response lost,
/// token store not written, two processes sharing one sign-in) sends the previous token again; that is not treated as theft
/// as long as nobody has used any of its successors. Everything else stays a replay and revokes the whole connection
/// (RFC 9700, section 4.14.2). All calls run under the row lock of the grant.
///
/// MariaDB: every statement here reads through the index on `rotated_from` and writes only by primary key. A write filtered
/// by a non-indexed column locks every scanned row of `oauth_secrets` and makes rotations of unrelated connections deadlock
/// (security review 26.11.2026).
enum OAuthRotation {
    /// Counted from the first use of the token; a repeat never extends it. Matches the margin in which MCP clients refresh
    /// before the 15 minute access token ends.
    static let reuseWindow: TimeInterval = 300
    /// Repeats of one token within the window. A lost answer needs one or two; more means someone keeps a stale copy.
    static let maxRepeats = 5

    enum Repeat: Equatable {
        /// Number of this repeat (1 for the first one).
        case allowed(Int)
        case replay(String)
    }

    /// Judges a consumed token that comes again. `replay` carries the reason for the protocol.
    static func judgeRepeat(_ secret: OAuthSecret, now: Date, on db: any Database) async throws -> Repeat {
        guard secret.kind == "refresh" else { return .replay("not_refresh") }
        guard let used = secret.consumedAt, secret.expiresAt > now else { return .replay("no_window") }
        guard now.timeIntervalSince(used) <= reuseWindow else { return .replay("window_over") }
        let successors = try await OAuthSecret.query(on: db).filter(\.$rotatedFrom == secret.requireID()).all()
        guard !successors.contains(where: \.consumed) else { return .replay("successor_used") }
        // The first use made one successor; each repeat one more.
        let repeats = successors.count
        guard repeats <= maxRepeats else { return .replay("repeat_limit") }
        return .allowed(repeats)
    }

    /// First use of a refresh token: the other tokens issued for the same predecessor die. Presenting one of them later is
    /// a replay (two holders of the same sign-in have diverged).
    static func retireSiblings(of secret: OAuthSecret, on db: any Database) async throws {
        guard secret.kind == "refresh", let parent = secret.rotatedFrom else { return }
        let ownID = try secret.requireID()
        let siblings = try await OAuthSecret.query(on: db).filter(\.$rotatedFrom == parent).all()
            .filter { !$0.consumed }.compactMap(\.id).filter { $0 != ownID }
        guard !siblings.isEmpty else { return }
        try await OAuthSecret.query(on: db).filter(\.$id ~~ siblings).set(\.$consumed, to: true).update()
    }
}
