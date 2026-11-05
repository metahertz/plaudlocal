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
        try Data("ciphertext".utf8).write(to: downloaded)

        let pipeline = NotePipeline(
            store: store,
            transcriber: FakeTranscriber(text: "hi"),
            summarizer: Summarizer(forceUnavailable: true),
            exporter: exporter,
            decrypt: { data, _ in data },
            privateKeyPEMProvider: { "KEY" }
        )
        let meta = try await pipeline.processDownloadedFile(downloaded, sessionId: 1, duration: 1)
        XCTAssertEqual(meta.exportStatus, .skipped)
    }

    func test_missing_key_throws_needsReSignIn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = NoteStore(root: root.appendingPathComponent("notes"))
        var settings = ExportSettings.load(keyVault: KeyVault(service: "com.local.plaudlocal.tests.nokey"))
        settings.autoExportEnabled = false
        let exporter = Exporter(settings: settings)
        let downloaded = root.appendingPathComponent("in.plaud")
        try Data("x".utf8).write(to: downloaded)

        let pipeline = NotePipeline(
            store: store,
            transcriber: FakeTranscriber(text: "hi"),
            summarizer: Summarizer(forceUnavailable: true),
            exporter: exporter,
            decrypt: { _, _ in throw FileDecryptorError.rsaFailed },
            privateKeyPEMProvider: { "bad" }
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
