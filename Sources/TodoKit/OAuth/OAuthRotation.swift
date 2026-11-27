import Fluent
import Foundation

/// ADR 0036 and 0040: refresh token rotation that survives lost answers. A client that lost the answer of a rotation
/// (response lost, token store not written, many processes sharing one sign-in) sends the previous token again, seconds or
/// days later; that is not treated as theft as long as nobody has used any of its successors. Everything else stays a replay
/// and revokes the whole connection (RFC 9700, section 4.14.2). All calls run under the row lock of the grant.
///
/// MariaDB: every statement here reads through the index on `rotated_from` and writes only by primary key. A write filtered
/// by a non-indexed column locks every scanned row of `oauth_secrets` and makes rotations of unrelated connections deadlock
/// (security review 26.11.2026).
enum OAuthRotation {
    /// Lifetime of a refresh token, counted from the rotation that issued it: a connection ends after this long without use.
    static let refreshLifetime: TimeInterval = 90 * 86_400
    /// Repeats of one token. Every parallel session that finds the same stored token sends it once; this only bounds a client
    /// that never manages to store a successor.
    static let maxRepeats = 50

    enum Repeat: Equatable {
        /// Number of this repeat (1 for the first one).
        case allowed(Int)
        case replay(String)
    }

    /// Judges a consumed token that comes again. `replay` carries the reason for the protocol.
    static func judgeRepeat(_ secret: OAuthSecret, now: Date, on db: any Database) async throws -> Repeat {
        guard secret.kind == "refresh" else { return .replay("not_refresh") }
        // `consumedAt` is only missing for retired siblings and for rows from before ADR 0036.
        guard secret.consumedAt != nil, secret.expiresAt > now else { return .replay("no_window") }
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
        // One row per statement: for `id IN (…)` a small table may still be scanned, equality on the primary key never is.
        for id in siblings.sorted(by: { $0.uuidString < $1.uuidString }) {
            try await OAuthSecret.query(on: db).filter(\.$id == id).set(\.$consumed, to: true).update()
        }
    }
}
