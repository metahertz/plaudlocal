import SwiftUI
import WebKit

struct PlaudLoginView: View {
    @ObservedObject var auth: PlaudAuthService
    @Environment(\.dismiss) private var dismiss
    @State private var errorText: String?
    @State private var isFinishing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("Sign in on the Plaud website below. Keys are not listed on that site — after you sign in, this app fetches them automatically.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding()
                PlaudWebView(onWebViewReady: { webView in
                    // retained by coordinator via binding below
                    _ = webView
                }, webViewBox: $webView)
                if let errorText {
                    Text(errorText).foregroundStyle(.red).font(.footnote).padding(.horizontal)
                }
                if !auth.statusMessage.isEmpty {
                    Text(auth.statusMessage).font(.footnote).padding(.bottom, 4)
                }
            }
            .navigationTitle("Plaud sign-in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isFinishing ? "Working…" : "I’m signed in") {
                        Task { await finish() }
                    }
                    .disabled(isFinishing || webView == nil)
                }
            }
        }
    }

    @State private var webView: WKWebView?

    private func finish() async {
        guard let webView else { return }
        isFinishing = true
        defer { isFinishing = false }
        do {
            try await auth.completeSignIn(from: webView)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

struct PlaudWebView: UIViewRepresentable {
    var onWebViewReady: (WKWebView) -> Void
    @Binding var webViewBox: WKWebView?

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.load(URLRequest(url: URL(string: "https://web.plaud.ai")!))
        DispatchQueue.main.async {
            webViewBox = webView
            onWebViewReady(webView)
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
