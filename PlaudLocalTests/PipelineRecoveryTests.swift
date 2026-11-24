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

    func test_notes_with_summaries_turned_off_are_not_retried() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = NoteStore(root: root)
        func makeNote(sessionId: UInt32, summary: String) throws -> NoteMetadata {
            var meta = try store.createNote(fromDecryptedAudio: Data("ogg".utf8), sessionId: sessionId, duration: 3)
            try store.writeTranscript(noteId: meta.id, text: "Some words.")
            try store.writeSummary(noteId: meta.id, text: summary)
            meta.transcriptStatus = .done
            meta.summaryStatus = .skipped
            meta.briefStatus = .done
            try store.updateMetadata(meta)
            return meta
        }
        let turnedOff = try makeNote(
            sessionId: 1_730_000_001, summary: "Summary unavailable: \(PipelineOptions.summaryOffReason)"
        )
        // A real (non-retryable) failure still gets its one retry per launch.
        let failed = try makeNote(sessionId: 1_730_000_002, summary: "Summary unavailable: Empty transcript")

        let queued = PipelineRecovery.recoverInterrupted(store: store).map(\.id)
        XCTAssertFalse(queued.contains(turnedOff.id))
        XCTAssertTrue(queued.contains(failed.id))
    }

    func test_failed_transcription_is_retried_once_per_launch_not_on_every_visit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = NoteStore(root: root)
        var meta = try store.createNote(fromDecryptedAudio: Data("ogg".utf8), sessionId: 1_730_000_101, duration: 4)
        meta.transcriptStatus = .failed
        try store.updateMetadata(meta)

        // First Library visit this launch: retried.
        XCTAssertTrue(PipelineRecovery.recoverInterrupted(store: store).map(\.id).contains(meta.id))

        // The retry fails again (e.g. the recording has no speech).
        var again = try XCTUnwrap(try store.allNotes().first { $0.id == meta.id })
        again.transcriptStatus = .failed
        try store.updateMetadata(again)

        // Later visits in the same launch leave it alone, and it still shows as failed.
        XCTAssertFalse(PipelineRecovery.recoverInterrupted(store: store).map(\.id).contains(meta.id))
        XCTAssertEqual(try store.allNotes().first { $0.id == meta.id }?.transcriptStatus, .failed)
    }

    func test_an_interrupted_brief_counts_as_done_only_with_the_poster_it_needs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = NoteStore(root: root)
        var meta = try store.createNote(fromDecryptedAudio: Data("ogg".utf8), sessionId: 1_730_000_301, duration: 3)
        try store.writeTranscript(noteId: meta.id, text: "Words.")
        try store.writeBrief(noteId: meta.id, brief: MeetingBrief(title: "From the brief", topics: [], actionItems: []))
        meta.transcriptStatus = .done
        meta.summaryStatus = .done
        meta.briefStatus = .running
        try store.updateMetadata(meta)
        // Image wanted, none written: the brief step still has work.
        _ = PipelineRecovery.recoverInterrupted(store: store, options: PipelineOptions(posterImage: true))
        XCTAssertEqual(try store.allNotes().first { $0.id == meta.id }?.briefStatus, .pending)
        meta.briefStatus = .running
        try store.updateMetadata(meta)
        // Image off: the written brief is done, and its title is restored.
        _ = PipelineRecovery.recoverInterrupted(store: store, options: PipelineOptions(posterImage: false))
        let recovered = try XCTUnwrap(try store.allNotes().first { $0.id == meta.id })
        XCTAssertEqual(recovered.briefStatus, .done)
        XCTAssertEqual(recovered.title, "From the brief")
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
