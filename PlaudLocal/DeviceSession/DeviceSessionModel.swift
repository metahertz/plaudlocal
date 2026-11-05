import Foundation

struct DeviceRecording: Identifiable, Equatable {
    var id: UInt32 { sessionId }
    let sessionId: UInt32
    let size: UInt32
}

enum ConnectionState: Equatable {
    case disconnected
    case scanning
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
    @Published var discovered: [DiscoveredPeripheral] = []

    private let ble: any BLEClienting
    private let keyVault: KeyVault
    private let userId: String
    private var discoverTask: Task<Void, Never>?

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

    func unlock() async throws {
        connectionState = .unlocking
        guard keyVault.load(account: "plaud.rsaPrivatePEM") != nil else {
            connectionState = .failed("Missing E2EE key — sign in under Settings first")
            throw DeviceSessionError.needsReSignIn("Missing E2EE key — sign in under Settings first")
        }

        for await packet in ble.notifications() {
            if SessionCrypto.isProtocol30Start(packet) {
                connectionState = .failed("Unsupported firmware (protocol 30)")
                throw SessionCryptoError.unsupportedProtocol30
            }
            break
        }
        connectionState = .ready
    }

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
                if let sessionId, sessionId != recording.sessionId { continue }
                if offset == 0xFFFF_FFFF {
                    sawEnd = true
                    try handle.close()
                    if FileManager.default.fileExists(atPath: finalURL.path) {
                        try FileManager.default.removeItem(at: finalURL)
                    }
                    try FileManager.default.moveItem(at: partURL, to: finalURL)
                    return finalURL
                }
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
        discovered = []
        connectionState = .scanning
        statusMessage = "Scanning… Wake the Note Pro (press its button) and force-quit the official Plaud app so it releases Bluetooth."

        discoverTask?.cancel()
        discoverTask = Task { [weak self] in
            guard let self else { return }
            for await item in ble.discovered {
                if Task.isCancelled { break }
                if !discovered.contains(where: { $0.id == item.id }) {
                    discovered.append(item)
                }
            }
        }

        await ble.scan(duration: 12)
        discoverTask?.cancel()
        connectionState = .disconnected
        if discovered.isEmpty {
            statusMessage = "Nothing found. Quit Plaud’s app, press the recorder’s button to wake it, keep it near the phone, then Scan again."
        } else {
            statusMessage = "Found \(discovered.count) device(s). Tap one to connect."
        }
    }

    func connect(to id: UUID) async {
        connectionState = .connecting
        statusMessage = "Connecting…"
        do {
            try await ble.connect(peripheralID: id)
            connectionState = .connected
            statusMessage = "Connected — unlocking…"
            try await unlock()
            statusMessage = "Ready"
        } catch {
            connectionState = .failed(error.localizedDescription)
            statusMessage = error.localizedDescription
        }
    }
}
