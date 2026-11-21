import XCTest
@testable import PlaudLocal

final class DownloadResumeTests: XCTestCase {
    @MainActor
    func test_download_ignores_wrong_offset_and_writes_at_expected() async throws {
        // session 7, offset 100, 3 bytes payload — but part file already has 100 bytes,
        // so only payload at offset 100 should append; offset 50 must be ignored.
        func recPacket(session: UInt32, offset: UInt32, payload: [UInt8]) -> Data {
            var d = Data([0x02])
            d.append(contentsOf: withUnsafeBytes(of: session.littleEndian) { Data($0) })
            d.append(contentsOf: withUnsafeBytes(of: offset.littleEndian) { Data($0) })
            d.append(UInt8(payload.count))
            d.append(contentsOf: payload)
            return d
        }
        let end: UInt32 = 0xFFFF_FFFF
        var endPacket = Data([0x02])
        endPacket.append(contentsOf: withUnsafeBytes(of: UInt32(7).littleEndian) { Data($0) })
        endPacket.append(contentsOf: withUnsafeBytes(of: end.littleEndian) { Data($0) })
        endPacket.append(0) // len

        // Sync-start ACK (cmd 28, status 0), then data, then end marker.
        var syncAck = Data([0x01, 0x1c, 0x00])
        syncAck.append(contentsOf: withUnsafeBytes(of: UInt32(7).littleEndian) { Data($0) })
        syncAck.append(0) // status OK

        let ble = MockBLEClient(notifyChunks: [
            syncAck,
            recPacket(session: 7, offset: 50, payload: [0xFF, 0xFF]), // duplicate/behind — ignore
            recPacket(session: 7, offset: 100, payload: [0x01, 0x02, 0x03]),
            endPacket,
        ])
        let model = DeviceSessionModel(
            ble: ble,
            keyVault: KeyVault(service: "dev.metahertz.plaudlocal.tests.resume"),
            userId: "u"
        )
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let part = dir.appendingPathComponent("7.plaud.part")
        try Data(repeating: 0xAB, count: 100).write(to: part)

        let url = try await model.download(
            recording: DeviceRecording(sessionId: 7, size: 103),
            to: dir
        )
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 103)
        XCTAssertEqual(Array(data.suffix(3)), [0x01, 0x02, 0x03])
        XCTAssertFalse(data.contains(where: { $0 == 0xFF }))
    }

    @MainActor
    func test_unlock_rejects_protocol30() async throws {
        // Device answers FE10 with FE30 (LE: 30 FE).
        let ble = MockBLEClient(packetQueue: [Data([0x30, 0xFE, 0x00, 0x00])])
        let id = UUID(uuidString: "00000000-0000-0000-0000-0000000000F3")!
        ble.serials[id] = "881TESTSERIAL030"
        let vault = KeyVault(service: "dev.metahertz.plaudlocal.tests.p30")
        try vault.save(Data("pem".utf8), account: "plaud.rsaPrivatePEM")
        try vault.save(Data("pub".utf8), account: "plaud.rsaPublicPEM")
        try vault.save(Data("token".utf8), account: "plaud.userToken")
        try vault.save(Data(repeating: 0x11, count: 32), account: "plaud.snSign.881TESTSERIAL030")

        let model = DeviceSessionModel(ble: ble, keyVault: vault)
        await model.connect(to: id)
        guard case .failed(let msg) = model.connectionState else {
            return XCTFail("expected failed, got \(model.connectionState)")
        }
        XCTAssertTrue(
            msg.lowercased().contains("protocol 30") || msg.lowercased().contains("unsupported"),
            "got: \(msg)"
        )
    }
}
