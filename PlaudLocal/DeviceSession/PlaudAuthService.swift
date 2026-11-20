import Foundation
import WebKit
import CommonCrypto

enum PlaudAuthError: Error, LocalizedError {
    case cancelled
    case missingToken
    case network(String)
    case decryptFailed
    case badResponse

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Sign-in cancelled"
        case .missingToken: return "No Plaud session cookie found after sign-in. Stay on the logged-in page, then tap I’m signed in."
        case .network(let s): return s
        case .decryptFailed: return "Could not decrypt Plaud API response"
        case .badResponse: return "Unexpected Plaud API response"
        }
    }
}

/// In-app web login → capture `pld_ut` / `pld_urt` → fetch E2EE key pair into KeyVault.
@MainActor
final class PlaudAuthService: NSObject, ObservableObject {
    @Published var isSignedIn = false
    @Published var hasE2EEKey = false
    @Published var statusMessage = ""

    private let keyVault: KeyVault
    private var resolvedAPIHost: String?

    /// Fernet key embedded in the Plaud Android/web client (public reverse-engineering).
    private static let fernetKeyB64 = "8rRmMCskL3NaUiGr-UsmEEeI8NKH-ZfeGbpRGqSLpuI="

    /// Hosts that currently resolve in DNS and answer HTTPS.
    /// Several names in older docs (`api-aps1`, `api-use1`, …) do not resolve.
    private static let discoveryHost = "https://api.plaud.ai"
    private static let liveRegionalHosts = [
        "https://api-usw2.plaud.ai",
        "https://api-euc1.plaud.ai",
        "https://api-apse1.plaud.ai",
        "https://api-apne1.plaud.ai",
    ]

    /// Prefer live hosts. Unmapped / dead doc names fall through to discovery.
    private static let regionToHost: [String: String] = [
        "aws:us-west-2": "https://api-usw2.plaud.ai",
        "aws:eu-central-1": "https://api-euc1.plaud.ai",
        "aws:ap-southeast-1": "https://api-apse1.plaud.ai",
        "aws:ap-northeast-1": "https://api-apne1.plaud.ai",
        // Documented but DNS-dead — force discovery instead of calling a missing host.
        "aws:us-east-1": discoveryHost,
        "aws:us-east-2": discoveryHost,
        "aws:us-west-1": discoveryHost,
        "aws:eu-west-1": discoveryHost,
        "aws:ap-southeast-2": discoveryHost,
        "aws:ap-south-1": discoveryHost,
    ]

    private static let deadHostFragments = ["aps1", "use1", "use2", "usw1", "euw1", "apse2"]

    init(keyVault: KeyVault = KeyVault()) {
        self.keyVault = keyVault
        isSignedIn = keyVault.load(account: "plaud.userToken") != nil
        hasE2EEKey = keyVault.load(account: "plaud.rsaPrivatePEM") != nil
        if let data = keyVault.load(account: "plaud.apiHost"),
           let host = String(data: data, encoding: .utf8),
           !Self.isDeadHost(host) {
            resolvedAPIHost = host
        } else {
            // Drop stale cache pointing at DNS-dead hosts (e.g. api-aps1).
            try? keyVault.delete(account: "plaud.apiHost")
            resolvedAPIHost = nil
        }
    }

    private static func isDeadHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return deadHostFragments.contains { h.contains("api-\($0).plaud.ai") || h.contains("api-\($0)") }
    }

    func signOut() throws {
        try keyVault.delete(account: "plaud.userToken")
        try keyVault.delete(account: "plaud.refreshToken")
        try keyVault.delete(account: "plaud.rsaPrivatePEM")
        try keyVault.delete(account: "plaud.rsaPublicPEM")
        try keyVault.delete(account: "plaud.apiHost")
        isSignedIn = false
        hasE2EEKey = false
        resolvedAPIHost = nil
        statusMessage = "Signed out"
    }

    func storeTokens(userToken: String, refreshToken: String?) throws {
        try keyVault.save(Data(userToken.utf8), account: "plaud.userToken")
        if let refreshToken {
            try keyVault.save(Data(refreshToken.utf8), account: "plaud.refreshToken")
        }
        isSignedIn = true
    }

    func completeSignIn(from webView: WKWebView) async throws {
        statusMessage = "Reading session…"
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let relevant = cookies.filter { $0.domain.contains("plaud.ai") }

        // Prefer user token (typ UT). Workspace tokens won't work for gen_key.
        let ut = relevant.first(where: { $0.name == "pld_ut" })?.value
            ?? relevant.first(where: { $0.name == "tokenstr" })?.value
        let urt = relevant.first(where: { $0.name == "pld_urt" })?.value

        guard let ut, !ut.isEmpty else {
            let names = relevant.map(\.name).joined(separator: ", ")
            throw PlaudAuthError.network(
                "No pld_ut cookie yet (saw: \(names.isEmpty ? "none" : names)). Finish login until you see your library, then try again."
            )
        }
        try storeTokens(userToken: ut, refreshToken: urt)
        // Don't reuse a previously cached dead host from an earlier failed attempt.
        resolvedAPIHost = nil
        try? keyVault.delete(account: "plaud.apiHost")
        statusMessage = "Fetching encryption keys…"
        try await fetchAndStoreE2EEKeys(userToken: ut)
        hasE2EEKey = true
        let hostNote = resolvedAPIHost.map { " via \($0)" } ?? ""
        statusMessage = "Keys saved on this iPhone\(hostNote)"
    }

    func fetchAndStoreE2EEKeys(userToken: String) async throws {
        let json = try await apiPOST(
            path: "/device-app/e2ee/gen_key",
            body: Data("{}".utf8),
            userToken: userToken
        )
        let data = json["data"] as? [String: Any] ?? json
        guard let priv = data["private_key_base64"] as? String ?? data["private_key"] as? String,
              let pub = data["public_key_base64"] as? String ?? data["public_key"] as? String else {
            throw PlaudAuthError.badResponse
        }
        try keyVault.save(Data(decodePossiblyBase64PEM(priv).utf8), account: "plaud.rsaPrivatePEM")
        try keyVault.save(Data(decodePossiblyBase64PEM(pub).utf8), account: "plaud.rsaPublicPEM")
    }

    func fetchSNSign(serial: String, userToken: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["sns": [serial]])
        let json = try await apiPOST(
            path: "/device-app/device/sn-sign",
            body: body,
            userToken: userToken
        )
        let data = json["data"] as? [String: Any] ?? json
        let signatures = data["signature"] as? [String: String]
            ?? data["signatures"] as? [String: String]
        guard let b64 = signatures?[serial], let sig = Data(base64Encoded: b64) else {
            throw PlaudAuthError.badResponse
        }
        try keyVault.save(sig, account: "plaud.snSign.\(serial)")
    }

    // MARK: - Regional routing

    private func candidateHosts(for userToken: String) -> [String] {
        var hosts: [String] = []
        // 1) Discovery host first — returns -302 + correct regional domain.
        hosts.append(Self.discoveryHost)
        // 2) Cached live host from a previous success.
        if let resolvedAPIHost, !Self.isDeadHost(resolvedAPIHost) {
            hosts.append(resolvedAPIHost)
        }
        // 3) JWT region hint (only if it maps to a live host / discovery).
        if let region = jwtClaim(userToken, key: "region"),
           let mapped = Self.regionToHost[region] {
            hosts.append(mapped)
        }
        // 4) Remaining live regionals.
        hosts.append(contentsOf: Self.liveRegionalHosts)
        var seen = Set<String>()
        return hosts
            .filter { !Self.isDeadHost($0) }
            .filter { seen.insert($0).inserted }
    }

    private func rememberHost(_ host: String) {
        guard !Self.isDeadHost(host) else { return }
        resolvedAPIHost = host
        try? keyVault.save(Data(host.utf8), account: "plaud.apiHost")
    }

    private func apiPOST(path: String, body: Data, userToken: String) async throws -> [String: Any] {
        var errors: [String] = []
        let hosts = candidateHosts(for: userToken)

        for host in hosts {
            do {
                let json = try await postJSON(
                    url: URL(string: host + path)!,
                    body: body,
                    userToken: userToken
                )

                // Plaud often returns HTTP 200 with status:-302 for region mismatch.
                if let status = json["status"] as? Int, status == -302 || status == 302 {
                    if let redirected = redirectHost(from: json), !Self.isDeadHost(redirected) {
                        rememberHost(redirected)
                        let retried = try await postJSON(
                            url: URL(string: redirected + path)!,
                            body: body,
                            userToken: userToken
                        )
                        if let s = retried["status"] as? Int, s == -302 || s == 302 {
                            errors.append("\(redirected): \(retried["msg"] as? String ?? "region mismatch")")
                            continue
                        }
                        rememberHost(redirected)
                        return retried
                    }
                    errors.append("\(host): \(json["msg"] as? String ?? "user region mismatch")")
                    continue
                }

                // Treat non-zero Plaud status as failure (except ok/success variants).
                if let status = json["status"] as? Int, status != 0, status != 200 {
                    errors.append("\(host): status \(status) \(json["msg"] as? String ?? "")")
                    continue
                }

                rememberHost(host)
                return json
            } catch let err as PlaudAuthError {
                errors.append("\(host): \(err.localizedDescription)")
                continue
            } catch {
                let ns = error as NSError
                if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCannotFindHost {
                    errors.append("\(host): DNS miss (skipped)")
                    continue
                }
                errors.append("\(host): \(error.localizedDescription)")
                continue
            }
        }
        let detail = errors.suffix(4).joined(separator: " | ")
        throw PlaudAuthError.network(
            "Could not reach a working Plaud API host. \(detail)"
        )
    }

    private func redirectHost(from json: [String: Any]) -> String? {
        if let data = json["data"] as? [String: Any] {
            if let domains = data["domains"] as? [String: Any],
               let api = domains["api"] as? String {
                return normalizeHost(api)
            }
            if let api = data["api"] as? String {
                return normalizeHost(api)
            }
            if let domain = data["domain"] as? String {
                return normalizeHost(domain)
            }
        }
        if let api = json["api"] as? String {
            return normalizeHost(api)
        }
        return nil
    }

    private func normalizeHost(_ value: String) -> String? {
        var host = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("http://") || host.hasPrefix("https://") {
            // ok
        } else {
            host = "https://\(host)"
        }
        guard let url = URL(string: host), let h = url.host, h.hasSuffix("plaud.ai") else {
            return nil
        }
        return "https://\(h)"
    }

    /// JWT `sub` claim is the Plaud user_id / BLE bind token.
    static func subject(of token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2,
              let payload = base64URLDecode(String(parts[1])),
              let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return nil
        }
        if let sub = obj["sub"] as? String { return sub }
        if let n = obj["sub"] as? NSNumber { return n.stringValue }
        if let i = obj["sub"] as? Int { return String(i) }
        return nil
    }

    private func jwtClaim(_ token: String, key: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2,
              let payload = Self.base64URLDecode(String(parts[1])),
              let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return nil
        }
        return obj[key] as? String
    }

    private func postJSON(url: URL, body: Data, userToken: String) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(userToken)", forHTTPHeaderField: "Authorization")
        request.setValue("1", forHTTPHeaderField: "X-Encrypt-Response")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PlaudAuthError.badResponse }

        if http.statusCode == 302 {
            if let location = http.value(forHTTPHeaderField: "Location"),
               let host = normalizeHost(location) {
                rememberHost(host)
                throw PlaudAuthError.network("Region redirect to \(host)")
            }
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw PlaudAuthError.network("HTTP \(http.statusCode) from \(url.host ?? "?"): \(text.prefix(120))")
        }

        let asString = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let encrypted = http.value(forHTTPHeaderField: "x-encrypt-response") == "1"
            || asString.hasPrefix("gAAAA")
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
        if let decoded = Data(base64Encoded: value),
           let s = String(data: decoded, encoding: .utf8),
           s.contains("BEGIN") {
            return s
        }
        return value
    }

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
        guard token.count > 1 + 8 + 16 + 32, token[0] == 0x80 else {
            throw PlaudAuthError.decryptFailed
        }
        // Key is URL-safe base64 (contains '-' / '_'); std Swift base64 decode fails.
        guard let key = Self.base64URLDecode(Self.fernetKeyB64), key.count == 32 else {
            throw PlaudAuthError.decryptFailed
        }
        let signingKey = key.prefix(16)
        let encryptionKey = key.suffix(16)
        let hmacPart = token.suffix(32)
        let signed = token.prefix(token.count - 32)
        let expected = HMACSHA256(key: Data(signingKey), data: Data(signed))
        guard expected == Data(hmacPart) else { throw PlaudAuthError.decryptFailed }

        let iv = token.subdata(in: 9..<25)
        let cipher = token.subdata(in: 25..<(token.count - 32))
        return try AES128CBCDecrypt(key: Data(encryptionKey), iv: iv, data: cipher)
    }

    /// Test seam: decrypt a Fernet token produced with Plaud's embedded key.
    static func decryptFernetForTests(_ tokenUTF8: String) throws -> Data {
        let service = PlaudAuthService(keyVault: KeyVault(service: "com.local.plaudlocal.fernet.tests"))
        return try service.decryptFernet(Data(tokenUTF8.utf8))
    }
}

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
