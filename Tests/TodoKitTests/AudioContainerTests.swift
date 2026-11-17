import Foundation
import XCTest
@testable import TodoKit

final class AudioContainerTests: XCTestCase {
    /// ftyp(M4A) followed by a `moov` box whose extended size is Int.max: must be rejected, not trap on `pos + size`.
    func testExtendedBoxSizeOfIntMaxIsRejectedWithoutOverflow() throws {
        let hex = "0000000c667479704d344120000000016d6f6f767fffffffffffffff"
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        XCTAssertEqual(bytes.count, 28)
        XCTAssertEqual(AudioContainer.mediaType(bytes), "audio/mp4")
        XCTAssertThrowsError(try AudioContainer.duration(Data(bytes), mediaType: "audio/mp4")) {
            XCTAssertTrue($0 is AudioContainer.Invalid)
        }
    }
}
