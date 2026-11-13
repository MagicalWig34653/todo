import Foundation

/// Limits of role `voice` (ADR 0030): voice memos are short.
public enum VoiceLimits {
    public static let maxBytes = 5 * 1024 * 1024
    public static let maxSeconds: UInt64 = 120
    static let mediaTypes: Set<String> = ["audio/mp4", "audio/wav"]
}

/// Reads the duration from the container itself (M4A `mvhd`, WAV `fmt `/`data`); the client's claims are never used.
/// Only boxes and chunks are walked, audio is not decoded. Anything unreadable is `invalid`.
enum AudioContainer {
    struct Invalid: Error {}

    /// Duration as `ticks / perSecond`, kept rational so the 120 s boundary is exact.
    struct Duration { let ticks: UInt64; let perSecond: UInt64
        func exceeds(seconds: UInt64) -> Bool { ticks > seconds * perSecond }
    }

    static func mediaType(_ b: [UInt8]) -> String? {
        guard b.count >= 12 else { return nil }
        if b[4..<8] == Array("ftyp".utf8)[...], m4aBrands.contains(String(decoding: b[8..<12], as: UTF8.self)) { return "audio/mp4" }
        if b[0..<4] == Array("RIFF".utf8)[...], b[8..<12] == Array("WAVE".utf8)[...] { return "audio/wav" }
        return nil
    }
    private static let m4aBrands: Set<String> = ["M4A ", "M4B ", "mp41", "mp42", "isom", "iso2"]

    static func duration(_ data: Data, mediaType: String) throws -> Duration {
        let b = [UInt8](data)
        let d: Duration
        switch mediaType {
        case "audio/mp4": d = try m4aDuration(b)
        case "audio/wav": d = try wavDuration(b)
        default: throw Invalid()
        }
        guard d.ticks > 0, d.perSecond > 0 else { throw Invalid() }
        return d
    }

    // MARK: M4A (ISO base media file format)

    private struct Box { let type: String; let body: Range<Int> }

    private static func uint(_ b: [UInt8], _ at: Int, _ n: Int, bigEndian: Bool = true) -> UInt64? {
        guard at >= 0, n > 0, at + n <= b.count else { return nil }
        let bytes = b[at..<(at + n)]
        let ordered: [UInt8] = bigEndian ? Array(bytes) : bytes.reversed()
        return ordered.reduce(0) { $0 << 8 | UInt64($1) }
    }

    private static func boxes(_ b: [UInt8], in range: Range<Int>) throws -> [Box] {
        var out: [Box] = [], pos = range.lowerBound
        while pos < range.upperBound {
            guard let size32 = uint(b, pos, 4), pos + 8 <= range.upperBound else { throw Invalid() }
            var header = 8, size = Int(size32)
            if size32 == 1 {
                guard let big = uint(b, pos + 8, 8), big <= UInt64(Int.max) else { throw Invalid() }
                header = 16; size = Int(big)
            } else if size32 == 0 {
                size = range.upperBound - pos
            }
            guard size >= header, pos + size <= range.upperBound else { throw Invalid() }
            out.append(Box(type: String(decoding: b[(pos + 4)..<(pos + 8)], as: UTF8.self), body: (pos + header)..<(pos + size)))
            pos += size
        }
        return out
    }

    private static func m4aDuration(_ b: [UInt8]) throws -> Duration {
        let top = try boxes(b, in: 0..<b.count)
        // Fragmented files keep their real length in moof/sidx boxes, so mvhd would understate it.
        guard !top.contains(where: { ["moof", "sidx", "mvex"].contains($0.type) }),
              let moov = top.first(where: { $0.type == "moov" }),
              let mvhd = try boxes(b, in: moov.body).first(where: { $0.type == "mvhd" }) else { throw Invalid() }
        let p = mvhd.body.lowerBound
        switch b[safe: p] {
        case 0:
            guard let scale = uint(b, p + 12, 4), let dur = uint(b, p + 16, 4), mvhd.body.count >= 20 else { throw Invalid() }
            return Duration(ticks: dur, perSecond: scale)
        case 1:
            guard let scale = uint(b, p + 20, 4), let dur = uint(b, p + 24, 8), mvhd.body.count >= 32 else { throw Invalid() }
            return Duration(ticks: dur, perSecond: scale)
        default: throw Invalid()
        }
    }

    // MARK: WAV (RIFF)

    private static func wavDuration(_ b: [UInt8]) throws -> Duration {
        var pos = 12, byteRate: UInt64?
        while pos + 8 <= b.count {
            let id = String(decoding: b[pos..<(pos + 4)], as: UTF8.self)
            guard let size = uint(b, pos + 4, 4, bigEndian: false) else { throw Invalid() }
            let body = pos + 8
            if id == "fmt " {
                guard size >= 16, let rate = uint(b, body + 8, 4, bigEndian: false) else { throw Invalid() }
                byteRate = rate
            } else if id == "data" {
                guard let byteRate else { throw Invalid() }
                // Streamed files may declare a bogus size; the bytes actually present bound the duration.
                return Duration(ticks: min(size, UInt64(b.count - body)), perSecond: byteRate)
            }
            let (next, overflow) = body.addingReportingOverflow(Int(size) + Int(size & 1))
            guard !overflow else { throw Invalid() }
            pos = next
        }
        throw Invalid()
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
