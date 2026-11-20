import XCTest
@testable import PlaudLocal

final class ProtocolCodecTests: XCTestCase {
    func test_packHandshake() {
        let token = String(repeating: "a", count: 32)
        let packed = ProtocolCodec.packHandshake(token: token, portVersion: 20, second: false)
        XCTAssertEqual(packed[0], 0x01)
        XCTAssertEqual(UInt16(packed[1]) | (UInt16(packed[2]) << 8), PlaudCommand.handshake.rawValue)
        XCTAssertEqual(Array(packed[3...5]), [0x02, 0x00, 0x00])
        XCTAssertEqual(String(bytes: packed[6...], encoding: .utf8), token)
    }

    func test_packHandshake_padsWithAsciiZero() {
        let packed = ProtocolCodec.packHandshake(token: "abc", portVersion: 20)
        // Must keep trailing ASCII '0' padding (bug: old packCommand stripped them).
        XCTAssertEqual(packed.count, 1 + 2 + 3 + 32)
        XCTAssertEqual(packed.last, 0x30)
    }

    func test_packFEChunk() {
        let chunk = ProtocolCodec.packFEChunk(0xFE10, total: 2, index: 0, slice: Data([0xAA, 0xBB]))
        XCTAssertEqual(Array(chunk.prefix(4)), [0x10, 0xFE, 2, 0])
        XCTAssertEqual(Array(chunk.suffix(2)), [0xAA, 0xBB])
    }

    func test_parseCommandNotify() {
        let data = Data([0x01, 0x1a, 0x00, 0x01, 0x02, 0x03])
        guard case let .command(cmd, fields) = ProtocolCodec.parseNotify(data) else {
            return XCTFail("expected command packet")
        }
        XCTAssertEqual(cmd, PlaudCommand.getSessions.rawValue)
        XCTAssertEqual(fields, Data([0x01, 0x02, 0x03]))
    }

    func test_parseSessionList_empty() {
        // [01][1a 00][?][?][?][?][total=0 LE][idx=0 LE]
        var pkt = Data([0x01, 0x1a, 0x00, 0, 0, 0, 0])
        pkt.append(contentsOf: [0, 0]) // total
        pkt.append(contentsOf: [0, 0]) // index
        let parsed = ProtocolCodec.parseSessionListPacket(pkt, portVersion: 20)
        XCTAssertEqual(parsed.total, 0)
        XCTAssertTrue(parsed.entries.isEmpty)
    }
}
