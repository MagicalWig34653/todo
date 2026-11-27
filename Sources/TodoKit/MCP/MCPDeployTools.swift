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
             description: "Pull the changes someone made directly on the server of a deploy target, read only (needs edit rights on the project). You send the manifest of your repo state like compare_deploy_target (path, size, sha256 per file; optional eol per file: lf (default), crlf or keep = the line endings the file has in your repo). Answer {ok, code?, branch, commitMessage, summary: {changed, serverOnly, onlyInRepo, same, withheld, unverified}, files: [{path, serverPath, status: changed|serverOnly, eol, encoding: utf-8|base64, content, size, sha256}], findings: [{path, serverPath, reason}], findingsTotal, remaining: [repo paths]}. Content comes with the line endings of the repo. Files that look like secrets (.env, *.pem, keys, config files with passwords), live in .git/.github, match the target's exclude rules or are too large are NEVER delivered, only named in findings (reasons secret_name, blocked_path, secret_content, excluded, too_large, unreadable). The answer is limited to maxBytes (default 256 kB, at most 16 MB; one file is always delivered); `remaining` lists the repo paths not yet delivered: call again with paths = remaining. To make the branch: git switch -c <branch>, write every file at its path (base64 content decoded), commit with commitMessage (group by purpose and improve the message; the author is the person who changed the server) or save the answer as JSON and run scripts/deploy-pull-apply.py REPO < answer.json. Todolino itself writes nothing to GitHub and nothing to the server.",
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
            let request: DeployPullRequest
            do {
                var object: [String: JSONValue] = [:]
                if case .object(let o) = a { object = o }
                object["targetID"] = nil
                request = try JSONDecoder().decode(DeployPullRequest.self, from: JSONEncoder().encode(JSONValue.object(object)))
            } catch { throw Abort(.badRequest, reason: "deploy_manifest_invalid") }
            return try .encoded(try await service.pull(try t.requireID(), request: request, defaultBytes: DeployPullLimits.defaultBytesMCP))
        default:
            throw Abort(.badRequest, reason: "invalid_arguments")
        }
    }

    /// The target's project must be in the grant and the person needs edit rights there; otherwise 404 like everywhere.
    private func deployTarget(_ a: JSONValue, service: DeployService, user: User, grant: OAuthGrant, db: any Database) async throws -> DeployTarget {
        guard let t = try await DeployTarget.find(try uuid(a["targetID"]), on: db) else { throw Abort(.notFound) }
        _ = try await project(t.projectID, user: user, grant: grant, db: db, role: .edit)
        return t
    }
}
