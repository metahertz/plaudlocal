import Foundation
import Security

enum FileDecryptorError: Error, Equatable {
    case badMagic
    case unsupportedVersion(UInt16)
    case rsaFailed
    case integrityFailed
    case truncated
}

enum FileDecryptor {
    private static let magic = Data("PLAUD.AI".utf8)

    static func decrypt(fileData: Data, privateKeyPEM: String) throws -> Data {
        guard fileData.count >= 12 else { throw FileDecryptorError.truncated }
        guard fileData.prefix(8) == magic else { throw FileDecryptorError.badMagic }

        let version = readUInt16(fileData, at: 8)
        guard version == 1 else { throw FileDecryptorError.unsupportedVersion(version) }

        let headerSize = Int(readUInt16(fileData, at: 10))
        guard headerSize >= 512, fileData.count >= headerSize else { throw FileDecryptorError.truncated }

        let counter = readUInt32(fileData, at: 128)
        let nonce = fileData.subdata(in: 132..<144)
        let segmentSize = readUInt32(fileData, at: 144)
        let keyCipher = fileData.subdata(in: 256..<512)
        let body = fileData.subdata(in: headerSize..<fileData.count)

        let contentKey = try rsaDecryptPKCS1(cipher: keyCipher, privateKeyPEM: privateKeyPEM)
        let key32 = contentKey.count >= 32 ? contentKey.suffix(32) : contentKey
        guard key32.count == 32 else { throw FileDecryptorError.rsaFailed }

        if segmentSize > 0 {
            var out = Data()
            var offset = 0
            let seg = Int(segmentSize)
            while offset < body.count {
                let end = min(offset + seg, body.count)
                let chunk = body.subdata(in: offset..<end)
                out.append(ChaCha20.encrypt(key: Data(key32), nonce: nonce, counter: 0, data: chunk))
                offset = end
            }
            return out
        }

        return ChaCha20.encrypt(key: Data(key32), nonce: nonce, counter: counter, data: body)
    }

    private static func rsaDecryptPKCS1(cipher: Data, privateKeyPEM: String) throws -> Data {
        let cleaned = privateKeyPEM
            .replacingOccurrences(of: "-----BEGIN RSA PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END RSA PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        guard let der = Data(base64Encoded: cleaned) else { throw FileDecryptorError.rsaFailed }

        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, &error) else {
            throw FileDecryptorError.rsaFailed
        }
        guard let plain = SecKeyCreateDecryptedData(
            key,
            .rsaEncryptionPKCS1,
            cipher as CFData,
            &error
        ) as Data? else {
            throw FileDecryptorError.rsaFailed
        }
        return plain
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}

/// RFC 8439 ChaCha20 (cipher stream; encrypt == decrypt).
enum ChaCha20 {
    static func encrypt(key: Data, nonce: Data, counter: UInt32, data: Data) -> Data {
        precondition(key.count == 32)
        precondition(nonce.count == 12)
        var out = Data(count: data.count)
        var blockCounter = counter
        var offset = 0
        while offset < data.count {
            let keystream = block(key: key, counter: blockCounter, nonce: nonce)
            let n = min(64, data.count - offset)
            for i in 0..<n {
                out[offset + i] = data[offset + i] ^ keystream[i]
            }
            offset += n
            blockCounter &+= 1
        }
        return out
    }

    private static func block(key: Data, counter: UInt32, nonce: Data) -> [UInt8] {
        var state = [UInt32](repeating: 0, count: 16)
        state[0] = 0x61707865
        state[1] = 0x3320646e
        state[2] = 0x79622d32
        state[3] = 0x6b206574
        for i in 0..<8 {
            state[4 + i] = readLE32(key, i * 4)
        }
        state[12] = counter
        state[13] = readLE32(nonce, 0)
        state[14] = readLE32(nonce, 4)
        state[15] = readLE32(nonce, 8)

        var working = state
        for _ in 0..<10 {
            quarter(&working, 0, 4, 8, 12)
            quarter(&working, 1, 5, 9, 13)
            quarter(&working, 2, 6, 10, 14)
            quarter(&working, 3, 7, 11, 15)
            quarter(&working, 0, 5, 10, 15)
            quarter(&working, 1, 6, 11, 12)
            quarter(&working, 2, 7, 8, 13)
            quarter(&working, 3, 4, 9, 14)
        }
        for i in 0..<16 {
            working[i] &+= state[i]
        }
        var out = [UInt8](repeating: 0, count: 64)
        for i in 0..<16 {
            let v = working[i]
            out[i * 4] = UInt8(v & 0xff)
            out[i * 4 + 1] = UInt8((v >> 8) & 0xff)
            out[i * 4 + 2] = UInt8((v >> 16) & 0xff)
            out[i * 4 + 3] = UInt8((v >> 24) & 0xff)
        }
        return out
    }

    private static func quarter(_ s: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        s[a] &+= s[b]; s[d] ^= s[a]; s[d] = rotl(s[d], 16)
        s[c] &+= s[d]; s[b] ^= s[c]; s[b] = rotl(s[b], 12)
        s[a] &+= s[b]; s[d] ^= s[a]; s[d] = rotl(s[d], 8)
        s[c] &+= s[d]; s[b] ^= s[c]; s[b] = rotl(s[b], 7)
    }

    private static func rotl(_ v: UInt32, _ n: UInt32) -> UInt32 {
        (v << n) | (v >> (32 - n))
    }

    private static func readLE32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
