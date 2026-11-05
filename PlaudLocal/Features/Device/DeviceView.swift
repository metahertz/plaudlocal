import SwiftUI

struct DeviceView: View {
    @StateObject private var model = DeviceSessionModel(
        ble: BLEClient(),
        keyVault: KeyVault(),
        userId: "local"
    )
    @State private var downloadDirectory = FileManager.default.temporaryDirectory
    @State private var lastError: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    Text(stateLabel)
                    if case .failed(let message) = model.connectionState {
                        Text(message).foregroundStyle(.red)
                    }
                    if !model.statusMessage.isEmpty {
                        Text(model.statusMessage).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("On device") {
                    if model.deviceRecordings.isEmpty {
                        Text("No recordings listed yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.deviceRecordings) { rec in
                            Button {
                                Task { await download(rec) }
                            } label: {
                                HStack {
                                    Text("Session \(rec.sessionId)")
                                    Spacer()
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(rec.size), countStyle: .file))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Device")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Scan") {
                        Task { await model.bleScan() }
                    }
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
        }
    }

    private var stateLabel: String {
        switch model.connectionState {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .unlocking: return "Unlocking…"
        case .ready: return "Ready"
        case .failed: return "Failed"
        }
    }

    private func download(_ rec: DeviceRecording) async {
        do {
            let url = try await model.download(recording: rec, to: downloadDirectory)
            var settings = ExportSettings.load()
            settings.autoExportEnabled = UserDefaults.standard.bool(forKey: "export.autoEnabled")
            let pipeline = NotePipeline(
                store: NoteStore(),
                transcriber: Transcriber(),
                summarizer: Summarizer(),
                exporter: Exporter(settings: settings)
            )
            _ = try await pipeline.processDownloadedFile(url, sessionId: rec.sessionId, duration: 0)
        } catch FileDecryptorError.needsReSignIn {
            lastError = "Missing or invalid keys — sign in again in Settings to re-fetch keys."
        } catch {
            lastError = error.localizedDescription
        }
    }
}
