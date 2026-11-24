import XCTest
@testable import PlaudLocal

final class ProcessingSettingsTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let name = "dev.metahertz.plaudlocal.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func remote(
        enabled: Bool = true, configured: Bool = true, fallback: Bool = true,
        transcribe: Bool = true, summarize: Bool = true
    ) -> RemoteProcessingSettings {
        RemoteProcessingSettings(
            enabled: enabled,
            serverURL: configured ? URL(string: "https://server.test")! : nil,
            fallbackOnDevice: fallback,
            token: configured ? "token" : nil,
            transcribeRemotely: transcribe,
            summarizeRemotely: summarize
        )
    }

    // MARK: - Mode

    func test_mode_defaults_to_on_device_and_round_trips() {
        let defaults = makeDefaults()
        XCTAssertEqual(ProcessingMode.current(defaults: defaults), .onDevice)
        for mode in ProcessingMode.allCases {
            mode.save(to: defaults)
            XCTAssertEqual(ProcessingMode.current(defaults: defaults), mode)
        }
    }

    func test_mode_is_read_from_the_existing_switches() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: RemoteProcessingSettings.enabledKey)
        XCTAssertEqual(ProcessingMode.current(defaults: defaults), .remote)
        // Audio-only wins, as it did before modes existed.
        defaults.set(true, forKey: ExportSettings.audioOnlyModeKey)
        XCTAssertEqual(ProcessingMode.current(defaults: defaults), .audioOnly)
        ProcessingMode.remote.save(to: defaults)
        XCTAssertFalse(defaults.bool(forKey: ExportSettings.audioOnlyModeKey))
    }

    func test_pipeline_options_default_to_everything_on() {
        let defaults = makeDefaults()
        XCTAssertEqual(PipelineOptions.load(defaults: defaults), PipelineOptions(summarize: true, buildPoster: true))
        defaults.set(false, forKey: PipelineOptions.summarizeKey)
        defaults.set(false, forKey: PipelineOptions.posterKey)
        XCTAssertEqual(PipelineOptions.load(defaults: defaults), PipelineOptions(summarize: false, buildPoster: false))
        XCTAssertTrue(PipelineOptions.load(defaults: defaults).posterImage, "the poster image switch defaults on")
        defaults.set(false, forKey: PipelineOptions.posterImageKey)
        XCTAssertFalse(PipelineOptions.load(defaults: defaults).posterImage)
    }

    func test_with_the_poster_image_off_a_brief_without_a_poster_is_done() {
        var meta = NoteMetadata(id: "n", sessionId: 1, createdAt: Date(), durationSeconds: 1, title: "t",
                                transcriptStatus: .done, summaryStatus: .done, briefStatus: .done,
                                exportStatus: .pending, audioFileName: "audio.ogg")
        XCTAssertFalse(PipelineOptions(posterImage: false).briefNeeded(for: meta))
        XCTAssertTrue(PipelineOptions(posterImage: true).briefNeeded(for: meta), "image on: the missing poster is still work")
        meta.posterFileName = "p.png"
        XCTAssertFalse(PipelineOptions(posterImage: true).briefNeeded(for: meta))
    }

    // MARK: - Engine selection

    func test_on_device_engines_when_remote_is_off_or_not_set_up() {
        XCTAssertTrue(PipelineEngines.transcriber(remote: remote(enabled: false), options: .init()) is Transcriber)
        XCTAssertTrue(PipelineEngines.summarizer(remote: remote(enabled: false)) is Summarizer)
        XCTAssertTrue(PipelineEngines.transcriber(remote: remote(configured: false), options: .init()) is Transcriber)
        XCTAssertTrue(
            PipelineEngines.transcriber(remote: remote(configured: false), options: .init(), override: .remote) is Transcriber,
            "asking for the server without one set up must still work"
        )
    }

    func test_remote_mode_uses_the_server_with_or_without_fallback() {
        XCTAssertTrue(PipelineEngines.transcriber(remote: remote(), options: .init()) is FallbackTranscriber)
        XCTAssertTrue(PipelineEngines.summarizer(remote: remote()) is FallbackSummarizer)
        XCTAssertTrue(PipelineEngines.transcriber(remote: remote(fallback: false), options: .init()) is RemoteTranscriber)
        XCTAssertTrue(PipelineEngines.summarizer(remote: remote(fallback: false)) is RemoteSummarizer)
    }

    func test_each_stage_can_stay_on_device_in_remote_mode() {
        XCTAssertTrue(PipelineEngines.transcriber(remote: remote(transcribe: false), options: .init()) is Transcriber)
        XCTAssertTrue(PipelineEngines.summarizer(remote: remote(fallback: false, transcribe: false)) is RemoteSummarizer)
        XCTAssertTrue(PipelineEngines.summarizer(remote: remote(summarize: false)) is Summarizer)
    }

    func test_server_is_asked_for_a_summary_only_when_it_will_be_used() throws {
        func wantSummary(_ settings: RemoteProcessingSettings, _ options: PipelineOptions) throws -> Bool {
            try XCTUnwrap(PipelineEngines.transcriber(remote: settings, options: options) as? RemoteTranscriber).wantSummary
        }
        XCTAssertTrue(try wantSummary(remote(fallback: false), .init()))
        XCTAssertFalse(try wantSummary(remote(fallback: false, summarize: false), .init()))
        XCTAssertFalse(try wantSummary(remote(fallback: false), .init(summarize: false)))
    }

    func test_per_note_override_beats_the_saved_mode() {
        // Server set up but mode is on-device: a note can still be sent to the server.
        let idle = remote(enabled: false, fallback: false)
        XCTAssertTrue(PipelineEngines.transcriber(remote: idle, options: .init(), override: .remote) is RemoteTranscriber)
        XCTAssertTrue(PipelineEngines.summarizer(remote: idle, override: .remote) is RemoteSummarizer)
        // Remote mode: a note can still be kept on the iPhone.
        XCTAssertTrue(PipelineEngines.transcriber(remote: remote(), options: .init(), override: .onDevice) is Transcriber)
        XCTAssertTrue(PipelineEngines.summarizer(remote: remote(), override: .onDevice) is Summarizer)
        XCTAssertEqual(PipelineEngines.transcriberTitle(remote: idle, override: .remote), "remote server")
        XCTAssertNotEqual(PipelineEngines.transcriberTitle(remote: remote(), override: .onDevice), "remote server")
    }

    // MARK: - Optional steps

    func test_summary_and_poster_can_be_switched_off() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = NoteStore(root: root.appendingPathComponent("notes"))
        let vault = KeyVault(service: "dev.metahertz.plaudlocal.tests.options")
        let downloaded = root.appendingPathComponent("in.plaud")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try NotePipelineTests.fakePlaudContainer(duration: 5).write(to: downloaded)
        let calls = CallCounter()

        let pipeline = NotePipeline(
            store: store,
            transcriber: FakeTranscriber(text: "hello world"),
            summarizer: CountingSummarizer(calls: calls),
            briefBuilder: CountingBriefBuilder(calls: calls),
            exporter: Exporter(settings: ExportSettings.load(defaults: makeDefaults(), keyVault: vault)),
            decrypt: { _, _ in Data("OggSfakeaudio".utf8) },
            privateKeyPEMProvider: { "KEY" },
            options: PipelineOptions(summarize: false, buildPoster: false)
        )
        let meta = try await pipeline.processDownloadedFile(downloaded, sessionId: 21, duration: 5)

        XCTAssertEqual(meta.transcriptStatus, .done)
        XCTAssertEqual(meta.summaryStatus, .skipped)
        XCTAssertEqual(meta.briefStatus, .skipped)
        XCTAssertNil(meta.posterFileName)
        XCTAssertEqual(calls.count, 0, "switched-off steps must not run")
        let summary = try XCTUnwrap(store.readSummary(noteId: meta.id))
        XCTAssertTrue(summary.contains(PipelineOptions.summaryOffReason))
        XCTAssertFalse(PipelineRecovery.isRetryableSkipReason(summary), "a deliberate skip is not retried")
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); value += 1; lock.unlock() }
}

private struct CountingSummarizer: Summarizing {
    let calls: CallCounter
    func summarize(transcript: String) async throws -> SummaryResult {
        calls.increment()
        return .text("summary")
    }
}

private struct CountingBriefBuilder: BriefBuilding {
    let calls: CallCounter
    func build(transcript: String, summary: String?) async throws -> MeetingBrief {
        calls.increment()
        throw BriefBuilderError.empty
    }
}
