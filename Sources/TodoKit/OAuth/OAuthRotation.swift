import Fluent
import Foundation

/// ADR 0036: refresh token rotation with a short reuse window. A client that lost the answer of a rotation (response lost,
/// token store not written, two processes sharing one sign-in) sends the previous token again; that is not treated as theft
/// as long as nobody has used any of its successors. Everything else stays a replay and revokes the whole connection
/// (RFC 9700, section 4.14.2). All calls run under the row lock of the grant.
enum OAuthRotation {
    /// Counted from the first use of the token; a repeat never extends it. Matches the margin in which MCP clients refresh
    /// before the 15 minute access token ends.
    static let reuseWindow: TimeInterval = 300

    static func mayRepeat(_ secret: OAuthSecret, now: Date, on db: any Database) async throws -> Bool {
        guard secret.kind == "refresh", secret.expiresAt > now, let used = secret.consumedAt,
              now.timeIntervalSince(used) <= reuseWindow else { return false }
        return try await OAuthSecret.query(on: db).filter(\.$rotatedFrom == secret.requireID())
            .filter(\.$consumed == true).count() == 0
    }

    /// First use of a refresh token: the other tokens issued for the same predecessor die. Presenting one of them later is
    /// a replay (two holders of the same sign-in have diverged).
    static func retireSiblings(of secret: OAuthSecret, on db: any Database) async throws {
        guard secret.kind == "refresh", let parent = secret.rotatedFrom else { return }
        try await OAuthSecret.query(on: db).filter(\.$rotatedFrom == parent).filter(\.$id != secret.requireID())
            .filter(\.$consumed == false).set(\.$consumed, to: true).update()
    }
}
