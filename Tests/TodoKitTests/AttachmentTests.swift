import Crypto
import Fluent
import XCTVapor
@testable import TodoKit

final class AttachmentTests: XCTestCase {
    // A real one-pixel PNG; magic-byte checks intentionally do not promise a full image decoder.
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aXZkAAAAASUVORK5CYII=")!

    let sqlitePath = "/private/tmp/attachment-test-\(UUID()).sqlite"

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
    func service() -> AttachmentService {
        AttachmentService(store: S3Store(endpoint: URL(string: "http://localhost:29090")!, bucket: "todo-attachments", accessKey: nil, secretKey: nil, region: "us-east-1"))
    }
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
        await expectAbort(.badRequest) { _ = try await service.begin(self.input(task, size: AttachmentService.maxSize + 1), user: alice, db: t.app.db) }
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
        XCTAssertNil(service().store.signedRequest("GET", key: "x").value(forHTTPHeaderField: "Authorization"))
    }

    func testS3MockReplicaUploadDownloadAuthorizationAndCleanup() async throws {
        try XCTSkipIf(Environment.get("S3_ENDPOINT") == nil, "S3_ENDPOINT is unset; requires S3Mock")
        let (a, alice, bob, task, token, foreignToken) = try await fixture()
        let b = try await (TestApp.useMariaDB ? a.replica() : makeApp())
        defer { Task { await a.shutdown(); await b.shutdown() } }
        let service = try AttachmentService(store: .fromEnvironment())
        // S3Mock accepts unsigned access; test it independently of optional configured keys.
        let unsigned = S3Store(endpoint: service.store.endpoint, bucket: service.store.bucket,
                               accessKey: nil, secretKey: nil, region: service.store.region)
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
        _ = try await service.store.send("PUT", key: objectKey, data: Data(repeating: 65, count: png.count))
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
}
