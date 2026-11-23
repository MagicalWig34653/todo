import Foundation

/// Target policy of the webhook: `OutboundGuard` at level strict (loopback, private, link-local, CGNAT, metadata, IPv4-mapped IPv6 by
/// the embedded address, always, whatever the server setting for SMTP/S3 says) plus ranges that the guard does not know and that
/// either embed an IPv4 address (transition mechanisms: a tunnel or NAT64 gateway could reach an internal network through them)
/// or are never a public web server (multicast, reserved, benchmarking). The webhook is the only caller, so the guard itself
/// stays as it is for mail and S3.
enum WebhookTarget {
    static func isBlocked(_ ip: String) -> Bool {
        if OutboundGuard.isBlocked(ip, .strict) { return true }
        guard let bytes = octets(ip) else { return true }  // unparseable: fail closed
        if bytes.count == 4 { return isBlockedIPv4(bytes) }
        guard bytes.count == 16 else { return true }
        // IPv4-compatible (::a.b.c.d, deprecated), NAT64 well-known prefix (64:ff9b::/96) and 6to4 (2002::/16): judged by the embedded IPv4.
        if bytes[0..<12].allSatisfy({ $0 == 0 }) { return OutboundGuard.isBlocked(bytes: Array(bytes[12...15]), .strict) || isBlockedIPv4(Array(bytes[12...15])) }
        if bytes[0] == 0x00, bytes[1] == 0x64, bytes[2] == 0xff, bytes[3] == 0x9b, bytes[4..<12].allSatisfy({ $0 == 0 }) {
            return OutboundGuard.isBlocked(bytes: Array(bytes[12...15]), .strict) || isBlockedIPv4(Array(bytes[12...15]))
        }
        // Local-use NAT64 (64:ff9b:1::/48) and Teredo (2001:0::/32) hide the IPv4 address: not allowed at all.
        if bytes[0] == 0x00, bytes[1] == 0x64, bytes[2] == 0xff, bytes[3] == 0x9b, bytes[4] == 0x00, bytes[5] == 0x01 { return true }
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x00, bytes[3] == 0x00 { return true }
        if bytes[0] == 0x20, bytes[1] == 0x02 {
            let embedded = Array(bytes[2..<6])
            return OutboundGuard.isBlocked(bytes: embedded, .strict) || isBlockedIPv4(embedded)
        }
        if bytes[0] == 0xff { return true }                                // multicast
        if bytes[0] == 0xfe, (bytes[1] & 0xc0) == 0xc0 { return true }     // site-local (fec0::/10, deprecated)
        return false
    }

    private static func isBlockedIPv4(_ b: [UInt8]) -> Bool {
        if b[0] >= 224 { return true }                                     // multicast and reserved, incl. broadcast
        if b[0] == 192, b[1] == 0, b[2] == 0 { return true }               // IETF protocol assignments
        if b[0] == 198, (b[1] & 0xfe) == 18 { return true }                // benchmarking 198.18.0.0/15
        return false
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
}
