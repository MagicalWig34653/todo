import Fluent
import Vapor

struct DirectoryUser: Content {
    let id: UUID
    let displayName: String
}

/// Display names for IDs the caller already encountered through an authorized object (comment, activity, team).
func displayNames(_ ids: [UUID], on db: any Database) async throws -> [UUID: String] {
    let unique = Array(Set(ids))
    guard !unique.isEmpty else { return [:] }
    var result: [UUID: String] = [:]
    for user in try await User.query(on: db).filter(\.$id ~~ unique).all() { result[try user.requireID()] = user.displayName }
    return result
}

/// Scoped user directory for invitations. There is deliberately no global directory: only people the
/// caller already shares a team or project with can be found. Everyone else is invited by account ID.
struct DirectoryController: RouteCollection {
    static let minimumQueryLength = 2
    static let maximumResults = 20

    func boot(routes: any RoutesBuilder) throws {
        routes.grouped("v1").get("users", "search", use: search)
    }

    @Sendable func search(_ req: Request) async throws -> [DirectoryUser] {
        let user = try await req.requireUser()
        let query = (req.query[String.self, at: "q"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= Self.minimumQueryLength, query.count <= 100 else { throw Abort(.badRequest, reason: "invalid_query") }
        let limit = req.query[Int.self, at: "limit"] ?? Self.maximumResults
        guard (1...Self.maximumResults).contains(limit) else { throw Abort(.badRequest, reason: "invalid_limit") }
        let connected = try await connectedUserIDs(of: user, on: req.db)
        guard !connected.isEmpty else { return [] }
        let needle = query.lowercased()
        let candidates = try await User.query(on: req.db).filter(\.$id ~~ Array(connected)).all()
        return try candidates.filter { $0.displayName.lowercased().contains(needle) }
            .sorted { ($0.displayName.lowercased(), $0.id?.uuidString ?? "") < ($1.displayName.lowercased(), $1.id?.uuidString ?? "") }
            .prefix(limit).map { DirectoryUser(id: try $0.requireID(), displayName: $0.displayName) }
    }

    /// Accepted co-members of the caller's teams, members the caller invited as team admin, and people
    /// with a stake in projects the caller can see (owners; direct grantees where the caller manages).
    private func connectedUserIDs(of user: User, on db: any Database) async throws -> Set<UUID> {
        let uid = try user.requireID()
        let access = SharingAccess(user: user, db: db)
        var ids = Set<UUID>()
        let memberships = try await access.memberships()
        let teamIDs = memberships.map(\.teamID)
        if !teamIDs.isEmpty {
            let adminTeams = Set(memberships.filter(\.isAdmin).map(\.teamID))
            for member in try await TeamMembership.query(on: db).filter(\.$teamID ~~ teamIDs).all()
            where member.accepted || adminTeams.contains(member.teamID) { ids.insert(member.userID) }
        }
        for project in try await ProjectAccess(user: user, db: db).visibleProjects() {
            let visibility = try await access.visibility(project)
            if let sharing = try await ProjectSharing.query(on: db).filter(\.$projectID == project.requireID()).first() {
                if sharing.ownerType == "person" { ids.insert(sharing.ownerID) }
            } else {
                ids.insert(project.ownerID)
            }
            if visibility.role == .manage {
                for grant in try await ProjectGrant.query(on: db).filter(\.$projectID == project.requireID()).all()
                where grant.principalType == "person" { ids.insert(grant.principalID) }
            }
        }
        ids.remove(uid)
        return ids
    }
}
