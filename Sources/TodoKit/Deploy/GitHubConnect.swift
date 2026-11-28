import Fluent
import Foundation
import SQLKit
import Vapor

// ADR 0042 addendum, contracts/deploy.yaml 1.3.0 (card E51E8B8C): ONE GitHub App of the operator, one installation per person.
//
// - A person connects an installation in the PWA ("Mit GitHub verbinden"). The one-time `state` is bound to the person and used once;
//   the installation id that comes back in a URL is never trusted: GitHub's user authorization of the app says which installations
//   belong to this person (`GET /user/installations`), so nobody can claim somebody else's installation.
// - A project is mapped to a repository of one of the person's connections. Todolino acts on GitHub only through the installation
//   token of the app, and on EVERY use it asks again: the installation, the repository (same id), and whether the person who
//   mapped it may still write there (their GitHub login, same GitHub user id) and may still manage the project in Todolino.
// - The user token of the authorization is used for these calls and dropped; nothing of GitHub's tokens, codes or states is stored.
//   Agents see none of this (no MCP tool, no id in any answer).

enum GitHubConnectLimits {
    static let stateLifetime: TimeInterval = 600
    static let pendingStatesPerPerson = 10
    static let connectionsPerPerson = 20
    static let repositoriesPerProject = 20
    static let listedRepositories = 100
}

// MARK: - Models

/// A person's installation of the operator's app. `github_user_id` and `github_login` are who the person is on GitHub (proven by the
/// app's user authorization); rights are always asked of GitHub for exactly this identity.
final class GitHubConnection: Model, @unchecked Sendable {
    static let schema = "github_connections"
    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userID: UUID
    @Field(key: "installation_id") var installationID: String
    @Field(key: "account_login") var accountLogin: String
    @Field(key: "account_type") var accountType: String
    @Field(key: "github_user_id") var githubUserID: Int
    @Field(key: "github_login") var githubLogin: String
    @Field(key: "created_at") var createdAt: Date
    @Field(key: "updated_at") var updatedAt: Date
    init() {}
}

/// A pending step of the connect flow. Only the hash of the state is stored. `kind`: `setup` (back from the installation page) or
/// `callback` (back from the user authorization); `installation_id` is set when the callback belongs to one named installation.
final class GitHubConnectState: Model, @unchecked Sendable {
    static let schema = "github_connect_states"
    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userID: UUID
    @Field(key: "state_hash") var stateHash: String
    @Field(key: "kind") var kind: String
    @OptionalField(key: "installation_id") var installationID: String?
    @Field(key: "expires_at") var expiresAt: Date
    @Field(key: "created_at") var createdAt: Date
    init() {}
}

/// Project -> repository of one connection. `assigned_by` is the person whose GitHub rights count.
final class GitHubProjectRepository: Model, @unchecked Sendable {
    static let schema = "github_project_repositories"
    @ID(key: .id) var id: UUID?
    @Field(key: "project_id") var projectID: UUID
    @Field(key: "connection_id") var connectionID: UUID
    @Field(key: "repository") var repository: String
    @Field(key: "repository_id") var repositoryID: Int
    @Field(key: "assigned_by") var assignedBy: UUID
    @Field(key: "created_at") var createdAt: Date
    init() {}
}

struct CreateGitHubConnect: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(GitHubConnection.schema).id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("installation_id", .string, .required)
            .field("account_login", .string, .required)
            .field("account_type", .string, .required)
            .field("github_user_id", .int64, .required)
            .field("github_login", .string, .required)
            .field("created_at", .datetime, .required).field("updated_at", .datetime, .required)
            .unique(on: "user_id", "installation_id").create()
        try await db.schema(GitHubConnectState.schema).id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("state_hash", .string, .required)
            .field("kind", .string, .required)
            .field("installation_id", .string)
            .field("expires_at", .datetime, .required).field("created_at", .datetime, .required)
            .unique(on: "state_hash").create()
        try await db.schema(GitHubProjectRepository.schema).id()
            .field("project_id", .uuid, .required, .references("projects", "id", onDelete: .cascade))
            .field("connection_id", .uuid, .required, .references(GitHubConnection.schema, "id", onDelete: .cascade))
            .field("repository", .string, .required)
            .field("repository_id", .int64, .required)
            .field("assigned_by", .uuid, .required)
            .field("created_at", .datetime, .required)
            .unique(on: "project_id", "repository").create()
    }
    func revert(on db: any Database) async throws {
        try await db.schema(GitHubProjectRepository.schema).delete()
        try await db.schema(GitHubConnectState.schema).delete()
        try await db.schema(GitHubConnection.schema).delete()
    }
}

// MARK: - DTOs

struct GitHubConnectionDTO: Content {
    let id: UUID
    let accountLogin: String
    /// `User` | `Organization`
    let accountType: String
    let githubLogin: String
    /// Where the person changes or removes the installation on GitHub.
    let manageURL: String
    let createdAt: Date
}

struct GitHubOverview: Content {
    let available: Bool
    let connections: [GitHubConnectionDTO]
}
struct GitHubConnections: Content { let connections: [GitHubConnectionDTO] }
struct GitHubUrlAnswer: Content { let url: String }

struct GitHubRepositoryItem: Content, Equatable { let repository: String; let id: Int; let `private`: Bool }
struct GitHubRepositoryList: Content {
    var ok = false
    var code: String?
    var items: [GitHubRepositoryItem] = []
    /// The installation has more repositories than the first 100 that are looked at.
    var truncated = false
}

struct GitHubAssignmentDTO: Content {
    /// Missing for the operator's old per-instance entries.
    let id: UUID?
    let repository: String
    /// `user` (mapped in the PWA) | `operator` (old `GITHUB_APP_REPOSITORIES`)
    let source: String
    let assignedBy: String?
    let mine: Bool
    /// False when the person who mapped it can no longer manage this project: nothing is written through it until somebody maps it again.
    let active: Bool
    let createdAt: Date?
}
struct GitHubAssignments: Content { let items: [GitHubAssignmentDTO] }

private struct ConnectRequest: Decodable { let mode: String? }
private struct SetupRequest: Decodable { let state: String?; let installationID: String?; let code: String? }
private struct CallbackRequest: Decodable { let state: String?; let code: String? }
private struct AssignRequest: Decodable { let connectionID: UUID?; let repository: String? }

// MARK: - Service

struct GitHubConnectService: Sendable {
    let app: Application
    let user: User
    var db: any Database { app.db }

    private static let installKind = "setup", callbackKind = "callback"

    /// The operator's app with the connect flow switched on, else 409 `github_not_configured`.
    private func connectConfig() throws -> (config: GitHubAppConfig, connect: GitHubConnectConfig) {
        guard case .enabled(let config) = app.githubApp, let connect = config.connect else { throw Abort(.conflict, reason: "github_not_configured") }
        return (config, connect)
    }

    private func dto(_ c: GitHubConnection, web: String) throws -> GitHubConnectionDTO {
        let manage = c.accountType == "Organization"
            ? "\(web)/organizations/\(c.accountLogin)/settings/installations/\(c.installationID)"
            : "\(web)/settings/installations/\(c.installationID)"
        return GitHubConnectionDTO(id: try c.requireID(), accountLogin: c.accountLogin, accountType: c.accountType, githubLogin: c.githubLogin,
                                   manageURL: manage, createdAt: c.createdAt)
    }

    private func webURL() -> String {
        if case .enabled(let c) = app.githubApp, let web = c.connect?.webURL { return web }
        return "https://github.com"
    }

    func own(_ id: UUID) async throws -> GitHubConnection {
        guard let c = try await GitHubConnection.query(on: db).filter(\.$id == id).filter(\.$userID == user.requireID()).first() else { throw Abort(.notFound) }
        return c
    }

    func connections() async throws -> [GitHubConnectionDTO] {
        let web = webURL()
        return try await GitHubConnection.query(on: db).filter(\.$userID == user.requireID()).sort(\.$createdAt).sort(\.$id).all().map { try dto($0, web: web) }
    }

    func overview() async throws -> GitHubOverview {
        var available = false
        if case .enabled(let c) = app.githubApp, c.connect != nil { available = true }
        return GitHubOverview(available: available, connections: try await connections())
    }

    // MARK: States

    private func newState(kind: String, installationID: String?) async throws -> String {
        let uid = try user.requireID()
        let now = Date()
        try await GitHubConnectState.query(on: db).filter(\.$expiresAt < now).delete()
        // At most a handful of open steps per person: older ones make room.
        let open = try await GitHubConnectState.query(on: db).filter(\.$userID == uid).sort(\.$createdAt, .descending).all()
        for old in open.dropFirst(GitHubConnectLimits.pendingStatesPerPerson - 1) { try await old.delete(on: db) }
        let raw = AuthSupport.randomToken()
        let row = GitHubConnectState()
        row.id = UUID(); row.userID = uid; row.stateHash = AuthSupport.hash(raw); row.kind = kind; row.installationID = installationID
        row.expiresAt = now.addingTimeInterval(GitHubConnectLimits.stateLifetime); row.createdAt = now
        try await row.create(on: db)
        return raw
    }

    /// Uses the state up. It has to be this person's, of this kind and not expired; a second use (also a parallel one) fails.
    private func consume(_ raw: String?, kind: String) async throws -> GitHubConnectState {
        let invalid = Abort(.badRequest, reason: "github_state_invalid")
        guard let raw, (16...200).contains(raw.utf8.count) else { throw invalid }
        let hash = AuthSupport.hash(raw), uid = try user.requireID()
        let row: GitHubConnectState? = try await db.transaction { tx in
            guard let sql = tx as? any SQLDatabase else { return nil }
            // A locking read on MariaDB: of two parallel requests the second finds the row gone after the first has committed.
            let lock: SQLQueryString = sql.dialect.name == "sqlite" ? "" : " FOR UPDATE"
            let found = try await sql.raw("SELECT id FROM \(unsafeRaw: GitHubConnectState.schema) WHERE state_hash = \(bind: hash) AND user_id = \(bind: uid) AND kind = \(bind: kind)\(lock)").all()
            guard let first = found.first, let id = try? first.decode(column: "id", as: UUID.self),
                  let state = try await GitHubConnectState.find(id, on: tx) else { return nil }
            try await state.delete(on: tx)
            return state
        }
        guard let row, row.expiresAt > Date() else { throw invalid }
        return row
    }

    // MARK: Steps of the flow

    func start(mode: String?) async throws -> GitHubUrlAnswer {
        let (_, connect) = try connectConfig()
        switch mode {
        case "install":
            let state = try await newState(kind: Self.installKind, installationID: nil)
            return GitHubUrlAnswer(url: try Self.url("\(connect.webURL)/apps/\(connect.slug)/installations/new", ["state": state]))
        case "existing":
            return GitHubUrlAnswer(url: try authorizeURL(connect, state: try await newState(kind: Self.callbackKind, installationID: nil)))
        default: throw Abort(.badRequest, reason: "github_mode_invalid")
        }
    }

    private func authorizeURL(_ connect: GitHubConnectConfig, state: String) throws -> String {
        try Self.url("\(connect.webURL)/login/oauth/authorize",
                     ["client_id": connect.clientID, "redirect_uri": "\(app.settings.relyingPartyOrigin)/github/callback", "state": state])
    }

    private static func url(_ base: String, _ query: KeyValuePairs<String, String>) throws -> String {
        guard var c = URLComponents(string: base) else { throw Abort(.internalServerError, reason: "github_not_configured") }
        c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let out = c.string else { throw Abort(.internalServerError, reason: "github_not_configured") }
        return out
    }

    /// Back from the installation page. Without `code` the person goes on to GitHub's user authorization; with `code` (the app asks for the
    /// authorization during the installation) the connection is finished at once.
    func setup(state: String?, installationID: String?, code: String?) async throws -> (url: GitHubUrlAnswer?, connections: [GitHubConnectionDTO]?) {
        let (config, connect) = try connectConfig()
        guard let id = installationID, GitHubRepoClient.isNumeric(id) else { throw Abort(.badRequest, reason: "github_installation_invalid") }
        _ = try await consume(state, kind: Self.installKind)
        if let code {
            return (nil, try await complete(code: code, installationID: id, config: config, connect: connect))
        }
        let next = try await newState(kind: Self.callbackKind, installationID: id)
        return (GitHubUrlAnswer(url: try authorizeURL(connect, state: next)), nil)
    }

    func callback(state: String?, code: String?) async throws -> [GitHubConnectionDTO] {
        let (config, connect) = try connectConfig()
        let row = try await consume(state, kind: Self.callbackKind)
        return try await complete(code: code, installationID: row.installationID, config: config, connect: connect)
    }

    private struct InstallationEntry: Decodable {
        struct Account: Decodable { let login: String; let id: Int?; let type: String }
        let id: Int; let app_id: Int?; let account: Account
    }

    /// Exchanges the code, learns who the person is on GitHub and which installations of THIS app are theirs, and saves the wanted ones.
    private func complete(code: String?, installationID: String?, config: GitHubAppConfig, connect: GitHubConnectConfig) async throws -> [GitHubConnectionDTO] {
        guard let code, (1...200).contains(code.utf8.count), code.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7f }) else { throw Abort(.badRequest, reason: "github_authorization_failed") }
        struct Exchange: Encodable { let client_id: String; let client_secret: String; let code: String; let redirect_uri: String }
        struct Token: Decodable { let access_token: String? }
        struct Me: Decodable { let id: Int; let login: String }
        struct Installations: Decodable { let installations: [InstallationEntry] }
        let transport = app.githubTransport
        let userToken: String, me: Me, installations: [InstallationEntry]
        do {
            let answer = try await GitHubRepoClient.call(transport, .POST, "\(connect.webURL)/login/oauth/access_token", bearer: nil, accept: "application/json",
                                                         body: Exchange(client_id: connect.clientID, client_secret: connect.clientSecret, code: code,
                                                                        redirect_uri: "\(app.settings.relyingPartyOrigin)/github/callback"),
                                                         operation: "oauth", as: Token.self)
            guard let token = answer.access_token, !token.isEmpty else { throw Abort(.badRequest, reason: "github_authorization_failed") }
            userToken = token
            me = try await GitHubRepoClient.call(transport, .GET, "\(config.apiURL)/user", bearer: userToken, operation: "user", as: Me.self)
            guard GitHubRepositoryName.isLogin(me.login) else { throw Abort(.badRequest, reason: "github_authorization_failed") }
            installations = try await GitHubRepoClient.call(transport, .GET, "\(config.apiURL)/user/installations?per_page=100", bearer: userToken,
                                                            operation: "user-installations", as: Installations.self).installations
        } catch let e as GitHubError {
            app.logger.warning("github connect failed", metadata: ["operation": .string(e.operation), "status": .stringConvertible(e.status), "code": .string(e.code)])
            throw Abort(e.code == "deploy_github_unavailable" ? .badGateway : .badRequest, reason: e.code == "deploy_github_unavailable" ? e.code : "github_authorization_failed")
        }
        let mine = installations.filter { ($0.app_id == nil || String($0.app_id!) == config.appID) && GitHubRepositoryName.isLogin($0.account.login) }
        let chosen: [InstallationEntry]
        if let installationID {
            // The id came in through a URL anybody can edit: it counts only if GitHub lists it for this very person.
            guard let found = mine.first(where: { String($0.id) == installationID }) else { throw Abort(.forbidden, reason: "github_installation_not_yours") }
            chosen = [found]
        } else {
            guard !mine.isEmpty else { throw Abort(.notFound, reason: "github_no_installation") }
            chosen = mine
        }
        let uid = try user.requireID(), now = Date()
        for entry in chosen {
            let id = String(entry.id)
            let existing = try await GitHubConnection.query(on: db).filter(\.$userID == uid).filter(\.$installationID == id).first()
            if existing == nil {
                guard try await GitHubConnection.query(on: db).filter(\.$userID == uid).count() < GitHubConnectLimits.connectionsPerPerson else {
                    throw Abort(.badRequest, reason: "github_connection_limit")
                }
            }
            let c = existing ?? GitHubConnection()
            if existing == nil { c.id = UUID(); c.userID = uid; c.installationID = id; c.createdAt = now }
            c.accountLogin = entry.account.login; c.accountType = entry.account.type == "Organization" ? "Organization" : "User"
            c.githubUserID = me.id; c.githubLogin = me.login; c.updatedAt = now
            try await c.save(on: db)
        }
        app.logger.info("github installation connected", metadata: ["user": .string(uid.uuidString), "installations": .stringConvertible(chosen.count)])
        return try await connections()
    }

    func remove(_ id: UUID) async throws {
        let c = try await own(id)
        try await db.transaction { tx in
            try await GitHubProjectRepository.query(on: tx).filter(\.$connectionID == id).delete()
            try await c.delete(on: tx)
        }
    }

    // MARK: Repositories of a connection

    private func enabledConfig() -> GitHubAppConfig? {
        if case .enabled(let c) = app.githubApp { return c }
        return nil
    }

    /// The repositories of the installation this person may write to on GitHub (private and public; public ones cannot be mapped).
    func repositories(of id: UUID) async throws -> GitHubRepositoryList {
        let connection = try await own(id)
        var out = GitHubRepositoryList()
        guard let config = enabledConfig() else { out.code = "deploy_github_not_configured"; return out }
        do {
            let transport = app.githubTransport
            let status = try await GitHubRepoClient.installationStatus(config: config, installationID: connection.installationID, transport: transport)
            if status.suspended { out.code = "deploy_github_installation_suspended"; return out }
            let token = try await GitHubRepoClient.installationToken(config: config, installationID: connection.installationID, repositories: nil,
                                                                     permissions: ["metadata": "read"], transport: transport)
            let listed = try await GitHubRepoClient.installationRepositories(config: config, token: token, transport: transport)
            out.truncated = listed.more
            for repo in listed.items.prefix(GitHubConnectLimits.listedRepositories) {
                let client = GitHubRepoClient(apiURL: config.apiURL, repository: repo.name, token: token, transport: transport)
                do {
                    guard GitHubAccess.mayWrite(try await client.permission(ofLogin: connection.githubLogin), connection) else { continue }
                } catch let e as GitHubError where e.status == 404 || e.status == 403 {
                    // No answer for this one repository; anything else (GitHub down, token refused) is reported, not read as "no rights".
                    continue
                }
                out.items.append(GitHubRepositoryItem(repository: repo.name, id: repo.id, private: repo.isPrivate))
            }
            out.items.sort { $0.repository.lowercased() < $1.repository.lowercased() }
            out.ok = true
        } catch let e as GitHubError {
            app.logger.warning("github repositories failed", metadata: ["operation": .string(e.operation), "status": .stringConvertible(e.status), "code": .string(e.code)])
            out.code = e.code
            out.items = []
        }
        return out
    }

    // MARK: Mapping project -> repository

    private func manageProject(_ id: UUID) async throws -> Project { try await ProjectAccess(user: user, db: db).project(id, role: .manage) }

    func assign(projectID: UUID, connectionID: UUID?, repository: String?) async throws -> GitHubAssignmentDTO {
        let project = try await manageProject(projectID)
        guard let repository, GitHubRepositoryName.isValid(repository) else { throw Abort(.badRequest, reason: "github_repository_invalid") }
        guard let connectionID else { throw Abort(.badRequest, reason: "github_connection_required") }
        let connection = try await own(connectionID)
        guard let config = enabledConfig() else { throw Abort(.conflict, reason: "github_not_configured") }
        let existing = try await GitHubProjectRepository.query(on: db).filter(\.$projectID == projectID).all()
        guard existing.count < GitHubConnectLimits.repositoriesPerProject else { throw Abort(.badRequest, reason: "github_repository_limit") }
        guard !existing.contains(where: { $0.repository.lowercased() == repository.lowercased() }) else { throw Abort(.conflict, reason: "github_repository_assigned") }
        let notAllowed = Abort(.forbidden, reason: "deploy_github_repository_not_allowed")
        // An installation belongs to one account: only its repositories can be reached through it.
        guard repository.split(separator: "/").first.map({ $0.lowercased() == connection.accountLogin.lowercased() }) == true else { throw notAllowed }
        let info: (defaultBranch: String, isPrivate: Bool, id: Int?, fullName: String?)
        do {
            info = try await GitHubAccess.open(config: config, connection: connection, repository: repository, expectedRepositoryID: nil,
                                               project: nil, assignedBy: nil, app: app).info
        } catch let e as GitHubError {
            app.logger.info("github assignment refused", metadata: ["operation": .string(e.operation), "status": .stringConvertible(e.status), "code": .string(e.code)])
            switch e.code {
            case "deploy_github_repository_removed", "deploy_github_repository_access_lost", "deploy_github_not_found", "deploy_github_repository_changed": throw notAllowed
            case "deploy_github_installation_removed", "deploy_github_installation_suspended": throw Abort(.conflict, reason: e.code)
            case "deploy_github_unavailable": throw Abort(.badGateway, reason: e.code)
            default: throw Abort(.badRequest, reason: e.code)
            }
        }
        guard info.isPrivate else { throw Abort(.badRequest, reason: "deploy_github_repository_public") }
        guard let repositoryID = info.id else { throw Abort(.badRequest, reason: "deploy_github_failed") }
        let row = GitHubProjectRepository()
        row.id = UUID(); row.projectID = try project.requireID(); row.connectionID = try connection.requireID()
        row.repository = info.fullName.flatMap { GitHubRepositoryName.isValid($0) ? $0 : nil } ?? repository
        row.repositoryID = repositoryID; row.assignedBy = try user.requireID(); row.createdAt = Date()
        do { try await row.create(on: db) } catch { throw Abort(.conflict, reason: "github_repository_assigned") }
        app.logger.info("github repository assigned", metadata: ["project": .string(projectID.uuidString), "repository": .string(row.repository)])
        return try await assignmentDTO(row, project: project)
    }

    private func assignmentDTO(_ row: GitHubProjectRepository, project: Project) async throws -> GitHubAssignmentDTO {
        let assigner = try await User.find(row.assignedBy, on: db)
        return GitHubAssignmentDTO(id: row.id, repository: row.repository, source: "user", assignedBy: assigner?.displayName,
                                   mine: row.assignedBy == (try user.requireID()), active: try await GitHubAccess.assignerMayManage(row.assignedBy, project: project, db: db),
                                   createdAt: row.createdAt)
    }

    func assignments(projectID: UUID) async throws -> GitHubAssignments {
        let project = try await ProjectAccess(user: user, db: db).project(projectID, role: .read)
        var items: [GitHubAssignmentDTO] = []
        if case .enabled(let c) = app.githubApp, c.installationID != nil {
            for name in c.repositories[projectID] ?? [] {
                items.append(GitHubAssignmentDTO(id: nil, repository: name, source: "operator", assignedBy: nil, mine: false, active: true, createdAt: nil))
            }
        }
        for row in try await GitHubProjectRepository.query(on: db).filter(\.$projectID == projectID).sort(\.$createdAt).sort(\.$id).all() {
            items.append(try await assignmentDTO(row, project: project))
        }
        return GitHubAssignments(items: items)
    }

    func unassign(projectID: UUID, id: UUID) async throws {
        _ = try await manageProject(projectID)
        guard let row = try await GitHubProjectRepository.query(on: db).filter(\.$id == id).filter(\.$projectID == projectID).first() else { throw Abort(.notFound) }
        try await row.delete(on: db)
    }
}

// MARK: - Every use asks GitHub and Todolino again

enum GitHubAccess {
    /// `admin` and `write` may push; the GitHub identity must still be the person who connected.
    static func mayWrite(_ p: (permission: String, userID: Int?), _ connection: GitHubConnection) -> Bool {
        ["admin", "write"].contains(p.permission) && p.userID == connection.githubUserID
    }

    /// The person who mapped the repository still exists, is not locked and still manages the project.
    static func assignerMayManage(_ userID: UUID, project: Project, db: any Database) async throws -> Bool {
        guard let assigner = try await User.find(userID, on: db), !assigner.isLocked else { return false }
        return (try? await SharingAccess(user: assigner, db: db).require(project, role: .manage)) != nil
    }

    /// A client for the repository, after these checks (each a fixed error code):
    /// 1. the mapping's person may still manage the project in Todolino (`deploy_github_assignment_revoked`; no call to GitHub before that),
    /// 2. the installation exists and is not suspended, 3. the installation still has the repository (the token is limited to it),
    /// 4. it is the same repository (id), not a new one under the old name, 5. the person's GitHub identity may still write there.
    static func open(config: GitHubAppConfig, connection: GitHubConnection, repository: String, expectedRepositoryID: Int?, project: UUID?, assignedBy: UUID?,
                     app: Application) async throws -> (client: GitHubRepoClient, info: (defaultBranch: String, isPrivate: Bool, id: Int?, fullName: String?)) {
        if let project, let assignedBy {
            guard let p = try await Project.find(project, on: app.db), try await assignerMayManage(assignedBy, project: p, db: app.db) else {
                throw GitHubError(code: "deploy_github_assignment_revoked", operation: "assignment")
            }
        }
        let transport = app.githubTransport
        let status = try await GitHubRepoClient.installationStatus(config: config, installationID: connection.installationID, transport: transport)
        if status.suspended { throw GitHubError(code: "deploy_github_installation_suspended", operation: "installation") }
        let client = try await GitHubRepoClient.open(config: config, installationID: connection.installationID, repository: repository, transport: transport)
        let info = try await client.info()
        if let expectedRepositoryID, info.id != expectedRepositoryID { throw GitHubError(code: "deploy_github_repository_changed", operation: "repository") }
        let permission: (permission: String, userID: Int?)
        do { permission = try await client.permission(ofLogin: connection.githubLogin) }
        catch let e as GitHubError where e.status == 404 || e.status == 403 { throw GitHubError(code: "deploy_github_repository_access_lost", status: e.status, operation: "permission") }
        guard mayWrite(permission, connection) else { throw GitHubError(code: "deploy_github_repository_access_lost", operation: "permission") }
        return (client, info)
    }
}

// MARK: - REST

struct GitHubConnectController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let g = routes.grouped("v1", "github")
        g.get(use: overview)
        g.post("connect", use: connect)
        g.post("setup", use: setup)
        g.post("callback", use: callback)
        g.delete("connections", ":connectionID", use: remove)
        g.get("connections", ":connectionID", "repositories", use: repositories)
        let p = routes.grouped("v1", "projects", ":id", "github-repositories")
        p.get(use: assignments)
        p.post(use: assign)
        p.delete(":mappingID", use: unassign)
    }

    // `requireUser` accepts person sessions only: OAuth access tokens (MCP connections) are 401 here.
    private func service(_ req: Request) async throws -> GitHubConnectService { GitHubConnectService(app: req.application, user: try await req.requireUser()) }
    private func id(_ req: Request, _ name: String) throws -> UUID {
        guard let id = req.parameters.get(name, as: UUID.self) else { throw Abort(.notFound) }
        return id
    }
    private func body<T: Decodable>(_ req: Request, _ type: T.Type) throws -> T {
        do { return try req.content.decode(type) } catch { throw Abort(.badRequest, reason: "github_request_invalid") }
    }

    @Sendable func overview(_ req: Request) async throws -> GitHubOverview { try await service(req).overview() }
    @Sendable func connect(_ req: Request) async throws -> GitHubUrlAnswer {
        let s = try await service(req)
        return try await s.start(mode: try body(req, ConnectRequest.self).mode)
    }
    @Sendable func setup(_ req: Request) async throws -> Response {
        let s = try await service(req)
        let b = try body(req, SetupRequest.self)
        let r = try await s.setup(state: b.state, installationID: b.installationID, code: b.code)
        if let url = r.url { return try await url.encodeResponse(for: req) }
        return try await GitHubConnections(connections: r.connections ?? []).encodeResponse(for: req)
    }
    @Sendable func callback(_ req: Request) async throws -> GitHubConnections {
        let s = try await service(req)
        let b = try body(req, CallbackRequest.self)
        return GitHubConnections(connections: try await s.callback(state: b.state, code: b.code))
    }
    @Sendable func remove(_ req: Request) async throws -> HTTPStatus {
        try await service(req).remove(try id(req, "connectionID"))
        return .noContent
    }
    @Sendable func repositories(_ req: Request) async throws -> GitHubRepositoryList { try await service(req).repositories(of: try id(req, "connectionID")) }
    @Sendable func assignments(_ req: Request) async throws -> GitHubAssignments { try await service(req).assignments(projectID: try id(req, "id")) }
    @Sendable func assign(_ req: Request) async throws -> Response {
        let s = try await service(req)
        let b = try body(req, AssignRequest.self)
        let made = try await s.assign(projectID: try id(req, "id"), connectionID: b.connectionID, repository: b.repository)
        return try await made.encodeResponse(status: .created, for: req)
    }
    @Sendable func unassign(_ req: Request) async throws -> HTTPStatus {
        try await service(req).unassign(projectID: try id(req, "id"), id: try id(req, "mappingID"))
        return .noContent
    }
}

func configureGitHubConnect(_ app: Application) {
    app.migrations.add(CreateGitHubConnect())
}
