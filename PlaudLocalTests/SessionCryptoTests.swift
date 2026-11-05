import XCTest
@testable import PlaudLocal

final class SessionCryptoTests: XCTestCase {
    func test_padBindToken() {
        XCTAssertEqual(SessionCrypto.padBindToken(userId: "abc"), "abc" + String(repeating: "0", count: 29))
        XCTAssertEqual(SessionCrypto.padBindToken(userId: String(repeating: "x", count: 40)).count, 32)
    }

    func test_sealOpen_roundTrip() throws {
        var crypto = SessionCrypto(
            key: Data(repeating: 0x11, count: 32),
            nonce: Data(repeating: 0x22, count: 12),
            aad: Data(repeating: 0x33, count: 12)
        )
        let plain = Data([0x01, 0x01, 0x00, 0x00])
        let sealed = try crypto.seal(plain)
        XCTAssertNotEqual(sealed, plain)
        // Receiver uses its own seq tracking; open expects ciphertext from peer.
        // For round-trip of the same object, reopen with a fresh instance that
        // accepts the first sealed packet as inbound.
        var peer = SessionCrypto(
            key: Data(repeating: 0x11, count: 32),
            nonce: Data(repeating: 0x22, count: 12),
            aad: Data(repeating: 0x33, count: 12)
        )
        let opened = try peer.open(sealed)
        XCTAssertEqual(opened, plain)
    }
}
