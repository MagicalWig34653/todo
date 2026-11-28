import Fluent
import Vapor

/// Deploy targets for agents (ADR 0039, contracts/deploy.yaml, phase 1a): list, connection test and read-only compare. Agents see
/// target id, name, stage, protocol and results only; there is no tool to create or change a target (persons only, REST).
extension MCPController {
    static let deployTools: [Tool] = [
        Tool(name: "list_deploy_targets", scope: "projects:read",
             description: "List the deploy targets (SFTP, FTP, FTPS servers) of a project: {targets: [{id, name, stage, protocol, hostKeyConfirmed}]}. Never host, user, path or credentials. Targets are created and changed only by persons in the PWA.",
             properties: ["projectID": Schema.uuid("Project whose targets to list; must be in your grant.")], required: ["projectID"]),
        Tool(name: "test_deploy_target", scope: "projects:read",
             description: "Connection test of a deploy target with its stored credentials (needs edit rights on the project). Answer {ok, code?, files?}: files = number of files below the base path. Codes: deploy_host_key_unconfirmed (a person must confirm the SFTP host key first), deploy_host_key_mismatch, deploy_tls_untrusted, deploy_auth_failed, deploy_base_path_missing, deploy_unreachable, deploy_target_blocked, deploy_transport_unavailable, deploy_failed. Changes nothing on the server.",
             properties: ["targetID": Schema.uuid("Deploy target id from list_deploy_targets.")], required: ["targetID"]),
        Tool(name: "compare_deploy_target", scope: "projects:read",
             description: "Read-only compare of a deploy target with a repo state you send as manifest (path, size, sha256 of every repo file, paths relative to the repo root). The server applies the target's rules (includes, excludes, default excludes, path mappings), lists the server and downloads only files whose status depends on the content. Answer {ok, code?, summary: {same, new, changed, serverOnly, unverified}, files: [{path, serverPath, status, repoSize?, serverSize?}]}; status same | new (only in the repo) | changed | serverOnly | unverified (too large to download). Text files up to 2 MB compare without CRLF/LF differences. Never uploads or deletes anything.",
             properties: [
                "targetID": Schema.uuid("Deploy target id from list_deploy_targets."),
                "files": .object(["type": .string("array"), "maxItems": .number(Double(DeployLimits.maxManifest)),
                                  "description": .string("Repo manifest: every file of the repo state to compare, as {path, size, sha256}. Paths relative, '/'-separated, without '..'."),
                                  "items": .object(["type": .string("object"), "additionalProperties": .bool(false), "required": .strings(["path", "size", "sha256"]),
                                                    "properties": .object([
                                                        "path": Schema.string("Repo-relative path.", maxLength: DeployLimits.maxRepoPath),
                                                        "size": Schema.integer("Size in bytes.", min: 0),
                                                        "sha256": Schema.string("SHA-256 of the file content, 64 hex characters.", maxLength: 64),
                                                    ])])]),
             ], required: ["targetID", "files"]),
        Tool(name: "pull_server_changes", scope: "projects:read",
             description: "Pull the changes someone made directly on the server of a deploy target, read only (needs edit rights on the project). You send the manifest of your repo state like compare_deploy_target (path, size, sha256 per file; optional eol per file: lf (default), crlf or keep = the line endings the file has in your repo). Answer {ok, code?, branch, commitMessage, summary: {changed, serverOnly, onlyInRepo, same, withheld, unverified}, files: [{path, serverPath, status: changed|serverOnly, eol, encoding: utf-8|base64, content, size, sha256}], findings: [{path, serverPath, reason}], findingsTotal, remaining: [repo paths]}. Content comes with the line endings of the repo. Files that look like secrets (.env, *.pem, keys, config files with passwords), live in .git/.github, match the target's exclude rules or are too large are NEVER delivered, only named in findings (reasons secret_name, blocked_path, secret_content, excluded, too_large, unreadable). The answer is limited to maxBytes (default 256 kB, at most 16 MB; one file is always delivered); `remaining` lists the repo paths not yet delivered: call again with paths = remaining. To make the branch: git switch -c <branch>, write every file at its path (base64 content decoded), commit with commitMessage (group by purpose and improve the message; the author is the person who changed the server) or save the answer as JSON and run scripts/deploy-pull-apply.py REPO < answer.json. This tool writes nothing to GitHub and nothing to the server; if the server has a GitHub App configured, open_server_changes_pr opens the pull request itself.",
             properties: [
                "targetID": Schema.uuid("Deploy target id from list_deploy_targets."),
                "files": .object(["type": .string("array"), "maxItems": .number(Double(DeployLimits.maxManifest)),
                                  "description": .string("Repo manifest: every file of the repo state to compare with, as {path, size, sha256, eol?}. Paths relative, '/'-separated, without '..'."),
                                  "items": .object(["type": .string("object"), "additionalProperties": .bool(false), "required": .strings(["path", "size", "sha256"]),
                                                    "properties": .object([
                                                        "path": Schema.string("Repo-relative path.", maxLength: DeployLimits.maxRepoPath),
                                                        "size": Schema.integer("Size in bytes.", min: 0),
                                                        "sha256": Schema.string("SHA-256 of the file content, 64 hex characters.", maxLength: 64),
                                                        "eol": Schema.string("Line endings in the repo: lf (default), crlf or keep.", maxLength: 4),
                                                    ])])]),
                "paths": .object(["type": .string("array"), "maxItems": .number(Double(DeployPullLimits.maxSelection)),
                                  "description": .string("Only these repo paths (for example the `remaining` of the last answer)."),
                                  "items": .object(["type": .string("string"), "maxLength": .number(Double(DeployLimits.maxRepoPath))])]),
                "maxBytes": Schema.integer("Budget of the answer in bytes of delivered content, 1 to 16777216 (default 262144).", min: 1),
                "eol": Schema.string("Line endings for files that are not in your manifest: lf (default) or keep.", maxLength: 4),
             ], required: ["targetID", "files"]),
        Tool(name: "open_server_changes_pr", scope: "projects:write",
             description: "Let Todolino open a pull request with the changes made directly on the server of a deploy target (needs edit rights on the project; the server is only read). The files are the same as pull_server_changes delivers (same secret protection); except pipeline definitions (Jenkinsfile, .circleci/ …); at most 500 per run, the rest is in remaining. They become one commit on a NEW branch server/<ziel>-JJJJ-MM-TT on top of baseCommit and a pull request to the default branch, written through the GitHub App of the operator, into a repository a person mapped to the project in the PWA (or the operator allowed). GitHub rights and project rights of that person are checked on every call. Never main or any ref outside server/ (deploy_branch_forbidden), no existing branch is moved (a taken name gets -2, -3 …), nothing is merged. Send the manifest of the repo state at baseCommit, a commit of the default branch. Answer {ok, code?, repository, branch, baseBranch, baseCommit, commit, pullRequest: {number, url}, summary, files: [{path, serverPath, status, size, sha256}], findings, findingsTotal, remaining, remainingTotal}. Codes: deploy_github_not_configured (switched off: use pull_server_changes and make the branch yourself), deploy_github_config_invalid, deploy_github_repository_not_allowed, deploy_github_repository_required, deploy_github_repository_public (only private repositories), deploy_github_assignment_revoked (the person who mapped the repository can no longer manage the project), deploy_github_installation_removed, deploy_github_installation_suspended, deploy_github_repository_removed (no longer selected in the installation), deploy_github_repository_changed, deploy_github_repository_access_lost (a person has to map it again in the PWA), deploy_github_base_unknown, deploy_pull_nothing, deploy_github_auth_failed, deploy_github_forbidden, deploy_github_not_found, deploy_github_unavailable, deploy_github_failed, deploy_github_branch_exists, deploy_github_pr_failed (branch and commit exist), and the codes of test_deploy_target.",
             properties: [
                "targetID": Schema.uuid("Deploy target id from list_deploy_targets."),
                "files": .object(["type": .string("array"), "maxItems": .number(Double(DeployLimits.maxManifest)),
                                  "description": .string("Manifest of the repo state at baseCommit, every file as {path, size, sha256, eol?}. Paths relative, '/'-separated, without '..'."),
                                  "items": .object(["type": .string("object"), "additionalProperties": .bool(false), "required": .strings(["path", "size", "sha256"]),
                                                    "properties": .object([
                                                        "path": Schema.string("Repo-relative path.", maxLength: DeployLimits.maxRepoPath),
                                                        "size": Schema.integer("Size in bytes.", min: 0),
                                                        "sha256": Schema.string("SHA-256 of the file content, 64 hex characters.", maxLength: 64),
                                                        "eol": Schema.string("Line endings in the repo: lf (default), crlf or keep.", maxLength: 4),
                                                    ])])]),
                "baseCommit": Schema.string("Full commit id of the default branch that the manifest describes (git rev-parse).", maxLength: 64),
                "paths": .object(["type": .string("array"), "maxItems": .number(Double(DeployPullLimits.maxSelection)),
                                  "description": .string("Only these repo paths (for example the `remaining` of the last answer)."),
                                  "items": .object(["type": .string("string"), "maxLength": .number(Double(DeployLimits.maxRepoPath))])]),
                "maxBytes": Schema.integer("Budget of delivered content in bytes, 1 to 16777216 (default 4194304).", min: 1),
                "eol": Schema.string("Line endings for files that are not in your manifest: lf (default) or keep.", maxLength: 4),
                "branch": Schema.string("Own branch name server/<a-z, 0-9, -> (default server/<ziel>-JJJJ-MM-TT).", maxLength: GitHubBranch.maxName),
                "repository": Schema.string("owner/repo, only needed when several are allowed for the project.", maxLength: 140),
             ], required: ["targetID", "files", "baseCommit"]),
    ]

    func callDeploy(_ name: String, _ a: JSONValue, user: User, grant: OAuthGrant, db: any Database, app: Application) async throws -> JSONValue {
        let service = DeployService(app: app, user: user)
        switch name {
        case "list_deploy_targets":
            let projectID = try uuid(a["projectID"])
            _ = try await project(projectID, user: user, grant: grant, db: db)
            let targets = try await service.list(projectID: projectID).map(DeployTargetSummary.init)
            return try .encoded(["targets": targets])
        case "test_deploy_target":
            let t = try await deployTarget(a, service: service, user: user, grant: grant, db: db)
            let r = try await service.test(try t.requireID(), forPerson: false)
            var out: [String: JSONValue] = ["ok": .bool(r.ok)]
            if let code = r.code { out["code"] = .string(code) }
            if let files = r.files { out["files"] = .number(Double(files)) }
            return .object(out)
        case "compare_deploy_target":
            let t = try await deployTarget(a, service: service, user: user, grant: grant, db: db)
            let files: [DeployManifestEntry]
            do { files = try JSONDecoder().decode([DeployManifestEntry].self, from: JSONEncoder().encode(a["files"])) }
            catch { throw Abort(.badRequest, reason: "deploy_manifest_invalid") }
            return try .encoded(try await service.compare(try t.requireID(), manifest: files))
        case "pull_server_changes":
            let t = try await deployTarget(a, service: service, user: user, grant: grant, db: db)
            let request = try Self.deployRequest(DeployPullRequest.self, a)
            return try .encoded(try await service.pull(try t.requireID(), request: request, defaultBytes: DeployPullLimits.defaultBytesMCP))
        case "open_server_changes_pr":
            let t = try await deployTarget(a, service: service, user: user, grant: grant, db: db)
            return try .encoded(try await service.openPullRequest(try t.requireID(), request: try Self.deployRequest(DeployPublishRequest.self, a)))
        default:
            throw Abort(.badRequest, reason: "invalid_arguments")
        }
    }

    /// The arguments without `targetID` as the request body of the REST route.
    private static func deployRequest<T: Decodable>(_ type: T.Type, _ a: JSONValue) throws -> T {
        var object: [String: JSONValue] = [:]
        if case .object(let o) = a { object = o }
        object["targetID"] = nil
        do { return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(JSONValue.object(object))) }
        catch { throw Abort(.badRequest, reason: "deploy_manifest_invalid") }
    }

    /// The target's project must be in the grant and the person needs edit rights there; otherwise 404 like everywhere.
    private func deployTarget(_ a: JSONValue, service: DeployService, user: User, grant: OAuthGrant, db: any Database) async throws -> DeployTarget {
        guard let t = try await DeployTarget.find(try uuid(a["targetID"]), on: db) else { throw Abort(.notFound) }
        _ = try await project(t.projectID, user: user, grant: grant, db: db, role: .edit)
        return t
    }
}
