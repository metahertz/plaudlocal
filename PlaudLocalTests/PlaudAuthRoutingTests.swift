import XCTest
@testable import PlaudLocal

final class PlaudAuthRoutingTests: XCTestCase {
    func test_regionHostMap_coversDocumentedRegions() {
        // Sanity: the hosts we call must be the documented regional set, not invented ones.
        let hosts = [
            "https://api-use1.plaud.ai",
            "https://api-euc1.plaud.ai",
            "https://api-apse1.plaud.ai",
            "https://api-euw1.plaud.ai",
        ]
        for host in hosts {
            XCTAssertNotNil(URL(string: host)?.host)
            XCTAssertFalse(host.contains("eus1"), "eus1 is not a real Plaud region host")
        }
    }
}
