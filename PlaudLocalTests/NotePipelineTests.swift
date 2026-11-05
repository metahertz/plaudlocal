import XCTest
@testable import PlaudLocal

final class NotePipelineTests: XCTestCase {
    func test_skipsSummaryStillExports() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = NoteStore(root: root.appendingPathComponent("notes"))
        let exportRoot = root.appendingPathComponent("export")
        try FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: true)

        let vault = KeyVault(service: "com.local.plaudlocal.tests.pipeline")
        try vault.save(Data("KEY".utf8), account: "plaud.rsaPrivatePEM")

        var settings = ExportSettings.load(keyVault: vault)
        settings.autoExportEnabled = true
        var exporter = Exporter(settings: settings)
        exporter.localFolderOverride = exportRoot

        let downloaded = root.appendingPathComponent("in.plaud")
        try Data("ciphertext".utf8).write(to: downloaded)

        let pipeline = NotePipeline(
            store: store,
            transcriber: FakeTranscriber(text: "hello world"),
            summarizer: Summarizer(forceUnavailable: true),
            exporter: exporter,
            decrypt: { data, _ in data },
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

struct FakeTranscriber: Transcribing {
    let text: String
    func transcribe(audioURL: URL) async throws -> String { text }
}
