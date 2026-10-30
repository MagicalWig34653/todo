import Fluent
import Vapor

struct PairDeviceRequest: Content { let label: String }
struct PairDeviceResponse: Content { let deviceID: UUID; let code: String; let expiresAt: Date }
struct CompletePairingRequest: Content { let code: String }
struct DeviceTokenResponse: Content { let deviceID: UUID; let token: String }
struct CreateBindingRequest: Content { let projectID: UUID; let deviceID: UUID; let repositoryKey: String; let label: String }
struct BindingDTO: Content {
    let id: UUID; let projectID: UUID; let deviceID: UUID; let repositoryKey: String; let label: String
    init(_ binding: ProjectRunnerBinding) throws {
        id = try binding.requireID(); projectID = binding.projectID; deviceID = binding.deviceID
        repositoryKey = binding.repositoryKey; label = binding.label
    }
}
struct ReleaseJobRequest: Content {
    /// Caller-generated ID makes an uncertain release retry safe.
    let id: UUID
    let taskID: UUID
    let bindingID: UUID
    let previousJobID: UUID?
    let taskRevision: Int
    let mode: String
    let scope: String
}
struct AnswerRequest: Content { let value: String }
struct ReviewRequest: Content { let decision: String }
struct AgentQuestionDTO: Content {
    let id: UUID; let taskID: UUID; let prompt: String; let options: [String]
    let answer: String?; let authorID: UUID?
}
struct AgentEventDTO: Content {
    let id: UUID; let runID: UUID?; let kind: String; let detail: String; let createdAt: Date
}
struct AgentDetail: Content {
    let job: AgentJobDTO
    let task: TaskDTO
    let questions: [AgentQuestionDTO]
    let events: [AgentEventDTO]
    init(_ job: AgentJob, on db: any Database) async throws {
        self.job = try AgentJobDTO(job)
        guard let task = try await TodoTask.find(job.taskID, on: db), task.projectID == job.projectID else { throw Abort(.notFound) }
        self.task = try TaskDTO(task)
        var questions: [AgentQuestionDTO] = []
        for question in try await AgentQuestion.query(on: db).filter(\.$jobID == job.requireID()).sort(\.$id).all() {
            let answer = try await AgentAnswer.query(on: db).filter(\.$questionID == question.requireID()).first()
            questions.append(AgentQuestionDTO(id: try question.requireID(), taskID: question.taskID,
                prompt: question.prompt, options: question.options, answer: answer?.value, authorID: answer?.authorID))
        }
        self.questions = questions
        events = try await AgentEvent.query(on: db).filter(\.$jobID == job.requireID()).sort(\.$createdAt).sort(\.$id).all().map {
            AgentEventDTO(id: try $0.requireID(), runID: $0.runID, kind: $0.kind, detail: $0.detail, createdAt: $0.createdAt)
        }
    }
}

struct RunnerDeviceDTO: Content {
    let id: UUID
    let label: String
    /// False until the one-time pairing code was redeemed.
    let paired: Bool
    let revokedAt: Date?
    let bindings: [BindingDTO]
    /// Runs without `endedAt` (also expired-lease runs that were not yet reconciled).
    let activeRunCount: Int
}

struct AgentJobListItem: Content {
    let job: AgentJobDTO
    let taskTitle: String
    let projectName: String
    /// Time of the `released` event; absent for legacy jobs without one.
    let createdAt: Date?
}

struct AgentJobPage: Content {
    static let states: Set<String> = ["queued", "claimed", "running", "waiting_for_answer", "awaiting_review", "succeeded", "failed", "cancelled"]
    static let defaultLimit = 50
    static let maxLimit = 100
    let items: [AgentJobListItem]
    let nextCursor: String?
}

struct AgentController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let human = routes.grouped("v1", "agents")
        human.get("devices", use: listDevices)
        human.get("jobs", use: listJobs)
        human.post("devices", use: createPairing)
        human.delete("devices", ":id", use: revoke)
        human.post("bindings", use: bind)
        human.post("jobs", use: release)
        human.get("jobs", ":id", use: detail)
        human.post("jobs", ":id", "stop", use: stop)
        human.post("jobs", ":id", "review", use: review)
        human.post("questions", ":id", "answer", use: answer)
        let runner = routes.grouped("v1", "runner")
        runner.post("pair", use: pair)
        runner.get("bindings", use: bindings)
        runner.get("jobs", use: queued)
        runner.post("jobs", ":id", "claim", use: claim)
        runner.get("jobs", ":id", use: runnerDetail)
        runner.get("runs", use: runs)
        runner.post("runs", ":id", ":action", use: command)
    }

    private func id(_ req: Request) throws -> UUID {
        guard let id = req.parameters.get("id", as: UUID.self) else { throw Abort(.badRequest) }
        return id
    }

    private func device(_ req: Request) async throws -> RunnerDevice {
        guard let token = req.headers.bearerAuthorization?.token,
              let device = try await RunnerDevice.query(on: req.db).filter(\.$tokenHash == AuthSupport.hash(token)).first(),
              device.revokedAt == nil else { throw Abort(.unauthorized) }
        return device
    }

    /// Own runner devices with their project bindings. Never exposes tokens, token hashes or pairing codes.
    @Sendable func listDevices(_ req: Request) async throws -> [RunnerDeviceDTO] {
        let user = try await req.requireUser()
        let devices = try await RunnerDevice.query(on: req.db).filter(\.$ownerID == user.requireID()).sort(\.$label).sort(\.$id).all()
        var result: [RunnerDeviceDTO] = []
        for device in devices {
            let id = try device.requireID()
            let bindings = try await ProjectRunnerBinding.query(on: req.db).filter(\.$deviceID == id).sort(\.$id).all()
            let active = try await AgentRun.query(on: req.db).filter(\.$deviceID == id).filter(\.$endedAt == nil).count()
            result.append(RunnerDeviceDTO(id: id, label: device.label, paired: device.tokenHash != nil,
                revokedAt: device.revokedAt, bindings: try bindings.map(BindingDTO.init), activeRunCount: active))
        }
        return result
    }

    /// Agent jobs of the caller's own projects (agent execution stays an owner capability, like the detail route).
    @Sendable func listJobs(_ req: Request) async throws -> AgentJobPage {
        let user = try await req.requireUser()
        let access = ProjectAccess(user: user, db: req.db)
        var projects: [Project]
        if let raw = req.query[String.self, at: "projectID"] {
            guard let id = UUID(uuidString: raw) else { throw Abort(.badRequest, reason: "invalid_project") }
            projects = [try await access.startAgent(in: id)]
        } else {
            projects = try await access.visibleProjects().filter { $0.ownerID == user.id }
        }
        var taskID: UUID?
        if let raw = req.query[String.self, at: "taskID"] {
            guard let id = UUID(uuidString: raw) else { throw Abort(.badRequest, reason: "invalid_task") }
            taskID = id
        }
        var state: String?
        if let raw = req.query[String.self, at: "state"] {
            guard AgentJobPage.states.contains(raw) else { throw Abort(.badRequest, reason: "invalid_state") }
            state = raw
        }
        var limit = AgentJobPage.defaultLimit
        if let raw = req.query[String.self, at: "limit"] {
            guard let value = Int(raw), (1...AgentJobPage.maxLimit).contains(value) else { throw Abort(.badRequest, reason: "invalid_limit") }
            limit = value
        }
        var cursor: (Double, String)?
        if let raw = req.query[String.self, at: "before"] {
            let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, let time = Double(parts[0]), time.isFinite, let id = UUID(uuidString: String(parts[1])) else {
                throw Abort(.badRequest, reason: "invalid_cursor")
            }
            cursor = (time, id.uuidString)
        }
        guard !projects.isEmpty else { return AgentJobPage(items: [], nextCursor: nil) }
        let names = Dictionary(uniqueKeysWithValues: try projects.map { (try $0.requireID(), $0.name) })
        var query = AgentJob.query(on: req.db).filter(\.$projectID ~~ Array(names.keys))
        if let taskID { query = query.filter(\.$taskID == taskID) }
        if let state { query = query.filter(\.$state == state) }
        let jobs = try await query.all()
        // Jobs carry no timestamp of their own; the `released` event is the creation time.
        let released = try await AgentEvent.query(on: req.db).filter(\.$kind == "released")
            .filter(\.$jobID ~~ jobs.map { try $0.requireID() }).all()
        var createdAt: [UUID: Date] = [:]
        for event in released { createdAt[event.jobID] = min(createdAt[event.jobID] ?? event.createdAt, event.createdAt) }
        let titles = Dictionary(uniqueKeysWithValues: try await TodoTask.query(on: req.db)
            .filter(\.$id ~~ Array(Set(jobs.map(\.taskID)))).all().map { (try $0.requireID(), $0.title) })
        var rows = try jobs.map { job -> (key: (Double, String), item: AgentJobListItem) in
            let id = try job.requireID()
            let created = createdAt[id]
            return ((created?.timeIntervalSince1970 ?? 0, id.uuidString), AgentJobListItem(
                job: try AgentJobDTO(job), taskTitle: titles[job.taskID] ?? "", projectName: names[job.projectID] ?? "",
                createdAt: created))
        }
        rows.sort { $0.key.0 != $1.key.0 ? $0.key.0 > $1.key.0 : $0.key.1 > $1.key.1 }
        if let cursor { rows = rows.filter { $0.key.0 < cursor.0 || ($0.key.0 == cursor.0 && $0.key.1 < cursor.1) } }
        let hasMore = rows.count > limit
        let page = Array(rows.prefix(limit))
        let next = hasMore ? page.last.map { "\($0.key.0):\($0.key.1)" } : nil
        return AgentJobPage(items: page.map(\.item), nextCursor: next)
    }

    @Sendable func createPairing(_ req: Request) async throws -> PairDeviceResponse {
        let user = try await req.requireUser()
        let body = try req.content.decode(PairDeviceRequest.self)
        let code = AuthSupport.randomToken(bytes: 24)
        let expires = Date().addingTimeInterval(600)
        return try await req.db.transaction { db in
            let device = try RunnerDevice(ownerID: user.requireID(), label: AgentService.text(body.label, max: 100), tokenHash: nil, revokedAt: nil)
            try await device.save(on: db)
            try await RunnerPairing(deviceID: device.requireID(), codeHash: AuthSupport.hash(code), expiresAt: expires, usedAt: nil).save(on: db)
            return PairDeviceResponse(deviceID: try device.requireID(), code: code, expiresAt: expires)
        }
    }

    @Sendable func pair(_ req: Request) async throws -> DeviceTokenResponse {
        let body = try req.content.decode(CompletePairingRequest.self)
        guard let pairing = try await RunnerPairing.query(on: req.db).filter(\.$codeHash == AuthSupport.hash(body.code)).first() else {
            throw Abort(.unauthorized)
        }
        return try await req.db.transaction { db in
            try await lockRow(table: RunnerDevice.schema, id: pairing.deviceID, on: db)
            guard let current = try await RunnerPairing.find(pairing.requireID(), on: db), current.usedAt == nil,
                  current.expiresAt > Date(), let device = try await RunnerDevice.find(current.deviceID, on: db),
                  device.revokedAt == nil, device.tokenHash == nil else { throw Abort(.unauthorized) }
            let token = AuthSupport.randomToken()
            device.tokenHash = AuthSupport.hash(token)
            current.usedAt = Date()
            try await device.save(on: db)
            try await current.save(on: db)
            return DeviceTokenResponse(deviceID: try device.requireID(), token: token)
        }
    }

    @Sendable func revoke(_ req: Request) async throws -> HTTPStatus {
        let user = try await req.requireUser()
        let deviceID = try id(req)
        try await req.db.transaction { db in
            try await lockRow(table: RunnerDevice.schema, id: deviceID, on: db)
            guard let device = try await RunnerDevice.find(deviceID, on: db), device.ownerID == user.id else { throw Abort(.notFound) }
            device.revokedAt = Date()
            try await device.save(on: db)
            // Revocation cannot confirm termination of a local process. Its repository stays occupied.
            for run in try await AgentRun.query(on: db).filter(\.$deviceID == deviceID).filter(\.$endedAt == nil).all() {
                run.generation += 1
                run.leaseUntil = Date()
                try await run.save(on: db)
                if let job = try await AgentJob.find(run.jobID, on: db) {
                    job.state = "cancelled"
                    try await job.save(on: db)
                    try await AgentService.event(job, run: run, kind: "device_revoked", on: db)
                }
            }
        }
        return .noContent
    }

    @Sendable func bind(_ req: Request) async throws -> BindingDTO {
        let user = try await req.requireUser()
        let body = try req.content.decode(CreateBindingRequest.self)
        return try await req.db.transaction { db in
            try await lockRow(table: RunnerDevice.schema, id: body.deviceID, on: db)
            _ = try await ProjectAccess(user: user, db: db).startAgent(in: body.projectID)
            guard let device = try await RunnerDevice.find(body.deviceID, on: db), device.ownerID == user.id,
                  device.revokedAt == nil, device.tokenHash != nil else { throw Abort(.notFound) }
            // An opaque local repository ID groups aliases without storing a filesystem path.
            guard UUID(uuidString: body.repositoryKey) != nil else { throw Abort(.badRequest, reason: "repository_key_must_be_uuid") }
            let label = try AgentService.text(body.label, max: 100)
            guard !label.contains("/"), !label.contains("\\") else { throw Abort(.badRequest, reason: "label_must_not_be_path") }
            let binding = ProjectRunnerBinding(projectID: body.projectID, deviceID: body.deviceID,
                repositoryKey: body.repositoryKey.lowercased(), label: label)
            try await binding.save(on: db)
            return try BindingDTO(binding)
        }
    }

    @Sendable func release(_ req: Request) async throws -> AgentJobDTO {
        try await AgentService.release(req.content.decode(ReleaseJobRequest.self), user: req.requireUser(), on: req.db)
    }

    @Sendable func detail(_ req: Request) async throws -> AgentDetail {
        let user = try await req.requireUser()
        return try await AgentDetail(AgentService.humanJob(id(req), user: user, on: req.db), on: req.db)
    }

    @Sendable func stop(_ req: Request) async throws -> AgentJobDTO {
        try await AgentService.humanTransition(jobID: id(req), decision: "stop", user: req.requireUser(), on: req.db)
    }

    @Sendable func review(_ req: Request) async throws -> AgentJobDTO {
        let decision = try req.content.decode(ReviewRequest.self).decision
        guard ["accept", "request_changes"].contains(decision) else { throw Abort(.badRequest) }
        return try await AgentService.humanTransition(jobID: id(req), decision: decision, user: req.requireUser(), on: req.db)
    }

    @Sendable func answer(_ req: Request) async throws -> AgentDetail {
        try await AgentService.answer(questionID: id(req), value: req.content.decode(AnswerRequest.self).value,
                                      user: req.requireUser(), on: req.db)
    }

    @Sendable func bindings(_ req: Request) async throws -> [BindingDTO] {
        let device = try await device(req)
        var result: [BindingDTO] = []
        for binding in try await ProjectRunnerBinding.query(on: req.db).filter(\.$deviceID == device.requireID()).all() {
            try await AgentService.authorized(binding, device: device, on: req.db)
            result.append(try BindingDTO(binding))
        }
        return result
    }

    @Sendable func queued(_ req: Request) async throws -> [AgentJobDTO] {
        let device = try await device(req)
        let bindings = try await ProjectRunnerBinding.query(on: req.db).filter(\.$deviceID == device.requireID()).all()
        var result: [AgentJobDTO] = []
        for binding in bindings {
            try await AgentService.authorized(binding, device: device, on: req.db)
            result += try await AgentJob.query(on: req.db).filter(\.$bindingID == binding.requireID()).filter(\.$state == "queued").all().map(AgentJobDTO.init)
        }
        return result
    }

    @Sendable func claim(_ req: Request) async throws -> AgentRunDTO {
        let device = try await device(req)
        return try await AgentService.claim(jobID: id(req), deviceID: device.requireID(), on: req.db)
    }

    @Sendable func command(_ req: Request) async throws -> AgentRunDTO {
        let device = try await device(req)
        return try await AgentService.command(runID: id(req), deviceID: device.requireID(),
            action: req.parameters.get("action") ?? "", body: req.content.decode(AgentRunCommand.self), on: req.db)
    }

    @Sendable func runs(_ req: Request) async throws -> [AgentRunDTO] {
        let device = try await device(req)
        var result: [AgentRunDTO] = []
        for run in try await AgentRun.query(on: req.db).filter(\.$deviceID == device.requireID()).filter(\.$endedAt == nil).all() {
            guard let binding = try await ProjectRunnerBinding.find(run.bindingID, on: req.db),
                  let job = try await AgentJob.find(run.jobID, on: req.db) else { continue }
            try await AgentService.authorized(binding, device: device, on: req.db)
            result.append(try await AgentRunDTO(run, job: job, on: req.db))
        }
        return result
    }

    @Sendable func runnerDetail(_ req: Request) async throws -> AgentDetail {
        let device = try await device(req)
        guard let job = try await AgentJob.find(id(req), on: req.db),
              let binding = try await ProjectRunnerBinding.find(job.bindingID, on: req.db) else { throw Abort(.notFound) }
        try await AgentService.authorized(binding, device: device, on: req.db)
        return try await AgentDetail(job, on: req.db)
    }
}
