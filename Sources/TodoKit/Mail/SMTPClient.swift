import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import Vapor

// MARK: - Transport abstraction

struct MailMessage: Sendable, Equatable {
    var to: String
    var subject: String
    var text: String
    var html: String
}

/// Why a delivery failed. Carries no server text, address or credential, so it is safe to log and store.
struct MailSendError: Error, Equatable, CustomStringConvertible, Sendable {
    enum Stage: String, Sendable { case blocked, connect, tls, auth, sender, recipient, data, timeout, protocolError = "protocol", message }
    let stage: Stage
    /// SMTP reply code when the server answered with one.
    let code: Int?
    /// 5xx at recipient/data stage (or an unusable message): retrying cannot help.
    var isPermanent: Bool {
        if stage == .message { return true }
        guard let code, (500...599).contains(code) else { return false }
        return stage == .recipient || stage == .data
    }
    var description: String { code.map { "\(stage.rawValue)_\($0)" } ?? stage.rawValue }
}

/// Everything that touches the network. Tests replace it; production uses `SMTPClient`.
protocol MailTransport: Sendable {
    func send(_ message: MailMessage) async throws
}

// MARK: - Message building

enum MailFormat {
    /// RFC 2047 encoded-words (UTF-8, base64), split so that no word exceeds 75 characters. Plain ASCII passes through.
    static func encodedHeader(_ value: String) -> String {
        if value.utf8.allSatisfy({ (32...126).contains($0) && $0 != 61 && $0 != 63 }) { return value }
        var words: [String] = [], chunk = ""
        for scalar in value.unicodeScalars {
            if chunk.utf8.count + String(scalar).utf8.count > 30, !chunk.isEmpty {
                words.append("=?UTF-8?B?\(Data(chunk.utf8).base64EncodedString())?="); chunk = ""
            }
            chunk.unicodeScalars.append(scalar)
        }
        if !chunk.isEmpty { words.append("=?UTF-8?B?\(Data(chunk.utf8).base64EncodedString())?=") }
        return words.joined(separator: "\r\n ")
    }

    static func quotedPrintable(_ body: String) -> String {
        let normalized = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return normalized.components(separatedBy: "\n").map { line in
            var out = "", length = 0
            let bytes = Array(line.utf8)
            for (i, byte) in bytes.enumerated() {
                let trailingSpace = (byte == 32 || byte == 9) && i == bytes.count - 1
                let token = ((33...126).contains(byte) && byte != 61) || ((byte == 32 || byte == 9) && !trailingSpace)
                    ? String(UnicodeScalar(byte)) : String(format: "=%02X", byte)
                if length + token.count > 73 { out += "=\r\n"; length = 0 }
                out += token; length += token.count
            }
            return out
        }.joined(separator: "\r\n")
    }

    static func dotStuff(_ value: String) -> String {
        value.components(separatedBy: "\r\n").map { $0.hasPrefix(".") ? "." + $0 : $0 }.joined(separator: "\r\n")
    }

    /// The DATA payload including the terminating `<CRLF>.<CRLF>`: multipart/alternative (text first, HTML last).
    static func data(config: MailConfig, message: MailMessage, now: Date = Date(), id: UUID = UUID()) throws -> String {
        guard MailAddress.isValid(message.to), !message.subject.utf8.contains(13), !message.subject.utf8.contains(10) else {
            throw MailSendError(stage: .message, code: nil)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let domain = config.from.split(separator: "@").last.map(String.init) ?? "localhost"
        let boundary = "=_todolino_" + id.uuidString.replacingOccurrences(of: "-", with: "")
        let headers = [
            "From: \(encodedHeader(config.fromName)) <\(config.from)>",
            "To: <\(message.to)>",
            "Subject: \(encodedHeader(message.subject))",
            "Date: \(formatter.string(from: now))",
            "Message-ID: <\(id.uuidString.lowercased())@\(domain)>",
            "Auto-Submitted: auto-generated",
            "MIME-Version: 1.0",
            "Content-Type: multipart/alternative; boundary=\"\(boundary)\"",
        ]
        func part(_ type: String, _ value: String) -> String {
            "--\(boundary)\r\nContent-Type: \(type); charset=UTF-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n\(quotedPrintable(value))\r\n"
        }
        let content = part("text/plain", message.text) + part("text/html", message.html) + "--\(boundary)--"
        return dotStuff(headers.joined(separator: "\r\n") + "\r\n\r\n" + content) + "\r\n.\r\n"
    }
}

// MARK: - SMTP client

struct SMTPReply: Sendable, Equatable {
    var code: Int
    var lines: [String]
}

/// Splits the byte stream into (possibly multi-line) SMTP replies.
final class SMTPReplyDecoder: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let continuation: AsyncThrowingStream<SMTPReply, any Error>.Continuation
    private var buffer = ""
    private var lines: [String] = []
    private var code: Int?
    private var total = 0

    init(_ continuation: AsyncThrowingStream<SMTPReply, any Error>.Continuation) { self.continuation = continuation }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var bytes = unwrapInboundIn(data)
        buffer += bytes.readString(length: bytes.readableBytes) ?? ""
        guard buffer.utf8.count <= 65_536 else { return fail(context, .protocolError) }
        // SMTP lines end in CRLF, which Swift treats as one Character: search for the pair, not for "\n".
        while let end = buffer.range(of: "\r\n") {
            let line = String(buffer[..<end.lowerBound]); buffer.removeSubrange(..<end.upperBound)
            let raw = Array(line.utf8)
            guard raw.count >= 4, raw.count <= 1024, let c = Int(String(line.prefix(3))), raw[3] == 32 || raw[3] == 45,
                  code == nil || code == c else { return fail(context, .protocolError) }
            code = c; total += raw.count
            guard total <= 65_536 else { return fail(context, .protocolError) }
            lines.append(String(line.dropFirst(4)))
            if raw[3] == 32 {
                continuation.yield(SMTPReply(code: c, lines: lines))
                lines = []; code = nil; total = 0
            }
        }
    }

    private func fail(_ context: ChannelHandlerContext, _ stage: MailSendError.Stage) {
        continuation.finish(throwing: MailSendError(stage: stage, code: nil))
        context.close(promise: nil)
    }
    func channelInactive(context: ChannelHandlerContext) {
        continuation.finish(throwing: MailSendError(stage: .protocolError, code: nil))
        context.fireChannelInactive()
    }
    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        continuation.finish(throwing: MailSendError(stage: error is NIOSSLError ? .tls : .connect, code: nil))
        context.close(promise: nil)
    }
}

/// Minimal SMTP submission client (RFC 5321 + STARTTLS RFC 3207 + AUTH PLAIN/LOGIN RFC 4954) on SwiftNIO.
/// One connection per message. Timeouts: 10 s connect, `timeout` for the whole dialog. Errors are reduced to
/// `MailSendError`, so neither server text, addresses nor credentials can reach a log.
struct SMTPClient: MailTransport {
    let config: MailConfig
    var timeout: TimeAmount = .seconds(30)
    var group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    private let tlsContext: NIOSSLContext?

    init(config: MailConfig, timeout: TimeAmount = .seconds(30), group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton) throws {
        self.config = config; self.timeout = timeout; self.group = group
        if config.security == .none { tlsContext = nil } else {
            var tls = TLSConfiguration.makeClientConfiguration()
            tls.minimumTLSVersion = .tlsv12
            tlsContext = try NIOSSLContext(configuration: tls)
        }
    }

    func send(_ message: MailMessage) async throws {
        let payload = try MailFormat.data(config: config, message: message)
        guard MailAddress.isValid(config.from) else { throw MailSendError(stage: .message, code: nil) }
        let deadline = timeout
        try await withThrowingTaskGroup(of: Void.self) { tasks in
            tasks.addTask { try await self.dialog(to: message.to, payload: payload) }
            tasks.addTask {
                try await Task.sleep(nanoseconds: UInt64(deadline.nanoseconds))
                throw MailSendError(stage: .timeout, code: nil)
            }
            defer { tasks.cancelAll() }
            _ = try await tasks.next()
        }
    }

    private var serverName: String? { (try? SocketAddress(ipAddress: config.host, port: 0)) == nil ? config.host : nil }

    private func dialog(to recipient: String, payload: String) async throws {
        let (stream, continuation) = AsyncThrowingStream<SMTPReply, any Error>.makeStream()
        let context = tlsContext, name = serverName, implicit = config.security == .tls
        let channel: any Channel
        let target: SocketAddress
        do {
            target = try await OutboundGuard.resolve(host: config.host, port: config.port, protection: config.protection, group: group)
        } catch is OutboundBlocked {
            throw MailSendError(stage: .blocked, code: nil)
        } catch {
            throw MailSendError(stage: .connect, code: nil)
        }
        do {
            channel = try await ClientBootstrap(group: group).connectTimeout(.seconds(10))
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        if implicit, let context {
                            try channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: context, serverHostname: name))
                        }
                        try channel.pipeline.syncOperations.addHandler(SMTPReplyDecoder(continuation))
                    }
                }
                .connect(to: target).get()
        } catch {
            throw MailSendError(stage: .connect, code: nil)
        }
        defer { channel.close(promise: nil) }
        var replies = stream.makeAsyncIterator()

        func write(_ line: String) async throws {
            var buffer = channel.allocator.buffer(capacity: line.utf8.count + 2)
            buffer.writeString(line.hasSuffix("\r\n") ? line : line + "\r\n")
            do { try await channel.writeAndFlush(buffer) } catch { throw MailSendError(stage: .connect, code: nil) }
        }
        func read(_ stage: MailSendError.Stage, expect: Set<Int>) async throws -> SMTPReply {
            guard let reply = try await replies.next() else { throw MailSendError(stage: stage, code: nil) }
            guard expect.contains(reply.code) else { throw MailSendError(stage: stage, code: reply.code) }
            return reply
        }
        func ehlo(_ stage: MailSendError.Stage) async throws -> [String] {
            try await write("EHLO todolino.local")
            return try await read(stage, expect: [250]).lines.map { $0.uppercased() }
        }

        _ = try await read(implicit ? .tls : .connect, expect: [220])
        var caps = try await ehlo(implicit ? .tls : .connect)
        if config.security == .starttls {
            guard caps.contains(where: { $0 == "STARTTLS" }), let context else { throw MailSendError(stage: .tls, code: nil) }
            try await write("STARTTLS")
            _ = try await read(.tls, expect: [220])
            do {
                try await channel.eventLoop.submit {
                    try channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: context, serverHostname: name), position: .first)
                }.get()
            } catch { throw MailSendError(stage: .tls, code: nil) }
            caps = try await ehlo(.tls)
        }
        if let user = config.user, let password = config.password {
            let mechanisms = caps.first { $0.hasPrefix("AUTH ") || $0.hasPrefix("AUTH=") }.map { $0.dropFirst(5).split(separator: " ").map(String.init) } ?? []
            func b64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }
            if mechanisms.contains("PLAIN") {
                try await write("AUTH PLAIN " + b64("\0" + user + "\0" + password))
                _ = try await read(.auth, expect: [235])
            } else if mechanisms.contains("LOGIN") {
                try await write("AUTH LOGIN")
                _ = try await read(.auth, expect: [334])
                try await write(b64(user))
                _ = try await read(.auth, expect: [334])
                try await write(b64(password))
                _ = try await read(.auth, expect: [235])
            } else {
                throw MailSendError(stage: .auth, code: nil)
            }
        }
        try await write("MAIL FROM:<\(config.from)>")
        _ = try await read(.sender, expect: [250])
        try await write("RCPT TO:<\(recipient)>")
        _ = try await read(.recipient, expect: [250, 251])
        try await write("DATA")
        _ = try await read(.data, expect: [354])
        try await write(payload)
        _ = try await read(.data, expect: [250])
        // The server has accepted the message; a failing QUIT must never turn this into a retry.
        try? await write("QUIT")
    }
}

extension Application {
    private struct MailTransportKey: StorageKey { typealias Value = Locked<(any MailTransport)?> }
    /// nil while mail is disabled. Tests assign a double; the settings runtime replaces it on a hot reload.
    var mailTransport: (any MailTransport)? {
        get { lockedBox(MailTransportKey.self, nil).value }
        set { lockedBox(MailTransportKey.self, nil).value = newValue }
    }
}
