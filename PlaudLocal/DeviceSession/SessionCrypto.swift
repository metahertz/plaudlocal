import CryptoKit
import Foundation

enum SessionCryptoError: Error {
    case invalidKeyMaterial
    case sealFailed
    case openFailed
    case replayOrStaleSequence
    case unsupportedProtocol30
}

struct SessionCrypto {
    private let symmetricKey: SymmetricKey
    private let nonce: ChaChaPoly.Nonce
    private let aad: Data
    private var sendSeq: UInt32
    private var lastRecvSeq: UInt32

    init(key: Data, nonce: Data, aad: Data, sendSeqStart: UInt32 = 2) {
        precondition(key.count == 32)
        precondition(nonce.count == 12)
        precondition(aad.count == 12)
        self.symmetricKey = SymmetricKey(data: key)
        self.nonce = try! ChaChaPoly.Nonce(data: nonce)
        self.aad = aad
        self.sendSeq = sendSeqStart
        self.lastRecvSeq = 0
    }

    static func padBindToken(userId: String) -> String {
        if userId.count >= 32 {
            return String(userId.prefix(32))
        }
        return userId + String(repeating: "0", count: 32 - userId.count)
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
            guard seq > lastRecvSeq else { throw SessionCryptoError.replayOrStaleSequence }
            lastRecvSeq = seq
            return opened.subdata(in: 4..<opened.count)
        } catch let err as SessionCryptoError {
            throw err
        } catch {
            throw SessionCryptoError.openFailed
        }
    }

    /// Detect protocol-30 ECC start packet (0xFE30 little-endian as first two bytes of raw notify).
    static func isProtocol30Start(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        return data[0] == 0x30 && data[1] == 0xFE || data[0] == 0xFE && data[1] == 0x30
    }
}
