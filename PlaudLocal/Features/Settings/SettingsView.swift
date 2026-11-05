import SwiftUI

struct SettingsView: View {
    @StateObject private var auth = PlaudAuthService()
    @AppStorage("export.nextcloudURL") private var nextcloudURL = ""
    @AppStorage("export.nextcloudUser") private var nextcloudUser = ""
    @AppStorage("export.nextcloudPath") private var nextcloudPath = "PlaudLocal"
    @AppStorage("export.autoEnabled") private var autoExport = false
    @State private var nextcloudPassword = ""
    @State private var status = ""
    @State private var showLogin = false

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

                Section("Export") {
                    Toggle("Auto-export after processing", isOn: $autoExport)
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
