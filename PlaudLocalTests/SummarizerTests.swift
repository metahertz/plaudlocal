import XCTest
@testable import PlaudLocal

final class SummarizerTests: XCTestCase {
    func test_unavailable_whenModelMissing() async throws {
        let summarizer = Summarizer(forceUnavailable: true)
        let result = try await summarizer.summarize(transcript: "Hello meeting notes")
        guard case let .unavailable(reason) = result else {
            return XCTFail("expected unavailable")
        }
        XCTAssertFalse(reason.isEmpty)
    }
}
