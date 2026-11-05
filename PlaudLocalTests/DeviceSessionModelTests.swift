import XCTest
@testable import PlaudLocal

final class DeviceSessionModelTests: XCTestCase {
    @MainActor
    func test_protocol30_aborts() async {
        let ble = MockBLEClient(notifyChunks: [Data([0xFE, 0x30, 0x01])])
        let model = DeviceSessionModel(
            ble: ble,
            keyVault: KeyVault(service: "com.local.plaudlocal.tests.device"),
            userId: "testid"
        )
        do {
            try await model.unlockForTests()
            XCTFail("expected protocol 30 abort")
        } catch SessionCryptoError.unsupportedProtocol30 {
            // expected
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    @MainActor
    func test_download_resume_offset() async throws {
        let ble = MockBLEClient(notifyChunks: [])
        let model = DeviceSessionModel(
            ble: ble,
            keyVault: KeyVault(service: "com.local.plaudlocal.tests.device2"),
            userId: "testid"
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
    var notifyChunks: [Data]
    private(set) var writes: [Data] = []

    init(notifyChunks: [Data]) {
        self.notifyChunks = notifyChunks
    }

    func scan() async {}
    func connect(peripheralID: UUID) async throws {}
    func write(_ data: Data) async throws { writes.append(data) }
    func notifications() -> AsyncStream<Data> {
        AsyncStream { continuation in
            for chunk in notifyChunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }
}
