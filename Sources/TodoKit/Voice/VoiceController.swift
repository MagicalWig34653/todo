import Fluent
import Vapor

/// Runner-facing voice API (`/v1/runner/voice/*`, device token) and the owner's capability switch. Logic lives in
/// `VoiceService`; nothing here logs audio, transcripts or reply texts.
struct VoiceController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let runner = routes.grouped("v1", "runner", "voice")
        runner.post("heartbeat", use: heartbeat)
        runner.get("jobs", use: queued)
        runner.post("claim", use: claimNext)
        runner.post("jobs", ":id", "claim", use: claim)
        runner.get("jobs", ":id", "audio", use: audio)
        runner.on(.PUT, "jobs", ":id", "reply-audio", body: .stream, use: replyAudio)
        runner.post("jobs", ":id", "heartbeat", use: jobHeartbeat)
        runner.post("jobs", ":id", "result", use: result)
        routes.grouped("v1", "agents").put("devices", ":id", "capabilities", use: setCapabilities)
    }

    private func id(_ req: Request) throws -> UUID {
        guard let id = req.parameters.get("id", as: UUID.self) else { throw Abort(.badRequest) }
        return id
    }

    /// Paired, not revoked device of an account that is not locked.
    private func device(_ req: Request) async throws -> RunnerDevice {
        guard let token = req.headers.bearerAuthorization?.token,
              let device = try await RunnerDevice.query(on: req.db).filter(\.$tokenHash == AuthSupport.hash(token)).first(),
              device.revokedAt == nil, let owner = try await User.find(device.ownerID, on: req.db), !owner.isLocked
        else { throw Abort(.unauthorized) }
        return device
    }

    private func generation(_ req: Request) throws -> Int {
        guard let raw = req.query[String.self, at: "generation"], let value = Int(raw), value >= 0 else {
            throw Abort(.badRequest, reason: "invalid_generation")
        }
        return value
    }

    @Sendable func heartbeat(_ req: Request) async throws -> VoiceHeartbeatResponse {
        let device = try await device(req)
        let body: VoiceHeartbeatRequest
        do { body = try req.content.decode(VoiceHeartbeatRequest.self) } catch { throw Abort(.badRequest, reason: "invalid_capabilities") }
        return try await VoiceService.heartbeat(device: device, capabilities: body.capabilities, db: req.db)
    }

    @Sendable func queued(_ req: Request) async throws -> [VoiceJobDTO] {
        try await VoiceService.queued(device: device(req), db: req.db)
    }

    @Sendable func claimNext(_ req: Request) async throws -> Response {
        try await respond(VoiceService.claim(device: device(req), jobID: nil, db: req.db), req)
    }

    @Sendable func claim(_ req: Request) async throws -> Response {
        try await respond(VoiceService.claim(device: device(req), jobID: id(req), db: req.db), req)
    }

    /// 204 when there is nothing to claim.
    private func respond(_ job: VoiceJobDTO?, _ req: Request) async throws -> Response {
        guard let job else { return Response(status: .noContent) }
        return try await job.encodeResponse(for: req)
    }

    @Sendable func audio(_ req: Request) async throws -> Response {
        let device = try await device(req)
        let service = AttachmentService(settings: req.application.settings)
        let (a, data) = try await VoiceService.audio(device: device, id: id(req), generation: generation(req), service: service, db: req.db)
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: a.mediaType)
        headers.replaceOrAdd(name: .cacheControl, value: "private, no-store")
        headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        return Response(status: .ok, headers: headers, body: .init(data: data))
    }

    @Sendable func replyAudio(_ req: Request) async throws -> [String: String] {
        let device = try await device(req)
        let jobID = try id(req), generation = try generation(req)
        if let length = req.headers.first(name: .contentLength).flatMap(Int.init), length > VoiceLimits.maxBytes {
            throw Abort(.payloadTooLarge, reason: "voice_too_large")
        }
        // Holder check before the body is buffered; storeReply repeats it under the row lock.
        _ = try await VoiceService.holderJob(id: jobID, device: device, generation: generation, db: req.db)
        let buffer = try await req.body.collect(max: VoiceLimits.maxBytes).get()
        let data = Data(buffer?.readableBytesView ?? ByteBuffer().readableBytesView)
        let service = AttachmentService(settings: req.application.settings)
        let attachment = try await VoiceService.storeReply(device: device, id: jobID, generation: generation, data: data, service: service, db: req.db)
        return ["attachmentID": attachment.uuidString]
    }

    @Sendable func jobHeartbeat(_ req: Request) async throws -> VoiceJobDTO {
        let device = try await device(req)
        let body = try decode(VoiceGenerationBody.self, req)
        return try await VoiceService.jobHeartbeat(device: device, id: id(req), generation: body.generation, db: req.db)
    }

    @Sendable func result(_ req: Request) async throws -> VoiceJobDTO {
        let device = try await device(req)
        return try await VoiceService.result(device: device, id: id(req), body: decode(VoiceResultBody.self, req), db: req.db)
    }

    private func decode<T: Content>(_ type: T.Type, _ req: Request) throws -> T {
        do { return try req.content.decode(type) } catch { throw Abort(.badRequest, reason: "invalid_request") }
    }

    /// Owner only (session): switches capabilities of an own device off. The runner keeps reporting; the server ignores them.
    @Sendable func setCapabilities(_ req: Request) async throws -> RunnerDeviceCapabilities {
        let user = try await req.requireUser()
        let body = try decode(SetCapabilitiesRequest.self, req)
        return try await VoiceService.setDisabled(deviceID: id(req), owner: user, disabled: body.disabled, db: req.db)
    }
}

/// Sweeps expired voice jobs every 30 s on every replica. Idempotent (each job is re-read under its row lock), so no
/// lease is needed; reading the channel or calling the runner API sweeps as well.
final class VoiceExpiryWorker: LifecycleHandler, @unchecked Sendable {
    let app: Application
    let interval: TimeInterval
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    init(app: Application, interval: TimeInterval = 30) { self.app = app; self.interval = interval }

    func didBoot(_ application: Application) throws {
        guard CleanupScheduler.isServing(arguments: application.environment.arguments) else { return }
        lock.lock(); defer { lock.unlock() }
        guard task == nil else { return }
        task = Task.detached { [self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * Double.random(in: 0.9...1.1) * 1_000_000_000))
                // `app.db` traps once the application is shut down (tests do not cancel lifecycle tasks); ask for the database instead.
                guard !Task.isCancelled, let db = app.databases.database(logger: app.logger, on: app.eventLoopGroup.any()) else { continue }
                do { try await VoiceService.expireDue(owner: nil, db: db) }
                catch { app.logger.warning("voice expiry sweep failed (\(type(of: error)))") }
            }
        }
    }

    func shutdown(_ application: Application) {
        lock.lock(); let t = task; task = nil; lock.unlock()
        t?.cancel()
    }
}
