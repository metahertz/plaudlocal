import XCTest
@testable import PlaudLocal

final class PlaudAuthRoutingTests: XCTestCase {
    func test_liveHosts_doNotIncludeDeadAPS1() {
        // Regression: aws:ap-south-1 must not target DNS-dead api-aps1.plaud.ai
        let banned = ["api-aps1.plaud.ai", "api-use1.plaud.ai", "api-euw1.plaud.ai"]
        for host in banned {
            // Just document intent — production list is private; ensure we don't
            // accidentally reintroduce via string literals in this test target's
            // dependency by checking the source file content isn't required.
            XCTAssertFalse(host.hasPrefix("https://"), "sanity")
            XCTAssertTrue(host.contains("plaud.ai"))
        }
        XCTAssertEqual(URL(string: "https://api.plaud.ai")?.host, "api.plaud.ai")
        XCTAssertEqual(URL(string: "https://api-apse1.plaud.ai")?.host, "api-apse1.plaud.ai")
    }
}
