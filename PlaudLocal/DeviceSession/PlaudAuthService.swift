import Foundation
import WebKit

enum PlaudAuthError: Error, LocalizedError {
    case cancelled
    case missingToken
    case network(String)
    case decryptFailed
    case badResponse

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Sign-in cancelled"
        case .missingToken: return "No Plaud session cookie found after sign-in"
        case .network(let s): return s
        case .decryptFailed: return "Could not decrypt Plaud API response"
        case .badResponse: return "Unexpected Plaud API response"
        }
    }
}

/// In-app web login → capture `pld_ut` / `pld_urt` → fetch E2EE key pair into KeyVault.
///
/// Keys are **not** shown on web.plaud.ai. After you sign in, this app calls Plaud’s
/// private API (`gen_key`, `sn-sign`) the same way the official app does.
@MainActor
final class PlaudAuthService: NSObject, ObservableObject {
    @Published var isSignedIn = false
    @Published var hasE2EEKey = false
    @Published var statusMessage = ""

    private let keyVault: KeyVault
    /// Fernet key embedded in the Plaud Android/web client (public reverse-engineering).
    private static let fernetKeyB64 = "8rRmMCskL3NaUiGr-UsmEEeI8NKH-ZfeGbpRGqSLpuI="
    private static let apiHosts = [
        "https://api.plaud.ai",
        "https://api-apse1.plaud.ai",
        "https://api-eus1.plaud.ai",
        "https://api-euw1.plaud.ai",
    ]

    init(keyVault: KeyVault = KeyVault()) {
        self.keyVault = keyVault
        isSignedIn = keyVault.load(account: "plaud.userToken") != nil
        hasE2EEKey = keyVault.load(account: "plaud.rsaPrivatePEM") != nil
    }

    func signOut() throws {
        try keyVault.delete(account: "plaud.userToken")
        try keyVault.delete(account: "plaud.refreshToken")
        try keyVault.delete(account: "plaud.rsaPrivatePEM")
        try keyVault.delete(account: "plaud.rsaPublicPEM")
        isSignedIn = false
        hasE2EEKey = false
        statusMessage = "Signed out"
    }

    func storeTokens(userToken: String, refreshToken: String?) throws {
        try keyVault.save(Data(userToken.utf8), account: "plaud.userToken")
        if let refreshToken {
            try keyVault.save(Data(refreshToken.utf8), account: "plaud.refreshToken")
        }
        isSignedIn = true
    }

    /// After WKWebView login, read cookies and pull the E2EE key pair.
    func completeSignIn(from webView: WKWebView) async throws {
        statusMessage = "Reading session…"
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let relevant = cookies.filter {
            $0.domain.contains("plaud.ai")
        }
        let ut = relevant.first(where: { $0.name == "pld_ut" })?.value
            ?? relevant.first(where: { $0.name == "tokenstr" })?.value
        let urt = relevant.first(where: { $0.name == "pld_urt" })?.value

        guard let ut, !ut.isEmpty else {
            throw PlaudAuthError.missingToken
        }
        try storeTokens(userToken: ut, refreshToken: urt)
        statusMessage = "Fetching encryption keys…"
        try await fetchAndStoreE2EEKeys(userToken: ut)
        hasE2EEKey = true
        statusMessage = "Keys saved on this iPhone"
    }

    func fetchAndStoreE2EEKeys(userToken: String) async throws {
        var lastError: Error = PlaudAuthError.network("No API host responded")
        for host in Self.apiHosts {
            do {
                let json = try await postJSON(
                    url: URL(string: "\(host)/device-app/e2ee/gen_key")!,
                    body: Data("{}".utf8),
                    userToken: userToken
                )
                let data = json["data"] as? [String: Any] ?? json
                guard let priv = data["private_key_base64"] as? String
                        ?? data["private_key"] as? String,
                      let pub = data["public_key_base64"] as? String
                        ?? data["public_key"] as? String else {
                    throw PlaudAuthError.badResponse
                }
                let privPEM = decodePossiblyBase64PEM(priv)
                let pubPEM = decodePossiblyBase64PEM(pub)
                try keyVault.save(Data(privPEM.utf8), account: "plaud.rsaPrivatePEM")
                try keyVault.save(Data(pubPEM.utf8), account: "plaud.rsaPublicPEM")
                return
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError
    }

    func fetchSNSign(serial: String, userToken: String) async throws {
        var lastError: Error = PlaudAuthError.network("No API host responded")
        let body = try JSONSerialization.data(withJSONObject: ["sns": [serial]])
        for host in Self.apiHosts {
            do {
                let json = try await postJSON(
                    url: URL(string: "\(host)/device-app/device/sn-sign")!,
                    body: body,
                    userToken: userToken
                )
                let data = json["data"] as? [String: Any] ?? json
                let signatures = data["signature"] as? [String: String]
                    ?? data["signatures"] as? [String: String]
                guard let b64 = signatures?[serial],
                      let sig = Data(base64Encoded: b64) else {
                    throw PlaudAuthError.badResponse
                }
                try keyVault.save(sig, account: "plaud.snSign.\(serial)")
                return
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError
    }

    private func postJSON(url: URL, body: Data, userToken: String) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(userToken)", forHTTPHeaderField: "Authorization")
        request.setValue("1", forHTTPHeaderField: "X-Encrypt-Response")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PlaudAuthError.badResponse }

        // Region redirect
        if http.statusCode == 302 || http.statusCode == -302 {
            throw PlaudAuthError.network("Region redirect — try next host")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw PlaudAuthError.network("HTTP \(http.statusCode): \(text.prefix(160))")
        }

        let encrypted = http.value(forHTTPHeaderField: "x-encrypt-response") == "1"
            || (String(data: data, encoding: .utf8)?.hasPrefix("gAAAA") == true)
        let payload: Data
        if encrypted {
            payload = try decryptFernet(data)
        } else {
            payload = data
        }
        guard let obj = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw PlaudAuthError.badResponse
        }
        return obj
    }

    private static func base64URLDecode(_ string: String) -> Data? {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - s.count % 4) % 4
        s.append(String(repeating: "=", count: pad))
        return Data(base64Encoded: s, options: [.ignoreUnknownCharacters])
    }

    private func decodePossiblyBase64PEM(_ value: String) -> String {
        if value.contains("BEGIN") { return value }
        if let decoded = Data(base64Encoded: value), let s = String(data: decoded, encoding: .utf8),
           s.contains("BEGIN") {
            return s
        }
        return value
    }

    /// Minimal Fernet decrypt (AES-128-CBC + HMAC-SHA256) for Plaud API bodies.
    private func decryptFernet(_ tokenData: Data) throws -> Data {
        let token: Data
        if let s = String(data: tokenData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let b64 = Self.base64URLDecode(s) {
            token = b64
        } else if let b64 = Self.base64URLDecode(String(data: tokenData, encoding: .utf8) ?? "") {
            token = b64
        } else {
            token = tokenData
        }
        // Fernet: version(1) + timestamp(8) + iv(16) + ciphertext + hmac(32)
        guard token.count > 1 + 8 + 16 + 32, token[0] == 0x80 else {
            throw PlaudAuthError.decryptFailed
        }
        guard let key = Data(base64Encoded: Self.fernetKeyB64), key.count == 32 else {
            throw PlaudAuthError.decryptFailed
        }
        let signingKey = key.prefix(16)
        let encryptionKey = key.suffix(16)
        let hmacPart = token.suffix(32)
        let signed = token.prefix(token.count - 32)
        let expected = HMACSHA256(key: Data(signingKey), data: signed)
        guard expected == Data(hmacPart) else { throw PlaudAuthError.decryptFailed }

        let iv = token.subdata(in: 9..<25)
        let cipher = token.subdata(in: 25..<(token.count - 32))
        return try AES128CBCDecrypt(key: Data(encryptionKey), iv: iv, data: cipher)
    }
}

// MARK: - Crypto helpers (CommonCrypto via Security)

import CommonCrypto

private func HMACSHA256(key: Data, data: Data) -> Data {
    var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    data.withUnsafeBytes { dataBuf in
        key.withUnsafeBytes { keyBuf in
            CCHmac(
                CCHmacAlgorithm(kCCHmacAlgSHA256),
                keyBuf.baseAddress, key.count,
                dataBuf.baseAddress, data.count,
                &out
            )
        }
    }
    return Data(out)
}

private func AES128CBCDecrypt(key: Data, iv: Data, data: Data) throws -> Data {
    var out = Data(count: data.count + kCCBlockSizeAES128)
    var moved = 0
    let status = out.withUnsafeMutableBytes { outBuf in
        data.withUnsafeBytes { dataBuf in
            key.withUnsafeBytes { keyBuf in
                iv.withUnsafeBytes { ivBuf in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBuf.baseAddress, key.count,
                        ivBuf.baseAddress,
                        dataBuf.baseAddress, data.count,
                        outBuf.baseAddress, outBuf.count,
                        &moved
                    )
                }
            }
        }
    }
    guard status == kCCSuccess else { throw PlaudAuthError.decryptFailed }
    return out.prefix(moved)
}
