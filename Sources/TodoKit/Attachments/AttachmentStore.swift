import Crypto
import Fluent
import Foundation
import Vapor

public enum AttachmentStorageKind: String, Sendable, CaseIterable {
    case database
    case s3
}

enum AttachmentConfigError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String { if case .invalid(let message) = self { return message }; return "" }
}

public enum AttachmentLimits {
    /// Default per-file limit (10 MiB), documented in docs/adr/0013-anhaenge-in-datenbank.md.
    public static let defaultMaxBytes = 10 * 1024 * 1024
    static let minMaxBytes = 1024
    /// Upload bodies are buffered in memory, so the configurable limit has a hard ceiling.
    static let hardMaxBytes = 128 * 1024 * 1024
    /// Rows in `attachment_blobs` stay far below any `max_allowed_packet` (MariaDB default 16 MiB).
    static let chunkBytes = 1024 * 1024
}

enum AttachmentChecksum {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Byte storage behind an `attachments` row. `db` is the surrounding transaction; only the database
/// store uses it, so blob rows and row state commit or roll back together.
protocol AttachmentStore: Sendable {
    var kind: AttachmentStorageKind { get }
    /// Replaces any previous content for `key` (idempotent).
    func put(key: String, data: Data, db: any Database) async throws
    func get(key: String, db: any Database) async throws -> Data
    /// Missing content is not an error.
    func delete(key: String, db: any Database) async throws
}

/// Default store: chunked LONGBLOB rows in `attachment_blobs`, shared by all replicas through the database.
struct DatabaseStore: AttachmentStore {
    let kind = AttachmentStorageKind.database
    var chunkBytes: Int = AttachmentLimits.chunkBytes

    /// Keys look like `attachments/<uuid>`; the UUID is the owning attachment id.
    static func attachmentID(_ key: String) throws -> UUID {
        guard let last = key.split(separator: "/").last, let id = UUID(uuidString: String(last)) else {
            throw Abort(.badGateway, reason: "attachment_storage_failed")
        }
        return id
    }

    /// Deletes only when rows exist: a DELETE over an empty key range takes InnoDB gap locks that make
    /// concurrent inserts of other attachments deadlock.
    private static func removeChunks(_ id: UUID, on db: any Database) async throws {
        guard try await AttachmentBlob.query(on: db).filter(\.$attachmentID == id).count() > 0 else { return }
        try await AttachmentBlob.query(on: db).filter(\.$attachmentID == id).delete()
    }

    func put(key: String, data: Data, db: any Database) async throws {
        let id = try Self.attachmentID(key)
        do {
            try await Self.removeChunks(id, on: db)
            var index = 0, offset = 0
            repeat {
                let end = min(offset + chunkBytes, data.count)
                let row = AttachmentBlob()
                row.id = UUID(); row.attachmentID = id; row.chunkIndex = index
                row.bytes = Data(data[data.startIndex.advanced(by: offset)..<data.startIndex.advanced(by: end)])
                try await row.create(on: db)
                index += 1; offset = end
            } while offset < data.count
        } catch { throw Abort(.badGateway, reason: "attachment_storage_failed") }
    }

    func get(key: String, db: any Database) async throws -> Data {
        let id = try Self.attachmentID(key)
        let rows: [AttachmentBlob]
        do { rows = try await AttachmentBlob.query(on: db).filter(\.$attachmentID == id).sort(\.$chunkIndex).all() }
        catch { throw Abort(.badGateway, reason: "attachment_storage_failed") }
        // A gap or missing first chunk means lost content; fail instead of returning a short file.
        guard !rows.isEmpty, rows.enumerated().allSatisfy({ $0.offset == $0.element.chunkIndex }) else {
            throw Abort(.badGateway, reason: "attachment_storage_failed")
        }
        var result = Data(); result.reserveCapacity(rows.reduce(0) { $0 + $1.bytes.count })
        for row in rows { result.append(row.bytes) }
        return result
    }

    func delete(key: String, db: any Database) async throws {
        let id = try Self.attachmentID(key)
        do { try await Self.removeChunks(id, on: db) }
        catch { throw Abort(.badGateway, reason: "attachment_storage_failed") }
    }
}

extension S3Store: AttachmentStore {
    var kind: AttachmentStorageKind { .s3 }
    func put(key: String, data: Data, db: any Database) async throws { _ = try await send("PUT", key: key, data: data) }
    func get(key: String, db: any Database) async throws -> Data { try await send("GET", key: key) }
    func delete(key: String, db: any Database) async throws { _ = try await send("DELETE", key: key) }
}

/// Single-range `Range: bytes=` header handling (RFC 9110). Multiple ranges are ignored (full response).
enum ByteRange: Equatable {
    case full
    case partial(ClosedRange<Int>)
    case unsatisfiable

    static func parse(_ header: String?, size: Int) -> ByteRange {
        guard let header, header.lowercased().hasPrefix("bytes="), size > 0 else { return .full }
        let spec = header.dropFirst("bytes=".count).trimmingCharacters(in: .whitespaces)
        guard !spec.contains(",") else { return .full }
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return .full }
        switch (Int(parts[0]), Int(parts[1])) {
        case let (start?, end?):
            guard start >= 0, end >= start else { return .full }
            return start >= size ? .unsatisfiable : .partial(start...min(end, size - 1))
        case let (start?, nil) where parts[1].isEmpty:
            guard start >= 0 else { return .full }
            return start >= size ? .unsatisfiable : .partial(start...(size - 1))
        case let (nil, suffix?) where parts[0].isEmpty:
            guard suffix > 0 else { return .unsatisfiable }
            return .partial(max(0, size - suffix)...(size - 1))
        default:
            return .full
        }
    }
}
