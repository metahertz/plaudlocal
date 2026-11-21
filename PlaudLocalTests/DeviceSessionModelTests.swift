import XCTest
@testable import PlaudLocal

final class DeviceSessionModelTests: XCTestCase {
    @MainActor
    func test_protocol30_aborts_during_unlock() async {
        // FE10 write → device answers with FE30.
        let ble = MockBLEClient(packetQueue: [Data([0x30, 0xFE, 0x01, 0x00])])
        let vault = KeyVault(service: "dev.metahertz.plaudlocal.tests.device.p30")
        try? vault.save(Data("-----BEGIN PRIVATE KEY-----\nMIIE\n-----END PRIVATE KEY-----".utf8), account: "plaud.rsaPrivatePEM")
        try? vault.save(Data("-----BEGIN PUBLIC KEY-----\nMIIB\n-----END PUBLIC KEY-----".utf8), account: "plaud.rsaPublicPEM")
        try? vault.save(Data("tok.payload.sig".utf8), account: "plaud.userToken")
        try? vault.save(Data(repeating: 0xAB, count: 64), account: "plaud.snSign.881TESTSERIAL01")
        ble.serials[UUID(uuidString: "00000000-0000-0000-0000-000000000001")!] = "881TESTSERIAL01"

        let model = DeviceSessionModel(ble: ble, keyVault: vault)
        // Pretend we connected to a known peripheral.
        await model.connect(to: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)

        if case .failed(let msg) = model.connectionState {
            XCTAssertTrue(
                msg.lowercased().contains("protocol 30") || msg.lowercased().contains("unsupported"),
                "got: \(msg)"
            )
        } else {
            // unlockProtocol20 throws before connect finishes — state may be failed via catch.
            XCTAssertEqual(model.connectionState, .failed(model.statusMessage))
        }
    }

    @MainActor
    func test_missing_serial_fails() async {
        let ble = MockBLEClient(packetQueue: [])
        let vault = KeyVault(service: "dev.metahertz.plaudlocal.tests.device.noserial")
        try? vault.save(Data("pem".utf8), account: "plaud.rsaPrivatePEM")
        try? vault.save(Data("pub".utf8), account: "plaud.rsaPublicPEM")
        try? vault.save(Data("token".utf8), account: "plaud.userToken")
        UserDefaults.standard.removeObject(forKey: "plaud.lastSerial")

        let model = DeviceSessionModel(ble: ble, keyVault: vault)
        await model.connect(to: UUID())
        if case .failed(let msg) = model.connectionState {
            XCTAssertTrue(msg.lowercased().contains("serial"), "got: \(msg)")
        } else {
            XCTFail("expected failed for missing serial, got \(model.connectionState)")
        }
    }

    @MainActor
    func test_download_resume_offset() async throws {
        let ble = MockBLEClient(packetQueue: [])
        let model = DeviceSessionModel(
            ble: ble,
            keyVault: KeyVault(service: "dev.metahertz.plaudlocal.tests.device2")
        )
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let part = dir.appendingPathComponent("rec.part")
        try Data(repeating: 0xAB, count: 100).write(to: part)
        let offset = model.resumeOffset(forPartFile: part)
        XCTAssertEqual(offset, 100)
    }
}

final class MockBLEClient: BLEClienting {
    var packetQueue: [Data]
    var serials: [UUID: String] = [:]
    private(set) var writes: [Data] = []
    private var session: SessionCrypto?
    var decryptDropCount: Int = 0
    var isLinkConnected: Bool = false

    init(packetQueue: [Data]) {
        self.packetQueue = packetQueue
    }

    /// Back-compat for older tests.
    convenience init(notifyChunks: [Data]) {
        self.init(packetQueue: notifyChunks)
    }

    var discovered: AsyncStream<DiscoveredPeripheral> {
        AsyncStream { $0.finish() }
    }

    func scan(duration: TimeInterval) async {}
    func stopScan() {}
    func connect(peripheralID: UUID) async throws {}
    func disconnect() { isLinkConnected = false }
    func write(_ data: Data) async throws { writes.append(data) }
    func clearPacketBuffer() {}
    func requeue(_ packet: Data) { packetQueue.insert(packet, at: 0) }
    func setSession(_ crypto: SessionCrypto?) { session = crypto }
    var sessionMaterial: SessionKeyMaterial? { session?.material }
    func serial(for peripheralID: UUID) -> String? { serials[peripheralID] }
    func resolveSavedPeripheral(id: UUID) -> UUID? { serials[id] != nil || knownIDs.contains(id) ? id : nil }
    var knownIDs: Set<UUID> = []

    func nextPacket(timeout: TimeInterval) async throws -> Data {
        if packetQueue.isEmpty { throw BLEClientError.timeout }
        return packetQueue.removeFirst()
    }

    func notifications() -> AsyncStream<Data> {
        AsyncStream { continuation in
            for chunk in packetQueue {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }
}
