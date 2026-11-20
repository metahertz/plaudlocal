import Foundation

enum WiFiTransferError: Error, LocalizedError, Equatable {
    case notReady
    case missingSessionKeys
    case missingToken
    case missingSerial
    case wifiOpenFailed(Int)
    case emptyPassword
    case hotspotJoinFailed(String)
    case timeout(String)
    case protocolError(String)
    case handshakeFailed(Int)
    case syncRejected(UInt32, Int)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notReady: return "Connect and unlock the Note Pro first"
        case .missingSessionKeys: return "Missing BLE session keys — reconnect and unlock"
        case .missingToken: return "Not signed in — open Settings"
        case .missingSerial: return "Missing device serial"
        case .wifiOpenFailed(let s): return "Device refused to open Wi‑Fi hotspot (status \(s))"
        case .emptyPassword: return "Device did not provide a hotspot password"
        case .hotspotJoinFailed(let s): return "Could not join device hotspot: \(s)"
        case .timeout(let s): return s
        case .protocolError(let s): return "Wi‑Fi transfer protocol error: \(s)"
        case .handshakeFailed(let s): return "Wi‑Fi handshake failed (status \(s))"
        case .syncRejected(let id, let s): return "Device rejected sync for session \(id) (status \(s))"
        case .cancelled: return "Fast Transfer cancelled"
        }
    }
}

enum FastTransferPhase: Equatable {
    case idle
    case openingHotspot
    /// SoftAP is up; user must join manually (no Hotspot Configuration entitlement on personal teams).
    case joinHotspotManually(ssid: String, password: String)
    case handshaking
    case listing
    case transferring(sessionId: UInt32, received: UInt32, total: UInt32)
    case closing
    case done
    case failed(String)
}

/// SoftAP SSID used by Plaud devices: prefer advertisement name if it ends in 4 digits,
/// otherwise `PLAUD` + last 4 of the serial.
enum PlaudSoftAPSSID {
    static func resolve(serial: String, advertisedName: String?) -> String {
        if let name = advertisedName?.trimmingCharacters(in: .whitespacesAndNewlines),
           name.range(of: #"^.*\d{4}$"#, options: .regularExpression) != nil {
            return name
        }
        let suffix = String(serial.suffix(4))
        return "PLAUD\(suffix)"
    }

    /// SN-derived fallback when the open response omits a password (last 8 of serial).
    static func fallbackPassword(serial: String) -> String {
        let trimmed = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 8 { return String(trimmed.suffix(8)) }
        return trimmed.padding(toLength: 8, withPad: "0", startingAt: 0)
    }
}

/// Official Fast Transfer path: BLE SoftAP open → phone joins hotspot → WS :8081 → encrypted sync.
@MainActor
final class WiFiFastTransferSession {
    private let ble: any BLEClienting
    private let keyVault: KeyVault
    private var server: WiFiWebSocketServer?
    private var crypto: SessionCrypto?
    private var bindToken: String = ""
    private var handshakeOK = false
    private var cancelRequested = false

    private var pduBuffer: [WiFiPDU] = []
    private var pduWaiter: CheckedContinuation<WiFiPDU, Error>?
    private var pduWaitGeneration: UInt64 = 0

    var onPhase: ((FastTransferPhase) -> Void)?

    init(ble: any BLEClienting, keyVault: KeyVault) {
        self.ble = ble
        self.keyVault = keyVault
    }

    func cancel() {
        cancelRequested = true
        // Also unblock the (up to 120s) wait for the device to join our WebSocket port.
        server?.cancelWaitForClient(WiFiTransferError.cancelled)
        pduWaiter?.resume(throwing: WiFiTransferError.cancelled)
        pduWaiter = nil
    }

    /// Download the given recordings over Wi‑Fi into `directory` as `.plaud` files.
    func transfer(
        recordings: [DeviceRecording],
        serial: String,
        advertisedName: String?,
        to directory: URL,
        skipping known: Set<UInt32>
    ) async throws -> [URL] {
        cancelRequested = false
        handshakeOK = false
        pduBuffer.removeAll()
        pduWaiter = nil

        guard let material = ble.sessionMaterial else {
            throw WiFiTransferError.missingSessionKeys
        }
        guard let tokenData = keyVault.load(account: "plaud.userToken"),
              let userToken = String(data: tokenData, encoding: .utf8) else {
            throw WiFiTransferError.missingToken
        }
        bindToken = PlaudAuthService.subject(of: userToken) ?? serial
        crypto = SessionCrypto.wifiLink(from: material)

        let targets = recordings.filter { !known.contains($0.sessionId) }
        guard !targets.isEmpty else {
            setPhase(.done)
            return []
        }

        setPhase(.openingHotspot)
        let password = try await openDeviceHotspot(serial: serial)
        let ssid = PlaudSoftAPSSID.resolve(serial: serial, advertisedName: advertisedName)

        defer {
            server?.stop()
            server = nil
            Task { try? await closeDeviceHotspot() }
        }

        // SoftAP needs a few seconds before it appears in Settings.
        try await Task.sleep(nanoseconds: 3_000_000_000)
        try throwIfCancelled()

        // Keep credentials on-screen while we listen — personal teams can't auto-join SoftAP.
        setPhase(.joinHotspotManually(ssid: ssid, password: password))
        let server = WiFiWebSocketServer(port: 8081)
        self.server = server
        try server.start()
        server.setBinaryHandler { [weak self] data in
            await self?.handleIncoming(data)
        }
        // Long window: user leaves the app, joins SoftAP in Settings, then returns.
        try await server.waitForClient(timeout: 120)
        try throwIfCancelled()

        setPhase(.handshaking)
        try await runHandshake()
        try throwIfCancelled()

        setPhase(.listing)
        var queue = targets
        if let listed = try? await fetchFileList() {
            // The device's list is untrusted input — a repeated session id must not trap.
            let byId = Dictionary(listed.map { ($0.sessionId, $0) }, uniquingKeysWith: { first, _ in first })
            queue = targets.compactMap { rec in
                if let hit = byId[rec.sessionId] { return hit }
                return rec
            }
        }

        var urls: [URL] = []
        for rec in queue {
            try throwIfCancelled()
            setPhase(.transferring(sessionId: rec.sessionId, received: 0, total: rec.size))
            let url = try await syncFile(rec, to: directory) { received, total in
                self.setPhase(.transferring(sessionId: rec.sessionId, received: received, total: total))
            }
            urls.append(url)
        }

        setPhase(.closing)
        setPhase(.done)
        return urls
    }

    // MARK: - BLE SoftAP

    private func openDeviceHotspot(serial: String) async throws -> String {
        ble.clearPacketBuffer()
        try await ble.write(ProtocolCodec.packWiFiOpen())
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            try throwIfCancelled()
            let pkt = try await ble.nextPacket(timeout: max(0.5, deadline.timeIntervalSinceNow))
            if let parsed = ProtocolCodec.parseWiFiOpenResponse(pkt) {
                guard parsed.status == 0 else { throw WiFiTransferError.wifiOpenFailed(parsed.status) }
                if !parsed.password.isEmpty { return parsed.password }
                let fallback = PlaudSoftAPSSID.fallbackPassword(serial: serial)
                guard fallback.count == 8 else { throw WiFiTransferError.emptyPassword }
                return fallback
            }
        }
        throw WiFiTransferError.timeout("Timed out waiting for device hotspot credentials")
    }

    private func closeDeviceHotspot() async throws {
        guard ble.isLinkConnected else { return }
        try? await ble.write(ProtocolCodec.packWiFiClose())
    }

    // MARK: - WS protocol

    private func handleIncoming(_ wire: Data) async {
        guard var crypto else { return }
        do {
            let plain = try crypto.open(wire)
            self.crypto = crypto
            let pdu = try WiFiPDU.decode(plain)
            if let waiter = pduWaiter {
                pduWaiter = nil
                pduWaitGeneration &+= 1
                waiter.resume(returning: pdu)
            } else {
                pduBuffer.append(pdu)
            }
        } catch {
            // Drop undecryptable / malformed frames.
        }
    }

    private func send(_ pdu: WiFiPDU) throws {
        guard var crypto, let server else {
            throw WiFiTransferError.protocolError("Wi‑Fi link not ready")
        }
        let plain = try pdu.encode()
        let sealed = try crypto.seal(plain)
        self.crypto = crypto
        server.sendBinary(sealed)
    }

    private func nextPDU(timeout: TimeInterval) async throws -> WiFiPDU {
        if !pduBuffer.isEmpty {
            return pduBuffer.removeFirst()
        }
        pduWaitGeneration &+= 1
        let generation = pduWaitGeneration
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<WiFiPDU, Error>) in
            self.pduWaiter = cont
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard self.pduWaitGeneration == generation, let waiter = self.pduWaiter else { return }
                self.pduWaiter = nil
                waiter.resume(throwing: WiFiTransferError.timeout("Timed out waiting for Wi‑Fi response"))
            }
        }
    }

    private func runHandshake() async throws {
        let first = try await nextPDU(timeout: 20)
        if first.type == .sayHello {
            try send(WiFiPDU.helloAck(token: bindToken))
        } else if first.type == .handshake {
            let status = intValue(first.json["status"]) ?? -1
            if status == 0 {
                handshakeOK = true
                return
            }
        } else if first.type == .heartbeat {
            try send(WiFiPDU.heartbeatPong())
        }

        try send(WiFiPDU.handshakeRequest(token: bindToken))
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let pdu = try await nextPDU(timeout: max(1, deadline.timeIntervalSinceNow))
            switch pdu.type {
            case .sayHello:
                try send(WiFiPDU.helloAck(token: bindToken))
            case .heartbeat:
                try send(WiFiPDU.heartbeatPong())
            case .handshake:
                let status = intValue(pdu.json["status"]) ?? -1
                guard status == 0 else { throw WiFiTransferError.handshakeFailed(status) }
                handshakeOK = true
                return
            default:
                continue
            }
        }
        throw WiFiTransferError.timeout("Wi‑Fi handshake timed out")
    }

    private func fetchFileList() async throws -> [DeviceRecording] {
        try send(WiFiPDU.getFileList())
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let pdu = try await nextPDU(timeout: max(1, deadline.timeIntervalSinceNow))
            switch pdu.type {
            case .heartbeat:
                try send(WiFiPDU.heartbeatPong())
            case .getFileList:
                let entries = WiFiPDU.parseFileListBinary(pdu.binary)
                return entries.map { DeviceRecording(sessionId: $0.sessionId, size: $0.size) }
            default:
                continue
            }
        }
        throw WiFiTransferError.timeout("File list timed out")
    }

    private func syncFile(
        _ recording: DeviceRecording,
        to directory: URL,
        onProgress: @MainActor (UInt32, UInt32) -> Void
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let partURL = directory.appendingPathComponent("\(recording.sessionId).plaud.part")
        let finalURL = directory.appendingPathComponent("\(recording.sessionId).plaud")
        try? FileManager.default.removeItem(at: partURL)
        FileManager.default.createFile(atPath: partURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partURL)
        defer { try? handle.close() }

        try send(WiFiPDU.fileSync(sessionId: recording.sessionId, scene: 1, start: 0, end: 0))

        var expectedTotal = recording.size
        var received: UInt32 = 0
        let deadlineIdle: TimeInterval = 30
        var lastData = Date()

        while true {
            try throwIfCancelled()
            if Date().timeIntervalSince(lastData) > deadlineIdle {
                throw WiFiTransferError.timeout("File transfer stalled for session \(recording.sessionId)")
            }
            let pdu = try await nextPDU(timeout: 15)
            switch pdu.type {
            case .heartbeat:
                try send(WiFiPDU.heartbeatPong())
            case .fileSync:
                let status = intValue(pdu.json["status"]) ?? -1
                if let total = intValue(pdu.json["totalSize"]) ?? intValue(pdu.json["size"]) {
                    expectedTotal = UInt32(total)
                }
                if status != 0 {
                    throw WiFiTransferError.syncRejected(recording.sessionId, status)
                }
            case .fileSyncContent:
                let offset = UInt32(intValue(pdu.json["offset"]) ?? Int(received))
                let size = intValue(pdu.json["size"]) ?? pdu.binary.count
                let last = (intValue(pdu.json["last"]) ?? 0) != 0
                guard pdu.binary.count == size || size == 0 else {
                    throw WiFiTransferError.protocolError("Sync content size mismatch")
                }
                if offset > received {
                    // A skipped range would leave a zero-filled hole in a file we then call complete.
                    throw WiFiTransferError.protocolError(
                        "Missing data for session \(recording.sessionId) (got offset \(offset), expected \(received))"
                    )
                }
                if offset != received {
                    try handle.seek(toOffset: UInt64(offset))
                }
                if !pdu.binary.isEmpty {
                    try handle.write(contentsOf: pdu.binary)
                    received = max(received, offset + UInt32(pdu.binary.count))
                    lastData = Date()
                    onProgress(received, expectedTotal)
                }
                if last || (expectedTotal > 0 && received >= expectedTotal) {
                    try handle.close()
                    try requireComplete(received: received, expected: expectedTotal, recording: recording)
                    try? FileManager.default.removeItem(at: finalURL)
                    try FileManager.default.moveItem(at: partURL, to: finalURL)
                    try? send(WiFiPDU.fileSyncStop(sessionId: recording.sessionId))
                    return finalURL
                }
            case .fileSyncStop:
                try handle.close()
                if received == 0 {
                    throw WiFiTransferError.protocolError("Transfer stopped with no data")
                }
                // A device-side abort (low battery, internal error) must not be promoted as a full file.
                try requireComplete(received: received, expected: expectedTotal, recording: recording)
                try? FileManager.default.removeItem(at: finalURL)
                try FileManager.default.moveItem(at: partURL, to: finalURL)
                return finalURL
            case .wifiClose:
                throw WiFiTransferError.protocolError("Device closed Wi‑Fi during transfer")
            default:
                continue
            }
        }
    }

    // MARK: - Helpers

    /// Only a file with every expected byte may be renamed from `.part` to `.plaud`.
    private func requireComplete(received: UInt32, expected: UInt32, recording: DeviceRecording) throws {
        guard expected > 0, received < expected else { return }
        throw WiFiTransferError.protocolError(
            "Transfer for session \(recording.sessionId) ended early (\(received) of \(expected) bytes)"
        )
    }

    private func setPhase(_ phase: FastTransferPhase) {
        onPhase?(phase)
    }

    private func throwIfCancelled() throws {
        if cancelRequested || Task.isCancelled { throw WiFiTransferError.cancelled }
    }

    private func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }
}
