import Foundation

struct DeviceRecording: Identifiable, Equatable {
    var id: UInt32 { sessionId }
    let sessionId: UInt32
    let size: UInt32
}

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case unlocking
    case ready
    case failed(String)
}

@MainActor
final class DeviceSessionModel: ObservableObject {
    @Published var connectionState: ConnectionState = .disconnected
    @Published var deviceRecordings: [DeviceRecording] = []
    @Published var statusMessage: String = ""

    private let ble: any BLEClienting
    private let keyVault: KeyVault
    private let userId: String

    init(ble: any BLEClienting, keyVault: KeyVault, userId: String) {
        self.ble = ble
        self.keyVault = keyVault
        self.userId = userId
    }

    func resumeOffset(forPartFile url: URL) -> UInt32 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = attrs?[.size] as? NSNumber
        return size?.uint32Value ?? 0
    }

    /// Test hook: consume the first notification and abort on protocol 30.
    func unlockForTests() async throws {
        connectionState = .unlocking
        for await packet in ble.notifications() {
            if SessionCrypto.isProtocol30Start(packet) {
                connectionState = .failed("Unsupported firmware (protocol 30)")
                throw SessionCryptoError.unsupportedProtocol30
            }
            break
        }
        connectionState = .ready
    }

    func download(recording: DeviceRecording, to directory: URL) async throws -> URL {
        let partURL = directory.appendingPathComponent("\(recording.sessionId).plaud.part")
        let finalURL = directory.appendingPathComponent("\(recording.sessionId).plaud")
        let start = resumeOffset(forPartFile: partURL)

        var params = Data()
        params.append(contentsOf: withUnsafeBytes(of: recording.sessionId.littleEndian) { Data($0) })
        params.append(contentsOf: withUnsafeBytes(of: start.littleEndian) { Data($0) })
        params.append(contentsOf: withUnsafeBytes(of: UInt32(0xFFFF_FFFF).littleEndian) { Data($0) })
        let cmd = ProtocolCodec.packCommand(PlaudCommand.syncStart.rawValue, params: params)
        try await ble.write(cmd)

        if !FileManager.default.fileExists(atPath: partURL.path) {
            FileManager.default.createFile(atPath: partURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: partURL)
        defer { try? handle.close() }
        try handle.seekToEnd()

        for await raw in ble.notifications() {
            switch ProtocolCodec.parseNotify(raw) {
            case let .recordingData(_, offset, payload):
                if offset == 0xFFFF_FFFF {
                    try handle.close()
                    if FileManager.default.fileExists(atPath: finalURL.path) {
                        try FileManager.default.removeItem(at: finalURL)
                    }
                    try FileManager.default.moveItem(at: partURL, to: finalURL)
                    return finalURL
                }
                try handle.write(contentsOf: payload)
            default:
                continue
            }
        }
        throw BLEClientError.notConnected
    }

    func bleScan() async {
        connectionState = .connecting
        await ble.scan()
        connectionState = .disconnected
        statusMessage = "Scanning for Plaud Note Pro…"
    }
}
