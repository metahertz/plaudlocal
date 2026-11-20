import XCTest
@testable import PlaudLocal

final class WiFiFrameCodecTests: XCTestCase {
    func testEncodeDecodeRoundTrip() throws {
        let pdu = WiFiPDU.handshakeRequest(token: "abc", stamp: 1_700_000_000)
        let wire = try pdu.encode()
        XCTAssertEqual(wire[2], 0x01)
        XCTAssertEqual(wire[3], 0x01)
        let decoded = try WiFiPDU.decode(wire)
        XCTAssertEqual(decoded.type, .handshake)
        XCTAssertEqual(decoded.json["token"] as? String, WiFiPDU.padToken("abc"))
        XCTAssertEqual(decoded.json["stamp"] as? Int, 1_700_000_000)
    }

    func testFileListBinary() {
        var binary = Data()
        binary.append(ProtocolCodec.u32le(0x12345678))
        binary.append(ProtocolCodec.u32le(4096))
        binary.append(ProtocolCodec.u32le(99))
        binary.append(ProtocolCodec.u32le(2048))
        let entries = WiFiPDU.parseFileListBinary(binary)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].sessionId, 0x12345678)
        XCTAssertEqual(entries[0].size, 4096)
        XCTAssertEqual(entries[1].sessionId, 99)
        XCTAssertEqual(entries[1].size, 2048)
    }

    func testSoftAPSSID() {
        XCTAssertEqual(PlaudSoftAPSSID.resolve(serial: "ABCD1234", advertisedName: nil), "PLAUD1234")
        XCTAssertEqual(
            PlaudSoftAPSSID.resolve(serial: "ABCD1234", advertisedName: "NotePro5678"),
            "NotePro5678"
        )
        XCTAssertEqual(PlaudSoftAPSSID.fallbackPassword(serial: "ABCDEFGH12345678"), "12345678")
    }

    func testWebSocketServerBinaryFrame() {
        let payload = Data([1, 2, 3, 4, 5])
        let frame = WiFiWebSocketServer.encodeServerBinaryFrame(payload)
        XCTAssertEqual(frame[0], 0x82)
        XCTAssertEqual(frame[1], 5)
        XCTAssertEqual(Data(frame.dropFirst(2)), payload)
    }

    func testParseWiFiOpenResponse() {
        var packet = Data([0x01, 0x0a, 0x00, 0x00])
        packet.append(contentsOf: Array("pass1234\0\0\0\0".utf8))
        let parsed = ProtocolCodec.parseWiFiOpenResponse(packet)
        XCTAssertEqual(parsed?.status, 0)
        XCTAssertEqual(parsed?.password, "pass1234")
    }
}
