import Fluent
import Vapor

/// Batch 4 (docs/MCP-PARITAET.md): comments, activity, attachments. Same domain code as REST
/// (`CommentService`, `ProjectCommentService`, `ActivityFeedService`, `AttachmentService`, `WorkflowService`).
extension MCPController {
    /// Raw bytes of an inline preview. base64 grows it by 4/3, so the answer stays below about 60 KB: MCP clients
    /// reject larger tool answers (a 168 KB answer was refused). There is no image scaler on the server (no ImageIO
    /// on Linux, no image dependency); bigger images are fetched with get_attachment_download.
    static let inlinePreviewBytes = 45_000

    static let activityTools: [Tool] = [
        Tool(name: "update_comment", scope: "comments:write",
             description: "Edit the text of one of your own agent messages on a task (not messages written by people). Needs the current comment version (see list_comments).",
             properties: ["taskID": Schema.uuid("Task id."), "commentID": Schema.uuid("Comment id."),
                          "version": Schema.integer("Current comment version.", min: 1),
                          "body": Schema.string("New message text (Markdown, up to 10000 characters).")],
             required: ["taskID", "commentID", "version", "body"]),
        Tool(name: "delete_comment", scope: "comments:write",
             description: "Delete a task comment (the author, or a project manager for foreign comments)." + confirmationNote,
             properties: ["taskID": Schema.uuid("Task id."), "commentID": Schema.uuid("Comment id."),
                          "version": Schema.integer("Optional current comment version.", min: 1)],
             required: ["taskID", "commentID"]),
        Tool(name: "list_project_comments", scope: "projects:read",
             description: "List the comments of a project (not of its tasks) in chronological order, the newest ones when limit cuts the list.",
             properties: ["projectID": Schema.uuid("Project id (must be in this connection's grant)."),
                          "limit": Schema.integer("Maximum number of comments (default 100).", min: 1, max: 200)],
             required: ["projectID"]),
        Tool(name: "add_project_comment", scope: "comments:write",
             description: "Post a comment on a project (needs comment rights). Markdown, up to 10000 characters.",
             properties: ["projectID": Schema.uuid("Project id."), "body": Schema.string("Comment text."),
                          "idempotencyKey": Schema.string("Optional retry key (visible ASCII, up to 200 characters). The same key and text returns the original comment.", maxLength: 200)],
             required: ["projectID", "body"]),
        Tool(name: "update_project_comment", scope: "comments:write",
             description: "Edit your own project comment using its current version.",
             properties: ["projectID": Schema.uuid("Project id."), "commentID": Schema.uuid("Comment id."),
                          "version": Schema.integer("Current comment version.", min: 1), "body": Schema.string("New text.")],
             required: ["projectID", "commentID", "version", "body"]),
        Tool(name: "delete_project_comment", scope: "comments:write",
             description: "Delete a project comment (the author, or a project manager for foreign comments)." + confirmationNote,
             properties: ["projectID": Schema.uuid("Project id."), "commentID": Schema.uuid("Comment id."),
                          "version": Schema.integer("Optional current comment version.", min: 1)],
             required: ["projectID", "commentID"]),
        Tool(name: "list_activity", scope: "tasks:read",
             description: "Activity feed (newest first) over task and project events, limited to projects this connection lists and you can read. Each item has kind, actor, project, task and time. Page with nextCursor passed as before.",
             properties: ["projectID": Schema.uuid("Optional: only this project (must be in the grant)."),
                          "limit": Schema.integer("Items per page (default 50).", min: 1, max: 100),
                          "before": Schema.string("nextCursor of the previous page.", maxLength: 100)]),
        Tool(name: "read_attachment", scope: "attachments:read",
             description: "Read one completed attachment: metadata, build info (buildID, label, platform) if it is a build screenshot and, with preview=true, the image itself as base64 only if it is tiny (up to 45000 bytes; PDFs have no preview). Larger images return previewOmitted 'preview_unavailable' with a hint: use get_attachment_download and the plugin script fetch-attachment.sh, then Read the local file.",
             properties: ["id": Schema.uuid("Attachment id."),
                          "preview": Schema.boolean("Also return the image as base64 when it is small enough (default false).")],
             required: ["id"]),
        Tool(name: "get_attachment_download", scope: "attachments:read",
             description: "Get a short-lived (5 minutes) signed download URL for ONE completed attachment (any size up to the instance limit). The URL needs no login and works only for this file, only with GET and only until expiresAt. Never post it on the board. Download it with the plugin script (claude-plugin/scripts/fetch-attachment.sh <url> [dir]) and Read the local file to look at a screenshot.",
             properties: ["id": Schema.uuid("Attachment id.")], required: ["id"]),
        Tool(name: "register_build", scope: "attachments:write",
             description: "Register an already completed attachment (for example uploaded with begin_task_upload) as a build screenshot with buildID, label and platform. Idempotent per attachment.",
             properties: ["attachmentID": Schema.uuid("Completed attachment id."),
                          "buildID": Schema.string("Identifier of the build, 1 to 100 characters.", maxLength: 100),
                          "label": Schema.string("Optional caption.", maxLength: 200),
                          "platform": Schema.string("Optional platform such as ios, macos, web.", maxLength: 50)],
             required: ["attachmentID", "buildID"]),
        Tool(name: "begin_task_upload", scope: "attachments:write",
             description: "Start an upload with an explicit role: reference (material for the work), progress (intermediate result) or result (final result). Same flow as begin_attachment (PUT the bytes to uploadURL with the bearer token), then call complete_task_upload. For build screenshots use begin_attachment or register_build afterwards.",
             properties: ["taskID": Schema.uuid("Task id."),
                          "filename": Schema.string("File name without path separators.", maxLength: 200),
                          "role": Schema.string("Upload role.", values: ["reference", "progress", "result"]),
                          "mediaType": Schema.string("MIME type.", values: ["image/png", "image/jpeg", "image/webp", "application/pdf"]),
                          "size": Schema.integer("Exact size in bytes.", min: 1),
                          "checksum": Schema.string("SHA-256 as 64 lowercase hex characters.")],
             required: ["taskID", "filename", "role", "mediaType", "size", "checksum"]),
        Tool(name: "complete_task_upload", scope: "attachments:write",
             description: "Finish an upload started with begin_task_upload after the PUT succeeded; verifies size, type and checksum and makes the file visible.",
             properties: ["attachmentID": Schema.uuid("attachmentID returned by begin_task_upload.")], required: ["attachmentID"]),
        Tool(name: "delete_attachment", scope: "attachments:write",
             description: "Delete a completed attachment (and its build entry)." + confirmationNote,
             properties: ["attachmentID": Schema.uuid("Attachment id.")], required: ["attachmentID"]),
    ]

    func callActivity(_ name: String, _ a: JSONValue, user: User, grant: OAuthGrant, db: any Database, settings: AppSettings) async throws -> JSONValue {
        guard let tool = Self.activityTools.first(where: { $0.name == name }), grant.scopes.contains(tool.scope) else { throw Abort(.forbidden, reason: "insufficient_scope") }
        let a = a.isNull ? JSONValue.object([:]) : a
        guard case .object(let args) = a, Set(args.keys).isSubset(of: Set(tool.properties.keys)), tool.required.allSatisfy({ args[$0] != nil && !a[$0].isNull }) else { throw Abort(.badRequest, reason: "invalid_arguments") }
        let grantID = try grant.requireID()
        let actor: (type: ActivityActorType, id: UUID) = (.integration, grantID)
        func version(required: Bool = true) throws -> Int? {
            let v = try intArgument(a["version"], reason: "invalid_version")
            guard v.map({ $0 > 0 }) ?? !required else { throw Abort(.badRequest, reason: "invalid_version") }
            return v
        }
        func limit(_ fallback: Int, max: Int) throws -> Int {
            let value = try intArgument(a["limit"], reason: "invalid_limit") ?? fallback
            guard (1...max).contains(value) else { throw Abort(.badRequest, reason: "invalid_limit") }
            return value
        }
        func confirm(_ values: [String: String]) async throws -> JSONValue {
            let label = try await OAuthClient.find(grant.clientID, on: db)?.name
            let r = try await ActionRequestService.create(tool: name, args: values, user: user, grant: grant, label: label, on: db)
            throw ConfirmationRequired(requestID: try r.requireID())
        }
        func pending(_ values: [String: String]) async throws -> [String: String] {
            var values = values
            if let v = try version(required: false) { values["version"] = String(v) }
            return values
        }
        let projects = grant.projects
        let taskScope: @Sendable (TodoTask) throws -> Void = { t in guard projects.contains(t.projectID) else { throw Abort(.notFound) } }

        switch name {
        case "update_comment":
            let taskID = try uuid(a["taskID"])
            let dto = try await CommentService.edit(taskID: taskID, commentID: uuid(a["commentID"]), user: user, body: requiredString(a, "body"),
                version: version()!, actor: actor, agentOnly: true, scope: taskScope, on: db)
            return try .encoded(await named(dto, db: db))
        case "delete_comment":
            let taskID = try uuid(a["taskID"])
            _ = try await task(taskID, user: user, grant: grant, db: db, role: .comment)
            return try await confirm(pending(["taskID": taskID.uuidString, "commentID": uuid(a["commentID"]).uuidString]))
        case "list_project_comments":
            let id = try uuid(a["projectID"])
            let count = try limit(100, max: 200)
            _ = try await project(id, user: user, grant: grant, db: db)
            return try .encoded(Array(try await ProjectCommentService(user: user, db: db).list(id).suffix(count)))
        case "add_project_comment":
            let id = try uuid(a["projectID"])
            if !a["idempotencyKey"].isNull && a["idempotencyKey"].string == nil { throw Abort(.badRequest, reason: "invalid_idempotency_key") }
            _ = try await project(id, user: user, grant: grant, db: db, role: .comment)
            return try .encoded(await ProjectCommentService(user: user, db: db).create(id, body: requiredString(a, "body"), idempotencyKey: a["idempotencyKey"].string, actor: actor))
        case "update_project_comment":
            let id = try uuid(a["projectID"])
            _ = try await project(id, user: user, grant: grant, db: db, role: .comment)
            return try .encoded(await ProjectCommentService(user: user, db: db).edit(id, commentID: uuid(a["commentID"]), body: requiredString(a, "body"), version: version()!, actor: actor))
        case "delete_project_comment":
            let id = try uuid(a["projectID"])
            _ = try await project(id, user: user, grant: grant, db: db, role: .comment)
            return try await confirm(pending(["projectID": id.uuidString, "commentID": uuid(a["commentID"]).uuidString]))
        case "list_activity":
            let count = try limit(50, max: 100)
            let projectID = try optionalUUID(a, "projectID")
            return try .encoded(await ActivityFeedService(user: user, db: db, allowedProjects: Set(projects))
                .page(projectID: projectID, limit: count, before: try optionalString(a, "before")))
        case "read_attachment":
            guard let att = try await Attachment.find(uuid(a["id"]), on: db), att.status == "complete" else { throw Abort(.notFound) }
            _ = try await task(att.taskID, user: user, grant: grant, db: db)
            var result: [String: JSONValue] = ["attachment": try .encoded(AttachmentDTO(att))]
            let attID = try att.requireID()
            if let build = try await BuildArtifact.query(on: db).filter(\.$attachmentID == attID).first() {
                result["build"] = try .encoded(WorkflowService.buildDTO(build, attachment: AttachmentDTO(att)))
            }
            if try optionalBool(a, "preview") == true {
                if !att.mediaType.hasPrefix("image/") { result["previewOmitted"] = .string("not_an_image") }
                else if att.size > Self.inlinePreviewBytes {
                    result["previewOmitted"] = .string("preview_unavailable")
                    result["hint"] = .string("Too large for an inline answer. Call get_attachment_download, run claude-plugin/scripts/fetch-attachment.sh <url> <dir>, then Read the file.")
                }
                else {
                    let service = AttachmentService(settings: settings)
                    let data = try await service.store(for: att).get(key: att.objectKey, db: db)
                    try service.validate(data, for: att)
                    // Recheck after storage I/O, exactly like the REST preview.
                    _ = try await task(att.taskID, user: user, grant: grant, db: db)
                    result["preview"] = .object(["mediaType": .string(att.mediaType), "dataBase64": .string(data.base64EncodedString())])
                }
            }
            return .object(result)
        case "get_attachment_download":
            guard let att = try await Attachment.find(uuid(a["id"]), on: db), att.status == "complete" else { throw Abort(.notFound) }
            _ = try await task(att.taskID, user: user, grant: grant, db: db)
            let link = AttachmentLink.path(for: try att.requireID())
            return .object(["id": .string(try att.requireID().uuidString), "filename": .string(att.filename),
                            "mediaType": .string(att.mediaType), "size": .number(Double(att.size)),
                            "url": .string(settings.oauthIssuer + link.path), "expiresAt": try .encoded(link.expiresAt)])
        case "register_build":
            let body = RegisterBuildRequest(attachmentID: try uuid(a["attachmentID"]), buildID: try requiredString(a, "buildID"),
                label: try optionalString(a, "label"), platform: try optionalString(a, "platform"))
            return try .encoded(await workflowService(user: user, grant: grant, db: db, settings: settings)
                .registerBuild(body, actor: await self.actor(grant: grant, db: db)))
        case "begin_task_upload":
            let taskID = try uuid(a["taskID"])
            guard let size = try intArgument(a["size"], reason: "invalid_size") else { throw Abort(.badRequest, reason: "invalid_size") }
            _ = try await task(taskID, user: user, grant: grant, db: db, role: .edit)
            let capability = try await AttachmentService(settings: settings).begin(
                BeginAttachment(taskID: taskID, filename: requiredString(a, "filename"), role: requiredString(a, "role"),
                                mediaType: requiredString(a, "mediaType"), size: size, checksum: requiredString(a, "checksum")), user: user, db: db)
            return .object(["attachmentID": .string(capability.attachmentID.uuidString),
                "uploadURL": .string(settings.oauthIssuer + capability.uploadURL), "method": .string("PUT"),
                "token": .string(capability.token), "expiresAt": try .encoded(capability.expiresAt)])
        case "complete_task_upload":
            // Only uploads this account started on an allowed task.
            guard let att = try await Attachment.find(uuid(a["attachmentID"]), on: db), att.ownerID == (try user.requireID()) else { throw Abort(.notFound) }
            _ = try await task(att.taskID, user: user, grant: grant, db: db, role: .edit)
            return try .encoded(await AttachmentService(settings: settings).complete(att.requireID(), user: user, db: db))
        case "delete_attachment":
            let id = try uuid(a["attachmentID"])
            guard let att = try await Attachment.find(id, on: db), att.status == "complete" else { throw Abort(.notFound) }
            _ = try await task(att.taskID, user: user, grant: grant, db: db, role: .edit)
            return try await confirm(["attachmentID": id.uuidString])
        default: throw Abort(.badRequest, reason: "unknown_tool")
        }
    }

    private func named(_ dto: CommentDTO, db: any Database) async throws -> CommentDTO {
        var dto = dto
        dto.authorName = try await displayNames([dto.authorID], on: db)[dto.authorID]
        return dto
    }
}

extension ConfirmableActions {
    static let activityActions: [ConfirmableAction] = [deleteTaskComment, deleteProjectComment, deleteAttachment]

    private static func uuidArg(_ args: [String: String], _ key: String) throws -> UUID {
        guard let raw = args[key], let id = UUID(uuidString: raw) else { throw Abort(.badRequest, reason: "invalid_\(key)") }
        return id
    }

    static let deleteTaskComment = ConfirmableAction(tool: "delete_comment", describe: { args, user, db in
        let taskID = try uuidArg(args, "taskID"), commentID = try uuidArg(args, "commentID")
        let task = try await ProjectAccess(user: user, db: db).task(taskID, role: .comment)
        guard let c = try await TaskComment.find(commentID, on: db), c.taskID == taskID else { throw Abort(.notFound) }
        if c.authorID != (try user.requireID()) {
            do { _ = try await ProjectAccess(user: user, db: db).task(taskID, role: .manage) } catch { throw Abort(.forbidden, reason: "not_comment_author") }
        }
        if let v = args["version"].flatMap(Int.init), v != c.version { throw Abort(.conflict, reason: "version_conflict") }
        return .init(summary: "Kommentar in der Aufgabe „\(task.title)“ löschen", impact: ActionImpact(targetType: "comment", targetID: commentID, targetName: task.title, destructive: true), projectIDs: [task.projectID])
    }, execute: { args, user, db in
        try await CommentService.delete(taskID: try uuidArg(args, "taskID"), commentID: try uuidArg(args, "commentID"), user: user, version: args["version"].flatMap(Int.init), on: db)
        return "deleted"
    }, requiredScope: "comments:write")

    static let deleteProjectComment = ConfirmableAction(tool: "delete_project_comment", describe: { args, user, db in
        let projectID = try uuidArg(args, "projectID"), commentID = try uuidArg(args, "commentID")
        let access = ProjectAccess(user: user, db: db)
        let project = try await access.project(projectID, role: .comment)
        guard let c = try await ProjectComment.find(commentID, on: db), c.projectID == projectID else { throw Abort(.notFound) }
        if c.authorID != (try user.requireID()) {
            do { _ = try await access.project(projectID, role: .manage) } catch { throw Abort(.forbidden, reason: "not_comment_author") }
        }
        if let v = args["version"].flatMap(Int.init), v != c.version { throw Abort(.conflict, reason: "version_conflict") }
        return .init(summary: "Kommentar im Projekt „\(project.name)“ löschen", impact: ActionImpact(targetType: "comment", targetID: commentID, targetName: project.name, destructive: true), projectIDs: [projectID])
    }, execute: { args, user, db in
        // The request is bound to the version at creation time only when one was given.
        let projectID = try uuidArg(args, "projectID"), commentID = try uuidArg(args, "commentID")
        var version = args["version"].flatMap(Int.init)
        if version == nil { version = try await ProjectComment.find(commentID, on: db)?.version }
        guard let version else { throw Abort(.notFound) }
        try await ProjectCommentService(user: user, db: db).delete(projectID, commentID: commentID, version: version)
        return "deleted"
    }, requiredScope: "comments:write")

    static let deleteAttachment = ConfirmableAction(tool: "delete_attachment", describe: { args, user, db in
        let id = try uuidArg(args, "attachmentID")
        guard let att = try await Attachment.find(id, on: db), att.status == "complete" else { throw Abort(.notFound) }
        let task = try await ProjectAccess(user: user, db: db).task(att.taskID, role: .edit)
        return .init(summary: "Anhang „\(att.filename)“ der Aufgabe „\(task.title)“ löschen", impact: ActionImpact(targetType: "attachment", targetID: id, targetName: att.filename, destructive: true), projectIDs: [task.projectID])
    }, execute: { args, user, db in
        // Storage settings are not available here: the row is marked deleted (hidden everywhere) and `cleanup-uploads` removes the bytes.
        let id = try uuidArg(args, "attachmentID")
        try await lockRow(table: Attachment.schema, id: id, on: db)
        guard let att = try await Attachment.find(id, on: db), att.status == "complete" else { throw Abort(.notFound) }
        try await AttachmentService.authorize(att, user: user, db: db, role: .edit)
        try await BuildArtifact.query(on: db).filter(\.$attachmentID == id).delete()
        att.status = "deleted"
        try await att.save(on: db)
        try await appendLockedActivity(taskID: att.taskID, actorType: .person, actorID: try user.requireID(), kind: "attachment.deleted", subjectID: id, on: db)
        return "deleted"
    }, requiredScope: "attachments:write")
}
