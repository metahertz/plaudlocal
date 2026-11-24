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
