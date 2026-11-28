import Crypto
import Fluent
import Foundation
import SQLKit
import Vapor

// ADR 0044, contracts/deploy.yaml 1.3.0: upload to a test target (phase 3). Tables, limits and the sealed file contents.

enum DeployUploadLimits {
    /// Files one plan may write or delete.
    static let maxFiles = 500
    static let maxFile = 8 * 1024 * 1024
    /// Uploaded content of one plan.
    static let maxContent = 16 * 1024 * 1024
    /// Server files one run may have to back up.
    static let maxBackup = 64 * 1024 * 1024
    /// Plans of a target that still wait (planned or requested): bounds what a caller can store.
    static let maxOpenPlans = 10
    /// Plans of a target that never ran (rejected, expired, stopped before writing) kept for the history.
    static let keptClosed = 20
    /// Plans a process reads from servers at the same time (each holds up to `DeployLimits.maxReadTotal` in memory).
    static let concurrentPlanning = 2
    static let lifetime: TimeInterval = 24 * 3600
    /// A run that is still `running` after this time was interrupted (the server went down).
    static let lease: TimeInterval = 30 * 60
    /// Writing runs per target whose backups are kept.
    static let keptBackups = 5
    static let chunk = 1024 * 1024
    static let maxNote = 2000
    static let maxRef = 200
    static let maxTaskIDs = 50
    static let maxListed = 2000
}

/// What Todolino knows about one file on the server after its runs.
struct DeployManifestState: Codable, Sendable, Equatable { let path: String; let sha256: String }

struct DeployPlanItem: Codable, Sendable, Equatable {
    /// Repo path.
    let path: String
    let serverPath: String
    /// `upload` | `delete`
    let action: String
    /// `new` | `changed` | `drift` | `restore` | `remove`
    let reason: String
    /// Server file when the plan was made; nil = absent.
    let baseSha: String?
    let baseSize: Int?
    /// File after the run; nil = deleted.
    let newSha: String?
    let newSize: Int?
    /// Manifest entry once this item is applied; nil = Todolino does not know the file any more.
    let after: DeployManifestState?
}

struct DeployBlocker: Codable, Sendable, Equatable {
    let path: String
    let serverPath: String
    /// `unknown_server_state` | `server_changed` | `server_deleted` | `symlink` | `unverified`
    let reason: String
    /// A person may overwrite a change made on the server; a link or a file nobody could check stays locked.
    var overridable: Bool { reason != "symlink" && reason != "unverified" }
}

struct DeployPlanSummary: Codable, Sendable, Equatable {
    var upload = 0, delete = 0, unchanged = 0, serverOnly = 0, blocked = 0, skipped = 0
}

/// Everything a plan fixed when it was made (JSON column). No file contents, no host, no credentials.
struct DeployPlanData: Codable, Sendable {
    var items: [DeployPlanItem]
    var blockers: [DeployBlocker]
    var findings: [DeployPullFinding]
    var summary: DeployPlanSummary
    /// Server state of every file the plan looked at: SHA-256, `""` = absent, `"?"` = not checked.
    var observed: [String: String]
    /// Knowledge about files that no item changes (and about the others while their item is not applied).
    var manifest: [String: DeployManifestState]
    /// The target the plan was made for (endpoint, base path, rules, pinned keys). Any change voids the plan.
    var targetDigest: String
    var endpointDigest: String
    /// Latest run of the target when the plan was made.
    var baseRun: Int
    var taskIDs: [UUID]
    var written: [String] = []
}

struct DeployStoredManifest: Codable, Sendable { let endpoint: String; let files: [String: DeployManifestState] }

final class DeployPlan: Model, @unchecked Sendable {
    static let schema = "deploy_plans"
    @ID(key: .id) var id: UUID?
    @Field(key: "target_id") var targetID: UUID
    /// `upload` | `rollback`
    @Field(key: "kind") var kind: String
    /// `planned` | `requested` | `rejected` | `expired` | `running` | `succeeded` | `failed`
    @Field(key: "state") var state: String
    @OptionalField(key: "source_plan_id") var sourcePlanID: UUID?
    @OptionalField(key: "ref") var ref: String?
    @OptionalField(key: "note") var note: String?
    @Field(key: "data") var data: String
    /// State of the server after the run (`DeployStoredManifest`).
    @OptionalField(key: "manifest") var manifest: String?
    /// Order of the runs of a target; 0 = never run.
    @Field(key: "run_number") var runNumber: Int
    /// The run started to write: only such a run can be undone.
    @Field(key: "wrote") var wrote: Bool
    @OptionalField(key: "code") var code: String?
    @Field(key: "override_drift") var overrideDrift: Bool
    @Field(key: "created_by") var createdBy: UUID
    @OptionalField(key: "created_label") var createdLabel: String?
    @OptionalField(key: "requested_by") var requestedBy: UUID?
    @OptionalField(key: "requested_label") var requestedLabel: String?
    @OptionalField(key: "decided_by") var decidedBy: UUID?
    @Field(key: "created_at") var createdAt: Date
    @OptionalField(key: "requested_at") var requestedAt: Date?
    @OptionalField(key: "decided_at") var decidedAt: Date?
    @OptionalField(key: "finished_at") var finishedAt: Date?
    @Field(key: "expires_at") var expiresAt: Date
    @OptionalField(key: "lock_until") var lockUntil: Date?
    init() {}

    func planData() throws -> DeployPlanData { try JSONDecoder().decode(DeployPlanData.self, from: Data(data.utf8)) }
    func setData(_ value: DeployPlanData) throws { data = String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
}

/// File contents of a plan (`content`, to upload) and what a run overwrote (`backup`), sealed with the settings key, in chunks.
final class DeployBlob: Model, @unchecked Sendable {
    static let schema = "deploy_blobs"
    @ID(key: .id) var id: UUID?
    @Field(key: "plan_id") var planID: UUID
    @Field(key: "role") var role: String
    @Field(key: "item") var item: Int
    @Field(key: "chunk_index") var chunkIndex: Int
    @Field(key: "key_id") var keyID: String
    @Field(key: "bytes") var bytes: Data
    init() {}
}

struct CreateDeployPlans: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(DeployPlan.schema).id()
            .field("target_id", .uuid, .required, .references(DeployTarget.schema, "id", onDelete: .cascade))
            .field("kind", .string, .required)
            .field("state", .string, .required)
            .field("source_plan_id", .uuid)
            .field("ref", .string)
            .field("note", .sql(unsafeRaw: "TEXT"))
            .field("data", .sql(unsafeRaw: "LONGTEXT"), .required)
            .field("manifest", .sql(unsafeRaw: "LONGTEXT"))
            .field("run_number", .int, .required)
            .field("wrote", .bool, .required)
            .field("code", .string)
            .field("override_drift", .bool, .required)
            .field("created_by", .uuid, .required)
            .field("created_label", .string)
            .field("requested_by", .uuid)
            .field("requested_label", .string)
            .field("decided_by", .uuid)
            .field("created_at", .datetime, .required)
            .field("requested_at", .datetime)
            .field("decided_at", .datetime)
            .field("finished_at", .datetime)
            .field("expires_at", .datetime, .required)
            .field("lock_until", .datetime)
            .create()
    }
    func revert(on db: any Database) async throws { try await db.schema(DeployPlan.schema).delete() }
}

struct CreateDeployBlobs: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(DeployBlob.schema).id()
            .field("plan_id", .uuid, .required, .references(DeployPlan.schema, "id", onDelete: .cascade))
            .field("role", .string, .required)
            .field("item", .int, .required)
            .field("chunk_index", .int, .required)
            .field("key_id", .string, .required)
            // LONGBLOB on MariaDB; SQLite treats it as BLOB. Rows are at most DeployUploadLimits.chunk.
            .field("bytes", .sql(unsafeRaw: "LONGBLOB"), .required)
            .unique(on: "plan_id", "role", "item", "chunk_index")
            .create()
    }
    func revert(on db: any Database) async throws { try await db.schema(DeployBlob.schema).delete() }
}

/// Sealed storage of file contents: bound to plan, role, position and server path, so no row can stand in for another.
struct DeployBlobStore: Sendable {
    let ring: SettingsKeyRing

    private static func aad(_ plan: UUID, _ role: String, _ item: Int, _ serverPath: String) -> Data {
        Data("todolino.deploy.blob.v1:\(plan.uuidString):\(role):\(item):\(serverPath)".utf8)
    }

    func put(_ data: Data, plan: UUID, role: String, item: Int, serverPath: String, on db: any Database) async throws {
        guard let current = ring.current else { throw Abort(.conflict, reason: "encryption_key_missing") }
        let box = try AES.GCM.seal(data, using: current.key, nonce: AES.GCM.Nonce(), authenticating: Self.aad(plan, role, item, serverPath))
        guard let combined = box.combined else { throw Abort(.internalServerError, reason: "seal_failed") }
        var offset = 0, index = 0
        repeat {
            let end = min(offset + DeployUploadLimits.chunk, combined.count)
            let row = DeployBlob()
            row.id = UUID(); row.planID = plan; row.role = role; row.item = item; row.chunkIndex = index; row.keyID = current.id
            row.bytes = Data(combined[combined.startIndex.advanced(by: offset)..<combined.startIndex.advanced(by: end)])
            try await row.create(on: db)
            offset = end; index += 1
        } while offset < combined.count
    }

    /// nil = nothing stored. Stored but not readable (key gone, row changed) is an error.
    func get(plan: UUID, role: String, item: Int, serverPath: String, on db: any Database) async throws -> Data? {
        let rows = try await DeployBlob.query(on: db).filter(\.$planID == plan).filter(\.$role == role).filter(\.$item == item)
            .sort(\.$chunkIndex).all()
        guard let first = rows.first else { return nil }
        var combined = Data()
        for row in rows { combined.append(row.bytes) }
        for key in ([ring.current].compactMap { $0 } + ring.previous).filter({ $0.id == first.keyID }) {
            if let box = try? AES.GCM.SealedBox(combined: combined),
               let plain = try? AES.GCM.open(box, using: key.key, authenticating: Self.aad(plan, role, item, serverPath)) { return plain }
        }
        throw DeployTransportError(code: "deploy_content_unreadable")
    }

    static func delete(plan: UUID, role: String, on db: any Database) async throws {
        try await DeployBlob.query(on: db).filter(\.$planID == plan).filter(\.$role == role).delete()
    }
}
