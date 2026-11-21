import XCTest
@testable import PlaudLocal

final class KeyVaultTests: XCTestCase {
    func test_roundTripSecret() throws {
        let vault = KeyVault(service: "dev.metahertz.plaudlocal.tests")
        let payload = Data("secret-bytes".utf8)
        try vault.save(payload, account: "plaud.userToken")
        XCTAssertEqual(vault.load(account: "plaud.userToken"), payload)
        try vault.delete(account: "plaud.userToken")
        XCTAssertNil(vault.load(account: "plaud.userToken"))
    }
}
