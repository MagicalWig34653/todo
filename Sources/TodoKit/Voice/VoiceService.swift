import Crypto
import Fluent
import Vapor

struct VoiceAudioInfo: Content, Equatable {
    let mediaType: String
    let size: Int
    let checksum: String
}

struct VoiceJobDTO: Content {
    let id: UUID
    let state: String
    let generation: Int
    let messageID: UUID
    let attachmentID: UUID
    let requiredCapability: String
    let leaseUntil: Date?
    let expiresAt: Date
    let createdAt: Date
    let errorCode: String?
    /// Only on claim: what the runner will download (verify size and SHA-256 after the download).
    var audio: VoiceAudioInfo?
    init(_ j: VoiceJob, audio: VoiceAudioInfo? = nil) throws {
        id = try j.requireID(); state = j.state; generation = j.generation; messageID = j.messageID
        attachmentID = j.attachmentID; requiredCapability = j.requiredCapability; leaseUntil = j.leaseUntil
        expiresAt = j.expiresAt; createdAt = j.createdAt; errorCode = j.errorCode; self.audio = audio
    }
}

struct VoiceHeartbeatRequest: Content { let capabilities: [String] }
struct VoiceHeartbeatResponse: Content {
    /// What the server will assign work for: reported capabilities minus those the owner switched off.
    let capabilities: [String]
    let disabledCapabilities: [String]
    let serverTime: Date
}
struct VoiceGenerationBody: Content { let generation: Int }
struct VoiceResultBody: Content {
    let generation: Int
    let transcript: String?
    let replyText: String?
    let errorCode: String?
}
struct SetCapabilitiesRequest: Content { let disabled: [String] }

/// Fachregeln der Sprachaufträge. Jede Abfrage filtert auf das Konto; ein fremdes Gerät oder Konto sieht 404.
enum VoiceService {
    static let lease: TimeInterval = 60
    static let ttl: TimeInterval = 600
    /// A device counts as reachable when its last heartbeat is younger than this (runners beat every 30 s).
    static let freshness: TimeInterval = 90
    static let maxOpenJobs = 5
    static let maxPerMinute = 10
    static let maxPerDay = 200
    static let maxText = 4000

    // User-facing texts of the system messages (German, ADR 0030).
    static let textOnlyMessage = "Brain gerade nur per Text erreichbar."
    static let expiredMessage = "Die Sprachnachricht ist abgelaufen."
    static let failedMessage = "Die Sprachnachricht konnte nicht verarbeitet werden."

    // MARK: Reachability and limits

    static func reachableDevice(owner: UUID, db: any Database, now: Date = Date()) async throws -> Bool {
        let devices = try await RunnerDevice.query(on: db).filter(\.$ownerID == owner).filter(\.$revokedAt == nil)
            .filter(\.$lastSeenAt >= now.addingTimeInterval(-freshness)).all()
        return devices.contains { $0.tokenHash != nil && $0.effectiveCapabilities.contains(VoiceCapabilities.voice) }
    }

    /// Per account: 10 recordings per minute, 200 per day (all `voice_in` messages count, also those nobody could answer),
    /// at most 5 open jobs.
    static func checkLimits(owner: UUID, db: any Database, now: Date = Date()) async throws {
        let minute = try await ChannelMessage.query(on: db).filter(\.$ownerID == owner).filter(\.$kind == "voice_in")
            .filter(\.$createdAt > now.addingTimeInterval(-60)).count()
        let day = try await ChannelMessage.query(on: db).filter(\.$ownerID == owner).filter(\.$kind == "voice_in")
            .filter(\.$createdAt > now.addingTimeInterval(-86400)).count()
        if minute >= maxPerMinute || day >= maxPerDay { throw Abort(.tooManyRequests, reason: "voice_rate_limited") }
        let open = try await VoiceJob.query(on: db).filter(\.$ownerID == owner).filter(\.$state ~~ ["queued", "claimed"]).count()
        if open >= maxOpenJobs { throw Abort(.tooManyRequests, reason: "too_many_open_voice_jobs") }
    }

    /// Called inside the transaction that stores the `voice_in` message.
    static func enqueue(message: ChannelMessage, user: User, db: any Database) async throws {
        let owner = try user.requireID()
        guard let attachmentID = message.attachmentID else { return }
        guard try await reachableDevice(owner: owner, db: db) else {
            try await ChannelService(user: user, db: db).appendBrainMessage(kind: "status", text: textOnlyMessage, notBefore: message.createdAt)
            return
        }
        let job = VoiceJob()
        job.ownerID = owner; job.messageID = try message.requireID(); job.attachmentID = attachmentID
        job.requiredCapability = VoiceCapabilities.voice; job.state = "queued"; job.generation = 0
        job.createdAt = message.createdAt; job.expiresAt = message.createdAt.addingTimeInterval(ttl)
        try await job.save(on: db)
    }

    // MARK: Expiry

    /// Marks jobs older than 10 minutes expired, deletes their recording and tells the person. Idempotent and safe to run
    /// on every replica: each job is re-read under its row lock. `owner` nil sweeps all accounts (worker).
    @discardableResult
    static func expireDue(owner: UUID?, db: any Database, now: Date = Date()) async throws -> Int {
        var query = VoiceJob.query(on: db).filter(\.$state ~~ ["queued", "claimed"]).filter(\.$expiresAt <= now)
        if let owner { query = query.filter(\.$ownerID == owner) }
        var count = 0
        for id in try await query.field(\.$id).all().map({ try $0.requireID() }) {
            let didExpire = try await db.transaction { tx -> Bool in
                try await lockRow(table: VoiceJob.schema, id: id, on: tx)
                guard let job = try await VoiceJob.find(id, on: tx), !job.isEnded, job.expiresAt <= now else { return false }
                try await end(job, state: "expired", errorCode: nil, statusText: expiredMessage, db: tx)
                return true
            }
            if didExpire { count += 1 }
        }
        return count
    }

    /// Ends a job without an answer: state, recording deleted, one status message. Caller holds the job row lock.
    static func end(_ job: VoiceJob, state: String, errorCode: String?, statusText: String, db: any Database) async throws {
        job.state = state; job.errorCode = errorCode; job.leaseUntil = nil; job.endedAt = Date()
        try await job.save(on: db)
        try await deleteAttachment(job.attachmentID, db: db)
        if let reply = job.replyAttachmentID { try await deleteAttachment(reply, db: db) }
        guard let user = try await User.find(job.ownerID, on: db) else { return }
        let message = try await ChannelMessage.find(job.messageID, on: db)
        try await ChannelService(user: user, db: db).appendBrainMessage(kind: "status", text: statusText, notBefore: message?.createdAt)
    }

    /// Removes a recording at once when it lives in the database. An S3 object needs the storage settings that this layer
    /// does not have; its row is marked `deleted` so that no download is possible and `cleanup-uploads` removes the object.
    static func deleteAttachment(_ id: UUID, db: any Database) async throws {
        guard let a = try await Attachment.find(id, on: db) else { return }
        if a.storage == AttachmentStorageKind.database.rawValue {
            try await DatabaseStore().delete(key: a.objectKey, db: db)
            try await a.delete(on: db)
        } else {
            a.status = "deleted"
            try await a.update(on: db)
        }
    }

    // MARK: Capability

    static func heartbeat(device: RunnerDevice, capabilities: [String], db: any Database) async throws -> VoiceHeartbeatResponse {
        let list = try VoiceCapabilities.validated(capabilities)
        let id = try device.requireID()
        return try await db.transaction { tx in
            try await lockRow(table: RunnerDevice.schema, id: id, on: tx)
            guard let current = try await RunnerDevice.find(id, on: tx), current.revokedAt == nil else { throw Abort(.unauthorized) }
            current.capabilitiesRaw = VoiceCapabilities.join(list)
            current.lastSeenAt = Date()
            try await current.save(on: tx)
            return VoiceHeartbeatResponse(capabilities: current.effectiveCapabilities, disabledCapabilities: current.disabledCapabilityList,
                                          serverTime: Date())
        }
    }

    /// Owner switch (PWA). Only own, not revoked devices.
    static func setDisabled(deviceID: UUID, owner: User, disabled: [String], db: any Database) async throws -> RunnerDeviceCapabilities {
        let list = try VoiceCapabilities.validated(disabled)
        return try await db.transaction { tx in
            try await lockRow(table: RunnerDevice.schema, id: deviceID, on: tx)
            guard let device = try await RunnerDevice.find(deviceID, on: tx), device.ownerID == owner.id, device.revokedAt == nil else {
                throw Abort(.notFound)
            }
            device.disabledCapabilitiesRaw = VoiceCapabilities.join(list)
            try await device.save(on: tx)
            return RunnerDeviceCapabilities(capabilities: device.reportedCapabilities, disabledCapabilities: device.disabledCapabilityList,
                                            lastSeenAt: device.lastSeenAt)
        }
    }

    // MARK: Claim

    /// `jobID` nil: the oldest claimable job of the device's account, nil when there is none.
    /// A job is claimable when it is queued or its lease ran out (take-over: generation + 1). One live job per account.
    static func claim(device: RunnerDevice, jobID: UUID?, db: any Database) async throws -> VoiceJobDTO? {
        let owner = device.ownerID
        try await expireDue(owner: owner, db: db)
        return try await db.transaction { tx -> VoiceJobDTO? in
            // The account row serializes every claim of the account (two Macs, same queue).
            try await lockRow(table: User.schema, id: owner, on: tx)
            let now = Date()
            guard let current = try await RunnerDevice.find(device.requireID(), on: tx), current.revokedAt == nil,
                  let user = try await User.find(owner, on: tx), !user.isLocked else { throw Abort(.unauthorized) }
            guard current.effectiveCapabilities.contains(VoiceCapabilities.voice) else {
                if jobID == nil { return nil }
                throw Abort(.forbidden, reason: "capability_missing")
            }
            current.lastSeenAt = now
            try await current.save(on: tx)

            let live = try await VoiceJob.query(on: tx).filter(\.$ownerID == owner).filter(\.$state == "claimed")
                .filter(\.$leaseUntil > now).all()
            func claimable(_ j: VoiceJob) -> Bool {
                j.expiresAt > now && (j.state == "queued" || (j.state == "claimed" && (j.leaseUntil ?? .distantPast) <= now))
            }
            let candidate: VoiceJob
            if let jobID {
                guard let found = try await VoiceJob.find(jobID, on: tx), found.ownerID == owner else { throw Abort(.notFound) }
                if found.isEnded { throw Abort(.gone, reason: "job_ended") }
                guard claimable(found) else { throw Abort(.conflict, reason: "job_not_queued") }
                guard live.isEmpty else { throw Abort(.conflict, reason: "voice_job_running") }
                candidate = found
            } else {
                guard live.isEmpty else { return nil }
                let open = try await VoiceJob.query(on: tx).filter(\.$ownerID == owner).filter(\.$state ~~ ["queued", "claimed"])
                    .sort(\.$createdAt).sort(\.$id).all()
                guard let next = open.first(where: claimable) else { return nil }
                candidate = next
            }
            try await lockRow(table: VoiceJob.schema, id: candidate.requireID(), on: tx)
            guard let job = try await VoiceJob.find(candidate.requireID(), on: tx), claimable(job) else { throw Abort(.conflict, reason: "job_not_queued") }
            guard let a = try await Attachment.find(job.attachmentID, on: tx), a.status == "complete", a.ownerID == owner else {
                try await end(job, state: "failed", errorCode: "audio_missing", statusText: failedMessage, db: tx)
                throw Abort(.gone, reason: "job_ended")
            }
            job.state = "claimed"; job.deviceID = try current.requireID(); job.generation += 1
            job.leaseUntil = now.addingTimeInterval(lease)
            try await job.save(on: tx)
            return try VoiceJobDTO(job, audio: VoiceAudioInfo(mediaType: a.mediaType, size: a.size, checksum: a.checksum))
        }
    }

    // MARK: Holder checks

    enum Access { case read, write }

    /// Loads a job for its holder. Order matters: another account sees 404; an ended job is 410 `job_ended`; a stale
    /// generation is 409 (also for a former holder); any other device is 404; a lapsed lease is 410 `lease_lost`.
    /// The caller runs this inside a transaction and holds the job row lock.
    static func holderJob(id: UUID, device: RunnerDevice, generation: Int, db: any Database, now: Date = Date()) async throws -> VoiceJob {
        guard let job = try await VoiceJob.find(id, on: db), job.ownerID == device.ownerID else { throw Abort(.notFound) }
        if job.isEnded { throw Abort(.gone, reason: "job_ended") }
        guard job.generation == generation else { throw Abort(.conflict, reason: "stale_generation") }
        guard job.deviceID == device.id else { throw Abort(.notFound) }
        guard let lease = job.leaseUntil, lease > now, job.expiresAt > now else { throw Abort(.gone, reason: "lease_lost") }
        return job
    }

    static func jobHeartbeat(device: RunnerDevice, id: UUID, generation: Int, db: any Database) async throws -> VoiceJobDTO {
        try await expireDue(owner: device.ownerID, db: db)
        return try await db.transaction { tx in
            try await lockRow(table: VoiceJob.schema, id: id, on: tx)
            let job = try await holderJob(id: id, device: device, generation: generation, db: tx)
            job.leaseUntil = Date().addingTimeInterval(lease)
            try await job.save(on: tx)
            return try VoiceJobDTO(job)
        }
    }

    /// Audio bytes for the claiming device, checked against size, type and SHA-256 before they leave the server.
    static func audio(device: RunnerDevice, id: UUID, generation: Int, service: AttachmentService, db: any Database) async throws -> (Attachment, Data) {
        try await expireDue(owner: device.ownerID, db: db)
        let job = try await db.transaction { tx -> VoiceJob in
            try await holderJob(id: id, device: device, generation: generation, db: tx)
        }
        guard let a = try await Attachment.find(job.attachmentID, on: db), a.status == "complete", a.ownerID == job.ownerID else {
            throw Abort(.notFound)
        }
        let data = try await service.store(for: a).get(key: a.objectKey, db: db)
        try service.validate(data, for: a)
        return (a, data)
    }

    /// Stores reply audio from the runner as a task-less voice attachment. A repeated upload replaces the earlier one.
    static func storeReply(device: RunnerDevice, id: UUID, generation: Int, data: Data, service: AttachmentService, db: any Database) async throws -> UUID {
        try await expireDue(owner: device.ownerID, db: db)
        guard !data.isEmpty, data.count <= min(VoiceLimits.maxBytes, service.maxBytes) else { throw Abort(.payloadTooLarge, reason: "voice_too_large") }
        guard let media = AttachmentService.mediaType(data), VoiceLimits.mediaTypes.contains(media) else {
            throw Abort(.unsupportedMediaType, reason: "unsupported_audio_type")
        }
        let a = Attachment()
        a.id = UUID(); a.storage = service.writeKind.rawValue; a.taskID = Attachment.noTask; a.ownerID = device.ownerID
        a.filename = media == "audio/wav" ? "reply.wav" : "reply.m4a"; a.role = "voice"; a.mediaType = media
        a.size = data.count; a.checksum = AttachmentChecksum.sha256(data); a.status = "complete"
        a.objectKey = "attachments/\(try a.requireID().uuidString.lowercased())"
        try service.validate(data, for: a)  // container duration <= 120 s, magic bytes, checksum
        _ = try service.store(service.writeKind)
        return try await db.transaction { tx in
            try await lockRow(table: VoiceJob.schema, id: id, on: tx)
            let job = try await holderJob(id: id, device: device, generation: generation, db: tx)
            // The row first: blob rows reference it. Both commit or roll back together.
            try await a.create(on: tx)
            try await service.store(service.writeKind).put(key: a.objectKey, data: data, db: tx)
            if let old = job.replyAttachmentID { try await deleteAttachment(old, db: tx) }
            job.replyAttachmentID = try a.requireID()
            try await job.save(on: tx)
            return try a.requireID()
        }
    }

    // MARK: Result

    static func digest(_ body: VoiceResultBody, reply: UUID?) -> String {
        let parts = [body.transcript ?? "", body.replyText ?? "", body.errorCode ?? "", reply?.uuidString ?? ""]
        return AttachmentChecksum.sha256(Data(parts.joined(separator: "\u{1F}").utf8))
    }

    static func result(device: RunnerDevice, id: UUID, body: VoiceResultBody, db: any Database) async throws -> VoiceJobDTO {
        func clean(_ value: String?) throws -> String? {
            guard let value else { return nil }
            let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count <= maxText else { throw Abort(.badRequest, reason: "invalid_text") }
            return t.isEmpty ? nil : t
        }
        let transcript = try clean(body.transcript), reply = try clean(body.replyText)
        if let code = body.errorCode {
            guard (1...40).contains(code.count), code.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" })
            else { throw Abort(.badRequest, reason: "invalid_error_code") }
        }
        try await expireDue(owner: device.ownerID, db: db)
        return try await db.transaction { tx in
            try await lockRow(table: VoiceJob.schema, id: id, on: tx)
            if let job = try await VoiceJob.find(id, on: tx), job.ownerID == device.ownerID, job.state == "done" || job.state == "failed",
               job.deviceID == device.id, job.generation == body.generation,
               job.resultHash == digest(VoiceResultBody(generation: body.generation, transcript: transcript, replyText: reply, errorCode: body.errorCode),
                                        reply: job.replyAttachmentID) {
                return try VoiceJobDTO(job)  // the runner repeats a result it did not see arrive
            }
            let job = try await holderJob(id: id, device: device, generation: body.generation, db: tx)
            guard let user = try await User.find(job.ownerID, on: tx), !user.isLocked else { throw Abort(.unauthorized) }
            let channel = ChannelService(user: user, db: tx)
            let original = try await ChannelMessage.find(job.messageID, on: tx)
            let hash = digest(VoiceResultBody(generation: body.generation, transcript: transcript, replyText: reply, errorCode: body.errorCode),
                              reply: job.replyAttachmentID)
            if let code = body.errorCode {
                try await end(job, state: "failed", errorCode: code, statusText: failedMessage, db: tx)
                job.resultHash = hash
                try await job.save(on: tx)
                return try VoiceJobDTO(job)
            }
            guard reply != nil || job.replyAttachmentID != nil else { throw Abort(.badRequest, reason: "result_required") }
            if let original, let transcript { original.text = transcript; try await original.save(on: tx) }
            let hasAudio = job.replyAttachmentID != nil
            try await channel.appendBrainMessage(kind: hasAudio ? "voice_out" : "text", text: reply, attachmentID: job.replyAttachmentID,
                                                 notBefore: original?.createdAt)
            job.state = "done"; job.leaseUntil = nil; job.endedAt = Date(); job.resultHash = hash
            try await job.save(on: tx)
            return try VoiceJobDTO(job)
        }
    }

    static func queued(device: RunnerDevice, db: any Database) async throws -> [VoiceJobDTO] {
        try await expireDue(owner: device.ownerID, db: db)
        guard device.effectiveCapabilities.contains(VoiceCapabilities.voice) else { return [] }
        return try await VoiceJob.query(on: db).filter(\.$ownerID == device.ownerID).filter(\.$state == "queued")
            .sort(\.$createdAt).sort(\.$id).all().map { try VoiceJobDTO($0) }
    }
}

struct RunnerDeviceCapabilities: Content {
    let capabilities: [String]
    let disabledCapabilities: [String]
    let lastSeenAt: Date?
}
