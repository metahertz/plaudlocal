import XCTest
@testable import PlaudLocal

final class FernetDecryptTests: XCTestCase {
    @MainActor
    func test_decrypts_token_made_with_plaud_key() throws {
        // Fernet("8rRmMCskL3NaUiGr-UsmEEeI8NKH-ZfeGbpRGqSLpuI=").encrypt(b'{"ok":true}')
        let token = "gAAAAABq7O0gSIN6fa2mCz9mT60Jpp4ByW3yTDRr9PQuW62cJDjdpE3EYJ_GoRpZGneYO-Fz6b6jjjEGpgjhkvFO7BSC4pQC9g=="
        let plain = try PlaudAuthService.decryptFernetForTests(token)
        let obj = try JSONSerialization.jsonObject(with: plain) as? [String: Any]
        XCTAssertEqual(obj?["ok"] as? Bool, true)
    }

    @MainActor
    func test_urlSafeKey_isRequired() {
        // Standard base64 decode must fail on the Plaud key (contains '-').
        let key = "8rRmMCskL3NaUiGr-UsmEEeI8NKH-ZfeGbpRGqSLpuI="
        XCTAssertNil(Data(base64Encoded: key), "Plaud Fernet key is URL-safe; std decode must fail")
    }
}
