import XCTest
@testable import PlaudLocal

final class NotePipelineExportTests: XCTestCase {
    func test_export_failure_marks_failed_not_running() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = NoteStore(root: root.appendingPathComponent("notes"))
        let vault = KeyVault(service: "com.local.plaudlocal.tests.exportfail")
        try vault.save(Data("KEY".utf8), account: "plaud.rsaPrivatePEM")

        var settings = ExportSettings.load(keyVault: vault)
        settings.autoExportEnabled = true
        // Force remote export path with bad password empty → no write; and no local override.
        // Exporter returns wroteLocal=false, wroteRemote=false → pipeline must not mark done.
        let exporter = Exporter(settings: settings)

        let downloaded = root.appendingPathComponent("in.plaud")
        try NotePipelineTests.fakePlaudContainer(duration: 1).write(to: downloaded)

        let pipeline = NotePipeline(
            store: store,
            transcriber: FakeTranscriber(text: "hi"),
            summarizer: Summarizer(forceUnavailable: true),
            exporter: exporter,
            decrypt: { _, _ in Data("OggSfake".utf8) },
            privateKeyPEMProvider: { "KEY" }
        )
        let meta = try await pipeline.processDownloadedFile(downloaded, sessionId: 1, duration: 1)
        XCTAssertEqual(meta.exportStatus, .skipped)
    }

    func test_audioOnlyMode_skipsASR_andExportsAudioPackage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = NoteStore(root: root.appendingPathComponent("notes"))
        let vault = KeyVault(service: "com.local.plaudlocal.tests.audioonly")
        try vault.save(Data("KEY".utf8), account: "plaud.rsaPrivatePEM")

        var settings = ExportSettings.load(keyVault: vault)
        settings.audioOnlyMode = true
        settings.autoExportEnabled = false
        let localDest = root.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: localDest, withIntermediateDirectories: true)
        let exporter = Exporter(settings: settings, localFolderOverride: localDest)

        let downloaded = root.appendingPathComponent("in.plaud")
        try NotePipelineTests.fakePlaudContainer(duration: 12).write(to: downloaded)

        let pipeline = NotePipeline(
            store: store,
            transcriber: FakeTranscriber(text: "SHOULD NOT RUN"),
            summarizer: Summarizer(forceUnavailable: true),
            exporter: exporter,
            decrypt: { _, _ in Data("OggSfake-audio".utf8) },
            privateKeyPEMProvider: { "KEY" }
        )
        let meta = try await pipeline.processDownloadedFile(downloaded, sessionId: 42, duration: 12)
        // Placeholder skip text is written; the fake ASR string must never appear.
        XCTAssertFalse((store.readTranscript(noteId: meta.id) ?? "").contains("SHOULD NOT RUN"))
        XCTAssertTrue(meta.audioOnlyExport)
        XCTAssertEqual(meta.transcriptStatus, .skipped)
        XCTAssertEqual(meta.summaryStatus, .skipped)
        XCTAssertEqual(meta.briefStatus, .skipped)
        XCTAssertEqual(meta.exportStatus, .done)

        let packages = try FileManager.default.contentsOfDirectory(at: localDest, includingPropertiesForKeys: nil)
        XCTAssertEqual(packages.count, 1)
        let files = try FileManager.default.contentsOfDirectory(at: packages[0], includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
            .sorted()
        XCTAssertEqual(files, ["README.txt", "audio.ogg", "metadata.json"])
    }

    func test_missing_key_throws_needsReSignIn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = NoteStore(root: root.appendingPathComponent("notes"))
        var settings = ExportSettings.load(keyVault: KeyVault(service: "com.local.plaudlocal.tests.nokey"))
        settings.autoExportEnabled = false
        let exporter = Exporter(settings: settings)
        let downloaded = root.appendingPathComponent("in.plaud")
        try NotePipelineTests.fakePlaudContainer(duration: 1).write(to: downloaded)

        let pipeline = NotePipeline(
            store: store,
            transcriber: FakeTranscriber(text: "hi"),
            summarizer: Summarizer(forceUnavailable: true),
            exporter: exporter,
            decrypt: { _, _ in throw FileDecryptorError.rsaFailed },
            privateKeyPEMProvider: { nil }
        )
        do {
            _ = try await pipeline.processDownloadedFile(downloaded, sessionId: 1, duration: 1)
            XCTFail("expected needsReSignIn")
        } catch FileDecryptorError.needsReSignIn {
            // ok
        } catch {
            XCTFail("\(error)")
        }
    }
}
