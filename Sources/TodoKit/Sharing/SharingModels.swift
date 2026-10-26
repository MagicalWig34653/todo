import Fluent
import Vapor

enum ProjectRole: String, Content, CaseIterable {
    case read, comment, edit, manage
    var rank: Int { Self.allCases.firstIndex(of: self)! }
}

final class Team: Model, Content, @unchecked Sendable {
    static let schema = "sharing_teams"
    @ID(key: .id) var id: UUID?
    @Field(key: "name") var name: String
    @Field(key: "founder_id") var founderID: UUID
    init() {}
    init(name: String, founderID: UUID) { self.name = name; self.founderID = founderID }
}

final class TeamMembership: Model, Content, @unchecked Sendable {
    static let schema = "sharing_memberships"
    @ID(key: .id) var id: UUID?
    @Field(key: "team_id") var teamID: UUID
    @Field(key: "user_id") var userID: UUID
    @Field(key: "is_admin") var isAdmin: Bool
    @Field(key: "accepted") var accepted: Bool
    init() {}
    init(teamID: UUID, userID: UUID, isAdmin: Bool = false, accepted: Bool = false) {
        self.teamID = teamID; self.userID = userID; self.isAdmin = isAdmin; self.accepted = accepted
    }
}

/// A single principal is represented by a type and an ID, validated under the sharing lock.
final class ProjectGrant: Model, Content, @unchecked Sendable {
    static let schema = "sharing_grants"
    @ID(key: .id) var id: UUID?
    @Field(key: "project_id") var projectID: UUID
    @Field(key: "principal_type") var principalType: String
    @Field(key: "principal_id") var principalID: UUID
    @Field(key: "role") var role: ProjectRole
    init() {}
    init(projectID: UUID, principalType: String, principalID: UUID, role: ProjectRole) {
        self.projectID = projectID; self.principalType = principalType; self.principalID = principalID; self.role = role
    }
}

/// Optional overlay: absent rows preserve the original personal owner and default inheritance.
/// The original projects.owner_id remains the creator for migration compatibility, never an extra grant.
final class ProjectSharing: Model, @unchecked Sendable {
    static let schema = "sharing_projects"
    @ID(key: .id) var id: UUID?
    @Field(key: "project_id") var projectID: UUID
    @Field(key: "owner_type") var ownerType: String
    @Field(key: "owner_id") var ownerID: UUID
    @Field(key: "inherits") var inherits: Bool
    init() {}
    init(project: Project) throws {
        projectID = try project.requireID(); ownerType = "person"; ownerID = project.ownerID; inherits = true
    }
}
