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
                    Picker("Engine", selection: asrEngine) {
                        ForEach(TranscriptionEngine.allCases) { engine in
                            Text(engine.title).tag(engine)
                        }
                    }
                    Text(asrEngine.wrappedValue.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Transcription")
                } footer: {
                    Text(remoteEnabled
                        ? "Used when the remote server can't process a recording. Apple Speech is on-device via SpeechAnalyzer. WhisperKit downloads a Core ML model the first time you use it."
                        : "Apple Speech is on-device via SpeechAnalyzer. WhisperKit downloads a Core ML model the first time you use it.")
                }

                Section {
                    Toggle("Process on a remote server", isOn: $remoteEnabled)
                    if remoteEnabled {
                        TextField("Server address, e.g. http://192.168.1.20:8080", text: $remoteURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        SecureField(remoteTokenSaved ? "API token (saved)" : "API token", text: $remoteToken)
                        Toggle("Use on-device AI if the server fails", isOn: $remoteFallback)
                        Button(remoteTesting ? "Testing…" : "Save and test connection") {
                            Task { await testRemote() }
                        }
                        .disabled(remoteTesting)
                        if !remoteStatus.isEmpty {
                            Text(remoteStatus).font(.footnote)
                        }
                    }
                } header: {
                    Text("Remote processing")
                } footer: {
                    Text("Sends each recording's audio to your own Plaud Remote server, which transcribes and summarizes it with the models you configured there, then returns the text to this iPhone. The address and token are shown in the server's web page. Plain http:// only works for servers on your local network.")
                }

                Section {
                    Toggle("Keep screen on while downloading", isOn: $keepAwakeDuringDownload)
                } header: {
                    Text("Device")
                } footer: {
                    Text("Prevents Auto-Lock while Plaud Local is open and a Note Pro download is in progress. The screen can still lock if you leave the app.")
                }

                Section {
                    Toggle("Upload audio only (skip on-device AI)", isOn: $audioOnlyMode)
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
                        ? "Downloads decrypt and upload audio.ogg (+ metadata) to Nextcloud without on-device transcription or summarization — use your own larger AI tools. You can still run Transcribe & summarize later from a note. Configure Nextcloud below."
                        : "After on-device processing, optionally copy the note package to Nextcloud via WebDAV.")
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
            remoteStatus = "Enter the server address, starting with http:// or https://"
            return
        }
        guard let client = settings.client else {
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
