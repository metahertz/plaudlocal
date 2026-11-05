import XCTest
@testable import PlaudLocal

final class ProtocolCodecTests: XCTestCase {
    func test_packHandshake() {
        let token = String(repeating: "a", count: 32)
        let params = Data([0x02, 0x00, 0x00]) + Data(token.utf8)
        let packed = ProtocolCodec.packCommand(PlaudCommand.handshake.rawValue, params: params)
        XCTAssertEqual(packed[0], 0x01)
        XCTAssertEqual(UInt16(packed[1]) | (UInt16(packed[2]) << 8), PlaudCommand.handshake.rawValue)
        XCTAssertEqual(Array(packed[3...5]), [0x02, 0x00, 0x00])
        XCTAssertEqual(String(bytes: packed[6...], encoding: .utf8), token)
    }

    func test_parseCommandNotify() {
        let data = Data([0x01, 0x1a, 0x00, 0x01, 0x02, 0x03])
        guard case let .command(cmd, fields) = ProtocolCodec.parseNotify(data) else {
            return XCTFail("expected command packet")
        }
        XCTAssertEqual(cmd, PlaudCommand.getSessions.rawValue)
        XCTAssertEqual(fields, Data([0x01, 0x02, 0x03]))
    }
}
