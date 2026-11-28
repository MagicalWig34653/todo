import Crypto
import Fluent
import Foundation
import Vapor

// ADR 0044, contracts/deploy.yaml 1.4.0: upload to a test target. Plan -> request -> approval by a person -> run with backup;
// the way back is a plan of its own. Agents plan and ask; only a person session with the manage role starts a run.

// MARK: - DTOs (no field ever carries host, user, path of the base directory or a credential)

struct DeployPlanFileRequest: Decodable {
    var path: String
    var size: Int
    var sha256: String
    /// Base64 of the file; only needed for files the plan has to upload.
    var content: String?
}

struct DeployPlanRequest: Decodable {
    var files: [DeployPlanFileRequest]
    var ref: String?
    var note: String?
    var taskIDs: [UUID]?
}

struct DeployNoteRequest: Content { var note: String? = nil }
struct DeployApproveRequest: Content { var overrideDrift: Bool? = nil }

struct DeployPlanFileDTO: Content {
    let path: String
    let serverPath: String
    let action: String
    let reason: String
    let oldSize: Int?
    let newSize: Int?
}

struct DeployBlockerDTO: Content {
    let path: String
    let serverPath: String
    let reason: String
    let overridable: Bool
}

struct DeployPlanDTO: Content {
    let id: UUID
    let targetID: UUID
    let targetName: String
    let kind: String
    let state: String
    let ref: String?
    let note: String?
    let sourcePlanID: UUID?
    let taskIDs: [UUID]
    let createdAt: Date
    let createdBy: String?
    let requestedAt: Date?
    let requestedBy: String?
    let decidedAt: Date?
    let decidedBy: String?
    let finishedAt: Date?
    let expiresAt: Date
    let overrideDrift: Bool
    let summary: DeployPlanSummary
    let files: [DeployPlanFileDTO]
    let blockers: [DeployBlockerDTO]
    let findings: [DeployPullFinding]
    let blocked: Bool
    let overridable: Bool
    let written: [String]
    let code: String?
    let canRollback: Bool
}

struct DeployPlansResponse: Content { let items: [DeployPlanDTO] }

struct DeployPlanResult: Content {
    let ok: Bool
    let code: String?
    /// `deploy_plan_content_missing`: repo paths whose content the next call has to send.
    let missing: [String]?
    let plan: DeployPlanDTO?
    static func failure(_ code: String, missing: [String]? = nil) -> DeployPlanResult { DeployPlanResult(ok: false, code: code, missing: missing, plan: nil) }
}

// MARK: - Service

struct DeployUploadService: Sendable {
    let app: Application
    let user: User
    /// Name of the agent connection when the call comes over MCP.
    var label: String? = nil
    var db: any Database { app.db }
    private var targets: DeployService { DeployService(app: app, user: user) }

    private func blobs() throws -> DeployBlobStore { DeployBlobStore(ring: try app.requireSettingsRuntime().keyRing) }

    static func digest(_ parts: [String]) -> String {
        DeployService.sha256(Data((try? JSONEncoder().encode(parts)) ?? Data()))
    }
    static func endpointDigest(_ t: DeployTarget) -> String { digest([t.protocolName, t.host, String(t.port), t.username, t.basePath]) }
    static func targetDigest(_ t: DeployTarget) -> String {
        digest([endpointDigest(t), t.stage, t.rules, t.hostKeyType ?? "", t.hostKeyBase64 ?? "", t.tlsCertificate ?? ""])
    }

    // MARK: Reading plans

    /// The plan and its target, with the rights on the target's project checked.
    func plan(_ id: UUID, role: ProjectRole) async throws -> (plan: DeployPlan, target: DeployTarget) {
        guard let plan = try await DeployPlan.find(id, on: db) else { throw Abort(.notFound) }
        return (plan, try await targets.target(plan.targetID, role: role))
    }

    /// Runs whose server went away are closed as `deploy_interrupted`; their writes stay undoable.
    private func closeInterrupted(_ targetID: UUID, on db: any Database) async throws {
        let running = try await DeployPlan.query(on: db).filter(\.$targetID == targetID).filter(\.$state == "running").all()
        for p in running where (p.lockUntil ?? .distantPast) <= Date() {
            let id = try p.requireID(), now = Date()
            // Conditional: a run that renewed its lease or finished in the meantime stays as it is.
            try await DeployPlan.query(on: db).filter(\.$id == id).filter(\.$state == "running").filter(\.$lockUntil <= now)
                .set(\.$state, to: "failed").set(\.$code, to: "deploy_interrupted").set(\.$finishedAt, to: now).update()
            guard let after = try await DeployPlan.find(id, on: db), after.code == "deploy_interrupted" else { continue }
            try await DeployBlobStore.delete(plan: id, role: "content", on: db)
            if !after.wrote { try await DeployBlobStore.delete(plan: id, role: "backup", on: db) }
        }
    }

    /// Renews the lease while this process works on the run: only a run whose process is gone expires.
    private func keepAlive(_ planID: UUID) -> Task<Void, Never> {
        let db = db, lease = app.deployLease
        return Task {
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: UInt64(lease / 3 * 1_000_000_000)) } catch { return }
                try? await DeployPlan.query(on: db).filter(\.$id == planID).filter(\.$state == "running")
                    .set(\.$lockUntil, to: Date().addingTimeInterval(lease)).update()
            }
        }
    }

    private func latestRun(_ targetID: UUID, wroteOnly: Bool = false, on db: any Database) async throws -> DeployPlan? {
        var query = DeployPlan.query(on: db).filter(\.$targetID == targetID).filter(\.$runNumber > 0)
        if wroteOnly { query = query.filter(\.$wrote == true) }
        return try await query.sort(\.$runNumber, .descending).first()
    }

    /// What Todolino knows about the server from the latest finished run at this endpoint (before `run`, if given).
    private func knowledge(_ targetID: UUID, endpoint: String, before run: Int? = nil) async throws -> [String: DeployManifestState] {
        var query = DeployPlan.query(on: db).filter(\.$targetID == targetID).filter(\.$runNumber > 0).filter(\.$manifest != nil)
        if let run { query = query.filter(\.$runNumber < run) }
        for p in try await query.sort(\.$runNumber, .descending).limit(20).all() {
            if let text = p.manifest, let m = try? JSONDecoder().decode(DeployStoredManifest.self, from: Data(text.utf8)), m.endpoint == endpoint {
                return m.files
            }
        }
        return [:]
    }

    private static func isExpired(_ p: DeployPlan) -> Bool { ["planned", "requested"].contains(p.state) && p.expiresAt <= Date() }

    func dto(_ p: DeployPlan, target: DeployTarget, latestWriting: Int? = nil) async throws -> DeployPlanDTO {
        let data = try p.planData()
        let latest: Int
        if let latestWriting { latest = latestWriting } else { latest = try await latestRun(p.targetID, wroteOnly: true, on: db)?.runNumber ?? 0 }
        func name(_ id: UUID?, _ label: String?) async throws -> String? {
            if let label { return label }
            guard let id else { return nil }
            return try await User.find(id, on: db)?.displayName
        }
        return DeployPlanDTO(
            id: try p.requireID(), targetID: p.targetID, targetName: target.name, kind: p.kind,
            state: Self.isExpired(p) ? "expired" : p.state, ref: p.ref, note: p.note, sourcePlanID: p.sourcePlanID, taskIDs: data.taskIDs,
            createdAt: p.createdAt, createdBy: try await name(p.createdBy, p.createdLabel),
            requestedAt: p.requestedAt, requestedBy: try await name(p.requestedBy, p.requestedLabel),
            decidedAt: p.decidedAt, decidedBy: try await name(p.decidedBy, nil), finishedAt: p.finishedAt, expiresAt: p.expiresAt,
            overrideDrift: p.overrideDrift, summary: data.summary,
            files: data.items.map { DeployPlanFileDTO(path: $0.path, serverPath: $0.serverPath, action: $0.action, reason: $0.reason,
                                                      oldSize: $0.baseSize, newSize: $0.newSize) },
            blockers: data.blockers.prefix(DeployUploadLimits.maxListed).map {
                DeployBlockerDTO(path: $0.path, serverPath: $0.serverPath, reason: $0.reason, overridable: $0.overridable) },
            findings: Array(data.findings.prefix(DeployUploadLimits.maxListed)),
            blocked: !data.blockers.isEmpty, overridable: !data.blockers.isEmpty && data.blockers.allSatisfy(\.overridable),
            written: data.written, code: p.code,
            canRollback: p.wrote && ["succeeded", "failed"].contains(p.state) && p.runNumber == latest)
    }

    func get(_ id: UUID) async throws -> DeployPlanDTO {
        let found = try await plan(id, role: .read)
        try await closeInterrupted(found.plan.targetID, on: db)
        return try await dto(try await DeployPlan.find(id, on: db) ?? found.plan, target: found.target)
    }

    func list(targetID: UUID, limit: Int = 50) async throws -> [DeployPlanDTO] {
        let t = try await targets.target(targetID, role: .read)
        try await closeInterrupted(targetID, on: db)
        let plans = try await DeployPlan.query(on: db).filter(\.$targetID == targetID).sort(\.$createdAt, .descending).sort(\.$id)
            .limit(limit).all()
        let latest = try await latestRun(targetID, wroteOnly: true, on: db)?.runNumber ?? 0
        var out: [DeployPlanDTO] = []
        for p in plans { out.append(try await dto(p, target: t, latestWriting: latest)) }
        return out
    }

    // MARK: Planning

    /// Upload is only for test targets in this phase (production follows with its own mandatory approval).
    private func requireTestTarget(_ t: DeployTarget) throws {
        guard t.stage == "test" else { throw Abort(.badRequest, reason: "deploy_stage_not_supported") }
    }

    private func requireRoom(_ targetID: UUID) async throws {
        let open = try await DeployPlan.query(on: db).filter(\.$targetID == targetID).filter(\.$state ~~ ["planned", "requested"]).all()
        var waiting = 0
        for p in open {
            if Self.isExpired(p) { try await expire(try p.requireID()) } else { waiting += 1 }
        }
        guard waiting < DeployUploadLimits.maxOpenPlans else { throw Abort(.conflict, reason: "deploy_plan_limit") }
    }

    /// Conditional, so a decision taken at the same moment is never overwritten.
    private func expire(_ planID: UUID) async throws {
        try await DeployPlan.query(on: db).filter(\.$id == planID).filter(\.$state ~~ ["planned", "requested"]).filter(\.$expiresAt <= Date())
            .set(\.$state, to: "expired").update()
        guard try await DeployPlan.find(planID, on: db)?.state == "expired" else { return }
        try await DeployBlobStore.delete(plan: planID, role: "content", on: db)
    }

    private func prune(_ targetID: UUID) async throws {
        let old = try await DeployPlan.query(on: db).filter(\.$targetID == targetID).filter(\.$runNumber == 0)
            .filter(\.$state ~~ ["rejected", "expired", "failed"]).sort(\.$createdAt, .descending).offset(DeployUploadLimits.keptClosed).limit(100).all()
        for p in old {
            let id = try p.requireID()
            try await DeployBlob.query(on: db).filter(\.$planID == id).delete()
            try await p.delete(on: db)
        }
    }

    /// Only a few plans are read from servers at once; further calls are told to come back.
    private func withPlanningSlot<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        guard await DeployPlanningSlots.shared.take() else { throw Abort(.conflict, reason: "deploy_planning_busy") }
        do {
            let result = try await body()
            await DeployPlanningSlots.shared.give()
            return result
        } catch {
            await DeployPlanningSlots.shared.give()
            throw error
        }
    }

    private static func text(_ s: String?, max: Int, reason: String) throws -> String? {
        guard let s else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count <= max, !t.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\n" && $0 != "\t" }) else {
            throw Abort(.badRequest, reason: reason)
        }
        return t.isEmpty ? nil : t
    }

    private static func requireFits(_ items: [DeployPlanItem]) throws {
        let uploads = items.filter { $0.action == "upload" }
        guard items.count <= DeployUploadLimits.maxFiles, uploads.allSatisfy({ ($0.newSize ?? 0) <= DeployUploadLimits.maxFile }),
              uploads.reduce(0, { $0 + ($1.newSize ?? 0) }) <= DeployUploadLimits.maxContent,
              items.reduce(0, { $0 + ($1.baseSize ?? 0) }) <= DeployUploadLimits.maxBackup else {
            throw Abort(.badRequest, reason: "deploy_plan_too_large")
        }
    }

    /// Symlinks on the way to any file the plan would write become blockers nobody can override.
    private func addLinkBlockers(_ out: inout DeployPlanOutcome, _ conn: DeployConnection) async throws {
        guard !out.items.isEmpty else { return }
        let linked = try await app.deployTransport.linkedPaths(conn, paths: out.items.map(\.serverPath))
        for item in out.items where linked.contains(item.serverPath) {
            out.blockers.removeAll { $0.serverPath == item.serverPath }
            out.blockers.append(DeployBlocker(path: item.path, serverPath: item.serverPath, reason: "symlink"))
        }
    }

    private func store(_ t: DeployTarget, kind: String, outcome: DeployPlanOutcome, contents: [Int: Data], baseRun: Int,
                       source: UUID? = nil, ref: String? = nil, note: String? = nil, taskIDs: [UUID] = []) async throws -> DeployPlan {
        var summary = outcome.summary
        summary.blocked = outcome.blockers.count
        let data = DeployPlanData(items: outcome.items, blockers: outcome.blockers, findings: Array(outcome.findings.prefix(DeployUploadLimits.maxListed)),
                                  summary: summary, observed: outcome.observed, manifest: outcome.manifest,
                                  targetDigest: Self.targetDigest(t), endpointDigest: Self.endpointDigest(t), baseRun: baseRun, taskIDs: taskIDs)
        let p = DeployPlan()
        p.id = UUID(); p.targetID = try t.requireID(); p.kind = kind; p.state = "planned"; p.sourcePlanID = source; p.ref = ref; p.note = note
        try p.setData(data)
        p.runNumber = 0; p.wrote = false; p.overrideDrift = false
        p.createdBy = try user.requireID(); p.createdLabel = label; p.createdAt = Date()
        p.expiresAt = p.createdAt.addingTimeInterval(DeployUploadLimits.lifetime)
        let store = try blobs()
        let targetID = p.targetID
        try await db.transaction { tx in
            // Counted again under the target's lock: parallel calls read from the server for a while.
            try await lockRow(table: DeployTarget.schema, id: targetID, on: tx)
            let waiting = try await DeployPlan.query(on: tx).filter(\.$targetID == targetID).filter(\.$state ~~ ["planned", "requested"])
                .filter(\.$expiresAt > Date()).count()
            guard waiting < DeployUploadLimits.maxOpenPlans else { throw Abort(.conflict, reason: "deploy_plan_limit") }
            try await p.create(on: tx)
            for (index, bytes) in contents {
                try await store.put(bytes, plan: try p.requireID(), role: "content", item: index, serverPath: outcome.items[index].serverPath, on: tx)
            }
        }
        try await prune(targetID)
        app.logger.info("deploy plan created", metadata: ["target": .string(p.targetID.uuidString), "plan": .string(p.id!.uuidString),
                                                          "files": .stringConvertible(outcome.items.count), "blocked": .stringConvertible(outcome.blockers.count)])
        return p
    }

    func createPlan(targetID: UUID, _ request: DeployPlanRequest) async throws -> DeployPlanResult {
        let t = try await targets.target(targetID, role: .edit)
        try requireTestTarget(t)
        let repo = try DeployService.validManifest(request.files.map { DeployManifestEntry(path: $0.path, size: $0.size, sha256: $0.sha256) })
        let ref = try Self.text(request.ref, max: DeployUploadLimits.maxRef, reason: "deploy_plan_invalid")
        let note = try Self.text(request.note, max: DeployUploadLimits.maxNote, reason: "deploy_plan_invalid")
        let taskIDs = request.taskIDs ?? []
        guard taskIDs.count <= DeployUploadLimits.maxTaskIDs else { throw Abort(.badRequest, reason: "deploy_task_invalid") }
        for id in taskIDs {
            guard let task = try await TodoTask.find(id, on: db), task.projectID == t.projectID else { throw Abort(.badRequest, reason: "deploy_task_invalid") }
        }
        let rules = try DeployRulesDTO.decode(t.rules).rules()
        guard t.protocolName != DeployProtocol.sftp.rawValue || t.hostKey != nil else { return .failure("deploy_host_key_unconfirmed") }
        try await requireRoom(targetID)
        try await closeInterrupted(targetID, on: db)
        return try await withPlanningSlot { try await readAndStore(t, targetID: targetID, request: request, repo: repo, rules: rules,
                                                                     ref: ref, note: note, taskIDs: taskIDs) }
    }

    private func readAndStore(_ t: DeployTarget, targetID: UUID, request: DeployPlanRequest, repo: [String: DeployManifestEntry],
                              rules: DeployRules, ref: String?, note: String?, taskIDs: [UUID]) async throws -> DeployPlanResult {
        do {
            let conn = try targets.connection(t, address: try await targets.connectAddress(t))
            let baseRun = try await latestRun(targetID, on: db)?.runNumber ?? 0
            let selected = DeployPlanner.wanted(repo: repo, rules: rules)
            // Files that are excluded today are no longer managed, even if an earlier run wrote them.
            let last = try await knowledge(targetID, endpoint: Self.endpointDigest(t)).filter { serverPath, known in
                selected.files[serverPath] != nil || rules.repoPath(forServer: serverPath).map { !rules.isExcluded($0) && rules.serverPath(forRepo: $0) == serverPath } == true
            }
            let listed = try await app.deployTransport.list(conn)
            let relevant = Array(Set(selected.files.keys).union(last.keys))
            guard relevant.count <= DeployLimits.maxManifest else { throw Abort(.badRequest, reason: "deploy_plan_too_large") }
            let states = try await DeployPlanner.states(of: relevant, listed: listed) { try await app.deployTransport.read(conn, paths: $0) }.states
            var out = DeployPlanner.upload(wanted: selected.files, last: last, states: states)
            out.findings = selected.findings
            out.summary.skipped = selected.findings.count
            out.summary.serverOnly = listed.filter { f in
                guard DeployPath.isSafeRelative(f.path, allowEmpty: false), !DeployPlanner.isTemporary(f.path), selected.files[f.path] == nil,
                      last[f.path] == nil, let repoPath = rules.repoPath(forServer: f.path), rules.serverPath(forRepo: repoPath) == f.path else { return false }
                return !rules.isExcluded(repoPath)
            }.count
            try Self.requireFits(out.items)
            try await addLinkBlockers(&out, conn)

            // Content: only what the plan uploads, checked against the manifest.
            var sent: [String: String] = [:]
            for f in request.files { if let c = f.content { sent[f.path] = c } }
            var contents: [Int: Data] = [:]
            var missing: [String] = []
            var kept: [DeployPlanItem] = []
            for item in out.items {
                guard let encoded = sent[item.path] else { missing.append(item.path); continue }
                guard let bytes = Data(base64Encoded: encoded), bytes.count == item.newSize, DeployService.sha256(bytes) == item.newSha else {
                    throw Abort(.badRequest, reason: "deploy_plan_content_invalid")
                }
                // Content like a secret never goes up; it is named, like in a pull.
                if DeploySecretGuard.containsSecret(path: item.serverPath, data: bytes) || DeploySecretGuard.containsSecret(path: item.path, data: bytes) {
                    out.findings.append(DeployPullFinding(path: item.path, serverPath: item.serverPath, reason: "secret_content"))
                    out.blockers.removeAll { $0.serverPath == item.serverPath }
                    continue
                }
                contents[kept.count] = bytes
                kept.append(item)
            }
            guard missing.isEmpty else { return .failure("deploy_plan_content_missing", missing: missing.sorted()) }
            out.items = kept
            out.summary.upload = kept.count
            out.summary.skipped = out.findings.count
            let p = try await store(t, kind: "upload", outcome: out, contents: contents, baseRun: baseRun, ref: ref, note: note, taskIDs: taskIDs)
            return DeployPlanResult(ok: true, code: nil, missing: nil, plan: try await dto(p, target: t))
        } catch let e as DeployTransportError {
            return .failure(targets.failure(t, e.code, "plan"))
        } catch let e as any AbortError where e.reason == "deploy_target_blocked" {
            return .failure(targets.failure(t, "deploy_target_blocked", "plan"))
        }
    }

    func rollback(planID: UUID) async throws -> DeployPlanResult {
        let (source, t) = try await plan(planID, role: .edit)
        try requireTestTarget(t)
        let targetID = try t.requireID()
        try await closeInterrupted(targetID, on: db)
        guard let current = try await DeployPlan.find(planID, on: db) else { throw Abort(.notFound) }
        guard current.state != "running" else { throw Abort(.conflict, reason: "deploy_target_busy") }
        guard current.wrote, try await latestRun(targetID, wroteOnly: true, on: db)?.runNumber == current.runNumber else {
            throw Abort(.conflict, reason: "deploy_rollback_not_latest")
        }
        let sourceData = try current.planData()
        let endpoint = Self.endpointDigest(t)
        guard sourceData.endpointDigest == endpoint else { throw Abort(.conflict, reason: "deploy_plan_stale") }
        guard t.protocolName != DeployProtocol.sftp.rawValue || t.hostKey != nil else { return .failure("deploy_host_key_unconfirmed") }
        try await requireRoom(targetID)
        return try await withPlanningSlot { try await readAndStoreRollback(source, current: current, t, targetID: targetID, data: sourceData, endpoint: endpoint) }
    }

    private func readAndStoreRollback(_ source: DeployPlan, current: DeployPlan, _ t: DeployTarget, targetID: UUID, data sourceData: DeployPlanData,
                                      endpoint: String) async throws -> DeployPlanResult {
        let planID = try source.requireID()
        do {
            let conn = try targets.connection(t, address: try await targets.connectAddress(t))
            let baseRun = try await latestRun(targetID, on: db)?.runNumber ?? 0
            let known = try await knowledge(targetID, endpoint: endpoint)
            let previous = try await knowledge(targetID, endpoint: endpoint, before: current.runNumber)
            let listed = try await app.deployTransport.list(conn)
            let states = try await DeployPlanner.states(of: sourceData.items.map(\.serverPath), listed: listed) {
                try await app.deployTransport.read(conn, paths: $0) }.states
            var (out, backups) = DeployPlanner.rollback(source: sourceData.items, written: Set(sourceData.written), known: known, previous: previous, states: states)
            // The same bound as for an upload on what the run has to back up (the restored content itself comes from a backup).
            guard out.items.reduce(0, { $0 + ($1.baseSize ?? 0) }) <= DeployUploadLimits.maxBackup else { throw Abort(.badRequest, reason: "deploy_plan_too_large") }
            try await addLinkBlockers(&out, conn)
            var contents: [Int: Data] = [:]
            let store = try blobs()
            for (index, item) in out.items.enumerated() where item.action == "upload" {
                let from = backups[index]
                guard let bytes = try await store.get(plan: planID, role: "backup", item: from, serverPath: item.serverPath, on: db),
                      DeployService.sha256(bytes) == item.newSha else { throw Abort(.conflict, reason: "deploy_backup_missing") }
                contents[index] = bytes
            }
            // One planned way back per run: a newer look at the server replaces the earlier one (a requested one stays).
            for old in try await DeployPlan.query(on: db).filter(\.$sourcePlanID == planID).filter(\.$state == "planned").all() {
                let id = try old.requireID()
                try await DeployPlan.query(on: db).filter(\.$id == id).filter(\.$state == "planned").set(\.$state, to: "rejected").update()
                if try await DeployPlan.find(id, on: db)?.state == "rejected" { try await DeployBlobStore.delete(plan: id, role: "content", on: db) }
            }
            let p = try await self.store(t, kind: "rollback", outcome: out, contents: contents, baseRun: baseRun, source: planID, ref: source.ref)
            return DeployPlanResult(ok: true, code: nil, missing: nil, plan: try await dto(p, target: t))
        } catch let e as DeployTransportError {
            return .failure(targets.failure(t, e.code, "rollback"))
        } catch let e as any AbortError where e.reason == "deploy_target_blocked" {
            return .failure(targets.failure(t, "deploy_target_blocked", "rollback"))
        }
    }

    // MARK: Request, reject

    /// Loads the plan inside the transaction and holds the target's lock, so two decisions cannot cross.
    private func locked<T: Sendable>(_ planID: UUID, targetID: UUID, _ body: @escaping @Sendable (DeployPlan, any Database) async throws -> T) async throws -> T {
        try await db.transaction { tx in
            try await lockRow(table: DeployTarget.schema, id: targetID, on: tx)
            guard let p = try await DeployPlan.find(planID, on: tx) else { throw Abort(.notFound) }
            return try await body(p, tx)
        }
    }

    private func requireNotExpired(_ p: DeployPlan) async throws {
        guard Self.isExpired(p) || p.state == "expired" else { return }
        if p.state != "expired" { try await expire(try p.requireID()) }
        throw Abort(.gone, reason: "deploy_plan_expired")
    }

    func request(planID: UUID, note: String?) async throws -> DeployPlanDTO {
        let (found, t) = try await plan(planID, role: .edit)
        let note = try Self.text(note, max: DeployUploadLimits.maxNote, reason: "deploy_plan_invalid")
        try await requireNotExpired(found)
        let userID = try user.requireID(), label = label
        let p = try await locked(planID, targetID: found.targetID) { p, tx in
            switch p.state {
            case "requested": return p
            case "planned":
                p.state = "requested"; p.requestedBy = userID; p.requestedLabel = label; p.requestedAt = Date()
                if let note { p.note = note }
                try await p.save(on: tx)
                return p
            default: throw Abort(.conflict, reason: "deploy_plan_decided")
            }
        }
        app.logger.info("deploy requested", metadata: ["plan": .string(planID.uuidString)])
        return try await dto(p, target: t)
    }

    func reject(planID: UUID) async throws -> DeployPlanDTO {
        let (found, t) = try await plan(planID, role: .edit)
        let userID = try user.requireID()
        let p = try await locked(planID, targetID: found.targetID) { p, tx in
            switch p.state {
            case "rejected": return p
            case "planned", "requested":
                p.state = "rejected"; p.decidedBy = userID; p.decidedAt = Date()
                try await p.save(on: tx)
                try await DeployBlobStore.delete(plan: planID, role: "content", on: tx)
                return p
            default: throw Abort(.conflict, reason: "deploy_plan_decided")
            }
        }
        return try await dto(p, target: t)
    }

    // MARK: Run

    /// The approval of a person: checks that the plan still describes this target, takes the target's lock and runs.
    func approve(planID: UUID, overrideDrift: Bool) async throws -> DeployPlanDTO {
        let (found, t) = try await plan(planID, role: .manage)
        try await requireNotExpired(found)
        let targetID = try t.requireID(), userID = try user.requireID()
        try await closeInterrupted(targetID, on: db)
        let lease = app.deployLease
        let claimed: DeployPlan = try await locked(planID, targetID: targetID) { p, tx in
            switch p.state {
            case "requested": break
            case "planned": throw Abort(.conflict, reason: "deploy_plan_not_requested")
            default: throw Abort(.conflict, reason: "deploy_plan_decided")
            }
            guard !Self.isExpired(p) else { throw Abort(.gone, reason: "deploy_plan_expired") }
            let data = try p.planData()
            // The target as it is now, read under the lock.
            guard let target = try await DeployTarget.find(targetID, on: tx), target.stage == "test",
                  Self.targetDigest(target) == data.targetDigest else { throw Abort(.conflict, reason: "deploy_plan_stale") }
            guard data.blockers.isEmpty || (overrideDrift && data.blockers.allSatisfy(\.overridable)) else {
                throw Abort(.conflict, reason: "deploy_plan_blocked")
            }
            let others = try await DeployPlan.query(on: tx).filter(\.$targetID == targetID).filter(\.$state == "running").count()
            guard others == 0 else { throw Abort(.conflict, reason: "deploy_target_busy") }
            // Another run since the plan was made: what the plan knows about the server is out of date.
            let latest = try await DeployPlan.query(on: tx).filter(\.$targetID == targetID).filter(\.$runNumber > 0)
                .sort(\.$runNumber, .descending).first()?.runNumber ?? 0
            guard latest == data.baseRun else { throw Abort(.conflict, reason: "deploy_plan_stale") }
            p.state = "running"; p.decidedBy = userID; p.decidedAt = Date(); p.overrideDrift = overrideDrift && !data.blockers.isEmpty
            p.lockUntil = Date().addingTimeInterval(lease)
            try await p.save(on: tx)
            return p
        }
        app.logger.info("deploy run started", metadata: ["target": .string(targetID.uuidString), "plan": .string(planID.uuidString),
                                                         "override": .stringConvertible(claimed.overrideDrift)])
        try await run(claimed, target: targetID)
        guard let done = try await DeployPlan.find(planID, on: db), let target = try await DeployTarget.find(targetID, on: db) else { throw Abort(.notFound) }
        return try await dto(done, target: target)
    }

    /// Re-reads the server, backs up what will change, writes, verifies. Every outcome is recorded on the plan.
    private func run(_ p: DeployPlan, target targetID: UUID) async throws {
        let planID = try p.requireID()
        var data = try p.planData()
        var applied: [DeployPlanItem] = []
        var code: String?
        var connection: DeployConnection?
        let alive = keepAlive(planID)
        defer { alive.cancel() }
        do {
            guard let t = try await DeployTarget.find(targetID, on: db), Self.targetDigest(t) == data.targetDigest else {
                throw DeployTransportError(code: "deploy_plan_stale")
            }
            let conn = try targets.connection(t, address: try await targets.connectAddress(t))
            connection = conn
            // 1. The server must still be what the person saw in the plan.
            let listed = try await app.deployTransport.list(conn)
            let now = try await DeployPlanner.states(of: Array(data.observed.keys), listed: listed) { try await app.deployTransport.read(conn, paths: $0) }
            guard data.observed.allSatisfy({ path, sha in (now.states[path] ?? .missing).sha256 == sha }) else {
                throw DeployTransportError(code: "deploy_plan_stale")
            }
            if !data.items.isEmpty, try await !app.deployTransport.linkedPaths(conn, paths: data.items.map(\.serverPath)).isEmpty {
                throw DeployTransportError(code: "deploy_symlink_in_path")
            }
            // 2. Content to upload, then the backup of everything that changes. Nothing is written before both are complete.
            let store = try blobs()
            var uploads: [DeployUploadFile] = []
            for (index, item) in data.items.enumerated() {
                if item.action == "upload" {
                    guard let bytes = try await store.get(plan: planID, role: "content", item: index, serverPath: item.serverPath, on: db),
                          DeployService.sha256(bytes) == item.newSha else { throw DeployTransportError(code: "deploy_content_unreadable") }
                    uploads.append(DeployUploadFile(path: item.serverPath, data: bytes))
                }
                if let base = item.baseSha {
                    guard let old = now.contents[item.serverPath], DeployService.sha256(old) == base else { throw DeployTransportError(code: "deploy_plan_stale") }
                    try await store.put(old, plan: planID, role: "backup", item: index, serverPath: item.serverPath, on: db)
                }
            }
            // 3. From here on the run counts as writing (also if the server goes down).
            // Only while the run still holds its target: one closed as interrupted writes nothing. The plan row stays locked until
            // the commit, so closing it cannot slip in between the check and the record that this run writes.
            let writes = !data.items.isEmpty, baseRun = data.baseRun, lease = app.deployLease
            let number = try await db.transaction { tx -> Int in
                try await lockRow(table: DeployTarget.schema, id: targetID, on: tx)
                try await lockRow(table: DeployPlan.schema, id: planID, on: tx)
                let held = try await DeployPlan.query(on: tx).filter(\.$id == planID).filter(\.$state == "running").count()
                let latest = try await DeployPlan.query(on: tx).filter(\.$targetID == targetID).filter(\.$runNumber > 0)
                    .sort(\.$runNumber, .descending).first()?.runNumber ?? 0
                guard held == 1, latest == baseRun else { throw DeployRunSuperseded() }
                try await DeployPlan.query(on: tx).filter(\.$id == planID).set(\.$runNumber, to: latest + 1).set(\.$wrote, to: writes)
                    .set(\.$lockUntil, to: Date().addingTimeInterval(lease)).update()
                return latest + 1
            }
            // Taken over only after the commit: a run that never got this far is not recorded as writing.
            p.runNumber = number
            p.wrote = writes
            var failure: DeployTransportError?
            do {
                if !uploads.isEmpty { try await app.deployTransport.upload(conn, files: uploads) }
                let deletes = data.items.filter { $0.action == "delete" }.map(\.serverPath)
                if !deletes.isEmpty { try await app.deployTransport.delete(conn, paths: deletes) }
            } catch let e as DeployTransportError { failure = e }
            if failure != nil { try? await removeLeftovers(of: uploads.map(\.path), conn) }
            // 4. What is really on the server now.
            applied = try await verify(data.items, conn)
            if let failure { throw failure }
            guard applied.count == data.items.count else { throw DeployTransportError(code: "deploy_verify_failed") }
        } catch is DeployRunSuperseded {
            code = "deploy_interrupted"
        } catch let e as DeployTransportError {
            code = e.code
        } catch let e as any AbortError where e.reason == "deploy_target_blocked" || e.reason == "encryption_key_missing" {
            code = e.reason
        } catch {
            app.logger.error("deploy run failed (\(type(of: error)))", metadata: ["plan": .string(planID.uuidString)])
            code = "deploy_failed"
        }
        if code != nil, p.wrote, applied.isEmpty, let connection { applied = (try? await verify(data.items, connection)) ?? [] }

        alive.cancel()
        await alive.value
        // Closed as interrupted before it wrote anything: that record stays, whatever failed here afterwards.
        if !p.wrote, try await DeployPlan.query(on: db).filter(\.$id == planID).filter(\.$state == "running").count() == 0 {
            try await DeployBlobStore.delete(plan: planID, role: "content", on: db)
            try await DeployBlobStore.delete(plan: planID, role: "backup", on: db)
            return
        }
        // 5. Record: state, what was written, and what Todolino now knows about the server.
        data.written = applied.map(\.serverPath).sorted()
        var files = data.manifest
        for item in applied { files[item.serverPath] = item.after }
        try p.setData(data)
        p.state = code == nil ? "succeeded" : "failed"; p.code = code; p.finishedAt = Date(); p.lockUntil = nil
        if p.runNumber > 0 {
            p.manifest = String(decoding: try JSONEncoder().encode(DeployStoredManifest(endpoint: data.endpointDigest, files: files)), as: UTF8.self)
        }
        try await p.save(on: db)
        try await DeployBlobStore.delete(plan: planID, role: "content", on: db)
        // A run that never started to write keeps no backup.
        if !p.wrote { try await DeployBlobStore.delete(plan: planID, role: "backup", on: db) }
        try await pruneBackups(targetID)
        app.logger.info("deploy run finished", metadata: ["plan": .string(planID.uuidString), "state": .string(p.state),
                                                          "code": .string(code ?? "-"), "written": .stringConvertible(applied.count)])
    }

    /// Half files of this run that a broken upload left under their temporary names (in the web root they could be fetched).
    private func removeLeftovers(of paths: [String], _ conn: DeployConnection) async throws {
        let left = try await app.deployTransport.list(conn).map(\.path).filter { file in
            DeployPlanner.isTemporary(file) && paths.contains { DeployPlanner.isLeftover(file, of: $0) }
        }
        if !left.isEmpty { try await app.deployTransport.delete(conn, paths: left) }
    }

    /// The items whose file on the server is now what the plan wanted.
    private func verify(_ items: [DeployPlanItem], _ conn: DeployConnection) async throws -> [DeployPlanItem] {
        guard !items.isEmpty else { return [] }
        let listed = try await app.deployTransport.list(conn)
        let states = try await DeployPlanner.states(of: items.map(\.serverPath), listed: listed) { try await app.deployTransport.read(conn, paths: $0) }.states
        return items.filter { (states[$0.serverPath] ?? .missing).sha256 == ($0.newSha ?? "") }
    }

    private func pruneBackups(_ targetID: UUID) async throws {
        let old = try await DeployPlan.query(on: db).filter(\.$targetID == targetID).filter(\.$wrote == true)
            .sort(\.$runNumber, .descending).offset(DeployUploadLimits.keptBackups).limit(20).all()
        for p in old { try await DeployBlobStore.delete(plan: try p.requireID(), role: "backup", on: db) }
    }
}

/// The run lost its target (closed as interrupted) before it wrote anything.
private struct DeployRunSuperseded: Error {}

actor DeployPlanningSlots {
    static let shared = DeployPlanningSlots()
    private var used = 0
    func take() -> Bool {
        guard used < DeployUploadLimits.concurrentPlanning else { return false }
        used += 1
        return true
    }
    func give() { used -= 1 }
}

extension Application {
    private struct DeployLeaseKey: StorageKey { typealias Value = TimeInterval }
    /// How long a run holds its target without a sign of life (tests shorten it).
    var deployLease: TimeInterval {
        get { storage[DeployLeaseKey.self] ?? DeployUploadLimits.lease }
        set { storage[DeployLeaseKey.self] = newValue }
    }
}

// MARK: - REST (person sessions only: `requireUser` rejects OAuth access tokens)

struct DeployUploadController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let t = routes.grouped("v1", "deploy-targets", ":targetID", "plans")
        // Manifest plus the content of the files to upload (base64 of at most DeployUploadLimits.maxContent).
        t.on(.POST, body: .collect(maxSize: "32mb"), use: create)
        t.get(use: list)
        let p = routes.grouped("v1", "deploy-plans", ":planID")
        p.get(use: get)
        p.post("request", use: request)
        p.post("approve", use: approve)
        p.post("reject", use: reject)
        p.post("rollback", use: rollback)
    }

    private func service(_ req: Request) async throws -> DeployUploadService { DeployUploadService(app: req.application, user: try await req.requireUser()) }
    private func id(_ req: Request, _ name: String) throws -> UUID {
        guard let id = req.parameters.get(name, as: UUID.self) else { throw Abort(.notFound) }
        return id
    }

    @Sendable func create(_ req: Request) async throws -> DeployPlanResult {
        // The session is checked before the large body is decoded.
        let s = try await service(req)
        let body: DeployPlanRequest
        do { body = try req.content.decode(DeployPlanRequest.self) } catch { throw Abort(.badRequest, reason: "deploy_manifest_invalid") }
        return try await s.createPlan(targetID: try id(req, "targetID"), body)
    }
    @Sendable func list(_ req: Request) async throws -> DeployPlansResponse {
        DeployPlansResponse(items: try await service(req).list(targetID: try id(req, "targetID")))
    }
    @Sendable func get(_ req: Request) async throws -> DeployPlanDTO { try await service(req).get(try id(req, "planID")) }
    @Sendable func request(_ req: Request) async throws -> DeployPlanDTO {
        let s = try await service(req)
        return try await s.request(planID: try id(req, "planID"), note: try req.content.decode(DeployNoteRequest.self).note)
    }
    @Sendable func approve(_ req: Request) async throws -> DeployPlanDTO {
        let s = try await service(req)
        return try await s.approve(planID: try id(req, "planID"), overrideDrift: try req.content.decode(DeployApproveRequest.self).overrideDrift ?? false)
    }
    @Sendable func reject(_ req: Request) async throws -> DeployPlanDTO { try await service(req).reject(planID: try id(req, "planID")) }
    @Sendable func rollback(_ req: Request) async throws -> DeployPlanResult { try await service(req).rollback(planID: try id(req, "planID")) }
}
