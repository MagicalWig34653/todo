import Fluent
import Vapor

struct AttachmentController: RouteCollection {
    /// Body limit for the upload PUT; ATTACHMENT_MAX_BYTES.
    let maxBytes: Int
    init(maxBytes: Int = AttachmentLimits.defaultMaxBytes) { self.maxBytes = maxBytes }

    func boot(routes: any RoutesBuilder) throws {
        let v1 = routes.grouped("v1")
        v1.post("attachments", "begin", use: begin)
        v1.on(.PUT, "attachments", ":id", "upload", body: .collect(maxSize: ByteCount(value: maxBytes)), use: upload)
        v1.post("attachments", ":id", "complete", use: complete)
        v1.delete("attachments", ":id", use: abort)
        v1.get("attachments", ":id", "download", use: download)
        v1.get("attachments", ":id", "preview", use: preview)
        v1.get("tasks", ":id", "attachments", use: list)
    }
    private func id(_ req: Request) throws -> UUID {
        guard let id = req.parameters.get("id", as: UUID.self) else { throw Abort(.badRequest) }
        return id
    }
    private func service(_ req: Request) -> AttachmentService { AttachmentService(settings: req.application.settings) }
    @Sendable func begin(_ req: Request) async throws -> UploadCapability {
        let user = try await req.requireUser()
        return try await service(req).begin(req.content.decode(BeginAttachment.self), user: user, db: req.db)
    }
    @Sendable func upload(_ req: Request) async throws -> HTTPStatus {
        guard let token = req.headers.bearerAuthorization?.token else { throw Abort(.notFound) }
        try await service(req).upload(id(req), token: token, data: Data(req.body.data?.readableBytesView ?? ByteBuffer().readableBytesView), db: req.db)
        return .noContent
    }
    @Sendable func complete(_ req: Request) async throws -> AttachmentDTO {
        let user = try await req.requireUser()
        return try await service(req).complete(id(req), user: user, db: req.db)
    }
    @Sendable func abort(_ req: Request) async throws -> HTTPStatus {
        let user = try await req.requireUser()
        try await service(req).abort(id(req), user: user, db: req.db)
        return .noContent
    }
    @Sendable func list(_ req: Request) async throws -> [AttachmentDTO] {
        let user = try await req.requireUser()
        guard let taskID = req.parameters.get("id", as: UUID.self) else { throw Abort(.badRequest) }
        let access = ProjectAccess(user: user, db: req.db)
        let task = try await access.task(taskID)
        _ = try await access.project(task.projectID)
        return try await Attachment.query(on: req.db).filter(\.$taskID == taskID).filter(\.$status == "complete")
            .sort(\.$id).all().map(AttachmentDTO.init)
    }
    @Sendable func download(_ req: Request) async throws -> Response { try await file(req, preview: false) }
    @Sendable func preview(_ req: Request) async throws -> Response { try await file(req, preview: true) }
    private func file(_ req: Request, preview: Bool) async throws -> Response {
        let user = try await req.requireUser()
        guard let a = try await Attachment.find(id(req), on: req.db), a.status == "complete" else { throw Abort(.notFound) }
        try await AttachmentService.authorize(a, user: user, db: req.db)
        guard !preview || a.mediaType.hasPrefix("image/") else { throw Abort(.unsupportedMediaType) }
        let service = service(req)
        let data = try await service.store(for: a).get(key: a.objectKey, db: req.db)
        try service.validate(data, for: a)
        // Recheck after storage I/O so revoked access cannot reuse an earlier authorization.
        try await AttachmentService.authorize(a, user: user, db: req.db)
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: a.mediaType)
        headers.replaceOrAdd(name: .cacheControl, value: "private, no-store")
        headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        headers.replaceOrAdd(name: "Content-Security-Policy", value: "default-src 'none'; sandbox")
        let filename = a.filename.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "attachment"
        headers.replaceOrAdd(name: .contentDisposition, value: "\(preview ? "inline" : "attachment"); filename*=UTF-8''\(filename)")
        headers.replaceOrAdd(name: .acceptRanges, value: "bytes")
        // Bytes are always verified as a whole (size, magic bytes, SHA-256) before any range is cut out.
        switch ByteRange.parse(req.headers.first(name: .range), size: data.count) {
        case .full:
            return Response(status: .ok, headers: headers, body: .init(data: data))
        case .partial(let range):
            headers.replaceOrAdd(name: .contentRange, value: "bytes \(range.lowerBound)-\(range.upperBound)/\(data.count)")
            let slice = data.subdata(in: (data.startIndex + range.lowerBound)..<(data.startIndex + range.upperBound + 1))
            return Response(status: .partialContent, headers: headers, body: .init(data: slice))
        case .unsatisfiable:
            headers.replaceOrAdd(name: .contentRange, value: "bytes */\(data.count)")
            return Response(status: .rangeNotSatisfiable, headers: headers)
        }
    }
}

struct CleanupAttachmentsCommand: AsyncCommand {
    struct Signature: CommandSignature {}
    let help = "Delete expired uploads and orphaned attachment objects."
    func run(using context: CommandContext, signature: Signature) async throws {
        let count = try await AttachmentService(settings: context.application.settings).cleanup(db: context.application.db)
        context.console.print("Removed \(count) attachments.")
    }
}

func configureAttachments(_ app: Application) {
    app.migrations.add(CreateAttachmentSchema())
    app.migrations.add(AddAttachmentBlobStorage())
    app.asyncCommands.use(AttachmentsCommandGroup(), as: "attachments")
    app.asyncCommands.use(CleanupAttachmentsCommand(), as: "cleanup-uploads")
}
