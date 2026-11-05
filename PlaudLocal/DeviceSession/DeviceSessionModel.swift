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

enum DeviceSessionError: Error, Equatable {
    case needsReSignIn(String)
    case downloadInterrupted
    case offsetMismatch
}

@MainActor
final class DeviceSessionModel: ObservableObject {
    @Published var connectionState: ConnectionState = .disconnected
    @Published var deviceRecordings: [DeviceRecording] = []
    @Published var statusMessage: String = ""
    @Published var discoveredPeripheralIDs: [UUID] = []

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

    /// Protocol-20 unlock gate: abort immediately on protocol-30 start packet.
    func unlock() async throws {
        connectionState = .unlocking
        guard keyVault.load(account: "plaud.rsaPrivatePEM") != nil else {
            connectionState = .failed("Missing E2EE key — sign in again to re-fetch keys")
            throw DeviceSessionError.needsReSignIn("Missing E2EE key — sign in again to re-fetch keys")
        }

        for await packet in ble.notifications() {
            if SessionCrypto.isProtocol30Start(packet) {
                connectionState = .failed("Unsupported firmware (protocol 30)")
                throw SessionCryptoError.unsupportedProtocol30
            }
            // First non-P30 packet: treat unlock handshake as started/ok for v1 gate.
            break
        }
        connectionState = .ready
    }

    /// Back-compat test name.
    func unlockForTests() async throws { try await unlock() }

    func download(recording: DeviceRecording, to directory: URL) async throws -> URL {
        let partURL = directory.appendingPathComponent("\(recording.sessionId).plaud.part")
        let finalURL = directory.appendingPathComponent("\(recording.sessionId).plaud")
        var expectedOffset = resumeOffset(forPartFile: partURL)

        var params = Data()
        params.append(contentsOf: withUnsafeBytes(of: recording.sessionId.littleEndian) { Data($0) })
        params.append(contentsOf: withUnsafeBytes(of: expectedOffset.littleEndian) { Data($0) })
        params.append(contentsOf: withUnsafeBytes(of: UInt32(0xFFFF_FFFF).littleEndian) { Data($0) })
        let cmd = ProtocolCodec.packCommand(PlaudCommand.syncStart.rawValue, params: params)
        try await ble.write(cmd)

        if !FileManager.default.fileExists(atPath: partURL.path) {
            FileManager.default.createFile(atPath: partURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: partURL)
        defer { try? handle.close() }
        try handle.seekToEnd()

        var sawEnd = false
        for await raw in ble.notifications() {
            switch ProtocolCodec.parseNotify(raw) {
            case let .recordingData(sessionId, offset, payload):
                if let sessionId, sessionId != recording.sessionId {
                    continue
                }
                if offset == 0xFFFF_FFFF {
                    sawEnd = true
                    try handle.close()
                    if FileManager.default.fileExists(atPath: finalURL.path) {
                        try FileManager.default.removeItem(at: finalURL)
                    }
                    try FileManager.default.moveItem(at: partURL, to: finalURL)
                    return finalURL
                }
                // Only accept the next contiguous chunk; ignore stale/wrong offsets.
                guard offset == expectedOffset else { continue }
                try handle.write(contentsOf: payload)
                expectedOffset &+= UInt32(payload.count)
            default:
                continue
            }
        }
        if !sawEnd {
            statusMessage = "Download interrupted — reopen to resume from offset \(expectedOffset)"
            throw DeviceSessionError.downloadInterrupted
        }
        throw DeviceSessionError.downloadInterrupted
    }

    func bleScan() async {
        connectionState = .connecting
        statusMessage = "Scanning for Plaud Note Pro…"
        await ble.scan()
        // Scan alone does not imply connection; leave ready for user to connect.
        connectionState = .disconnected
    }

    func connect(to id: UUID) async {
        connectionState = .connecting
        do {
            try await ble.connect(peripheralID: id)
            connectionState = .connected
            try await unlock()
        } catch {
            connectionState = .failed(error.localizedDescription)
        }
    }
}
