import CryptoKit
import Foundation
import Security

enum SessionCryptoError: Error, LocalizedError {
    case invalidKeyMaterial
    case sealFailed
    case openFailed
    case replayOrStaleSequence
    case unsupportedProtocol30
    case rsaImportFailed
    case rsaDecryptFailed
    case sessionCheckFailed

    var errorDescription: String? {
        switch self {
        case .invalidKeyMaterial: return "Invalid session key material"
        case .sealFailed: return "Failed to encrypt BLE packet"
        case .openFailed: return "Failed to decrypt BLE packet"
        case .replayOrStaleSequence: return "Stale BLE sequence"
        case .unsupportedProtocol30: return "Unsupported firmware (protocol 30)"
        case .rsaImportFailed: return "Could not import E2EE private key"
        case .rsaDecryptFailed: return "Could not decrypt session key — device may hold another account's key"
        case .sessionCheckFailed: return "Session key check failed"
        }
    }
}

struct SessionKeyMaterial: Equatable {
    let key: Data
    let nonce: Data
    let aad: Data
}

struct SessionCrypto {
    private let symmetricKey: SymmetricKey
    private let nonce: ChaChaPoly.Nonce
    private let aad: Data
    private let keyData: Data
    private let nonceData: Data
    private var sendSeq: UInt32
    private var lastRecvSeq: UInt32
    private var hasReceived = false

    init(key: Data, nonce: Data, aad: Data, sendSeqStart: UInt32 = 2) {
        precondition(key.count == 32)
        precondition(nonce.count == 12)
        precondition(aad.count == 12)
        self.keyData = key
        self.nonceData = nonce
        self.symmetricKey = SymmetricKey(data: key)
        self.nonce = try! ChaChaPoly.Nonce(data: nonce)
        self.aad = aad
        self.sendSeq = sendSeqStart
        self.lastRecvSeq = 0
        self.hasReceived = false
    }

    /// Snapshot key material for Wi‑Fi Fast Transfer (independent sequence counters).
    var material: SessionKeyMaterial {
        SessionKeyMaterial(key: keyData, nonce: nonceData, aad: aad)
    }

    /// Fresh link using the same ChaCha key/nonce/AAD but Wi‑Fi send/recv sequences from 0.
    static func wifiLink(from material: SessionKeyMaterial) -> SessionCrypto {
        SessionCrypto(key: material.key, nonce: material.nonce, aad: material.aad, sendSeqStart: 0)
    }

    static func padBindToken(userId: String) -> String {
        if userId.count >= 32 {
            return String(userId.prefix(32))
        }
        return userId + String(repeating: "0", count: 32 - userId.count)
    }

    /// Unwrap protocol-20 FE12 plaintext: key(32) + nonce(12) + aad(12) [+ sealed "PLAUD.AI"].
    static func fromSessionSecret(_ plain: Data) throws -> SessionCrypto {
        guard plain.count >= 56 else { throw SessionCryptoError.invalidKeyMaterial }
        let key = Data(plain.prefix(32))
        let nonce = plain.subdata(in: 32..<44)
        let aad = plain.subdata(in: 44..<56)
        let tail = Data(plain.suffix(from: 56))
        if tail.count >= 16 {
            let box = try ChaChaPoly.SealedBox(
                nonce: try ChaChaPoly.Nonce(data: nonce),
                ciphertext: tail.prefix(tail.count - 16),
                tag: tail.suffix(16)
            )
            let check = try ChaChaPoly.open(box, using: SymmetricKey(data: key), authenticating: aad)
            guard check == Data("PLAUD.AI".utf8) else { throw SessionCryptoError.sessionCheckFailed }
        }
        return SessionCrypto(key: key, nonce: nonce, aad: aad)
    }

    static func rsaDecryptPKCS1(cipher: Data, privateKeyPEM: String) throws -> Data {
        let key = try importRSAPrivateKey(pem: privateKeyPEM)
        var error: Unmanaged<CFError>?
        guard let plain = SecKeyCreateDecryptedData(
            key,
            .rsaEncryptionPKCS1,
            cipher as CFData,
            &error
        ) as Data? else {
            throw SessionCryptoError.rsaDecryptFailed
        }
        return plain
    }

    mutating func seal(_ plaintext: Data) throws -> Data {
        var body = Data()
        body.append(contentsOf: withUnsafeBytes(of: sendSeq.littleEndian) { Data($0) })
        body.append(plaintext)
        sendSeq &+= 1
        do {
            let box = try ChaChaPoly.seal(body, using: symmetricKey, nonce: nonce, authenticating: aad)
            return box.ciphertext + box.tag
        } catch {
            throw SessionCryptoError.sealFailed
        }
    }

    mutating func open(_ ciphertextAndTag: Data) throws -> Data {
        guard ciphertextAndTag.count >= 16 else { throw SessionCryptoError.openFailed }
        let cipher = ciphertextAndTag.dropLast(16)
        let tag = ciphertextAndTag.suffix(16)
        do {
            let box = try ChaChaPoly.SealedBox(
                nonce: nonce,
                ciphertext: cipher,
                tag: tag
            )
            let opened = try ChaChaPoly.open(box, using: symmetricKey, authenticating: aad)
            guard opened.count >= 4 else { throw SessionCryptoError.openFailed }
            let seq = UInt32(opened[0])
                | (UInt32(opened[1]) << 8)
                | (UInt32(opened[2]) << 16)
                | (UInt32(opened[3]) << 24)
            if hasReceived {
                guard seq > lastRecvSeq else { throw SessionCryptoError.replayOrStaleSequence }
            }
            hasReceived = true
            lastRecvSeq = seq
            return opened.subdata(in: 4..<opened.count)
        } catch let err as SessionCryptoError {
            throw err
        } catch {
            throw SessionCryptoError.openFailed
        }
    }

    /// Detect protocol-30 ECC start packet (0xFE30 LE = `30 FE`, also accept swapped).
    static func isProtocol30Start(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        let le = UInt16(data[0]) | (UInt16(data[1]) << 8)
        let be = UInt16(data[1]) | (UInt16(data[0]) << 8)
        return le == PlaudCommand.fe30.rawValue || be == PlaudCommand.fe30.rawValue
    }

    private static func importRSAPrivateKey(pem: String) throws -> SecKey {
        let cleaned = pem
            .replacingOccurrences(of: "-----BEGIN RSA PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END RSA PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        guard let der = Data(base64Encoded: cleaned) else { throw SessionCryptoError.rsaImportFailed }

        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        if let direct = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, &error) {
            return direct
        }
        if let pkcs1 = extractPKCS1FromPKCS8(der),
           let unwrapped = SecKeyCreateWithData(pkcs1 as CFData, attrs as CFDictionary, &error) {
            return unwrapped
        }
        throw SessionCryptoError.rsaImportFailed
    }

    private static func extractPKCS1FromPKCS8(_ der: Data) -> Data? {
        guard der.count > 50 else { return nil }
        var i = 0
        while i + 4 < der.count {
            if der[i] == 0x04 {
                let (len, consumed) = readASN1Length(der, at: i + 1)
                guard let len, consumed > 0, i + 1 + consumed + len <= der.count, len > 200 else {
                    i += 1
                    continue
                }
                return der.subdata(in: (i + 1 + consumed)..<(i + 1 + consumed + len))
            }
            i += 1
        }
        return nil
    }

    private static func readASN1Length(_ data: Data, at offset: Int) -> (Int?, Int) {
        guard offset < data.count else { return (nil, 0) }
        let first = data[offset]
        if first & 0x80 == 0 { return (Int(first), 1) }
        let count = Int(first & 0x7f)
        guard count > 0, count <= 4, offset + count < data.count else { return (nil, 0) }
        var len = 0
        for j in 0..<count {
            len = (len << 8) | Int(data[offset + 1 + j])
        }
        return (len, 1 + count)
    }
}
