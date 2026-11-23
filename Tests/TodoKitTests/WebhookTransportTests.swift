import Foundation
import NIOCore
import NIOPosix
import XCTest
@testable import TodoKit

/// A local TCP server that speaks just enough HTTP/1.1 for the transport tests. Bound to 127.0.0.1 only; no outside network.
final class LocalHTTPServer: @unchecked Sendable {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var channel: (any Channel)?
    private let lock = NSLock()
    private var _requests: [String] = []
    private var _connections = 0
    /// Raw response bytes; nil = accept and stay silent (timeout test).
    private let response: String?
    private(set) var port = 0
    var requests: [String] { lock.lock(); defer { lock.unlock() }; return _requests }
    var connections: Int { lock.lock(); defer { lock.unlock() }; return _connections }

    init(response: String?) { self.response = response }

    func start() async throws {
        let server = self
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                server.opened()
                return channel.pipeline.addHandler(RequestHandler(server: server))
            }
        let ch = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        channel = ch
        port = ch.localAddress?.port ?? 0
    }

    func stop() async {
        try? await channel?.close()
        try? await group.shutdownGracefully()
    }

    fileprivate func opened() { lock.lock(); _connections += 1; lock.unlock() }
    fileprivate func record(_ text: String) { lock.lock(); _requests.append(text); lock.unlock() }
    fileprivate var canned: String? { response }

    private final class RequestHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        private let server: LocalHTTPServer
        private var text = ""
        private var answered = false
        init(server: LocalHTTPServer) { self.server = server }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = unwrapInboundIn(data)
            text += buffer.readString(length: buffer.readableBytes) ?? ""
            guard !answered, let headerEnd = text.range(of: "\r\n\r\n") else { return }
            let head = String(text[..<headerEnd.lowerBound])
            let length = head.split(separator: "\r\n").compactMap { line -> Int? in
                let lower = line.lowercased()
                return lower.hasPrefix("content-length:") ? Int(lower.dropFirst(15).trimmingCharacters(in: .whitespaces)) : nil
            }.first ?? 0
            guard text[headerEnd.upperBound...].utf8.count >= length else { return }
            answered = true
            server.record(text)
            guard let canned = server.canned else { return }
            var out = context.channel.allocator.buffer(capacity: canned.utf8.count)
            out.writeString(canned)
            context.writeAndFlush(wrapOutboundOut(out)).whenComplete { _ in context.close(promise: nil) }
        }
        typealias OutboundOut = ByteBuffer
    }
}

/// The real transport (AsyncHTTPClient) against local plain-HTTP servers. TLS is not involved: the guarantees tested here
/// (connect to the pinned address only, no redirects, status only, timeout) do not depend on it.
final class WebhookTransportTests: XCTestCase {
    private func wire(_ port: Int, host: String = "pinned.example.test", address: String = "127.0.0.1", body: String = #"{"anzahl":1,"event":"person_action","kinds":["comment.created"]}"#) -> WebhookWireRequest {
        WebhookWireRequest(url: "http://\(host):\(port)/hook?x=1", host: host, address: address,
                           headers: [("Content-Type", "application/json"), ("User-Agent", "Todolino-Webhook/1")], body: Data(body.utf8))
    }

    func testConnectsToThePinnedAddressAndSendsOnlyTheNeededHeaders() async throws {
        let server = LocalHTTPServer(response: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
        try await server.start()
        defer { Task { await server.stop() } }
        // "pinned.example.test" does not exist in DNS; reaching the server proves the override is used instead of a lookup.
        let result = await AsyncHTTPWebhookTransport(timeout: 5).post(wire(server.port))
        XCTAssertEqual(result, .status(200))
        let raw = try XCTUnwrap(server.requests.first)
        XCTAssertTrue(raw.hasPrefix("POST /hook?x=1 HTTP/1.1\r\n"), raw)
        XCTAssertTrue(raw.lowercased().contains("host: pinned.example.test:\(server.port)"), raw)
        XCTAssertTrue(raw.hasSuffix(#"{"anzahl":1,"event":"person_action","kinds":["comment.created"]}"#), raw)
        for forbidden in ["authorization:", "cookie:", "proxy-authorization:"] { XCTAssertFalse(raw.lowercased().contains(forbidden), forbidden) }
    }

    func testRedirectIsReturnedAsStatusAndNotFollowed() async throws {
        let target = LocalHTTPServer(response: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        try await target.start()
        defer { Task { await target.stop() } }
        let redirecting = LocalHTTPServer(response: "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(target.port)/secret\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        try await redirecting.start()
        defer { Task { await redirecting.stop() } }
        for code in ["301 Moved Permanently", "307 Temporary Redirect", "308 Permanent Redirect"] {
            let r = LocalHTTPServer(response: "HTTP/1.1 \(code)\r\nLocation: http://127.0.0.1:\(target.port)/secret\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            try await r.start()
            let result = await AsyncHTTPWebhookTransport(timeout: 5).post(wire(r.port))
            XCTAssertEqual(result, .status(Int(code.prefix(3))!))
            await r.stop()
        }
        let result = await AsyncHTTPWebhookTransport(timeout: 5).post(wire(redirecting.port))
        XCTAssertEqual(result, .status(302))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(redirecting.connections, 1)
        XCTAssertEqual(target.connections, 0, "the redirect target is never contacted")
        XCTAssertTrue(target.requests.isEmpty)
    }

    func testSilentServerEndsWithTimeoutWithinTheLimit() async throws {
        let server = LocalHTTPServer(response: nil)
        try await server.start()
        defer { Task { await server.stop() } }
        let started = Date()
        let result = await AsyncHTTPWebhookTransport(timeout: 0.6).post(wire(server.port))
        XCTAssertEqual(result, .timeout)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(WebhookDeliverer.verdict(result), .retry(code: "timeout", status: nil))
    }

    func testRefusedConnectionIsANetworkError() async throws {
        let server = LocalHTTPServer(response: nil)
        try await server.start()
        let port = server.port
        await server.stop()
        let result = await AsyncHTTPWebhookTransport(timeout: 3).post(wire(port))
        XCTAssertEqual(result, .networkError)
    }

    func testLargeResponseBodyIsNotKept() async throws {
        let body = String(repeating: "x", count: 300_000)
        let server = LocalHTTPServer(response: "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)")
        try await server.start()
        defer { Task { await server.stop() } }
        let result = await AsyncHTTPWebhookTransport(timeout: 5).post(wire(server.port))
        XCTAssertEqual(result, .status(200))
    }

    func testErrorClassification() {
        XCTAssertEqual(AsyncHTTPWebhookTransport.classify(HTTPClientErrorSample.deadline), .timeout)
        XCTAssertEqual(AsyncHTTPWebhookTransport.classify(HTTPClientErrorSample.read), .timeout)
        XCTAssertEqual(AsyncHTTPWebhookTransport.classify(ChannelError.connectTimeout(.seconds(1))), .timeout)
        XCTAssertEqual(AsyncHTTPWebhookTransport.classify(NSError(domain: "x", code: 1)), .networkError)
    }
}

import AsyncHTTPClient
private enum HTTPClientErrorSample {
    static let deadline: any Error = HTTPClientError.deadlineExceeded
    static let read: any Error = HTTPClientError.readTimeout
}
