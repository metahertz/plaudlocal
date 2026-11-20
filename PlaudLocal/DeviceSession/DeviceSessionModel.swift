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

enum DeviceSessionError: Error, Equatable, LocalizedError {
    case needsReSignIn(String)
    case downloadInterrupted
    case offsetMismatch
    case missingSerial
    case unlockFailed(String)
    case handshakeRefused(Int)
    case syncRefused(Int)
    case incompleteDownload(got: UInt32, expected: UInt32)

    var errorDescription: String? {
        switch self {
        case .needsReSignIn(let s): return s
        case .downloadInterrupted: return "Download interrupted"
        case .offsetMismatch: return "Download offset mismatch"
        case .missingSerial: return "Could not read the device serial from Bluetooth ads — wake the Note Pro and Scan again"
        case .unlockFailed(let s): return s
        case .handshakeRefused(let code): return "Device refused handshake (status \(code)). It may be bound to another account."
        case .syncRefused(let code): return "Device refused file sync (status \(code))"
        case .incompleteDownload(let got, let expected):
            return "Incomplete download: got \(got) of \(expected) bytes"
        }
    }
}

struct DownloadProgress: Equatable {
    var sessionId: UInt32?
    var bytesReceived: UInt32 = 0
    var totalBytes: UInt32 = 0
    var batchIndex: Int = 0
    var batchCount: Int = 0
    var isActive: Bool = false
    var label: String = ""

    var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(bytesReceived) / Double(totalBytes))
    }
}

@MainActor
final class DeviceSessionModel: ObservableObject {
    @Published var connectionState: ConnectionState = .disconnected
    @Published var deviceRecordings: [DeviceRecording] = []
    @Published var statusMessage: String = ""
    @Published var discovered: [DiscoveredPeripheral] = []
    @Published var downloadProgress = DownloadProgress()
    @Published var fastTransferPhase: FastTransferPhase = .idle
    @Published var autoConnect: Bool {
        didSet { UserDefaults.standard.set(autoConnect, forKey: Self.autoConnectKey) }
    }
    @Published var autoDownload: Bool {
        didSet { UserDefaults.standard.set(autoDownload, forKey: Self.autoDownloadKey) }
    }
    @Published var deleteAfterDownload: Bool {
        didSet { UserDefaults.standard.set(deleteAfterDownload, forKey: Self.deleteAfterDownloadKey) }
    }

    private static let autoConnectKey = "device.autoConnect"
    private static let autoDownloadKey = "device.autoDownload"
    private static let deleteAfterDownloadKey = "device.deleteAfterDownload"
    static let keepAwakeDuringDownloadKey = "device.keepAwakeDuringDownload"
    private static let lastPeripheralKey = "plaud.lastPeripheralID"

    static var keepAwakeDuringDownload: Bool {
        UserDefaults.standard.bool(forKey: keepAwakeDuringDownloadKey)
    }

    private let ble: any BLEClienting
    private let keyVault: KeyVault
    private let auth: PlaudAuthService
    private var discoverTask: Task<Void, Never>?
    private var connectedPeripheralID: UUID?
    private var portVersion: Int = 20
    private var downloadCancelRequested = false
    /// Prevents overlapping download tasks from racing `BLEClient.nextPacket` waiters.
    private var downloadSessionActive = false
    /// True while `downloadAll` holds the gate, so its per-file `download` calls don't re-take it
    /// (a batch of exactly one file used to trip its own "already in progress" guard).
    private var batchHoldsGate = false
    private var fastTransferSession: WiFiFastTransferSession?
    /// Set after a successful unlock; consumed by the first auto-download for that link.
    private(set) var autoDownloadPending = false
    private var lastSerial: String? {
        get { UserDefaults.standard.string(forKey: "plaud.lastSerial") }
        set { UserDefaults.standard.set(newValue, forKey: "plaud.lastSerial") }
    }
    private var lastPeripheralID: UUID? {
        get {
            UserDefaults.standard.string(forKey: Self.lastPeripheralKey).flatMap(UUID.init)
        }
        set {
            UserDefaults.standard.set(newValue?.uuidString, forKey: Self.lastPeripheralKey)
        }
    }

    init(ble: any BLEClienting, keyVault: KeyVault, auth: PlaudAuthService? = nil, userId: String = "local") {
        self.ble = ble
        self.keyVault = keyVault
        self.auth = auth ?? PlaudAuthService(keyVault: keyVault)
        self.autoConnect = UserDefaults.standard.bool(forKey: Self.autoConnectKey)
        self.autoDownload = UserDefaults.standard.bool(forKey: Self.autoDownloadKey)
        self.deleteAfterDownload = UserDefaults.standard.bool(forKey: Self.deleteAfterDownloadKey)
        _ = userId // bind token comes from JWT `sub` at unlock time
    }

    var isDownloading: Bool {
        downloadProgress.isActive || downloadSessionActive || isFastTransferActive
    }

    var isFastTransferActive: Bool {
        switch fastTransferPhase {
        case .idle, .done, .failed: return false
        default: return true
        }
    }

    func cancelDownloads() {
        downloadCancelRequested = true
        fastTransferSession?.cancel()
    }

    /// Wi‑Fi Fast Transfer: SoftAP + WebSocket pull for recordings not already in Library.
    func fastTransfer(to directory: URL, skipping sessionIds: Set<UInt32> = []) async throws -> [URL] {
        guard connectionState == .ready else { throw WiFiTransferError.notReady }
        guard !downloadSessionActive, !isFastTransferActive else {
            statusMessage = "Transfer already in progress"
            return []
        }
        let serial: String
        if let id = connectedPeripheralID, let s = ble.serial(for: id) {
            serial = s
        } else if let saved = lastSerial {
            serial = saved
        } else {
            throw WiFiTransferError.missingSerial
        }
        let advertised = discovered.first(where: { $0.id == connectedPeripheralID })?.name
            ?? discovered.first?.name
        let known = sessionIds.isEmpty ? NoteStore().knownSessionIds() : sessionIds
        let session = WiFiFastTransferSession(ble: ble, keyVault: keyVault)
        fastTransferSession = session
        // Both sides are MainActor: apply synchronously. A deferred hop let a late
        // "transferring" update land after the final .done/.failed and re-activate the UI.
        session.onPhase = { [weak self] phase in
            guard let self else { return }
            self.fastTransferPhase = phase
            self.statusMessage = Self.statusLabel(for: phase)
            if case .transferring(let sid, let received, let total) = phase {
                var p = self.downloadProgress
                p.isActive = true
                p.sessionId = sid
                p.bytesReceived = received
                p.totalBytes = total
                p.label = self.statusMessage
                self.downloadProgress = p
            }
        }
        downloadSessionActive = true
        defer {
            downloadSessionActive = false
            fastTransferSession = nil
            var p = downloadProgress
            p.isActive = false
            downloadProgress = p
        }
        do {
            let urls = try await session.transfer(
                recordings: deviceRecordings,
                serial: serial,
                advertisedName: advertised,
                to: directory,
                skipping: known
            )
            statusMessage = urls.isEmpty
                ? "Fast Transfer — nothing new to pull"
                : "Fast Transfer downloaded \(urls.count) recording(s)"
            fastTransferPhase = .done
            return urls
        } catch {
            fastTransferPhase = .failed(error.localizedDescription)
            throw error
        }
    }

    private static func statusLabel(for phase: FastTransferPhase) -> String {
        switch phase {
        case .idle: return ""
        case .openingHotspot: return "Fast Transfer — opening device hotspot…"
        case .joinHotspotManually(let ssid, let password):
            return WiFiHotspotJoiner.manualJoinMessage(ssid: ssid, password: password)
        case .handshaking: return "Fast Transfer — handshaking…"
        case .listing: return "Fast Transfer — listing files…"
        case .transferring(let sid, let received, let total):
            let pct = total > 0 ? Int(Double(received) / Double(total) * 100) : 0
            return "Fast Transfer — session \(sid) \(pct)%"
        case .closing: return "Fast Transfer — closing…"
        case .done: return "Fast Transfer complete"
        case .failed(let s): return "Fast Transfer failed: \(s)"
        }
    }

    func resumeOffset(forPartFile url: URL) -> UInt32 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = attrs?[.size] as? NSNumber
        return size?.uint32Value ?? 0
    }

    func unlock() async throws {
        connectionState = .unlocking
        deviceRecordings = []
        ble.clearPacketBuffer()
        ble.setSession(nil)

        guard let pemData = keyVault.load(account: "plaud.rsaPrivatePEM"),
              let pem = String(data: pemData, encoding: .utf8) else {
            connectionState = .failed("Missing E2EE key — sign in under Settings first")
            throw DeviceSessionError.needsReSignIn("Missing E2EE key — sign in under Settings first")
        }
        guard let pubData = keyVault.load(account: "plaud.rsaPublicPEM"),
              let pubPEM = String(data: pubData, encoding: .utf8) else {
            connectionState = .failed("Missing E2EE public key — sign in under Settings first")
            throw DeviceSessionError.needsReSignIn("Missing E2EE public key — sign in under Settings first")
        }
        guard let tokenData = keyVault.load(account: "plaud.userToken"),
              let userToken = String(data: tokenData, encoding: .utf8) else {
            connectionState = .failed("Not signed in — open Settings")
            throw DeviceSessionError.needsReSignIn("Not signed in — open Settings")
        }

        let serial: String
        if let id = connectedPeripheralID, let s = ble.serial(for: id) {
            serial = s
        } else if let saved = lastSerial {
            serial = saved
        } else {
            connectionState = .failed(DeviceSessionError.missingSerial.localizedDescription)
            throw DeviceSessionError.missingSerial
        }

        statusMessage = "Fetching device signature…"
        let signature = try await resolveSNSign(serial: serial, userToken: userToken)

        statusMessage = "Unlocking (protocol 20)…"
        try await unlockProtocol20(signature: signature, privateKeyPEM: pem, publicKeyPEM: pubPEM)

        let bindToken = PlaudAuthService.subject(of: userToken) ?? serial
        statusMessage = "Handshaking…"
        try await handshake(token: bindToken)

        lastSerial = serial
        if let id = connectedPeripheralID {
            lastPeripheralID = id
        }
        statusMessage = "Listing recordings…"
        let files = try await listSessions()
        deviceRecordings = files
        connectionState = .ready
        autoDownloadPending = autoDownload && !files.isEmpty
        statusMessage = files.isEmpty
            ? "Ready — no recordings on device"
            : "Ready — \(files.count) recording(s)"
    }

    /// Returns true once per unlock when auto-download should run.
    func consumeAutoDownloadPending() -> Bool {
        guard autoDownloadPending else { return false }
        autoDownloadPending = false
        return true
    }

    var isLinkActive: Bool {
        switch connectionState {
        case .connecting, .connected, .unlocking, .ready:
            return true
        default:
            return false
        }
    }

    func disconnect() {
        downloadCancelRequested = true
        autoDownloadPending = false
        ble.disconnect()
        deviceRecordings = []
        connectedPeripheralID = nil
        connectionState = .disconnected
        statusMessage = "Disconnected"
        var p = downloadProgress
        p.isActive = false
        downloadProgress = p
    }

    func unlockForTests() async throws { try await unlock() }

    // MARK: - Protocol 20 unlock / handshake / list

    private func resolveSNSign(serial: String, userToken: String) async throws -> Data {
        if let cached = keyVault.load(account: "plaud.snSign.\(serial)"), !cached.isEmpty {
            return cached
        }
        do {
            try await auth.fetchSNSign(serial: serial, userToken: userToken)
        } catch {
            throw DeviceSessionError.unlockFailed("sn-sign failed: \(error.localizedDescription)")
        }
        guard let sig = keyVault.load(account: "plaud.snSign.\(serial)"), !sig.isEmpty else {
            throw DeviceSessionError.unlockFailed("sn-sign returned empty signature")
        }
        return sig
    }

    private func unlockProtocol20(signature: Data, privateKeyPEM: String, publicKeyPEM: String) async throws {
        var secretParts: [Int: Data] = [:]
        var secretTotal: Int?
        var sawFE11 = false

        func ingest(_ pkt: Data) throws {
            if SessionCrypto.isProtocol30Start(pkt) {
                throw SessionCryptoError.unsupportedProtocol30
            }
            guard let cmd = ProtocolCodec.feCommandID(of: pkt) else { return }
            if cmd == PlaudCommand.fe11.rawValue {
                sawFE11 = true
            }
            if cmd == PlaudCommand.fe12.rawValue, pkt.count >= 4 {
                sawFE11 = false
                secretTotal = Int(pkt[2])
                secretParts[Int(pkt[3])] = pkt
            }
        }

        func sendChunks(_ cmd: UInt16, _ blob: Data) async throws {
            let n = max(1, (blob.count + 99) / 100)
            for i in 0..<n {
                let start = i * 100
                let end = min((i + 1) * 100, blob.count)
                let slice = blob.subdata(in: start..<end)
                try await ble.write(ProtocolCodec.packFEChunk(cmd, total: n, index: i, slice: slice))
                do {
                    let pkt = try await ble.nextPacket(timeout: i < n - 1 ? 0.3 : 10)
                    try ingest(pkt)
                } catch BLEClientError.timeout {
                    // Note Pro usually answers only the last chunk.
                }
            }
        }

        try await sendChunks(PlaudCommand.fe10.rawValue, signature)
        if sawFE11 {
            statusMessage = "First bind — sending public key…"
            secretParts.removeAll()
            secretTotal = nil
            try await sendChunks(PlaudCommand.fe12.rawValue, Data(publicKeyPEM.utf8))
        }

        statusMessage = "Waiting for session key…"
        let deadline = Date().addingTimeInterval(15)
        while secretTotal == nil || secretParts.count < (secretTotal ?? 1) {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                throw DeviceSessionError.unlockFailed(
                    "Device did not send session key (\(secretParts.count)/\(secretTotal.map(String.init) ?? "?") parts)"
                )
            }
            let pkt = try await ble.nextPacket(timeout: remaining)
            try ingest(pkt)
        }

        let blob = secretParts.keys.sorted().reduce(into: Data()) { acc, k in
            let p = secretParts[k]!
            if p.count > 4 {
                acc.append(p.suffix(from: p.startIndex.advanced(by: 4)))
            }
        }
        let plain = try SessionCrypto.rsaDecryptPKCS1(cipher: blob, privateKeyPEM: privateKeyPEM)
        let crypto = try SessionCrypto.fromSessionSecret(plain)
        ble.setSession(crypto)
    }

    private func handshake(token: String) async throws {
        try await ble.write(ProtocolCodec.packHandshake(token: token, portVersion: portVersion, second: false))
        var rsp = try await waitCommand(
            [PlaudCommand.handshake.rawValue, PlaudCommand.getSSN.rawValue],
            timeout: 10
        )
        if ProtocolCodec.commandID(of: rsp) == PlaudCommand.getSSN.rawValue {
            statusMessage = "Second handshake…"
            try await ble.write(ProtocolCodec.packHandshake(token: token, portVersion: portVersion, second: true))
            rsp = try await waitCommand([PlaudCommand.handshake.rawValue], timeout: 10)
        }
        let status = rsp.count > 3 ? Int(rsp[3]) : -1
        guard status == 0 else {
            throw DeviceSessionError.handshakeRefused(status)
        }
        if rsp.count >= 6 {
            portVersion = Int(rsp[4]) | (Int(rsp[5]) << 8)
        }
    }

    private func listSessions() async throws -> [DeviceRecording] {
        ble.clearPacketBuffer()
        try await ble.write(ProtocolCodec.packSessionList())
        var files: [DeviceRecording] = []
        var seen = Set<UInt32>()
        var total: Int?
        while total == nil || files.count < total! {
            let b = try await waitCommand([PlaudCommand.getSessions.rawValue], timeout: 15)
            let parsed = ProtocolCodec.parseSessionListPacket(b, portVersion: portVersion)
            if total == nil { total = parsed.total }
            if parsed.index != files.count { continue }
            for (sid, size) in parsed.entries {
                if seen.insert(sid).inserted {
                    files.append(DeviceRecording(sessionId: sid, size: size))
                }
            }
            // Empty device: total can be 0.
            if total == 0 { break }
        }
        return files
    }

    private func waitCommand(_ cmds: [UInt16], timeout: TimeInterval) async throws -> Data {
        let wanted = Set(cmds)
        let deadline = Date().addingTimeInterval(timeout)
        var deferredData: [Data] = []
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                for pkt in deferredData.reversed() { ble.requeue(pkt) }
                throw BLEClientError.timeout
            }
            let pkt = try await ble.nextPacket(timeout: remaining)
            if SessionCrypto.isProtocol30Start(pkt) {
                for d in deferredData.reversed() { ble.requeue(d) }
                throw SessionCryptoError.unsupportedProtocol30
            }
            if let cmd = ProtocolCodec.commandID(of: pkt), wanted.contains(cmd) {
                for d in deferredData.reversed() { ble.requeue(d) }
                return pkt
            }
            // Hold type-2 recording chunks; drop other unsolicited command replies.
            if !pkt.isEmpty, pkt[0] == 0x02 {
                deferredData.append(pkt)
            }
        }
    }

    func download(
        recording: DeviceRecording,
        to directory: URL,
        batchIndex: Int = 1,
        batchCount: Int = 1
    ) async throws -> URL {
        // Single-file entry points own the gate; downloadAll holds it for the whole batch.
        let ownsGate = !batchHoldsGate
        if ownsGate {
            guard !downloadSessionActive else {
                statusMessage = "Download already in progress"
                throw DeviceSessionError.downloadInterrupted
            }
            downloadSessionActive = true
            downloadCancelRequested = false
        }
        defer {
            if ownsGate { downloadSessionActive = false }
        }

        do {
            return try await performDownload(
                recording: recording,
                to: directory,
                batchIndex: batchIndex,
                batchCount: batchCount
            )
        } catch {
            // Every failure path (cancel, refused sync, link loss, file I/O) must tell the
            // device to stop streaming and release the UI — not just BLE timeouts.
            try? await stopTransfer()
            if downloadCancelRequested { statusMessage = "Download cancelled" }
            var p = downloadProgress
            p.isActive = false
            downloadProgress = p
            throw error
        }
    }

    private func performDownload(
        recording: DeviceRecording,
        to directory: URL,
        batchIndex: Int,
        batchCount: Int
    ) async throws -> URL {

        let partURL = directory.appendingPathComponent("\(recording.sessionId).plaud.part")
        let finalURL = directory.appendingPathComponent("\(recording.sessionId).plaud")

        // Never reuse PlaudDownloads disk cache. Library skip is the only short-circuit
        // (handled by callers via knownSessionIds). Stale .plaud/.part files after a
        // Library delete were making "Download all" finish instantly with corrupt audio.
        try? FileManager.default.removeItem(at: finalURL)
        try? FileManager.default.removeItem(at: partURL)
        FileManager.default.createFile(atPath: partURL.path, contents: nil)

        downloadProgress = DownloadProgress(
            sessionId: recording.sessionId,
            bytesReceived: 0,
            totalBytes: recording.size,
            batchIndex: batchIndex,
            batchCount: batchCount,
            isActive: true,
            label: batchCount > 1
                ? "Downloading \(batchIndex)/\(batchCount) — session \(recording.sessionId)"
                : "Downloading session \(recording.sessionId)"
        )
        statusMessage = downloadProgress.label

        var dataCount = 0
        /// Consecutive soft resumes with no byte progress.
        var stalledResumes = 0
        var progressAtResume = dataCount
        let total = Int(recording.size)
        var lastUIUpdate = Date.distantPast
        var lastUIBytes = dataCount

        func publishProgress(force: Bool = false) {
            let now = Date()
            let bytesDelta = dataCount - lastUIBytes
            let due = now.timeIntervalSince(lastUIUpdate) >= 0.2 || bytesDelta >= 32_768
            guard force || due else { return }
            lastUIUpdate = now
            lastUIBytes = dataCount
            var p = downloadProgress
            p.bytesReceived = UInt32(dataCount)
            downloadProgress = p
            let pct = total > 0 ? dataCount * 100 / total : 0
            statusMessage = batchCount > 1
                ? "\(batchIndex)/\(batchCount) session \(recording.sessionId) — \(pct)%"
                : "Session \(recording.sessionId) — \(pct)%"
        }

        while true {
            if downloadCancelRequested {
                throw DeviceSessionError.downloadInterrupted
            }

            var outcome: PullOutcome
            var hardStall = false
            do {
                outcome = try await pullRange(
                    recording: recording,
                    from: dataCount,
                    partURL: partURL
                ) { newCount in
                    dataCount = newCount
                    publishProgress()
                }
            } catch BLEClientError.timeout {
                // No packets for a while — ask the device to stop, then hard-resume.
                hardStall = true
                statusMessage = "Download stalled at \(total > 0 ? dataCount * 100 / total : 0)%…"
                outcome = .gap
            }

            if case .finished = outcome, total == 0 || dataCount == total {
                publishProgress(force: true)
                try promotePartFile(partURL: partURL, finalURL: finalURL, expectedSize: total)
                markDownloadComplete(received: UInt32(dataCount))
                return finalURL
            }
            if total > 0, dataCount > total {
                throw DeviceSessionError.incompleteDownload(got: UInt32(dataCount), expected: recording.size)
            }
            if case .finished = outcome {
                // Tail arrived early — soft-resume from current offset.
                statusMessage = "Transfer ended early at \(total > 0 ? dataCount * 100 / total : 0)% — continuing…"
            }

            if dataCount > progressAtResume {
                stalledResumes = 0
                progressAtResume = dataCount
            } else {
                stalledResumes += 1
            }
            // Soft gaps are normal; only give up after many resumes with zero progress.
            guard stalledResumes <= 12 else {
                statusMessage = "Incomplete download: \(dataCount)/\(total) (decrypt drops: \(ble.decryptDropCount))"
                throw DeviceSessionError.incompleteDownload(got: UInt32(dataCount), expected: recording.size)
            }

            if hardStall {
                try? await stopTransfer()
            } else {
                // Soft resume: don't send stop — just restart sync from the last good offset.
                // Calling stop on every tiny gap was thrashing the link and losing in-flight packets.
                ble.clearPacketBuffer()
            }
            // Only surface "Resuming…" when we actually stalled or lost progress, not every micro-gap.
            if hardStall || stalledResumes > 0 {
                statusMessage = "Resuming download at \(total > 0 ? dataCount * 100 / total : 0)%…"
            }
            // Brief pause so the device can settle before the next sync-start.
            try? await Task.sleep(nanoseconds: hardStall ? 250_000_000 : 50_000_000)
        }
    }

    private enum PullOutcome { case finished, gap }

    /// One sync from `from` to end. Returns `.finished` on tail/end-marker, `.gap` on offset hole.
    private func pullRange(
        recording: DeviceRecording,
        from: Int,
        partURL: URL,
        onProgress: (Int) -> Void
    ) async throws -> PullOutcome {
        ble.clearPacketBuffer()
        var params = Data()
        params.append(ProtocolCodec.u32le(recording.sessionId))
        params.append(ProtocolCodec.u32le(UInt32(from)))
        params.append(ProtocolCodec.u32le(recording.size))
        try await ble.write(ProtocolCodec.packCommand(PlaudCommand.syncStart.rawValue, params: params))

        let head = try await waitCommand([PlaudCommand.syncStart.rawValue], timeout: 15)
        if let status = ProtocolCodec.syncStartStatus(of: head), status > 0 {
            throw DeviceSessionError.syncRefused(Int(status))
        }

        let handle = try FileHandle(forWritingTo: partURL)
        defer {
            try? handle.synchronize()
            try? handle.close()
        }
        try handle.seekToEnd()

        var pos = from
        var packetsSinceYield = 0
        while true {
            if downloadCancelRequested { throw DeviceSessionError.downloadInterrupted }
            // Longer timeout — brief quiet periods mid-file are normal; don't thrash resumes.
            let pkt = try await ble.nextPacket(timeout: 45)

            if pkt.count >= 3, pkt[0] == 0x01,
               ProtocolCodec.commandID(of: pkt) == PlaudCommand.syncTailOrStop.rawValue {
                return .finished
            }

            guard let parsed = ProtocolCodec.parseRecordingData(
                pkt,
                expectedSession: recording.sessionId,
                portVersion: portVersion
            ) else { continue }

            if parsed.offset == 0xFFFF_FFFF {
                return .finished
            }
            let offset = Int(parsed.offset)
            if offset < pos { continue } // duplicate / retransmit
            if offset > pos {
                // Missing bytes (often a dropped notify). Soft-resume from `pos`.
                return .gap
            }
            try handle.write(contentsOf: parsed.payload)
            pos += parsed.payload.count
            onProgress(pos)
            packetsSinceYield += 1
            if packetsSinceYield >= 32 {
                packetsSinceYield = 0
                await Task.yield()
            }
        }
    }

    private func stopTransfer() async throws {
        try await ble.write(ProtocolCodec.packCommand(PlaudCommand.syncTailOrStop.rawValue))
        // Stop ack shares cmd 29 with the transfer tail; don't wait on delete (30).
        _ = try? await waitCommand([PlaudCommand.syncTailOrStop.rawValue], timeout: 3)
        ble.clearPacketBuffer()
    }

    /// Delete a recording from the Note Pro after a successful local import.
    func deleteRecording(sessionId: UInt32) async throws {
        var params = Data()
        params.append(ProtocolCodec.u32le(sessionId))
        try await ble.write(ProtocolCodec.packCommand(PlaudCommand.deleteFile.rawValue, params: params))
        _ = try await waitCommand([PlaudCommand.deleteFileRsp.rawValue], timeout: 10)
        deviceRecordings.removeAll { $0.sessionId == sessionId }
    }

    private func promotePartFile(partURL: URL, finalURL: URL, expectedSize: Int) throws {
        if FileManager.default.fileExists(atPath: finalURL.path) {
            try FileManager.default.removeItem(at: finalURL)
        }
        try FileManager.default.moveItem(at: partURL, to: finalURL)
        // Use attributes — don't load the whole recording into memory just to check size.
        let size = (try? FileManager.default.attributesOfItem(atPath: finalURL.path)[.size] as? NSNumber)?
            .intValue ?? 0
        if expectedSize > 0, size == 0 {
            try? FileManager.default.removeItem(at: finalURL)
            throw DeviceSessionError.incompleteDownload(got: 0, expected: UInt32(expectedSize))
        }
        if expectedSize > 0, size != expectedSize {
            // Keep the partial as .part for resume; don't leave a short "final".
            try? FileManager.default.moveItem(at: finalURL, to: partURL)
            throw DeviceSessionError.incompleteDownload(got: UInt32(size), expected: UInt32(expectedSize))
        }
    }

    /// Download every listed recording that is not already in the local library.
    /// `afterEach` runs after each successful BLE transfer (before the next file) so the
    /// caller can import to Library immediately — otherwise a long ASR on file 1 blocked
    /// imports of files already sitting on disk and looked like a partial download.
    func downloadAll(
        to directory: URL,
        skipping sessionIds: Set<UInt32> = [],
        afterEach: ((DeviceRecording, URL, Int, Int) async throws -> Void)? = nil
    ) async throws -> [(recording: DeviceRecording, url: URL)] {
        guard !downloadSessionActive else {
            statusMessage = "Download already in progress"
            return []
        }
        let known = sessionIds.isEmpty ? NoteStore().knownSessionIds() : sessionIds
        let list = deviceRecordings.filter { !known.contains($0.sessionId) }
        guard !list.isEmpty else {
            statusMessage = known.isEmpty
                ? "Nothing to download"
                : "All on-device recordings are already in Library"
            var p = downloadProgress
            p.isActive = false
            p.label = statusMessage
            downloadProgress = p
            return []
        }
        downloadSessionActive = true
        batchHoldsGate = true
        downloadCancelRequested = false
        defer {
            downloadSessionActive = false
            batchHoldsGate = false
        }
        var results: [(DeviceRecording, URL)] = []
        for (idx, rec) in list.enumerated() {
            if downloadCancelRequested { break }
            if Task.isCancelled { break }
            let url = try await download(
                recording: rec,
                to: directory,
                batchIndex: idx + 1,
                batchCount: list.count
            )
            results.append((rec, url))
            if let afterEach {
                try await afterEach(rec, url, results.count, list.count)
            }
        }
        var done = downloadProgress
        done.isActive = false
        done.label = results.count == list.count
            ? "Downloaded \(results.count) recording(s)"
            : "Downloaded \(results.count) of \(list.count)"
        downloadProgress = done
        statusMessage = done.label
        return results
    }

    private func markDownloadComplete(received: UInt32) {
        var p = downloadProgress
        p.bytesReceived = p.totalBytes > 0 ? max(received, p.totalBytes) : received
        p.isActive = false
        p.label = "Processing…"
        downloadProgress = p
    }

    func bleScan(duration: TimeInterval = 12, allowDuringAutoConnect: Bool = false) async {
        // Never scan away an active link — that was resetting Ready and tripping auto-download.
        if isLinkActive || isDownloading { return }
        // Manual scans race auto-connect; only the auto-connect path may scan while it's enabled.
        if autoConnect, !allowDuringAutoConnect { return }

        discovered = []
        connectionState = .scanning
        statusMessage = "Scanning… Wake the Note Pro (press its button) and force-quit the official Plaud app so it releases Bluetooth."

        discoverTask?.cancel()
        discoverTask = Task { [weak self] in
            guard let self else { return }
            for await item in ble.discovered {
                if Task.isCancelled { break }
                if let idx = discovered.firstIndex(where: { $0.id == item.id }) {
                    // Prefer the update that carries a serial.
                    if discovered[idx].serial == nil, item.serial != nil {
                        discovered[idx] = item
                    } else {
                        discovered[idx] = item
                    }
                } else {
                    discovered.append(item)
                }
            }
        }

        await ble.scan(duration: duration)
        discoverTask?.cancel()
        if connectionState == .scanning {
            connectionState = .disconnected
        }
        if discovered.isEmpty {
            statusMessage = "Nothing found. Quit Plaud’s app, press the recorder’s button to wake it, keep it near the phone, then Scan again."
        } else {
            let withSerial = discovered.filter { $0.serial != nil }.count
            statusMessage = "Found \(discovered.count) device(s) (\(withSerial) with serial). Tap one to connect."
        }
    }

    /// Reconnect to the last-known device when Auto Connect is on.
    ///
    /// Protocol 20 link keys are ephemeral: each reconnect runs a fresh FE10 unlock + handshake.
    /// We only reuse the saved peripheral id / serial to *find* the device — never a prior ChaCha session.
    @discardableResult
    func autoConnectIfNeeded() async -> Bool {
        guard autoConnect else { return false }
        switch connectionState {
        case .connecting, .connected, .unlocking, .ready:
            return connectionState == .ready
        default:
            break
        }

        // 1) Fast path: CoreBluetooth still knows the saved peripheral (or already holds the link).
        //    Session crypto is always rebuilt in connect/unlock — we only reuse the peripheral id.
        if let saved = lastPeripheralID,
           let resolved = ble.resolveSavedPeripheral(id: saved) {
            statusMessage = "Auto-connect: reconnecting saved device…"
            connectedPeripheralID = resolved
            await connect(to: resolved, fromAutoConnect: true)
            if connectionState == .ready { return true }
            ble.disconnect()
            connectionState = .disconnected
            statusMessage = "Auto-connect: saved device unreachable, scanning…"
        }

        // 2) Scan and match by saved id / serial.
        if discovered.isEmpty {
            statusMessage = "Auto-connect: scanning…"
            await bleScan(duration: 10, allowDuringAutoConnect: true)
        }

        let match = pickAutoConnectTarget()
        guard let match else {
            statusMessage = lastPeripheralID == nil && lastSerial == nil
                ? "Auto-connect: no saved device yet — connect once manually with Auto connect off"
                : "Auto-connect: no known device nearby"
            return false
        }
        await connect(to: match.id, fromAutoConnect: true)
        return connectionState == .ready
    }

    private func pickAutoConnectTarget() -> DiscoveredPeripheral? {
        if let id = lastPeripheralID,
           let hit = discovered.first(where: { $0.id == id }) {
            return hit
        }
        if let serial = lastSerial,
           let hit = discovered.first(where: { $0.serial == serial }) {
            return hit
        }
        // Only auto-pick a device that advertised a serial (needed for sn-sign).
        return discovered.first(where: { $0.serial != nil })
    }

    func connect(to id: UUID, fromAutoConnect: Bool = false) async {
        // Avoid racing a second GATT session while auto-connect owns the link lifecycle.
        if autoConnect, !fromAutoConnect {
            statusMessage = "Turn off Auto connect to pick a device manually"
            return
        }
        if isLinkActive || isDownloading {
            statusMessage = "Already connected — disconnect first"
            return
        }
        connectionState = .connecting
        connectedPeripheralID = id
        statusMessage = "Connecting…"
        do {
            try await ble.connect(peripheralID: id)
            connectionState = .connected
            statusMessage = "Connected — unlocking…"
            try await unlock()
        } catch {
            connectionState = .failed(error.localizedDescription)
            statusMessage = error.localizedDescription
        }
    }
}
