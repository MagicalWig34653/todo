import Crypto
import Fluent
import Foundation
import Logging
import SQLKit
import XCTVapor
@testable import TodoKit

struct WebhookTestError: Error { let what: String }

/// Transport double: records every request and answers with a scripted result. No network is involved.
final class RecordingWebhookTransport: WebhookTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [WebhookWireRequest] = []
    private var _handler: @Sendable (WebhookWireRequest) -> WebhookSendResult = { _ in .status(200) }
    var requests: [WebhookWireRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    var handler: @Sendable (WebhookWireRequest) -> WebhookSendResult {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); defer { lock.unlock() }; _handler = newValue }
    }
    private func record(_ request: WebhookWireRequest) -> WebhookSendResult {
        lock.lock(); defer { lock.unlock() }
        _requests.append(request)
        return _handler(request)
    }
    func post(_ request: WebhookWireRequest) async -> WebhookSendResult { record(request) }
    func header(_ name: String, in request: WebhookWireRequest) -> String? { request.headers.first { $0.0.lowercased() == name.lowercased() }?.1 }
}

/// Resolver double. Unknown names resolve to a public documentation address (TEST-NET-3), so no DNS is needed.
final class FixedWebhookResolver: WebhookResolver, @unchecked Sendable {
    private let lock = NSLock()
    private var map: [String: String]
    private var _fallback: String?
    init(_ map: [String: String] = [:], fallback: String? = "203.0.113.10") { self.map = map; _fallback = fallback }
    func set(_ host: String, _ address: String) { lock.lock(); map[host] = address; lock.unlock() }
    private func lookup(_ host: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return map[host] ?? _fallback
    }
    func resolve(host: String, port: Int) async throws -> String {
        guard let address = lookup(host) else { throw OutboundUnresolvable() }
        return address
    }
}

final class LogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
    func add(_ s: String) { lock.lock(); _lines.append(s); lock.unlock() }
}

struct CaptureLogHandler: LogHandler {
    let capture: LogCapture
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace
    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }
    func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, source: String, file: String, function: String, line: UInt) {
        capture.add("\(level) \(message) \((metadata ?? [:]).map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))")
    }
}

/// The person (REST session), an MCP connection of that person, recording doubles and helpers for the webhook tests.
struct WebhookFixture {
    static let keyBase64 = Data(repeating: 7, count: 32).base64EncodedString()
    static let secretURL = "https://hooks.example.test/SECRETPATH-9f8e7d?token=SECRETQUERY-1c2d"
    static let secretSigning = "SIGNING-SECRET-0123456789abcdef"

    let o: OAuthFixture
    let transport: RecordingWebhookTransport
    let resolver: FixedWebhookResolver
    let capture: LogCapture
    var test: TestApp { o.test }
    var app: Application { o.test.app }
    var session: String { o.session }
    var userID: UUID { o.user.id! }
    var projectID: String { o.project.id!.uuidString }

    static func make(key: Bool = true) async throws -> WebhookFixture {
        let o = try await OAuthFixture.make()
        let transport = RecordingWebhookTransport(), resolver = FixedWebhookResolver(), capture = LogCapture()
        installRuntime(o.test.app, key: key)
        o.test.app.webhookTransport = transport
        o.test.app.webhookResolver = resolver
        o.test.app.logger = Logger(label: "webhook-test") { _ in CaptureLogHandler(capture: capture) }
        return WebhookFixture(o: o, transport: transport, resolver: resolver, capture: capture)
    }

    static func installRuntime(_ app: Application, key: Bool = true) {
        let env: [String: String] = key ? ["SETTINGS_ENCRYPTION_KEY": keyBase64] : [:]
        app.settingsRuntime = SettingsRuntime(app: app, env: { env[$0] }, keyRing: (try? SettingsKeyRing.fromEnvironment(get: { env[$0] })) ?? SettingsKeyRing(), pollInterval: 1)
    }

    /// Another application instance on the same database (like a second swarm replica) with the same doubles.
    func replica() async throws -> TestApp {
        let r = try await test.replica()
        Self.installRuntime(r.app)
        r.app.webhookTransport = transport
        r.app.webhookResolver = resolver
        return r
    }

    typealias Response = (status: HTTPStatus, body: [String: Any]?, list: [[String: Any]]?, cookie: String?)

    func put(_ body: [String: Any], token: String? = nil) async throws -> Response {
        try await test.json(.PUT, "/v1/settings/webhook", body, token: token ?? session)
    }
    func get(token: String? = nil) async throws -> Response { try await test.json(.GET, "/v1/settings/webhook", token: token ?? session) }
    func deliveries(token: String? = nil) async throws -> Response { try await test.json(.GET, "/v1/settings/webhook/deliveries", token: token ?? session) }
    func sendTest(token: String? = nil) async throws -> Response { try await test.json(.POST, "/v1/settings/webhook/test", token: token ?? session) }

    /// Configures the webhook (default URL) and expects success.
    @discardableResult
    func configure(_ extra: [String: Any] = [:], url: String = WebhookFixture.secretURL, file: StaticString = #filePath, line: UInt = #line) async throws -> Response {
        var body: [String: Any] = ["url": url]
        for (k, v) in extra { body[k] = v }
        let r = try await put(body)
        XCTAssertEqual(r.status, .ok, "\(r.body ?? [:])", file: file, line: line)
        return r
    }

    // MARK: Person actions (REST with the session)

    func newTask(_ title: String = "Task", project: String? = nil) async throws -> String {
        let r = try await test.json(.POST, "/v1/tasks", ["projectID": project ?? projectID, "title": title], token: session)
        XCTAssertEqual(r.status, .created, "\(r.body ?? [:])")
        return try XCTUnwrap(r.body?["id"] as? String)
    }

    /// A task that exists before the webhook is configured (its creation does not count).
    func existingTask(_ title: String = "Task", project: Project? = nil) async throws -> String {
        let t = TodoTask(ownerID: userID, projectID: try (project ?? o.project).requireID(), title: title, details: "")
        try await t.save(on: app.db)
        return try t.requireID().uuidString
    }

    @discardableResult
    func comment(_ task: String, _ text: String = "Hello", token: String? = nil) async throws -> Response {
        let r = try await test.json(.POST, "/v1/tasks/\(task)/comments", ["body": text], token: token ?? session)
        XCTAssertEqual(r.status, .created, "\(r.body ?? [:])")
        return r
    }

    func version(of task: String) async throws -> Int {
        guard let t = try await TodoTask.find(UUID(uuidString: task), on: app.db) else { throw WebhookTestError(what: "no task") }
        return t.version
    }

    func rows() async throws -> [WebhookDelivery] {
        try await WebhookDelivery.query(on: app.db).sort(\.$createdAt).sort(\.$id).all()
    }

    func endpoint() async throws -> WebhookEndpoint? { try await WebhookEndpoint.query(on: app.db).first() }
    /// The endpoint row; fails the test when there is none.
    func ep() async throws -> WebhookEndpoint {
        guard let e = try await endpoint() else { throw WebhookTestError(what: "no webhook endpoint row") }
        return e
    }
    /// The newest delivery row.
    func last() async throws -> WebhookDelivery {
        guard let r = try await rows().last else { throw WebhookTestError(what: "no delivery row") }
        return r
    }

    func worker(_ on: Application? = nil) -> WebhookWorker { WebhookWorker(app: on ?? app, interval: 0) }

    /// Makes all pending rows due (the bundle window is 60 s; tests do not wait).
    func makeDue(_ at: Date = Date().addingTimeInterval(-5)) async throws {
        try await WebhookDelivery.query(on: app.db).filter(\.$state == "pending").set(\.$dueAt, to: at).set(\.$nextAttemptAt, to: at).update()
    }

    /// One person action that is whitelisted, a bundle and a due worker run; returns the row after the run.
    func bundleAndSend(at now: Date = Date()) async throws -> WebhookDelivery {
        let task = try await existingTask()
        try await comment(task)
        try await makeDue()
        _ = try await worker().tick(now: now)
        return try await last()
    }

    // MARK: MCP (the same person's connection)

    func mcpToken() async throws -> String { try await o.tokens(scope: CommandCenterTests.scopes).access }

    func mcp(_ token: String, _ name: String, _ args: [String: Any]) async throws -> (isError: Bool, text: String, json: [String: Any]?) {
        let r = try await o.rpc("tools/call", ["name": name, "arguments": args], access: token)
        let result = try XCTUnwrap(r.body?["result"] as? [String: Any], "\(r.body ?? [:])")
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        return (result["isError"] as? Bool ?? false, text, (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any])
    }

    /// Everything the webhook may leak: all stored columns of the endpoint row, as text.
    func storedText() async throws -> String {
        try await WebhookEndpoint.query(on: app.db).all().map {
            [$0.urlCiphertext, $0.keyID, $0.urlMask, $0.signingCiphertext ?? "", $0.signingKeyID ?? ""].joined(separator: "|")
        }.joined(separator: "\n")
    }

    func shutdown() async { await test.shutdown() }
}

extension XCTestCase {
    func withWebhook(key: Bool = true, _ body: (WebhookFixture) async throws -> Void) async throws {
        let f = try await WebhookFixture.make(key: key)
        do { try await body(f) } catch { await f.shutdown(); throw error }
        await f.shutdown()
    }

    func jsonString(_ value: Any?) -> String {
        guard let value, JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value) else { return "\(value as Any)" }
        return String(decoding: data, as: UTF8.self)
    }
}
