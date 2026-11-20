import XCTest
@testable import PlaudLocal

final class PipelineRecoveryTests: XCTestCase {
    func test_usableSummary_rejectsUnavailableAndSectionDumps() {
        XCTAssertFalse(PipelineRecovery.isUsableSummary(nil))
        XCTAssertFalse(PipelineRecovery.isUsableSummary(""))
        XCTAssertFalse(PipelineRecovery.isUsableSummary("Summary unavailable: timed out"))
        XCTAssertFalse(
            PipelineRecovery.isUsableSummary(
                """
                ### Section 1
                Hello
                ### Section 2
                World
                """
            )
        )
        XCTAssertTrue(
            PipelineRecovery.isUsableSummary(
                "## Meeting Summary\nThe team discussed cartridges and recoil."
            )
        )
    }

    func test_retryableSkipReasons() {
        XCTAssertTrue(
            PipelineRecovery.isRetryableSkipReason("Summary unavailable: On-device summary timed out after 90s")
        )
        XCTAssertTrue(
            PipelineRecovery.isRetryableSkipReason("Summary unavailable: On-device model rate limited — try again in a moment")
        )
        XCTAssertTrue(
            PipelineRecovery.isRetryableSkipReason("Summary unavailable: Interrupted — open the note")
        )
        XCTAssertFalse(
            PipelineRecovery.isRetryableSkipReason("Summary unavailable: Empty transcript")
        )
        XCTAssertFalse(PipelineRecovery.isRetryableSkipReason("A normal summary"))
    }

    func test_retryClassifiesTimeoutAsRetryable() {
        XCTAssertEqual(
            PipelineRetry.classify(SummarizerError.timedOut(seconds: 90)),
            .retryable
        )
        XCTAssertEqual(
            PipelineRetry.classify(TranscriberError.emptyTranscript),
            .retryable
        )
        XCTAssertEqual(
            PipelineRetry.classify(TranscriberError.missingAudio),
            .permanent
        )
    }
}
