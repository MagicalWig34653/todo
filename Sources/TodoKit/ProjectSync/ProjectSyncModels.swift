import Fluent
import Vapor

// MARK: - Models (ADR 0018)

/// Binds a project to an external repository identifier and records when the project was last reconciled with it.
/// One row per project (`id` = project id). `owner_id` is the project owner; `repo_key` is unique per owner, so two
/// accounts can bind the same public repository to their own projects without learning about each other.
final class ProjectBinding: Model, @unchecked Sendable {
    static let schema = "project_bindings"
    @ID(custom: "id", generatedBy: .user) var id: UUID?
    @Field(key: "owner_id") var ownerID: UUID
    /// Normalised repository key, see `RepositoryKey`.
    @Field(key: "repo_key") var repoKey: String
    @Field(key: "stale_after_days") var staleAfterDays: Int
    @OptionalField(key: "last_synced_at") var lastSyncedAt: Date?
    /// `Integration` | `Person`
    @OptionalField(key: "last_synced_by_type") var lastSyncedByType: String?
    @OptionalField(key: "last_synced_by_label") var lastSyncedByLabel: String?
    /// Free hint about the repository state of the last sync (commit, branch), at most 200 characters.
    @OptionalField(key: "last_repo_ref") var lastRepoRef: String?
    @OptionalField(key: "last_summary") var lastSummary: String?
    @Field(key: "version") var version: Int
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?
    init() {}
    init(projectID: UUID, ownerID: UUID, repoKey: String, staleAfterDays: Int) {
        id = projectID; self.ownerID = ownerID; self.repoKey = repoKey; self.staleAfterDays = staleAfterDays; version = 1
    }
}

/// Stable caller-chosen key of a task inside one project (idempotent plan import).
final class TaskExternalKey: Model, @unchecked Sendable {
    static let schema = "task_external_keys"
    @ID(key: .id) var id: UUID?
    @Field(key: "task_id") var taskID: UUID
    @Field(key: "project_id") var projectID: UUID
    @Field(key: "external_key") var externalKey: String
    init() {}
    init(taskID: UUID, projectID: UUID, externalKey: String) { self.taskID = taskID; self.projectID = projectID; self.externalKey = externalKey }
}

struct CreateProjectSync: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(ProjectBinding.schema)
            .field("id", .uuid, .identifier(auto: false), .references("projects", "id", onDelete: .cascade))
            .field("owner_id", .uuid, .required)
            .field("repo_key", .string, .required)
            .field("stale_after_days", .int, .required)
            .field("last_synced_at", .datetime)
            .field("last_synced_by_type", .string).field("last_synced_by_label", .string)
            .field("last_repo_ref", .string)
            .field("last_summary", .sql(raw: "TEXT"))
            .field("version", .int, .required)
            .field("created_at", .datetime).field("updated_at", .datetime)
            .unique(on: "owner_id", "repo_key")
            .create()
        try await db.schema(TaskExternalKey.schema).id()
            .field("task_id", .uuid, .required, .references("tasks", "id", onDelete: .cascade))
            .field("project_id", .uuid, .required, .references("projects", "id", onDelete: .cascade))
            .field("external_key", .string, .required)
            .unique(on: "task_id")
            .unique(on: "project_id", "external_key")
            .create()
    }
    func revert(on db: any Database) async throws {
        try await db.schema(TaskExternalKey.schema).delete()
        try await db.schema(ProjectBinding.schema).delete()
    }
}

func configureProjectSync(_ app: Application) {
    app.migrations.add(CreateProjectSync())
}

// MARK: - Repository key

/// Normalises a git remote URL (https, ssh, scp-like) or a free key to `host/path`, lower case, without credentials,
/// scheme, port-less `.git` suffix and trailing slashes. Free keys (no host) are accepted as `[a-z0-9._-/]`.
enum RepositoryKey {
    static func normalize(_ raw: String) throws -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty, s.count <= 300, !s.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Abort(.badRequest, reason: "invalid_repository")
        }
        if let range = s.range(of: "://") { s = String(s[range.upperBound...]) }
        // Credentials (user:token@host) never enter the key.
        if let at = s.firstIndex(of: "@"), !s[..<at].contains("/") { s = String(s[s.index(after: at)...]) }
        // scp-like git@host:owner/repo and host:port/path -> host/path (a purely numeric first segment is a port).
        if let colon = s.firstIndex(of: ":"), !s[..<colon].contains("/") {
            let host = String(s[..<colon])
            var rest = String(s[s.index(after: colon)...])
            let first = rest.prefix(while: { $0 != "/" })
            if !first.isEmpty, first.allSatisfy(\.isNumber) { rest = String(rest.dropFirst(first.count)) }
            while rest.hasPrefix("/") { rest.removeFirst() }
            s = host + "/" + rest
        }
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix(".git") { s.removeLast(4) }
        while s.hasPrefix("/") { s.removeFirst() }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789._-/")
        guard !s.isEmpty, s.count <= 200, s.allSatisfy({ allowed.contains($0) }), !s.contains("//"), !s.contains("..") else {
            throw Abort(.badRequest, reason: "invalid_repository")
        }
        return s
    }
}

// MARK: - DTOs

struct ProjectSyncDTO: Content {
    /// False when the project has no repository binding yet (state is then `never`).
    let bound: Bool
    let repository: String?
    /// `fresh` | `stale` | `never`
    let state: String
    let lastSyncedAt: Date?
    let lastSyncedBy: String?
    /// Whole days since the last sync; null if never synced.
    let daysSince: Int?
    let staleAfterDays: Int
    let repoRef: String?
    let lastSummary: String?

    static let defaultStaleAfterDays = 3

    static func make(_ binding: ProjectBinding?, now: Date = Date(), includeSummary: Bool = true) -> ProjectSyncDTO {
        guard let binding else {
            return ProjectSyncDTO(bound: false, repository: nil, state: "never", lastSyncedAt: nil, lastSyncedBy: nil, daysSince: nil,
                                  staleAfterDays: defaultStaleAfterDays, repoRef: nil, lastSummary: nil)
        }
        var state = "never", days: Int?
        if let last = binding.lastSyncedAt {
            let elapsed = max(0, now.timeIntervalSince(last))
            days = Int(elapsed / 86_400)
            state = elapsed < Double(binding.staleAfterDays) * 86_400 ? "fresh" : "stale"
        }
        return ProjectSyncDTO(bound: true, repository: binding.repoKey, state: state, lastSyncedAt: binding.lastSyncedAt,
            lastSyncedBy: binding.lastSyncedByLabel, daysSince: days, staleAfterDays: binding.staleAfterDays,
            repoRef: binding.lastRepoRef, lastSummary: includeSummary ? binding.lastSummary : nil)
    }
}

/// Per-project sync entry of the command center.
struct ProjectSyncEntry: Content {
    let projectID: UUID
    let name: String
    let sync: ProjectSyncDTO
}

struct RepositoryMatch: Content {
    let projectID: UUID
    let name: String
    let sync: ProjectSyncDTO
}

struct RepositoryLookupDTO: Content {
    let repository: String
    let found: Bool
    /// Visible, granted projects bound to this repository. More than one = ambiguous; ask the user.
    let matches: [RepositoryMatch]
    /// Projects bound to this repository that exist for the user but are not part of this connection's grant.
    let outsideGrant: Int
    let hint: String
}

struct BindingRequest: Content {
    let repository: String
    let staleAfterDays: Int?
}
