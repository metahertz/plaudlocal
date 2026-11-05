import Foundation
import WebKit

enum PlaudAuthError: Error {
    case cancelled
    case missingToken
    case network(Error)
}

/// Captures Plaud web session cookies and fetches sn-sign + gen_key into KeyVault.
@MainActor
final class PlaudAuthService: NSObject, ObservableObject {
    @Published var isSignedIn = false

    private let keyVault: KeyVault
    private var webView: WKWebView?

    init(keyVault: KeyVault = KeyVault()) {
        self.keyVault = keyVault
        if keyVault.load(account: "plaud.userToken") != nil {
            isSignedIn = true
        }
    }

    func signOut() throws {
        try keyVault.delete(account: "plaud.userToken")
        try keyVault.delete(account: "plaud.refreshToken")
        isSignedIn = false
    }

    /// Stores tokens supplied by the UI after WKWebView cookie inspection.
    func storeTokens(userToken: String, refreshToken: String?) throws {
        try keyVault.save(Data(userToken.utf8), account: "plaud.userToken")
        if let refreshToken {
            try keyVault.save(Data(refreshToken.utf8), account: "plaud.refreshToken")
        }
        isSignedIn = true
    }

    func storeKeyPair(privatePEM: String, publicPEM: String) throws {
        try keyVault.save(Data(privatePEM.utf8), account: "plaud.rsaPrivatePEM")
        try keyVault.save(Data(publicPEM.utf8), account: "plaud.rsaPublicPEM")
    }

    func storeSNSign(serial: String, signature: Data) throws {
        try keyVault.save(signature, account: "plaud.snSign.\(serial)")
    }

    func makeLoginWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.load(URLRequest(url: URL(string: "https://web.plaud.ai")!))
        self.webView = webView
        return webView
    }
}
