import XCTest
@testable import PlaudLocal

final class TranscriptChunkerTests: XCTestCase {
    func test_shortText_singleChunk() {
        let text = String(repeating: "Hello meeting. ", count: 20)
        let parts = TranscriptChunker.chunks(text)
        XCTAssertEqual(parts.count, 1)
        XCTAssertFalse(TranscriptChunker.needsChunking(text))
    }

    func test_longText_coversFullContent() {
        var paragraphs: [String] = []
        for i in 0..<40 {
            paragraphs.append("Topic \(i). " + String(repeating: "Detail about agenda item \(i). ", count: 30))
        }
        let text = paragraphs.joined(separator: "\n\n")
        XCTAssertTrue(TranscriptChunker.needsChunking(text))
        let parts = TranscriptChunker.chunks(text)
        XCTAssertGreaterThan(parts.count, 1)
        // First and last topic markers should appear somewhere across chunks.
        let joined = parts.joined(separator: "\n")
        XCTAssertTrue(joined.contains("Topic 0."))
        XCTAssertTrue(joined.contains("Topic 39."))
    }

    func test_heuristicTopics_splitsLongSummary() {
        let summary = (0..<6).map { i in
            "Theme \(i) covered staffing, budget numbers, and next steps for the regional plan in detail here."
        }.joined(separator: "\n\n")
        let topics = BriefBuilder.heuristicTopics(from: summary)
        XCTAssertGreaterThanOrEqual(topics.count, 3)
    }

    func test_defaultChunkSize_staysUnderContextBudget() {
        XCTAssertLessThanOrEqual(TranscriptChunker.defaultMaxChars, 3_200)
    }

    func test_representativeSample_keepsHeadAndTail() {
        let text = String((0..<200).map { "word\($0) " }.joined())
        let sample = Summarizer.representativeSample(text, limit: 600)
        XCTAssertTrue(sample.contains("word0 "))
        XCTAssertTrue(sample.contains("word199 "))
        XCTAssertTrue(sample.contains("…"))
    }
}
