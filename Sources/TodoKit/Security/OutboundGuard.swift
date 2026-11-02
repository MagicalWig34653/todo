import Foundation
import NIOCore
import NIOPosix

/// How strictly server-initiated connections (SMTP, S3) are restricted (ADR 0025, addendum "Zielschutz").
enum OutboundProtection: String, Sendable, CaseIterable {
    /// No restriction.
    case off
    /// Blocks link-local and cloud metadata addresses (169.254.0.0/16, fe80::/10, fd00:ec2::254, 0.0.0.0/8). Default.
    case standard
    /// Additionally blocks loopback and private networks (10/8, 172.16/12, 192.168/16, 100.64/10, fc00::/7).
    case strict
}

/// A target that the configured protection forbids. Carries no host, address or server text.
struct OutboundBlocked: Error, CustomStringConvertible, Sendable {
    var description: String { "outbound_target_blocked" }
}

/// The host did not resolve to any address.
struct OutboundUnresolvable: Error, Sendable {}

enum OutboundGuard {
    /// Classifies a numeric address (IPv4 dotted or IPv6 text) against the protection level.
    static func isBlocked(_ ip: String, _ protection: OutboundProtection) -> Bool {
        guard protection != .off else { return false }
        guard let bytes = octets(ip) else { return true }  // unparseable: fail closed
        return isBlocked(bytes: bytes, protection)
    }

    static func isBlocked(bytes: [UInt8], _ protection: OutboundProtection) -> Bool {
        guard protection != .off else { return false }
        if bytes.count == 16 {
            // IPv4-mapped (::ffff:a.b.c.d) addresses are judged by the embedded IPv4 address.
            let prefixZero = bytes[0..<10].allSatisfy { $0 == 0 }
            let mapped = bytes[10] == 0xff && bytes[11] == 0xff
            if prefixZero, mapped, bytes[12...15].contains(where: { $0 != 0 }) {
                return isBlocked(bytes: Array(bytes[12...15]), protection)
            }
            let unspecified = bytes.allSatisfy { $0 == 0 }
            let loopback = bytes[0..<15].allSatisfy { $0 == 0 } && bytes[15] == 1
            let linkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
            let awsMetadata = bytes[0] == 0xfd && bytes[1] == 0x00 && bytes[2] == 0x0e && bytes[3] == 0xc2
                && bytes[4..<14].allSatisfy { $0 == 0 } && bytes[14] == 0x02 && bytes[15] == 0x54
            if unspecified || linkLocal || awsMetadata { return true }
            guard protection == .strict else { return false }
            return loopback || (bytes[0] & 0xfe) == 0xfc
        }
        guard bytes.count == 4 else { return true }
        let a = bytes[0], b = bytes[1]
        if a == 0 || (a == 169 && b == 254) { return true }
        guard protection == .strict else { return false }
        return a == 127 || a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) || (a == 100 && (64...127).contains(b))
    }

    private static func octets(_ ip: String) -> [UInt8]? {
        var host = ip
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 { return withUnsafeBytes(of: &v6) { Array($0) } }
        return nil
    }

    /// Resolves `host` (A and AAAA) and returns the address to connect to. Blocked addresses are skipped,
    /// and the caller connects to exactly the returned IP, so a second DNS answer cannot redirect the connection.
    static func resolve(host: String, port: Int, protection: OutboundProtection, group: any EventLoopGroup) async throws -> SocketAddress {
        let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        var addresses: [SocketAddress] = []
        if let literal = try? SocketAddress(ipAddress: bare, port: port) {
            addresses = [literal]
        } else {
            let found = await Task.detached { lookup(bare, port: port) }.value
            addresses = found
        }
        guard !addresses.isEmpty else { throw OutboundUnresolvable() }
        // Connect to the first allowed address only: a name that also resolves to a blocked address
        // (e.g. fe80::1 for "localhost") stays usable, but never reaches the blocked one.
        guard let allowed = addresses.first(where: { address in address.ipAddress.map { !isBlocked($0, protection) } ?? false }) else {
            throw OutboundBlocked()
        }
        return allowed
    }

    /// Blocking `getaddrinfo` (A and AAAA), numeric results only.
    private static func lookup(_ host: String, port: Int) -> [SocketAddress] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if canImport(Glibc) || canImport(Musl)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        var head: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &head) == 0, let first = head else { return [] }
        defer { freeaddrinfo(head) }
        var out: [SocketAddress] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor {
            var buffer = [CChar](repeating: 0, count: 64)
            if let sa = entry.pointee.ai_addr,
               getnameinfo(sa, entry.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0,
               let address = try? SocketAddress(ipAddress: String(cString: buffer), port: port) {
                out.append(address)
            }
            cursor = entry.pointee.ai_next
        }
        return out
    }

    /// Checks all addresses of `host` without connecting (for URLSession based clients; the check and the
    /// connection resolve separately, which is documented as a residual risk in ADR 0025).
    static func check(host: String, port: Int, protection: OutboundProtection) async throws {
        guard protection != .off else { return }
        _ = try await resolve(host: host, port: port, protection: protection, group: MultiThreadedEventLoopGroup.singleton)
    }
}
