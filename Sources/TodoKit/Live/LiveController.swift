import Fluent
import Vapor

struct LiveHeadResponse: Content {
    /// Sync feed cursor (`c<n>`) at the time of the read; same meaning as in `/v1/sync/changes`.
    let cursor: String
    /// Opaque change token. Compare for equality only.
    let token: String
}

struct LiveWaitResponse: Content {
    let token: String
    let changed: Bool
    let cursor: String
    /// Set when the replica is shutting down: reconnect after this many seconds (it is a hint, not an error).
    var retryAfter: Int? = nil
}

struct LiveRefreshCapability: Content {
    let head: Bool
    let wait: Bool
    let stream: Bool
    let pollSeconds: Int
    let waitMaxSeconds: Int
}

/// ADR 0022. Hints only: neither route returns entity data, clients fetch with the existing routes.
struct LiveController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let sync = routes.grouped("v1", "sync")
        sync.get("head", use: head)
        sync.get("wait", use: wait)
    }

    static func capability(_ s: LiveSettings) -> LiveRefreshCapability? {
        s.enabled ? LiveRefreshCapability(head: true, wait: true, stream: false, pollSeconds: s.clientPollSeconds, waitMaxSeconds: s.maxWaitSeconds) : nil
    }

    private func etag(_ token: String) -> String { "\"\(token)\"" }

    private func requireEnabled(_ req: Request) throws {
        guard req.application.liveSettings.enabled else { throw Abort(.notFound) }
    }

    @Sendable func head(_ req: Request) async throws -> Response {
        _ = try await req.requireUser()
        try requireEnabled(req)
        let snap = try await LiveToken.current(on: req.db)
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .eTag, value: etag(snap.token))
        headers.replaceOrAdd(name: .cacheControl, value: "private, no-cache")
        if let inm = req.headers.first(name: .ifNoneMatch), inm.split(separator: ",").contains(where: {
            $0.trimmingCharacters(in: .whitespaces) == etag(snap.token) }) {
            return Response(status: .notModified, headers: headers)
        }
        let res = try await LiveHeadResponse(cursor: snap.cursor, token: snap.token).encodeResponse(for: req)
        res.headers.replaceOrAdd(name: .eTag, value: etag(snap.token))
        res.headers.replaceOrAdd(name: .cacheControl, value: "private, no-cache")
        return res
    }

    /// Long poll: returns as soon as the token differs from `since`, or after `timeout` seconds unchanged.
    @Sendable func wait(_ req: Request) async throws -> Response {
        let user = try await req.requireUser()
        try requireEnabled(req)
        let userID = try user.requireID()
        let settings = req.application.liveSettings
        let timeout = min(max(req.query[Int.self, at: "timeout"] ?? settings.defaultWaitSeconds, 1), settings.maxWaitSeconds)
        let initial = try await LiveToken.current(on: req.db)
        func reply(_ snap: LiveToken.Snapshot, changed: Bool, retryAfter: Int? = nil) async throws -> Response {
            let res = try await LiveWaitResponse(token: snap.token, changed: changed, cursor: snap.cursor, retryAfter: retryAfter).encodeResponse(for: req)
            res.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            res.headers.replaceOrAdd(name: "X-Accel-Buffering", value: "no")
            return res
        }
        let client = Self.clientID(req.query[String.self, at: "client"])
        guard let since = req.query[String.self, at: "since"], !since.isEmpty else { return try await reply(initial, changed: false) }
        if since != initial.token { return try await reply(initial, changed: true) }

        let deadline = Date().addingTimeInterval(Double(timeout))
        while true {
            let slice = min(settings.sessionRecheckSeconds, max(0.05, deadline.timeIntervalSinceNow))
            let (registration, wake) = await req.application.liveHub.wait(user: userID, client: client, since: since, seconds: slice, settings: settings)
            switch registration {
            case .accountLimit, .replicaLimit:
                var headers = HTTPHeaders(); headers.replaceOrAdd(name: .retryAfter, value: "5")
                throw Abort(.tooManyRequests, headers: headers, reason: registration == .accountLimit ? "too_many_waiters_account" : "too_many_waiters_replica")
            case .ok: break
            }
            // Revocation / expiry ends the connection: re-check the presented session on every wake.
            let stillValid = try await sessionValid(req)
            guard stillValid else { throw Abort(.unauthorized) }
            switch wake ?? .recheck {
            case .changed(let token):
                return try await reply(.init(token: token, cursor: try await LiveToken.current(on: req.db).cursor), changed: true)
            case .shutdown, .superseded:
                // Replica going down, or a newer wait of the same client replaced this one (an abandoned request or a duplicate
                // tab). The client takes over the token, so `changed` must say whether it differs: otherwise a change is lost.
                let snap = try await LiveToken.current(on: req.db)
                return try await reply(snap, changed: snap.token != since, retryAfter: 2)
            case .recheck:
                if deadline.timeIntervalSinceNow <= 0.01 {
                    let snap = try await LiveToken.current(on: req.db)
                    return try await reply(snap, changed: snap.token != since)
                }
            }
        }
    }

    /// Optional client key: 8 to 64 characters of letters, digits, `-` or `_`; anything else is ignored (no supersede).
    static func clientID(_ raw: String?) -> String? {
        guard let raw, (8...64).contains(raw.count),
              raw.unicodeScalars.allSatisfy({ ($0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0))) || $0 == "-" || $0 == "_" })
        else { return nil }
        return raw
    }

    private func sessionValid(_ req: Request) async throws -> Bool {
        guard let token = req.sessionTokenPresented else { return false }
        guard let session = try await UserSession.query(on: req.db).filter(\.$tokenHash == AuthSupport.hash(token)).first()
        else { return false }
        return session.expiresAt > Date()
    }
}
