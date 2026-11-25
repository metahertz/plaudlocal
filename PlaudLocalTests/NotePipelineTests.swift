import XCTest
@testable import PlaudLocal

final class NotePipelineTests: XCTestCase {
    func test_skipsSummaryStillExports() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = NoteStore(root: root.appendingPathComponent("notes"))
        let exportRoot = root.appendingPathComponent("export")
        try FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: true)

        let vault = KeyVault(service: "dev.metahertz.plaudlocal.tests.pipeline")
        try vault.save(Data("KEY".utf8), account: "plaud.rsaPrivatePEM")

        var settings = ExportSettings.load(keyVault: vault)
        settings.autoExportEnabled = true
        var exporter = Exporter(settings: settings)
        exporter.localFolderOverride = exportRoot

        let downloaded = root.appendingPathComponent("in.plaud")
        try Self.fakePlaudContainer(duration: 5).write(to: downloaded)

        let pipeline = NotePipeline(
            store: store,
            transcriber: FakeTranscriber(text: "hello world"),
            summarizer: Summarizer(forceUnavailable: true),
            exporter: exporter,
            decrypt: { _, _ in Data("OggSfakeaudio".utf8) },
            privateKeyPEMProvider: { "KEY" }
        )

        let meta = try await pipeline.processDownloadedFile(downloaded, sessionId: 11, duration: 5)
        XCTAssertEqual(meta.transcriptStatus, .done)
        XCTAssertEqual(meta.summaryStatus, .skipped)
        XCTAssertEqual(meta.exportStatus, .done)
        let packages = try FileManager.default.contentsOfDirectory(at: exportRoot, includingPropertiesForKeys: nil)
        XCTAssertEqual(packages.count, 1)
    }
}

extension NotePipelineTests {
    func test_cancelled_transcription_stays_pending_not_failed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = NoteStore(root: root.appendingPathComponent("notes"))
        let meta = try store.createNote(fromDecryptedAudio: Data("OggS".utf8), sessionId: 12, duration: 5)
        let pipeline = NotePipeline(
            store: store,
            transcriber: CancelledTranscriber(),
            summarizer: Summarizer(forceUnavailable: true),
            exporter: Exporter(settings: ExportSettings.load())
        )
        _ = try? await pipeline.enrichImportedNote(meta)
        XCTAssertEqual(try store.allNotes().first { $0.id == meta.id }?.transcriptStatus, .pending)
    }
}

private struct CancelledTranscriber: Transcribing {
    func transcribe(audioURL: URL) async throws -> String { throw CancellationError() }
}

extension NotePipelineTests {
    func test_a_pass_without_a_document_removes_an_old_one() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = NoteStore(root: root.appendingPathComponent("notes"))
        let meta = try store.createNote(fromDecryptedAudio: Data("OggS".utf8), sessionId: 13, duration: 5)
        let dir = store.noteDirectory(id: meta.id)
        try TranscriptDocument(version: 1, speakers: [], segments: [.init(text: "Old remote run.")]).write(in: dir)
        // An on-device re-run (no speaker document) must not leave the old remote document behind.
        let pipeline = NotePipeline(
            store: store,
            transcriber: FakeTranscriber(text: "new on-device text"),
            summarizer: Summarizer(forceUnavailable: true),
            exporter: Exporter(settings: ExportSettings.load()),
            options: PipelineOptions(summarize: false, buildPoster: false)
        )
        _ = try? await pipeline.reprocess(noteId: meta.id)
        XCTAssertEqual(store.readTranscript(noteId: meta.id), "new on-device text")
        XCTAssertNil(store.readTranscriptDocument(noteId: meta.id))
    }

    func test_a_pass_with_a_document_commits_it() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = NoteStore(root: root.appendingPathComponent("notes"))
        let meta = try store.createNote(fromDecryptedAudio: Data("OggS".utf8), sessionId: 14, duration: 5)
        let pipeline = NotePipeline(
            store: store,
            transcriber: DocumentTranscriber(),
            summarizer: Summarizer(forceUnavailable: true),
            exporter: Exporter(settings: ExportSettings.load()),
            options: PipelineOptions(summarize: false, buildPoster: false)
        )
        _ = try? await pipeline.reprocess(noteId: meta.id)
        XCTAssertEqual(store.readTranscriptDocument(noteId: meta.id)?.rendered(), "Speaker 1: Hi.\n\nSpeaker 2: Hello.")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.noteDirectory(id: meta.id).appendingPathComponent(TranscriptDocument.pendingFileName).path))
        XCTAssertTrue(Exporter(settings: ExportSettings.load()).packageFileNames(for: meta).contains(TranscriptDocument.fileName))
    }
}

extension NotePipelineTests {
    func test_a_pending_document_for_a_different_transcript_is_not_installed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = NoteStore(root: root.appendingPathComponent("notes"))
        let meta = try store.createNote(fromDecryptedAudio: Data("OggS".utf8), sessionId: 15, duration: 5)
        let dir = store.noteDirectory(id: meta.id)
        let other = TranscriptDocument(version: 1, speakers: [.init(id: "S1"), .init(id: "S2")],
                                       segments: [.init(speaker: "S1", text: "Other."), .init(speaker: "S2", text: "Pass.")])
        try other.write(in: dir, fileName: TranscriptDocument.pendingFileName)
        try store.writeTranscript(noteId: meta.id, text: "This pass's text.")
        store.commitTranscriptDocument(noteId: meta.id, transcript: "This pass's text.")
        XCTAssertNil(store.readTranscriptDocument(noteId: meta.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(TranscriptDocument.pendingFileName).path))
    }

    func test_reusing_a_stored_transcript_installs_its_pending_document() async throws {
        // A pass killed after writing transcript.md but before installing the document.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = NoteStore(root: root.appendingPathComponent("notes"))
        var meta = try store.createNote(fromDecryptedAudio: Data("OggS".utf8), sessionId: 16, duration: 5)
        let doc = TranscriptDocument(version: 1, speakers: [.init(id: "S1"), .init(id: "S2")],
                                     segments: [.init(speaker: "S1", text: "Hi."), .init(speaker: "S2", text: "Hello.")])
        try doc.write(in: store.noteDirectory(id: meta.id), fileName: TranscriptDocument.pendingFileName)
        try store.writeTranscript(noteId: meta.id, text: doc.rendered())
        meta.transcriptStatus = .done
        try store.updateMetadata(meta)
        let pipeline = NotePipeline(store: store, transcriber: FakeTranscriber(text: "unused"),
                                    summarizer: Summarizer(forceUnavailable: true),
                                    exporter: Exporter(settings: ExportSettings.load()),
                                    options: PipelineOptions(summarize: false, buildPoster: false))
        _ = try? await pipeline.enrichImportedNote(meta)
        XCTAssertEqual(store.readTranscriptDocument(noteId: meta.id), doc)
    }
}

/// Stands in for the remote transcriber: writes a pending document next to the audio.
private struct DocumentTranscriber: Transcribing {
    func transcribe(audioURL: URL) async throws -> String {
        let doc = TranscriptDocument(version: 1, speakers: [.init(id: "S1"), .init(id: "S2")],
                                     segments: [.init(speaker: "S1", text: "Hi."), .init(speaker: "S2", text: "Hello.")])
        try doc.write(in: audioURL.deletingLastPathComponent(), fileName: TranscriptDocument.pendingFileName)
        return doc.rendered()
    }
}

extension NotePipelineTests {
    func test_brief_without_the_poster_image_when_it_is_switched_off() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = NoteStore(root: root.appendingPathComponent("notes"))
        let meta = try store.createNote(fromDecryptedAudio: Data("OggS".utf8), sessionId: 21, duration: 5)
        let brief = CountingBriefBuilder()
        var pipeline = NotePipeline(
            store: store,
            transcriber: FakeTranscriber(text: "We agreed to ship on Friday."),
            summarizer: Summarizer(forceUnavailable: true),
            exporter: Exporter(settings: ExportSettings.load()),
            options: PipelineOptions(summarize: false, buildPoster: true, posterImage: false)
        )
        pipeline.briefBuilder = brief
        let done = try await pipeline.enrichImportedNote(meta)
        XCTAssertEqual(done.briefStatus, .done)
        XCTAssertNil(done.posterFileName)
        XCTAssertEqual(done.title, "Ship on Friday")
        XCTAssertNotNil(store.loadBrief(noteId: meta.id))
        _ = try await pipeline.enrichImportedNote(done)
        XCTAssertEqual(brief.calls, 1, "a finished brief without a poster isn't rebuilt")
    }

    func test_rebuilding_with_the_image_off_removes_the_old_poster() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = NoteStore(root: root.appendingPathComponent("notes"))
        var meta = try store.createNote(fromDecryptedAudio: Data("OggS".utf8), sessionId: 22, duration: 5)
        try store.writeTranscript(noteId: meta.id, text: "Some words.")
        try store.writePoster(noteId: meta.id, fileName: "old.png", pngData: Data([0x89]))
        meta.posterFileName = "old.png"
        meta.transcriptStatus = .done
        try store.updateMetadata(meta)
        var pipeline = NotePipeline(store: store, transcriber: FakeTranscriber(text: "Some words."),
                                    summarizer: Summarizer(forceUnavailable: true),
                                    exporter: Exporter(settings: ExportSettings.load()),
                                    options: PipelineOptions(summarize: false, buildPoster: true, posterImage: false))
        pipeline.briefBuilder = CountingBriefBuilder()
        let rebuilt = try await pipeline.reprocess(noteId: meta.id)
        XCTAssertNil(rebuilt.posterFileName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.noteDirectory(id: meta.id).appendingPathComponent("old.png").path))
    }

    func test_turning_the_brief_off_keeps_an_earlier_brief_without_a_poster() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = NoteStore(root: root.appendingPathComponent("notes"))
        let meta = try store.createNote(fromDecryptedAudio: Data("OggS".utf8), sessionId: 23, duration: 5)
        try store.writeBrief(noteId: meta.id, brief: MeetingBrief(title: "Kept", topics: [], actionItems: []))
        let pipeline = NotePipeline(store: store, transcriber: FakeTranscriber(text: "Words."),
                                    summarizer: Summarizer(forceUnavailable: true),
                                    exporter: Exporter(settings: ExportSettings.load()),
                                    options: PipelineOptions(summarize: false, buildPoster: false))
        let done = try await pipeline.reprocess(noteId: meta.id)
        XCTAssertEqual(done.briefStatus, .done)
    }
}

private final class CountingBriefBuilder: BriefBuilding, @unchecked Sendable {
    private(set) var calls = 0
    func build(transcript: String, summary: String?) async throws -> MeetingBrief {
        calls += 1
        return MeetingBrief(title: "Ship on Friday", topics: [], actionItems: [])
    }
}

struct FakeTranscriber: Transcribing {
    let text: String
    func transcribe(audioURL: URL) async throws -> String { text }
}

extension NotePipelineTests {
    static func fakePlaudContainer(duration: UInt32) -> Data {
        var d = Data("PLAUD.AI".utf8)
        d.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
        d.append(contentsOf: withUnsafeBytes(of: UInt16(512).littleEndian) { Data($0) })
        while d.count < 54 { d.append(0) }
        d.append(contentsOf: withUnsafeBytes(of: duration.littleEndian) { Data($0) })
        while d.count < 512 { d.append(0) }
        d.append(Data("ciphertext-body".utf8))
        return d
    }
}
