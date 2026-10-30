import Crypto
import Foundation
import Fluent
import XCTVapor
@testable import TodoKit

final class AttachmentTests: XCTestCase {
    // A real one-pixel PNG; magic-byte checks intentionally do not promise a full image decoder.
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aXZkAAAAASUVORK5CYII=")!

    let sqlitePath = NSTemporaryDirectory() + "attachment-test-\(UUID()).sqlite"

    func makeApp() async throws -> TestApp {
        if TestApp.useMariaDB { return try await TestApp.make() }
        let app = try await Application.make(.testing)
        configureContent()
        let settings = AppSettings()
        app.settings = settings
        try configureDatabase(app, settings: DatabaseSettings(driver: .sqlite, host: "", port: 0, name: sqlitePath, user: "", password: ""))
        configureMigrations(app)
        try routes(app)
        try await app.autoMigrate()
        return TestApp(app: app, settings: settings)
    }

    func fixture() async throws -> (TestApp, User, User, UUID, String, String) {
        let t = try await makeApp()
        let alice = User(displayName: "Attachment Alice", isAdmin: false)
        let bob = User(displayName: "Attachment Bob", isAdmin: false)
        try await alice.save(on: t.app.db); try await bob.save(on: t.app.db)
        let p = Project(ownerID: try alice.requireID(), parentID: nil, name: "Attachments")
        try await p.save(on: t.app.db)
        let task = TodoTask(ownerID: try alice.requireID(), projectID: try p.requireID(), title: "Screenshot", details: "")
        try await task.save(on: t.app.db)
        let a = AuthSupport.randomToken(), b = AuthSupport.randomToken()
        for (user, token) in [(alice, a), (bob, b)] {
            try await UserSession(userID: user.requireID(), tokenHash: AuthSupport.hash(token), expiresAt: Date().addingTimeInterval(3600)).save(on: t.app.db)
        }
        return (t, alice, bob, try task.requireID(), a, b)
    }
    func input(_ task: UUID, data: Data? = nil, media: String = "image/png", size: Int? = nil, checksum: String? = nil) -> BeginAttachment {
        let bytes = data ?? png
        return BeginAttachment(taskID: task, filename: "screenshot.png", role: "result", mediaType: media,
                               size: size ?? bytes.count, checksum: checksum ?? S3Store.checksum(bytes))
    }
    func service() -> AttachmentService { AttachmentService() }
    func expectAbort(_ status: HTTPStatus, _ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(status)") }
        catch let error as AbortError { XCTAssertEqual(error.status, status) }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testMagicBytesAndChecksum() throws {
        XCTAssertEqual(AttachmentService.mediaType(png), "image/png")
        XCTAssertEqual(AttachmentService.mediaType(Data([255,216,255,224])), "image/jpeg")
        XCTAssertEqual(AttachmentService.mediaType(Data("RIFF1234WEBP".utf8)), "image/webp")
        XCTAssertEqual(AttachmentService.mediaType(Data("%PDF-1.7".utf8)), "application/pdf")
        XCTAssertNil(AttachmentService.mediaType(Data("<svg/>".utf8)))
        XCTAssertNil(AttachmentService.mediaType(Data([137,80,78])))
        XCTAssertEqual(S3Store.checksum(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testPendingAuthorizationAndValidationWithoutStorage() async throws {
        let (t, alice, bob, task, a, b) = try await fixture()
        defer { Task { await t.shutdown() } }
        let service = service()
        let cap = try await service.begin(input(task), user: alice, db: t.app.db)
        let storedSession = try await UploadSession.query(on: t.app.db).filter(\.$attachmentID == cap.attachmentID).first()
        let session = try XCTUnwrap(storedSession)
        XCTAssertNotEqual(session.tokenHash, cap.token)
        XCTAssertEqual(session.tokenHash, AuthSupport.hash(cap.token))
        let anonymous = try await t.json(.GET, "/v1/tasks/\(task)/attachments")
        XCTAssertEqual(anonymous.status, .unauthorized)
        let pending = try await t.json(.GET, "/v1/tasks/\(task)/attachments", token: a)
        XCTAssertEqual(pending.list?.count, 0)
        let foreign = try await t.json(.GET, "/v1/tasks/\(task)/attachments", token: b)
        XCTAssertEqual(foreign.status, .notFound)
        for suffix in ["download", "preview"] {
            let r = try await t.json(.GET, "/v1/attachments/\(cap.attachmentID)/\(suffix)", token: a)
            XCTAssertEqual(r.status, .notFound)
        }
        await expectAbort(.notFound) { _ = try await service.begin(self.input(task), user: bob, db: t.app.db) }
        await expectAbort(.badRequest) { _ = try await service.begin(self.input(task, size: AttachmentLimits.defaultMaxBytes + 1), user: alice, db: t.app.db) }
        await expectAbort(.badRequest) { _ = try await service.begin(self.input(task, media: "text/html"), user: alice, db: t.app.db) }
        await expectAbort(.conflict) { _ = try await service.complete(cap.attachmentID, user: alice, db: t.app.db) }
        await expectAbort(.notFound) { try await service.upload(cap.attachmentID, token: "wrong", data: self.png, db: t.app.db) }
        await expectAbort(.unsupportedMediaType) {
            try await service.upload(cap.attachmentID, token: cap.token, data: Data(repeating: 65, count: self.png.count), db: t.app.db)
        }
        var corrupted = png; corrupted[corrupted.count - 1] ^= 1
        await expectAbort(.unprocessableEntity) { try await service.upload(cap.attachmentID, token: cap.token, data: corrupted, db: t.app.db) }
        session.expiresAt = Date().addingTimeInterval(-1)
        try await session.save(on: t.app.db)
        await expectAbort(.notFound) { try await service.upload(cap.attachmentID, token: cap.token, data: self.png, db: t.app.db) }
    }

    func testEffectiveRolesGateUploadsButNotReading() async throws {
        let (t, alice, bob, task, _, b) = try await fixture()
        defer { Task { await t.shutdown() } }
        let service = service()
        let storedTask = try await TodoTask.find(task, on: t.app.db)
        let projectID = try XCTUnwrap(storedTask).projectID
        let grant = ProjectGrant(projectID: projectID, principalType: "person", principalID: try bob.requireID(), role: .read)
        try await grant.save(on: t.app.db)
        let listed = try await t.json(.GET, "/v1/tasks/\(task)/attachments", token: b)
        XCTAssertEqual(listed.status, .ok)
        await expectAbort(.forbidden) { _ = try await service.begin(self.input(task), user: bob, db: t.app.db) }
        grant.role = .edit
        try await grant.update(on: t.app.db)
        let cap = try await service.begin(input(task), user: bob, db: t.app.db)
        // Revoking the grant also invalidates the already issued capability.
        try await grant.delete(on: t.app.db)
        await expectAbort(.notFound) { try await service.upload(cap.attachmentID, token: cap.token, data: self.png, db: t.app.db) }
        _ = alice
    }

    func testSigV4KnownSignature() throws {
        // Independently calculated fixture, using public AWS documentation example credentials.
        let store = S3Store(endpoint: URL(string: "https://s3.amazonaws.com")!, bucket: "examplebucket",
                            accessKey: "AKIAIOSFODNN7EXAMPLE", secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", region: "us-east-1")
        let request = store.signedRequest("GET", key: "test.txt", now: Date(timeIntervalSince1970: 1369353600))
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-date"), "20130524T000000Z")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=0fcb291c4b47980ad34dd9a29532ceae67b48e45de3d6054873b430740567ec2")
        XCTAssertEqual(request.url?.path, "/examplebucket/test.txt")
        let unsigned = S3Store(endpoint: URL(string: "http://localhost:29090")!, bucket: "todo-attachments", accessKey: nil, secretKey: nil, region: "us-east-1")
        XCTAssertNil(unsigned.signedRequest("GET", key: "x").value(forHTTPHeaderField: "Authorization"))
    }

    func testS3MockReplicaUploadDownloadAuthorizationAndCleanup() async throws {
        try XCTSkipIf(Environment.get("S3_ENDPOINT") == nil, "S3_ENDPOINT is unset; requires S3Mock")
        let (a, alice, bob, task, token, foreignToken) = try await fixture()
        let b = try await (TestApp.useMariaDB ? a.replica() : makeApp())
        defer { Task { await a.shutdown(); await b.shutdown() } }
        // The default is the database store; this test exercises the optional S3 store through REST.
        a.app.settings.attachmentStorage = .s3; b.app.settings.attachmentStorage = .s3
        let s3 = try S3Store.fromEnvironment()
        let service = AttachmentService(writeKind: .s3)
        // S3Mock accepts unsigned access; test it independently of optional configured keys.
        let unsigned = S3Store(endpoint: s3.endpoint, bucket: s3.bucket,
                               accessKey: nil, secretKey: nil, region: s3.region)
        let probeKey = "attachments/unsigned-probe-\(UUID())"
        _ = try await unsigned.send("PUT", key: probeKey, data: png)
        let probe = try await unsigned.send("GET", key: probeKey)
        XCTAssertEqual(probe, png)
        _ = try await unsigned.send("DELETE", key: probeKey)
        let begin = try await a.json(.POST, "/v1/attachments/begin", [
            "taskID": task.uuidString, "filename": "screenshot.png", "role": "progress",
            "mediaType": "image/png", "size": png.count, "checksum": S3Store.checksum(png)
        ], token: token)
        XCTAssertEqual(begin.status, .ok)
        let id = try XCTUnwrap(begin.body?["attachmentID"] as? String)
        let uploadToken = try XCTUnwrap(begin.body?["token"] as? String)
        let url = try XCTUnwrap(begin.body?["uploadURL"] as? String)
        try await a.app.test(.PUT, url, beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: uploadToken)
            req.body = ByteBuffer(data: self.png)
        }, afterResponse: { res async in XCTAssertEqual(res.status, .noContent) })
        let hidden = try await b.json(.GET, "/v1/attachments/\(id)/download", token: token)
        XCTAssertEqual(hidden.status, .notFound)
        let forbidden = try await b.json(.POST, "/v1/attachments/\(id)/complete", token: foreignToken)
        XCTAssertEqual(forbidden.status, .notFound)
        let completed = try await b.json(.POST, "/v1/attachments/\(id)/complete", token: token)
        XCTAssertEqual(completed.status, .ok)
        let repeated = try await a.json(.POST, "/v1/attachments/\(id)/complete", token: token)
        XCTAssertEqual(repeated.status, .ok)
        for suffix in ["download", "preview"] {
            try await b.app.test(.GET, "/v1/attachments/\(id)/\(suffix)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async in
                XCTAssertEqual(res.status, .ok)
                XCTAssertEqual(Data(res.body.readableBytesView), self.png)
                XCTAssertEqual(res.headers.first(name: .cacheControl), "private, no-store")
            })
            let foreign = try await b.json(.GET, "/v1/attachments/\(id)/\(suffix)", token: foreignToken)
            XCTAssertEqual(foreign.status, .notFound)
        }
        let visible = try await b.json(.GET, "/v1/tasks/\(task)/attachments", token: token)
        XCTAssertEqual(visible.list?.count, 1)
        await expectAbort(.notFound) { try await service.upload(UUID(uuidString: id)!, token: uploadToken, data: self.png, db: a.app.db) }
        let invalidStored = try await service.begin(input(task), user: alice, db: a.app.db)
        try await service.upload(invalidStored.attachmentID, token: invalidStored.token, data: png, db: a.app.db)
        let storedAttachment = try await Attachment.find(invalidStored.attachmentID, on: a.app.db)
        let objectKey = try XCTUnwrap(storedAttachment).objectKey
        _ = try await s3.send("PUT", key: objectKey, data: Data(repeating: 65, count: png.count))
        await expectAbort(.unsupportedMediaType) { _ = try await service.complete(invalidStored.attachmentID, user: alice, db: b.app.db) }
        try await service.abort(invalidStored.attachmentID, user: alice, db: b.app.db)
        let aborted = try await service.begin(input(task), user: alice, db: a.app.db)
        try await service.upload(aborted.attachmentID, token: aborted.token, data: png, db: a.app.db)
        await expectAbort(.notFound) { try await service.abort(aborted.attachmentID, user: bob, db: b.app.db) }
        try await service.abort(aborted.attachmentID, user: alice, db: b.app.db)
        let afterAbort = try await Attachment.find(aborted.attachmentID, on: a.app.db)
        XCTAssertNil(afterAbort)
        let expired = try await service.begin(input(task), user: alice, db: a.app.db)
        try await service.upload(expired.attachmentID, token: expired.token, data: png, db: a.app.db)
        let storedSession = try await UploadSession.query(on: a.app.db).filter(\.$attachmentID == expired.attachmentID).first()
        let session = try XCTUnwrap(storedSession)
        session.expiresAt = Date().addingTimeInterval(-1); try await session.update(on: a.app.db)
        _ = try await service.cleanup(db: b.app.db)
        let afterCleanup = try await Attachment.find(expired.attachmentID, on: a.app.db)
        XCTAssertNil(afterCleanup)
        // A task moved to another account is no longer accessible, even with an old upload token.
        let pending = try await service.begin(input(task), user: alice, db: a.app.db)
        let p = Project(ownerID: try bob.requireID(), parentID: nil, name: "Revoked")
        try await p.save(on: a.app.db)
        let storedTask = try await TodoTask.find(task, on: a.app.db)
        let moved = try XCTUnwrap(storedTask)
        moved.projectID = try p.requireID(); try await moved.update(on: a.app.db)
        let revoked = try await b.json(.GET, "/v1/attachments/\(id)/download", token: token)
        XCTAssertEqual(revoked.status, .notFound)
        await expectAbort(.notFound) { try await service.upload(pending.attachmentID, token: pending.token, data: self.png, db: b.app.db) }
        try await moved.delete(on: a.app.db)
        _ = try await service.cleanup(db: b.app.db)
        let afterDeletion = try await Attachment.find(UUID(uuidString: id), on: a.app.db)
        XCTAssertNil(afterDeletion)
    }

    // MARK: Database store (default)

    /// In-memory stand-in for S3, so migrate-storage can be tested without a bucket.
    final class MemoryStore: AttachmentStore, @unchecked Sendable {
        let kind = AttachmentStorageKind.s3
        private let lock = NSLock()
        private var objects: [String: Data] = [:]
        var keys: Set<String> { lock.withLock { Set(objects.keys) } }
        func put(key: String, data: Data, db: any Database) async throws { lock.withLock { objects[key] = data } }
        func get(key: String, db: any Database) async throws -> Data {
            guard let data = lock.withLock({ objects[key] }) else { throw Abort(.badGateway, reason: "attachment_storage_failed") }
            return data
        }
        func delete(key: String, db: any Database) async throws { lock.withLock { objects[key] = nil } }
    }

    /// A PDF-looking payload that spans several chunks (3 x 1 MiB chunks + remainder).
    func bigPDF(_ size: Int = 3 * 1024 * 1024 + 123) -> Data {
        var data = Data("%PDF-1.7\n".utf8)
        var generator = SystemRandomNumberGenerator()
        while data.count < size { data.append(UInt8.random(in: 0...255, using: &generator)) }
        return data
    }

    func blobCount(_ db: any Database, _ id: UUID? = nil) async throws -> Int {
        let q = AttachmentBlob.query(on: db)
        if let id { q.filter(\.$attachmentID == id) }
        return try await q.count()
    }

    func restUpload(_ t: TestApp, _ other: TestApp, task: UUID, token: String, data: Data, media: String = "application/pdf",
                    filename: String = "doc.pdf") async throws -> String {
        let begin = try await t.json(.POST, "/v1/attachments/begin", [
            "taskID": task.uuidString, "filename": filename, "role": "result",
            "mediaType": media, "size": data.count, "checksum": AttachmentChecksum.sha256(data)
        ], token: token)
        XCTAssertEqual(begin.status, .ok)
        let id = try XCTUnwrap(begin.body?["attachmentID"] as? String)
        let uploadToken = try XCTUnwrap(begin.body?["token"] as? String)
        let url = try XCTUnwrap(begin.body?["uploadURL"] as? String)
        try await t.app.test(.PUT, url, beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: uploadToken)
            req.body = ByteBuffer(data: data)
        }, afterResponse: { res async in XCTAssertEqual(res.status, .noContent) })
        let hidden = try await other.json(.GET, "/v1/attachments/\(id)/download", token: token)
        XCTAssertEqual(hidden.status, .notFound)
        let completed = try await other.json(.POST, "/v1/attachments/\(id)/complete", token: token)
        XCTAssertEqual(completed.status, .ok)
        return id
    }

    func testDatabaseStoreIsDefaultAndNeedsNoS3() throws {
        let settings = try AppSettings.fromEnvironment(get: { _ in nil })
        XCTAssertEqual(settings.attachmentStorage, .database)
        XCTAssertEqual(settings.attachmentMaxBytes, 10 * 1024 * 1024)
        let s3 = try AppSettings.fromEnvironment(get: { ["ATTACHMENT_STORAGE": "s3", "ATTACHMENT_MAX_BYTES": "2048"][$0] })
        XCTAssertEqual(s3.attachmentStorage, .s3); XCTAssertEqual(s3.attachmentMaxBytes, 2048)
        XCTAssertThrowsError(try AppSettings.fromEnvironment(get: { ["ATTACHMENT_STORAGE": "ftp"][$0] }))
        XCTAssertThrowsError(try AppSettings.fromEnvironment(get: { ["ATTACHMENT_MAX_BYTES": "0"][$0] }))
        XCTAssertThrowsError(try AppSettings.fromEnvironment(get: { ["ATTACHMENT_MAX_BYTES": "999999999999"][$0] }))
        // S3_* alone does not switch the store.
        let envOnly = try AppSettings.fromEnvironment(get: { ["S3_ENDPOINT": "http://x"][$0] })
        XCTAssertEqual(envOnly.attachmentStorage, .database)
    }

    func testByteRangeParsing() {
        XCTAssertEqual(ByteRange.parse(nil, size: 100), .full)
        XCTAssertEqual(ByteRange.parse("bytes=0-9", size: 100), .partial(0...9))
        XCTAssertEqual(ByteRange.parse("bytes=90-", size: 100), .partial(90...99))
        XCTAssertEqual(ByteRange.parse("bytes=-10", size: 100), .partial(90...99))
        XCTAssertEqual(ByteRange.parse("bytes=50-500", size: 100), .partial(50...99))
        XCTAssertEqual(ByteRange.parse("bytes=100-", size: 100), .unsatisfiable)
        XCTAssertEqual(ByteRange.parse("bytes=0-1,5-6", size: 100), .full)
        XCTAssertEqual(ByteRange.parse("bytes=9-3", size: 100), .full)
        XCTAssertEqual(ByteRange.parse("items=0-1", size: 100), .full)
    }

    func testDatabaseStoreChunksRangeAndReplicaAccess() async throws {
        let (a, _, _, task, token, foreign) = try await fixture()
        let b = try await (TestApp.useMariaDB ? a.replica() : makeApp())
        defer { Task { await a.shutdown(); await b.shutdown() } }
        let data = bigPDF()
        let id = try await restUpload(a, b, task: task, token: token, data: data)
        let uuid = UUID(uuidString: id)!
        // 3 MiB + 123 bytes -> 4 chunk rows, metadata row stays small and points at the database store.
        let chunks = try await blobCount(a.app.db, uuid)
        XCTAssertEqual(chunks, 4)
        let stored = try await Attachment.find(uuid, on: a.app.db)
        XCTAssertEqual(stored?.storage, "database")
        // Download from the other replica, with and without Range.
        try await b.app.test(.GET, "/v1/attachments/\(id)/download", beforeRequest: { $0.headers.bearerAuthorization = .init(token: token) }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(Data(res.body.readableBytesView), data)
            XCTAssertEqual(res.headers.first(name: .acceptRanges), "bytes")
            XCTAssertEqual(res.headers.first(name: .cacheControl), "private, no-store")
        })
        let from = 1024 * 1024 - 5, to = 1024 * 1024 + 9  // crosses a chunk boundary
        try await b.app.test(.GET, "/v1/attachments/\(id)/download", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token); req.headers.replaceOrAdd(name: .range, value: "bytes=\(from)-\(to)")
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .partialContent)
            XCTAssertEqual(Data(res.body.readableBytesView), data.subdata(in: from..<(to + 1)))
            XCTAssertEqual(res.headers.first(name: .contentRange), "bytes \(from)-\(to)/\(data.count)")
        })
        try await a.app.test(.GET, "/v1/attachments/\(id)/download", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token); req.headers.replaceOrAdd(name: .range, value: "bytes=\(data.count)-")
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .rangeNotSatisfiable)
            XCTAssertEqual(res.headers.first(name: .contentRange), "bytes */\(data.count)")
        })
        // Same permission rules as before: foreign accounts get 404, PDFs have no inline preview.
        let other = try await b.json(.GET, "/v1/attachments/\(id)/download", token: foreign)
        XCTAssertEqual(other.status, .notFound)
        let preview = try await b.json(.GET, "/v1/attachments/\(id)/preview", token: token)
        XCTAssertEqual(preview.status, .unsupportedMediaType)
        let listed = try await b.json(.GET, "/v1/tasks/\(task)/attachments", token: token)
        XCTAssertEqual(listed.list?.count, 1)
    }

    func testDatabaseStoreImagePreviewAndAbort() async throws {
        let (t, alice, bob, task, token, _) = try await fixture()
        defer { Task { await t.shutdown() } }
        let id = try await restUpload(t, t, task: task, token: token, data: png, media: "image/png", filename: "s.png")
        try await t.app.test(.GET, "/v1/attachments/\(id)/preview", beforeRequest: { $0.headers.bearerAuthorization = .init(token: token) }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(Data(res.body.readableBytesView), self.png)
            XCTAssertTrue(res.headers.first(name: .contentDisposition)?.hasPrefix("inline") == true)
        })
        let svc = service()
        let pending = try await svc.begin(input(task), user: alice, db: t.app.db)
        try await svc.upload(pending.attachmentID, token: pending.token, data: png, db: t.app.db)
        let before = try await blobCount(t.app.db, pending.attachmentID)
        XCTAssertEqual(before, 1)
        await expectAbort(.notFound) { try await svc.abort(pending.attachmentID, user: bob, db: t.app.db) }
        try await svc.abort(pending.attachmentID, user: alice, db: t.app.db)
        let after = try await blobCount(t.app.db, pending.attachmentID)
        XCTAssertEqual(after, 0)
        // Token reuse after a successful PUT is rejected.
        let used = try await svc.begin(input(task), user: alice, db: t.app.db)
        try await svc.upload(used.attachmentID, token: used.token, data: png, db: t.app.db)
        await expectAbort(.notFound) { try await svc.upload(used.attachmentID, token: used.token, data: self.png, db: t.app.db) }
    }

    func testConfiguredLimitSizeAndChecksumRules() async throws {
        let (t, alice, _, task, token, _) = try await fixture()
        defer { Task { await t.shutdown() } }
        let small = AttachmentService(maxBytes: 2048)
        let big = Data("%PDF-".utf8) + Data(repeating: 1, count: 4096)
        await expectAbort(.badRequest) { _ = try await small.begin(self.input(task, data: big, media: "application/pdf"), user: alice, db: t.app.db) }
        // Declared size smaller than the real body: size mismatch, nothing stored.
        let declared = Data("%PDF-".utf8) + Data(repeating: 2, count: 100)
        let cap = try await small.begin(input(task, data: declared, media: "application/pdf"), user: alice, db: t.app.db)
        await expectAbort(.unprocessableEntity) { try await small.upload(cap.attachmentID, token: cap.token, data: declared + Data([1]), db: t.app.db) }
        let none = try await blobCount(t.app.db, cap.attachmentID)
        XCTAssertEqual(none, 0)
        // Wrong declared checksum is caught on upload; stored tampering is caught on download and complete.
        let wrong = try await small.begin(input(task, data: declared, media: "application/pdf", checksum: String(repeating: "0", count: 64)), user: alice, db: t.app.db)
        await expectAbort(.unprocessableEntity) { try await small.upload(wrong.attachmentID, token: wrong.token, data: declared, db: t.app.db) }
        let id = try await restUpload(t, t, task: task, token: token, data: declared)
        let row = try await AttachmentBlob.query(on: t.app.db).filter(\.$attachmentID == UUID(uuidString: id)!).first()
        let blob = try XCTUnwrap(row)
        blob.bytes[blob.bytes.count - 1] ^= 1
        try await blob.update(on: t.app.db)
        let tampered = try await t.json(.GET, "/v1/attachments/\(id)/download", token: token)
        XCTAssertEqual(tampered.status, .unprocessableEntity)
        // A lost chunk is an error, never a short file.
        try await blob.delete(on: t.app.db)
        let lost = try await t.json(.GET, "/v1/attachments/\(id)/download", token: token)
        XCTAssertEqual(lost.status, .badGateway)
    }

    func testCleanupRemovesBlobsOfExpiredAndDeletedTasks() async throws {
        let (t, alice, _, task, token, _) = try await fixture()
        defer { Task { await t.shutdown() } }
        let svc = service()
        let keep = try await restUpload(t, t, task: task, token: token, data: png, media: "image/png", filename: "k.png")
        let expired = try await svc.begin(input(task), user: alice, db: t.app.db)
        try await svc.upload(expired.attachmentID, token: expired.token, data: png, db: t.app.db)
        let storedSession = try await UploadSession.query(on: t.app.db).filter(\.$attachmentID == expired.attachmentID).first()
        let session = try XCTUnwrap(storedSession)
        session.expiresAt = Date().addingTimeInterval(-1); try await session.update(on: t.app.db)
        let removed = try await svc.cleanup(db: t.app.db)
        XCTAssertEqual(removed, 1)
        let expiredBlobs = try await blobCount(t.app.db, expired.attachmentID)
        XCTAssertEqual(expiredBlobs, 0)
        let keptBlobs = try await blobCount(t.app.db, UUID(uuidString: keep))
        XCTAssertEqual(keptBlobs, 1)
        let storedTask = try await TodoTask.find(task, on: t.app.db)
        try await XCTUnwrap(storedTask).delete(on: t.app.db)
        let removedWithTask = try await svc.cleanup(db: t.app.db)
        XCTAssertEqual(removedWithTask, 1)
        let all = try await blobCount(t.app.db)
        XCTAssertEqual(all, 0)
    }

    func testMigrateStorageBothDirectionsIsIdempotent() async throws {
        let (t, alice, _, task, token, _) = try await fixture()
        defer { Task { await t.shutdown() } }
        let memory = MemoryStore()
        let svc = AttachmentService(writeKind: .database, overrides: [.s3: memory])
        let data = bigPDF(1_500_000)
        let id = try await restUpload(t, t, task: task, token: token, data: data)
        let uuid = UUID(uuidString: id)!
        // A legacy row that lives in "S3" (e.g. written before the database store existed).
        let legacy = try await AttachmentService(writeKind: .s3, overrides: [.s3: memory]).begin(input(task), user: alice, db: t.app.db)
        try await AttachmentService(writeKind: .s3, overrides: [.s3: memory]).upload(legacy.attachmentID, token: legacy.token, data: png, db: t.app.db)
        _ = try await AttachmentService(writeKind: .s3, overrides: [.s3: memory]).complete(legacy.attachmentID, user: alice, db: t.app.db)
        XCTAssertEqual(memory.keys.count, 1)

        let dry = try await svc.migrateStorage(from: .s3, to: .database, dryRun: true, db: t.app.db)
        XCTAssertEqual(dry.migrated, 1)
        let dryBlobs = try await blobCount(t.app.db, legacy.attachmentID)
        XCTAssertEqual(dryBlobs, 0)
        let first = try await svc.migrateStorage(from: .s3, to: .database, db: t.app.db)
        XCTAssertEqual(first, MigrateStorageReport(migrated: 1, skipped: 0, failed: []))
        let second = try await svc.migrateStorage(from: .s3, to: .database, db: t.app.db)
        XCTAssertEqual(second.migrated, 0)
        let migrated = try await Attachment.find(legacy.attachmentID, on: t.app.db)
        XCTAssertEqual(migrated?.storage, "database")
        XCTAssertEqual(memory.keys.count, 1, "source is kept unless --delete-source")
        try await t.app.test(.GET, "/v1/attachments/\(legacy.attachmentID)/download", beforeRequest: { $0.headers.bearerAuthorization = .init(token: token) }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok); XCTAssertEqual(Data(res.body.readableBytesView), self.png)
        })
        // Reverse: database -> s3, deleting the database copy.
        let back = try await svc.migrateStorage(from: .database, to: .s3, deleteSource: true, db: t.app.db)
        XCTAssertEqual(back.migrated, 2); XCTAssertTrue(back.failed.isEmpty)
        let afterBlobs = try await blobCount(t.app.db)
        XCTAssertEqual(afterBlobs, 0)
        XCTAssertTrue(memory.keys.contains("attachments/\(uuid.uuidString.lowercased())"))
        let readFromS3 = AttachmentService(writeKind: .database, overrides: [.s3: memory])
        let moved = try await Attachment.find(uuid, on: t.app.db)
        let bytes = try await readFromS3.store(for: XCTUnwrap(moved)).get(key: XCTUnwrap(moved).objectKey, db: t.app.db)
        XCTAssertEqual(bytes, data)
        // A corrupted source object is reported as failed and not switched.
        let key = "attachments/\(uuid.uuidString.lowercased())"
        try await memory.put(key: key, data: Data("%PDF-tampered".utf8), db: t.app.db)
        let broken = try await svc.migrateStorage(from: .s3, to: .database, db: t.app.db)
        XCTAssertEqual(broken.failed, [uuid])
        let unchanged = try await Attachment.find(uuid, on: t.app.db)
        XCTAssertEqual(unchanged?.storage, "s3")
        let leftover = try await blobCount(t.app.db, uuid)
        XCTAssertEqual(leftover, 0)
        await expectAbort(.badRequest) { _ = try await svc.migrateStorage(from: .s3, to: .s3, db: t.app.db) }
    }

    func testS3WriteKindWithoutConfigurationFailsBeforeCreatingRows() async throws {
        try XCTSkipIf(Environment.get("S3_ENDPOINT") != nil, "S3 is configured here")
        let (t, alice, _, task, _, _) = try await fixture()
        defer { Task { await t.shutdown() } }
        await expectAbort(.serviceUnavailable) { _ = try await AttachmentService(writeKind: .s3).begin(self.input(task), user: alice, db: t.app.db) }
        let rows = try await Attachment.query(on: t.app.db).count()
        XCTAssertEqual(rows, 0)
    }

    func testConcurrentReplicaUploadsAndCompletes() async throws {
        try XCTSkipUnless(TestApp.useMariaDB, "needs real row locks (MariaDB)")
        let (a, alice, _, task, _, _) = try await fixture()
        let b = try await a.replica()
        defer { Task { await a.shutdown(); await b.shutdown() } }
        let svc = service()
        let bytes = png
        // The same capability used from both replicas at once: exactly one PUT wins.
        let cap = try await svc.begin(input(task), user: alice, db: a.app.db)
        let results = await withTaskGroup(of: Bool.self) { group -> [Bool] in
            for db in [a.app.db, b.app.db, a.app.db, b.app.db] {
                group.addTask { (try? await svc.upload(cap.attachmentID, token: cap.token, data: bytes, db: db)) != nil }
            }
            var out: [Bool] = []; for await r in group { out.append(r) }; return out
        }
        XCTAssertEqual(results.filter { $0 }.count, 1)
        let completes = await withTaskGroup(of: Bool.self) { group -> [Bool] in
            for db in [a.app.db, b.app.db, a.app.db, b.app.db] {
                group.addTask { (try? await svc.complete(cap.attachmentID, user: alice, db: db)) != nil }
            }
            var out: [Bool] = []; for await r in group { out.append(r) }; return out
        }
        XCTAssertEqual(completes.filter { $0 }.count, 4, "complete is idempotent across replicas")
        let blobs = try await blobCount(a.app.db, cap.attachmentID)
        XCTAssertEqual(blobs, 1)
        // Parallel uploads of different attachments do not interfere.
        let data = bigPDF(2_200_000)
        let beginInput = input(task, data: data, media: "application/pdf")
        let ids = try await withThrowingTaskGroup(of: UUID.self) { group -> [UUID] in
            for i in 0..<4 {
                group.addTask {
                    let db = i % 2 == 0 ? a.app.db : b.app.db
                    let c = try await svc.begin(beginInput, user: alice, db: db)
                    try await svc.upload(c.attachmentID, token: c.token, data: data, db: db)
                    _ = try await svc.complete(c.attachmentID, user: alice, db: db)
                    return c.attachmentID
                }
            }
            var out: [UUID] = []; for try await id in group { out.append(id) }; return out
        }
        for id in ids {
            let a1 = try await Attachment.find(id, on: b.app.db)
            let bytes = try await svc.store(for: XCTUnwrap(a1)).get(key: XCTUnwrap(a1).objectKey, db: b.app.db)
            XCTAssertEqual(bytes, data)
        }
    }
}
