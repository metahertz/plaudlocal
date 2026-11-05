import SwiftUI

struct DeviceView: View {
    @StateObject private var model = DeviceSessionModel(
        ble: BLEClient(),
        keyVault: KeyVault(),
        userId: "local"
    )

    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    Text(stateLabel)
                    if case .failed(let message) = model.connectionState {
                        Text(message).foregroundStyle(.red)
                    }
                }
                Section("On device") {
                    if model.deviceRecordings.isEmpty {
                        Text("No recordings listed yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.deviceRecordings) { rec in
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
            .navigationTitle("Device")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Scan") {
                        Task { await model.bleScan() }
                    }
                }
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
}
