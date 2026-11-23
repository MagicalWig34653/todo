import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import Vapor

// MARK: - Seams (tests replace both)

/// Resolves a host name to one address. Production: `OutboundGuard.resolve` at level strict. The service checks the answer
/// against `OutboundGuard` again, so a replacement cannot widen the protection.
protocol WebhookResolver: Sendable {
    /// Throws `OutboundBlocked` (only blocked addresses) or `OutboundUnresolvable`.
    func resolve(host: String, port: Int) async throws -> String
}

struct SystemWebhookResolver: WebhookResolver {
    func resolve(host: String, port: Int) async throws -> String {
        let address = try await OutboundGuard.resolve(host: host, port: port, protection: .strict, group: MultiThreadedEventLoopGroup.singleton)
        guard let ip = address.ipAddress else { throw OutboundUnresolvable() }
        return ip
    }
}

/// What goes on the wire: the URL, the address to connect to (already checked) and the body. The transport must connect to
/// `address` only and must not follow redirects.
struct WebhookWireRequest: Sendable {
    let url: String
    let host: String
    let address: String
    let headers: [(String, String)]
    let body: Data
}

enum WebhookSendResult: Equatable, Sendable {
    case status(Int)
    case timeout
    case tlsError
    case networkError
    /// The request URL does not name the host the address was checked for (the pinning would not apply): nothing was sent.
    case targetBlocked
}

protocol WebhookTransport: Sendable {
    /// POSTs the body once. Only the status code comes back; a response body is never read.
    func post(_ request: WebhookWireRequest) async -> WebhookSendResult
}

// MARK: - AsyncHTTPClient implementation

/// One short-lived `HTTPClient` per request, configured for exactly this target:
/// - `dnsOverride` maps the host name to the checked address, so no second lookup happens (DNS rebinding between check and
///   connection is closed); SNI and certificate validation still use the host name;
/// - redirects are not followed (a 3xx is returned as status and counts as an error), no proxy, no cookies, no credentials;
/// - connect and total time are limited; the response body is discarded chunk by chunk.
struct AsyncHTTPWebhookTransport: WebhookTransport {
    var timeout: TimeInterval = WebhookLimits.timeout
    /// Lets tests trust a local certificate; never set in production.
    var tls: TLSConfiguration?

    /// The client configuration for exactly one target (see the type comment).
    func configuration(host: String, address: String) -> HTTPClient.Configuration {
        var config = HTTPClient.Configuration()
        config.redirectConfiguration = .disallow
        config.proxy = nil
        config.timeout = .init(connect: .milliseconds(Int64(timeout * 1000)), read: .milliseconds(Int64(timeout * 1000)))
        if let tls { config.tlsConfiguration = tls }
        if address != host { config.dnsOverride = [host: address] }
        return config
    }

    func post(_ r: WebhookWireRequest) async -> WebhookSendResult {
        let config = configuration(host: r.host, address: r.address)
        let client = HTTPClient(eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton), configuration: config)
        let delegate = StatusOnlyDelegate()
        let result: WebhookSendResult
        do {
            var headers = HTTPHeaders()
            for (name, value) in r.headers { headers.add(name: name, value: value) }
            let request = try HTTPClient.Request(url: r.url, method: .POST, headers: headers, body: .data(r.body))
            let status = try await client.execute(request: request, delegate: delegate,
                                                  deadline: .now() + .milliseconds(Int64(timeout * 1000))).get()
            result = .status(status)
        } catch {
            // The status line counts even if the body was cut off on purpose or the connection broke afterwards.
            result = delegate.status > 0 ? .status(delegate.status) : Self.classify(error)
        }
        try? await client.shutdown()
        return result
    }

    static func classify(_ error: any Error) -> WebhookSendResult {
        if let e = error as? HTTPClientError {
            if e == .deadlineExceeded || e == .readTimeout || e == .connectTimeout || e == .writeTimeout { return .timeout }
        }
        if let e = error as? ChannelError, case .connectTimeout = e { return .timeout }
        let name = String(describing: type(of: error))
        if name.contains("SSL") || name.contains("TLS") { return .tlsError }
        return .networkError
    }
}

/// Records the status line and throws the body away.
private final class StatusOnlyDelegate: HTTPClientResponseDelegate, @unchecked Sendable {
    typealias Response = Int
    private let lock = NSLock()
    private var _status = 0
    private var received = 0
    var status: Int { lock.lock(); defer { lock.unlock() }; return _status }

    func didReceiveHead(task: HTTPClient.Task<Int>, _ head: HTTPResponseHead) -> EventLoopFuture<Void> {
        lock.lock(); _status = Int(head.status.code); lock.unlock()
        return task.eventLoop.makeSucceededVoidFuture()
    }

    func didReceiveBodyPart(task: HTTPClient.Task<Int>, _ buffer: ByteBuffer) -> EventLoopFuture<Void> {
        received += buffer.readableBytes
        // Nobody reads the body: stop early instead of downloading what the target wants to stream.
        if received > 64 * 1024 { task.cancel() }
        return task.eventLoop.makeSucceededVoidFuture()
    }

    func didFinishRequest(task: HTTPClient.Task<Int>) throws -> Int { status }
}

// MARK: - Application storage

extension Application {
    private struct WebhookTransportKey: StorageKey { typealias Value = any WebhookTransport }
    private struct WebhookResolverKey: StorageKey { typealias Value = any WebhookResolver }

    /// Production default; tests set a recording transport.
    var webhookTransport: any WebhookTransport {
        get { storage[WebhookTransportKey.self] ?? AsyncHTTPWebhookTransport() }
        set { storage[WebhookTransportKey.self] = newValue }
    }

    var webhookResolver: any WebhookResolver {
        get { storage[WebhookResolverKey.self] ?? SystemWebhookResolver() }
        set { storage[WebhookResolverKey.self] = newValue }
    }

    private struct WebhookResolveTimeoutKey: StorageKey { typealias Value = TimeInterval }

    /// Upper bound for one name resolution (save and delivery). Tests shorten it.
    var webhookResolveTimeout: TimeInterval {
        get { storage[WebhookResolveTimeoutKey.self] ?? WebhookLimits.resolveTimeout }
        set { storage[WebhookResolveTimeoutKey.self] = newValue }
    }
}
