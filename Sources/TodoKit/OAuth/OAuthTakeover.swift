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
        /// What the consent page preselects: the projects of the old connection plus the mandate projects missing from that
        /// list (so nothing of the mandate is lost or moves along unseen), each readable by the person now.
        let projects: [Project]
        /// The mandate of the old connection that the person has not revoked, limited to projects readable now.
        let mandate: BrainMandate?
        let mandateProjects: [Project]
        let name: String
        /// ADR 0037: the rules of the old connection and of its mandate; they move along (limited, see `handOver`).
        var grantRule: SelectionRule? = nil
        var mandateRule: SelectionRule? = nil
    }

    enum Found { case none, ambiguous, one(Candidate) }

    /// What the consent page showed; kept server side with the consent token, so a click never hands over more than that.
    struct Offer: Codable { var grantID: UUID; var mandateProjects: [UUID]; var mandateRule: SelectionRule? = nil }

    /// A connection signed out by replay detection stays on offer this long after the revocation (security review 26.11.2026).
    static let offerPeriod: TimeInterval = 7 * 86_400

    /// Only connections that are alive or were ended by replay detection qualify. Revoked by the person, replaced, locked
    /// account or an unknown cause never do. Several matches mean: nothing.
    static func find(user: User, client: OAuthClient, redirect: String, resource: String, now: Date = Date(), on db: any Database) async throws -> Found {
        guard !user.isLocked else { return .none }
        let userID = try user.requireID(), clientID = try client.requireID()
        let grants = try await OAuthGrant.query(on: db).filter(\.$userID == userID).filter(\.$resource == resource).all()
            .filter { g in
                guard g.revoked else { return true }
                guard g.revokedReason == OAuthRevocation.replay.rawValue, let at = g.revokedAt else { return false }
                return now.timeIntervalSince(at) <= offerPeriod
            }
        guard !grants.isEmpty else { return .none }
        let clients = Dictionary(uniqueKeysWithValues: try await OAuthClient.query(on: db).filter(\.$id ~~ Set(grants.map(\.clientID))).all()
            .compactMap { c in c.id.map { ($0, c) } })
        let readable = Dictionary(uniqueKeysWithValues: try await ProjectAccess(user: user, db: db).visibleProjects()
            .compactMap { p in p.id.map { ($0, p) } })
        let mandates = try await BrainMandate.query(on: db).filter(\.$userID == userID).filter(\.$revokedAt == .null).all()
        // ADR 0037: old connection and mandate resolved like every check (explicit list plus rule, read right).
        var resolver = ProjectSelectionResolver(userID: userID, db: db)
        var reach: [UUID: [UUID]] = [:], rules: [UUID: SelectionRule] = [:]
        for g in grants { let id = try g.requireID(); reach[id] = try await resolver.projects(of: g); rules[id] = try await resolver.rule(of: id) }
        for m in mandates { let id = try m.requireID(); reach[id] = try await resolver.projects(of: m); rules[id] = try await resolver.rule(of: id) }

        func candidate(_ grant: OAuthGrant, _ match: Match) -> Candidate? {
            guard let gid = grant.id else { return nil }
            grant.resolvedProjects = reach[gid] ?? []
            let mandate = mandates.first { $0.grantID == grant.id }
            // By name: the consent page lists these as text.
            let covered = (mandate?.id.flatMap { reach[$0] } ?? []).compactMap { readable[$0] }.sorted { $0.name.lowercased() < $1.name.lowercased() }
            let listed = Set(grant.effectiveProjects)
            let projects = grant.effectiveProjects.compactMap { readable[$0] } + covered.filter { $0.id.map { !listed.contains($0) } ?? false }
            guard !projects.isEmpty || !covered.isEmpty else { return nil }
            return Candidate(grant: grant, match: match, projects: projects, mandate: covered.isEmpty ? nil : mandate,
                             mandateProjects: covered, name: ConnectionNames.display(grant, clientName: clients[grant.clientID]?.name),
                             grantRule: rules[gid], mandateRule: covered.isEmpty ? nil : mandate?.id.flatMap { rules[$0] })
        }
        var matches = grants.filter { $0.clientID == clientID }.compactMap { candidate($0, .client) }
        // By name: client names are free to choose in open registration, so only between loopback clients and only for a
        // connection that is dead anyway (never replacing a working one). The name every unnamed client gets proves nothing.
        if matches.isEmpty, isLoopback(redirect), isDistinctive(client.name) {
            matches = grants.filter { grant in
                guard grant.revoked, let old = clients[grant.clientID], old.name == client.name else { return false }
                return !old.redirects.isEmpty && old.redirects.allSatisfy(isLoopback)
            }.compactMap { candidate($0, .name) }
        }
        guard let first = matches.first else { return .none }
        return matches.count == 1 ? .one(first) : .ambiguous
    }

    static func isDistinctive(_ clientName: String) -> Bool {
        let name = clientName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name.caseInsensitiveCompare(OAuthClient.defaultName) != .orderedSame
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

        let chosen = Set(try await new.resolveProjects(on: db, locking: true))
        // Only what the person confirmed keeps the mandate (also mandate projects that were not in the old list: the page
        // preselects them, unchecking them drops them).
        let carried = Set(candidate.mandateProjects.compactMap(\.id)).intersection(offer.mandateProjects).intersection(chosen)
            .sorted { $0.uuidString < $1.uuidString }
        var mandateID: UUID?
        if !carried.isEmpty {
            // ADR 0037: a mandate rule moves along as shown on the page. Only the explicitly named projects stay explicit
            // (group members must still follow their group). Every project of the old mandate that was not on the page or
            // was not confirmed, and every old project the person unchecked, is excluded: no later group membership and no
            // "all except" brings it back.
            var rule = offer.mandateRule
            var explicit = carried
            if rule != nil {
                let named = Set(candidate.mandate?.explicitProjects ?? [])
                let shown = Set(offer.mandateProjects)
                let belonged = named.union(candidate.mandateProjects.compactMap(\.id)).union(shown)
                let excluded = Set(rule!.excludedProjectIDs).union(belonged.subtracting(shown))
                    .union(belonged.union(old.effectiveProjects).subtracting(chosen))
                rule!.excludedProjectIDs = excluded.sorted { $0.uuidString < $1.uuidString }
                explicit = carried.filter { named.contains($0) }
            }
            let mandate = BrainMandate(userID: userID, grantID: newID, projects: explicit, now: now)
            try await mandate.save(on: db)
            mandateID = try mandate.requireID()
            if let rule { try await ProjectSelectionResolver(userID: userID, db: db, locking: true).store(rule, of: mandate.requireID()) }
        }
        let note = "Bei der Neuanmeldung auf der Zustimmungsseite bestätigt: Übernahme von „\(candidate.name)“."
        var accessOnly = chosen.intersection(old.effectiveProjects).subtracting(carried).sorted { $0.uuidString < $1.uuidString }
        // Nothing in common: still one row, naming the earlier connection where a project would stand.
        if carried.isEmpty, accessOnly.isEmpty { accessOnly = [oldID] }
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
