import SwiftUI

struct SettingsView: View {
    @StateObject private var auth = PlaudAuthService()
    @AppStorage("export.nextcloudURL") private var nextcloudURL = ""
    @AppStorage("export.nextcloudUser") private var nextcloudUser = ""
    @AppStorage("export.nextcloudPath") private var nextcloudPath = "PlaudLocal"
    @AppStorage("export.autoEnabled") private var autoExport = false
    @State private var nextcloudPassword = ""
    @State private var status = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Plaud account") {
                    if auth.isSignedIn {
                        Text("Signed in")
                        Button("Sign out", role: .destructive) {
                            try? auth.signOut()
                        }
                    } else {
                        Text("Sign in at web.plaud.ai once to fetch device keys.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("Use a future build’s WKWebView sheet to capture cookies; for now paste is out of scope in v1 UI.")
                            .font(.footnote)
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
        }
    }
}
