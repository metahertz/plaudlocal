import SwiftUI
import UIKit

struct DeviceView: View {
    @StateObject private var model = DeviceSessionModel(
        ble: BLEClient(),
        keyVault: KeyVault()
    )
    @AppStorage(DeviceSessionModel.keepAwakeDuringDownloadKey) private var keepAwakeDuringDownload = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var downloadDirectory: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("PlaudDownloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    @State private var lastError: String?
    /// Sessions already in Library, cached so rows don't re-read every metadata.json per render.
    @State private var librarySessionIds = Set<UInt32>()
    @State private var isScanning = false
    @State private var autoDownloadTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                Section("Options") {
                    Toggle("Auto connect", isOn: $model.autoConnect)
                    Toggle("Auto download", isOn: $model.autoDownload)
                    Toggle("Delete from device after download", isOn: $model.deleteAfterDownload)
                    Text(optionsFooter)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Connection") {
                    Text(stateLabel)
                    if case .failed(let message) = model.connectionState {
                        Text(message).foregroundStyle(.red)
                    }
                    if !model.statusMessage.isEmpty {
                        Text(model.statusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if model.isLinkActive {
                        Button("Disconnect", role: .destructive) {
                            autoDownloadTask?.cancel()
                            model.disconnect()
                        }
                    } else if model.autoConnect {
                        Button("Connect now") {
                            Task { _ = await model.autoConnectIfNeeded() }
                        }
                    }
                }

                if model.isDownloading {
                    Section("Download") {
                        progressBlock
                    }
                }

                Section("Nearby") {
                    if model.autoConnect {
                        Text("Manual connect disabled while Auto connect is on")
                            .foregroundStyle(.secondary)
                    } else if model.discovered.isEmpty {
                        Text(model.isLinkActive ? "Connected — Scan disabled until you disconnect" : "No Plaud devices yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.discovered) { device in
                            Button {
                                Task { await model.connect(to: device.id) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(device.name)
                                        if let serial = device.serial {
                                            Text(serial)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        } else {
                                            Text("No serial in ad — may fail to unlock")
                                                .font(.caption2)
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                    Spacer()
                                    Text("\(device.rssi) dBm")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .disabled(model.isLinkActive || model.isDownloading || isBusyConnecting || model.autoConnect)
                        }
                    }
                }

                Section {
                    if model.deviceRecordings.isEmpty {
                        Text("No recordings listed yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.deviceRecordings) { rec in
                            let alreadyInLibrary = librarySessionIds.contains(rec.sessionId)
                            Button {
                                Task { await downloadOne(rec) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(sessionTitle(rec.sessionId))
                                        if isActiveSession(rec.sessionId) {
                                            ProgressView(value: model.downloadProgress.fraction)
                                                .tint(.accentColor)
                                        } else if alreadyInLibrary {
                                            Text("In Library")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(rec.size), countStyle: .file))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .disabled(model.isDownloading || model.connectionState != .ready || alreadyInLibrary)
                        }
                    }
                } header: {
                    HStack {
                        Text("On device")
                        Spacer()
                        if model.isDownloading {
                            Button("Cancel") {
                                model.cancelDownloads()
                            }
                            .font(.caption)
                        } else if !model.deviceRecordings.isEmpty {
                            Button("Download all") {
                                Task { await downloadAll() }
                            }
                            .font(.caption)
                            .disabled(model.connectionState != .ready)
                        }
                    }
                }

                if model.connectionState == .ready, !model.deviceRecordings.isEmpty {
                    Section {
                        Button {
                            Task { await fastTransfer() }
                        } label: {
                            HStack {
                                Image(systemName: "wifi")
                                Text("Fast Transfer")
                                Spacer()
                                if model.isFastTransferActive {
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(model.isDownloading)
                        Text("Opens the Note Pro hotspot and pulls recordings over Wi‑Fi (~10× BLE). Join that hotspot in Settings when prompted, then return — the phone leaves its usual Wi‑Fi until transfer finishes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if case .joinHotspotManually(let ssid, let password) = model.fastTransferPhase {
                            Text(WiFiHotspotJoiner.manualJoinMessage(ssid: ssid, password: password))
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .navigationTitle("Device")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(isScanning ? "Scanning…" : "Scan") {
                        Task {
                            isScanning = true
                            await model.bleScan()
                            isScanning = false
                        }
                    }
                    .disabled(
                        isScanning
                            || model.isDownloading
                            || model.isLinkActive
                            || isBusyConnecting
                            || model.autoConnect
                    )
                }
            }
            .alert("Error", isPresented: Binding(
                get: { lastError != nil },
                set: { if !$0 { lastError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(lastError ?? "")
            }
            .task {
                if model.autoConnect, !model.isLinkActive {
                    _ = await model.autoConnectIfNeeded()
                }
            }
            .onChange(of: model.connectionState) { _, newValue in
                guard newValue == .ready else { return }
                guard model.consumeAutoDownloadPending() else { return }
                // Never cancel an in-flight batch — that left later files downloaded
                // but never imported when a duplicate ready event fired.
                if model.isDownloading { return }
                if autoDownloadTask != nil { return }
                autoDownloadTask = Task {
                    await downloadAll()
                    await MainActor.run { autoDownloadTask = nil }
                }
            }
            .onChange(of: model.autoConnect) { _, enabled in
                guard enabled, !model.isLinkActive else { return }
                Task { _ = await model.autoConnectIfNeeded() }
            }
            .onChange(of: model.downloadProgress.isActive) { _, _ in
                updateIdleTimer()
            }
            .onChange(of: keepAwakeDuringDownload) { _, _ in
                updateIdleTimer()
            }
            .onChange(of: scenePhase) { _, phase in
                // Idle-timer disable only applies while the app is foregrounded.
                if phase != .active {
                    UIApplication.shared.isIdleTimerDisabled = false
                } else {
                    updateIdleTimer()
                }
            }
            .onChange(of: model.deviceRecordings.map(\.sessionId)) { _, _ in
                refreshLibraryState()
            }
            .onAppear {
                updateIdleTimer()
                refreshLibraryState()
            }
        }
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled =
            keepAwakeDuringDownload && model.isDownloading && scenePhase == .active
    }

    @ViewBuilder
    private var progressBlock: some View {
        let p = model.downloadProgress
        VStack(alignment: .leading, spacing: 8) {
            Text(p.label.isEmpty ? model.statusMessage : p.label)
                .font(.footnote)
            ProgressView(value: p.fraction)
            HStack {
                if p.batchCount > 1 {
                    Text("\(p.batchIndex) of \(p.batchCount)")
                }
                Spacer()
                Text("\(byteString(p.bytesReceived)) / \(byteString(p.totalBytes))")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var optionsFooter: String {
        var parts: [String] = []
        parts.append(model.autoConnect
            ? "Auto connect is on — Scan and manual Connect are disabled to avoid racing sessions."
            : "Auto connect uses your last Note Pro. Auto download pulls recordings not already in Library.")
        if model.deleteAfterDownload {
            parts.append("After a successful import, the Note Pro copy is deleted.")
        }
        return parts.joined(separator: " ")
    }

    private var isBusyConnecting: Bool {
        switch model.connectionState {
        case .connecting, .connected, .unlocking: return true
        default: return false
        }
    }

    private var stateLabel: String {
        switch model.connectionState {
        case .disconnected: return "Disconnected"
        case .scanning: return "Scanning…"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .unlocking: return "Unlocking…"
        case .ready: return "Ready"
        case .failed: return "Failed"
        }
    }

    /// Re-read which sessions are in Library and drop encrypted downloads that are already imported.
    private func refreshLibraryState() {
        librarySessionIds = NoteStore().knownSessionIds()
        purgeImportedDownloads()
    }

    /// The Library keeps the decrypted audio, so an imported `.plaud` is a second copy of the recording.
    private func purgeImportedDownloads() {
        guard !model.isDownloading else { return }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: downloadDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        for file in files where file.pathExtension == "plaud" {
            guard let sessionId = UInt32(file.deletingPathExtension().lastPathComponent),
                  librarySessionIds.contains(sessionId) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Call once a download is safely in Library.
    private func didImport(sessionId: UInt32, from url: URL) {
        try? FileManager.default.removeItem(at: url)
        librarySessionIds.insert(sessionId)
    }

    private func isActiveSession(_ sessionId: UInt32) -> Bool {
        model.isDownloading && model.downloadProgress.sessionId == sessionId
    }

    private func sessionTitle(_ sessionId: UInt32) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(sessionId))
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func byteString(_ n: UInt32) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }

    private func downloadOne(_ rec: DeviceRecording) async {
        if NoteStore().containsSession(rec.sessionId) {
            librarySessionIds.insert(rec.sessionId)
            model.statusMessage = "Already in Library — skipped session \(rec.sessionId)"
            return
        }
        do {
            let url = try await model.download(recording: rec, to: downloadDirectory)
            try await process(url: url, sessionId: rec.sessionId)
            await maybeDeleteFromDevice(sessionId: rec.sessionId)
            var p = model.downloadProgress
            p.isActive = false
            p.label = "Downloaded session \(rec.sessionId)"
            model.downloadProgress = p
            model.statusMessage = p.label
        } catch FileDecryptorError.needsReSignIn {
            lastError = "Missing or invalid keys — sign in again in Settings."
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func fastTransfer() async {
        do {
            let pipeline = makePipeline()
            var importedNotes: [NoteMetadata] = []
            var failures: [String] = []
            let urls = try await model.fastTransfer(to: downloadDirectory)
            for url in urls {
                let name = url.deletingPathExtension().lastPathComponent
                guard let sessionId = UInt32(name) else { continue }
                do {
                    let meta = try await pipeline.importDownloadedFile(url, sessionId: sessionId)
                    didImport(sessionId: sessionId, from: url)
                    importedNotes.append(meta)
                } catch {
                    failures.append("\(sessionId): \(error.localizedDescription)")
                }
            }
            let audioOnly = ExportSettings.load().audioOnlyMode
            for (index, meta) in importedNotes.enumerated() {
                if Task.isCancelled { break }
                model.statusMessage = audioOnly
                    ? "Uploading audio \(index + 1)/\(importedNotes.count)…"
                    : "Transcribing \(index + 1)/\(importedNotes.count)…"
                do {
                    _ = try await pipeline.enrichImportedNote(meta)
                    await maybeDeleteFromDevice(sessionId: meta.sessionId)
                } catch {
                    failures.append("\(meta.sessionId): \(error.localizedDescription)")
                }
            }
            if !failures.isEmpty {
                lastError = failures.prefix(3).joined(separator: "\n")
            }
            let imported = importedNotes.count
            model.statusMessage = imported == 0
                ? (failures.isEmpty ? model.statusMessage : "Fast Transfer import failed — see error")
                : (failures.isEmpty
                    ? (audioOnly
                        ? "Fast Transfer uploaded \(imported) recording(s)"
                        : "Fast Transfer imported \(imported) recording(s)")
                    : "Fast Transfer imported \(imported); some follow-up steps failed")
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func downloadAll() async {
        do {
            let pipeline = makePipeline()
            var importedNotes: [NoteMetadata] = []
            var failures: [String] = []

            let results = try await model.downloadAll(to: downloadDirectory) { rec, url, _, total in
                do {
                    let meta = try await pipeline.importDownloadedFile(url, sessionId: rec.sessionId)
                    didImport(sessionId: rec.sessionId, from: url)
                    importedNotes.append(meta)
                    model.statusMessage = "Imported \(importedNotes.count)/\(total) to Library"
                    var p = model.downloadProgress
                    p.isActive = false
                    p.label = model.statusMessage
                    model.downloadProgress = p
                } catch {
                    // Keep pulling remaining files even if one import fails.
                    failures.append("\(rec.sessionId): \(error.localizedDescription)")
                }
            }

            let audioOnly = ExportSettings.load().audioOnlyMode
            // Enrich after every file is in Library so a long ASR on #1 never blocks #2/#3 appearing.
            for (index, meta) in importedNotes.enumerated() {
                if Task.isCancelled { break }
                model.statusMessage = audioOnly
                    ? "Uploading audio \(index + 1)/\(importedNotes.count)…"
                    : "Transcribing \(index + 1)/\(importedNotes.count)…"
                do {
                    _ = try await pipeline.enrichImportedNote(meta)
                    await maybeDeleteFromDevice(sessionId: meta.sessionId)
                } catch {
                    failures.append("\(meta.sessionId): \(error.localizedDescription)")
                }
            }

            if !failures.isEmpty {
                lastError = failures.prefix(3).joined(separator: "\n")
            }
            let imported = importedNotes.count
            model.statusMessage = imported == 0
                ? (failures.isEmpty
                    ? (results.isEmpty ? model.statusMessage : "Import failed — see error")
                    : "Import failed — see error")
                : (failures.isEmpty
                    ? (audioOnly
                        ? "Downloaded & uploaded \(imported) recording(s)"
                        : "Downloaded & imported \(imported) recording(s)")
                    : "Imported \(imported); some follow-up steps failed")
            var p = model.downloadProgress
            p.isActive = false
            p.label = model.statusMessage
            model.downloadProgress = p
        } catch FileDecryptorError.needsReSignIn {
            lastError = "Missing or invalid keys — sign in again in Settings."
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func maybeDeleteFromDevice(sessionId: UInt32) async {
        guard model.deleteAfterDownload else { return }
        do {
            try await model.deleteRecording(sessionId: sessionId)
            model.statusMessage = "Imported & deleted session \(sessionId) from device"
        } catch {
            lastError = "Imported, but device delete failed: \(error.localizedDescription)"
        }
    }

    private func makePipeline() -> NotePipeline {
        var settings = ExportSettings.load()
        settings.autoExportEnabled = UserDefaults.standard.bool(forKey: "export.autoEnabled")
        return NotePipeline(
            store: NoteStore(),
            transcriber: Transcriber(engine: TranscriptionSettings.engine),
            summarizer: Summarizer(),
            exporter: Exporter(settings: settings)
        )
    }

    private func process(url: URL, sessionId: UInt32) async throws {
        let pipeline = makePipeline()
        // Import first so the encrypted copy can go even if transcription later fails.
        let meta = try await pipeline.importDownloadedFile(url, sessionId: sessionId, duration: 0)
        didImport(sessionId: sessionId, from: url)
        _ = try await pipeline.enrichImportedNote(meta)
    }
}
