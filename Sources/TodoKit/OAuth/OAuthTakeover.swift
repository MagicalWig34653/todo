import Fluent
import Vapor

/// ADR 0036 (card BEF08998): a new sign-in of the same client by the same person may take over the project list and the
/// active brain mandate of the previous connection. Offered and applied only in the consent step of the signed-in person;
/// there is no MCP way and nothing happens without `takeover_grant_id`.
///
/// What belongs to a mandate is copied in one place (`handOver`): when mandates later name more than projects (project
/// groups), that is where the further parts move and get limited.
enum OAuthTakeover {
    enum Match: String { case client, name }

    struct Candidate {
        let grant: OAuthGrant
        let match: Match
        /// Projects of the old connection the person can read now.
        let projects: [Project]
        /// The mandate of the old connection that the person has not revoked, limited to projects readable now.
        let mandate: BrainMandate?
        let mandateProjects: [Project]
        let name: String
    }

    enum Found { case none, ambiguous, one(Candidate) }

    /// What the consent page showed; kept server side with the consent token, so a click never hands over more than that.
    struct Offer: Codable { var grantID: UUID; var mandateProjects: [UUID] }

    /// Only connections that are alive or were ended by replay detection qualify. Revoked by the person, replaced, locked
    /// account or an unknown cause never do. Several matches mean: nothing.
    static func find(user: User, client: OAuthClient, redirect: String, resource: String, on db: any Database) async throws -> Found {
        guard !user.isLocked else { return .none }
        let userID = try user.requireID(), clientID = try client.requireID()
        let grants = try await OAuthGrant.query(on: db).filter(\.$userID == userID).filter(\.$resource == resource).all()
            .filter { !$0.revoked || $0.revokedReason == OAuthRevocation.replay.rawValue }
        guard !grants.isEmpty else { return .none }
        let clients = Dictionary(uniqueKeysWithValues: try await OAuthClient.query(on: db).filter(\.$id ~~ Set(grants.map(\.clientID))).all()
            .compactMap { c in c.id.map { ($0, c) } })
        let readable = Dictionary(uniqueKeysWithValues: try await ProjectAccess(user: user, db: db).visibleProjects()
            .compactMap { p in p.id.map { ($0, p) } })
        let mandates = try await BrainMandate.query(on: db).filter(\.$userID == userID).filter(\.$revokedAt == .null).all()

        func candidate(_ grant: OAuthGrant, _ match: Match) -> Candidate? {
            let projects = grant.projects.compactMap { readable[$0] }
            let mandate = mandates.first { $0.grantID == grant.id }
            // By name: the consent page lists these as text.
            let covered = (mandate?.projects ?? []).compactMap { readable[$0] }.sorted { $0.name.lowercased() < $1.name.lowercased() }
            guard !projects.isEmpty || !covered.isEmpty else { return nil }
            return Candidate(grant: grant, match: match, projects: projects, mandate: covered.isEmpty ? nil : mandate,
                             mandateProjects: covered, name: ConnectionNames.display(grant, clientName: clients[grant.clientID]?.name))
        }
        var matches = grants.filter { $0.clientID == clientID }.compactMap { candidate($0, .client) }
        // By name: client names are free to choose in open registration, so only between loopback clients and only for a
        // connection that is dead anyway (never replacing a working one).
        if matches.isEmpty, isLoopback(redirect) {
            matches = grants.filter { grant in
                guard grant.revoked, let old = clients[grant.clientID], old.name == client.name else { return false }
                return !old.redirects.isEmpty && old.redirects.allSatisfy(isLoopback)
            }.compactMap { candidate($0, .name) }
        }
        guard let first = matches.first else { return .none }
        return matches.count == 1 ? .one(first) : .ambiguous
    }

    static func isLoopback(_ redirect: String) -> Bool {
        guard let u = URLComponents(string: redirect), u.scheme == "http", let host = u.host else { return false }
        return ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
    }

    /// Runs in the consent transaction after the new grant was saved; the caller holds the locks (sharing graph, user,
    /// old mandate, old grant) and has checked that `candidate` is still the one that was offered.
    static func handOver(_ candidate: Candidate, to new: OAuthGrant, offer: Offer, user: User, on db: any Database) async throws {
        let userID = try user.requireID(), newID = try new.requireID(), old = candidate.grant, oldID = try old.requireID()
        let now = Date()
        old.revoke(.superseded, now: now); try await old.save(on: db)

        let chosen = Set(new.projects)
        // A project the person unchecked leaves the mandate as well.
        let unchecked = Set(old.projects).subtracting(chosen)
        let carried = Set(candidate.mandateProjects.compactMap(\.id)).intersection(offer.mandateProjects).subtracting(unchecked)
            .sorted { $0.uuidString < $1.uuidString }
        var mandateID: UUID?
        if !carried.isEmpty {
            let mandate = BrainMandate(userID: userID, grantID: newID, projects: carried, now: now)
            try await mandate.save(on: db)
            mandateID = try mandate.requireID()
        }
        let note = "Bei der Neuanmeldung auf der Zustimmungsseite bestätigt: Übernahme von „\(candidate.name)“."
        let accessOnly = chosen.intersection(old.projects).subtracting(carried).sorted { $0.uuidString < $1.uuidString }
        for (kind, projects) in [("mandate.taken_over", carried), ("connection.taken_over", accessOnly)] {
            for projectID in projects {
                let row = BrainConnectionAudit()
                // Without a mandate there is no mandate id; the new connection stands in (the column is internal).
                row.mandateID = mandateID ?? newID; row.userID = userID; row.grantID = newID; row.targetGrantID = oldID
                row.kind = kind; row.projectID = projectID; row.quote = note; row.createdAt = now
                try await row.save(on: db)
            }
        }
    }
}

extension OAuthGrant {
    /// ADR 0036: a connection that took over others is still the same requester for "never decide your own request".
    static func isSameRequester(_ requester: UUID, as actor: UUID, on db: any Database) async throws -> Bool {
        if requester == actor { return true }
        return try await OAuthGrant.find(actor, on: db)?.predecessors?.contains(requester) == true
    }
}
