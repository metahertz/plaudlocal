import SwiftUI

struct SettingsView: View {
    @StateObject private var auth = PlaudAuthService()
    @AppStorage("export.nextcloudURL") private var nextcloudURL = ""
    @AppStorage("export.nextcloudUser") private var nextcloudUser = ""
    @AppStorage("export.nextcloudPath") private var nextcloudPath = "PlaudLocal"
    @AppStorage("export.autoEnabled") private var autoExport = false
    @AppStorage(ExportSettings.audioOnlyModeKey) private var audioOnlyMode = false
    @AppStorage(TranscriptionSettings.engineKey) private var asrEngineRaw = TranscriptionEngine.apple.rawValue
    @AppStorage(DeviceSessionModel.keepAwakeDuringDownloadKey) private var keepAwakeDuringDownload = false
    @AppStorage(RemoteProcessingSettings.enabledKey) private var remoteEnabled = false
    @AppStorage(RemoteProcessingSettings.serverURLKey) private var remoteURL = ""
    @AppStorage(RemoteProcessingSettings.fallbackKey) private var remoteFallback = true
    @AppStorage(RemoteProcessingSettings.transcribeKey) private var remoteTranscribe = true
    @AppStorage(RemoteProcessingSettings.summarizeKey) private var remoteSummarize = true
    @AppStorage(PipelineOptions.summarizeKey) private var summarize = true
    @AppStorage(PipelineOptions.posterKey) private var buildPoster = true
    @State private var remoteToken = ""
    @State private var remoteTokenSaved = KeyVault().load(account: RemoteProcessingSettings.tokenAccount) != nil
    @State private var remoteStatus = ""
    @State private var remoteTesting = false
    @State private var nextcloudPassword = ""
    @State private var status = ""
    @State private var showLogin = false

    private var asrEngine: Binding<TranscriptionEngine> {
        Binding(
            get: { TranscriptionEngine(rawValue: asrEngineRaw) ?? .apple },
            set: { asrEngineRaw = $0.rawValue }
        )
    }

    private var mode: Binding<ProcessingMode> {
        Binding(
            get: { audioOnlyMode ? .audioOnly : (remoteEnabled ? .remote : .onDevice) },
            set: {
                audioOnlyMode = $0 == .audioOnly
                remoteEnabled = $0 == .remote
            }
        )
    }

    /// On-device engines are in play unless every AI step is handed to the server with no fallback.
    private var usesOnDeviceAI: Bool {
        switch mode.wrappedValue {
        case .onDevice: return true
        case .audioOnly: return false
        case .remote: return remoteFallback || !remoteTranscribe || (summarize && !remoteSummarize)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if auth.isSignedIn {
                        LabeledContent("Session", value: "Signed in")
                        LabeledContent("Device keys", value: auth.hasE2EEKey ? "Saved on this iPhone" : "Missing")
                        if !auth.hasE2EEKey {
                            Button("Fetch encryption keys") {
                                Task { await refetchKeys() }
                            }
                        }
                        Button("Sign out", role: .destructive) {
                            try? auth.signOut()
                        }
                    } else {
                        Button("Sign in to Plaud…") {
                            showLogin = true
                        }
                    }
                } header: {
                    Text("Plaud account")
                } footer: {
                    Text("web.plaud.ai never shows downloadable “keys”. Sign in here; the app captures your session and downloads the encryption key pair Plaud uses for your Note Pro.")
                }

                if !auth.statusMessage.isEmpty {
                    Section {
                        Text(auth.statusMessage).font(.footnote)
                    }
                }

                Section {
                    Picker("Process recordings", selection: mode) {
                        ForEach(ProcessingMode.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    if mode.wrappedValue != .audioOnly {
                        Toggle("Summarize", isOn: $summarize)
                        Toggle("Build brief and poster", isOn: $buildPoster)
                    }
                } header: {
                    Text("Processing")
                } footer: {
                    Text(mode.wrappedValue == .audioOnly
                        ? mode.wrappedValue.detail
                        : mode.wrappedValue.detail + " The brief also names the note; without it a note keeps its recording date as its title.")
                }

                if mode.wrappedValue == .remote {
                    Section {
                        TextField("Server address, e.g. https://plaud.example.com", text: $remoteURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        SecureField(remoteTokenSaved ? "API token (saved)" : "API token", text: $remoteToken)
                        Button(remoteTesting ? "Testing…" : "Save and test connection") {
                            Task { await testRemote() }
                        }
                        .disabled(remoteTesting)
                        if !remoteStatus.isEmpty {
                            Text(remoteStatus).font(.footnote)
                        }
                        Toggle("Transcribe on the server", isOn: $remoteTranscribe)
                        Toggle("Summarize on the server", isOn: $remoteSummarize)
                            .disabled(!summarize)
                        Toggle("Use on-device AI if the server fails", isOn: $remoteFallback)
                    } header: {
                        Text("Remote server")
                    } footer: {
                        Text("The address and token are shown on the server's web page. The server must be reachable over HTTPS with a certificate this iPhone trusts. A step you switch off here runs on this iPhone instead.")
                    }
                }

                if usesOnDeviceAI {
                    Section {
                        Picker("Transcription engine", selection: asrEngine) {
                            ForEach(TranscriptionEngine.allCases) { engine in
                                Text(engine.title).tag(engine)
                            }
                        }
                        Text(asrEngine.wrappedValue.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("On-device AI")
                    } footer: {
                        Text(mode.wrappedValue == .remote
                            ? "Used for the steps that are not sent to the server, and when the server fails. Summaries use Apple Intelligence where available."
                            : "Apple Speech is on-device via SpeechAnalyzer. WhisperKit downloads a Core ML model the first time you use it. Summaries use Apple Intelligence where available.")
                    }
                }

                Section {
                    Toggle("Keep screen on while downloading", isOn: $keepAwakeDuringDownload)
                } header: {
                    Text("Device")
                } footer: {
                    Text("Prevents Auto-Lock while Plaud Local is open and a Note Pro download is in progress. The screen can still lock if you leave the app.")
                }

                Section {
                    Toggle("Auto-export after processing", isOn: $autoExport)
                        .disabled(audioOnlyMode)
                    TextField("Nextcloud WebDAV base URL", text: $nextcloudURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Username", text: $nextcloudUser)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("App password", text: $nextcloudPassword)
                    TextField("Remote folder", text: $nextcloudPath)
                    Button("Save Nextcloud password") {
                        if let data = nextcloudPassword.data(using: .utf8) {
                            try? KeyVault().save(data, account: "nextcloud.password")
                            status = "Nextcloud password saved to Keychain"
                        }
                    }
                } header: {
                    Text("Export")
                } footer: {
                    Text(audioOnlyMode
                        ? "Audio-only mode always exports: each recording's audio.ogg and metadata go to Nextcloud as soon as it is downloaded."
                        : "After processing, optionally copy the note package to Nextcloud via WebDAV.")
                }
                if !status.isEmpty {
                    Section { Text(status).font(.footnote) }
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showLogin) {
                PlaudLoginView(auth: auth)
            }
        }
    }

    private func testRemote() async {
        remoteTesting = true
        defer { remoteTesting = false }
        let enteredToken = remoteToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !enteredToken.isEmpty {
            do {
                try KeyVault().save(Data(enteredToken.utf8), account: RemoteProcessingSettings.tokenAccount)
                remoteTokenSaved = true
                remoteToken = ""
            } catch {
                remoteStatus = "Could not save the token to Keychain"
                return
            }
        }
        let settings = RemoteProcessingSettings.load()
        guard settings.serverURL != nil else {
            remoteStatus = "Enter the server address, starting with https://"
            return
        }
        guard let client = settings.connection else {
            remoteStatus = "Enter the API token from the server's web page"
            return
        }
        do {
            let health = try await client.health()
            let transcription = health.transcription ? "transcription ready" : "transcription not set up"
            let summarization = health.summarization ? "summarization ready" : "summarization not set up"
            remoteStatus = "Connected: \(transcription), \(summarization)"
        } catch {
            remoteStatus = error.localizedDescription
        }
    }

    private func refetchKeys() async {
        guard let tokenData = KeyVault().load(account: "plaud.userToken"),
              let token = String(data: tokenData, encoding: .utf8) else {
            auth.statusMessage = "No session — sign in again"
            return
        }
        do {
            try await auth.fetchAndStoreE2EEKeys(userToken: token)
            auth.hasE2EEKey = true
            auth.statusMessage = "Keys saved on this iPhone"
        } catch {
            auth.statusMessage = error.localizedDescription
        }
    }
}
