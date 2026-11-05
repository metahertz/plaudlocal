import XCTest
@testable import PlaudLocal

final class ExporterTests: XCTestCase {
    func test_filesExport_writesPackage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = NoteStore(root: root.appendingPathComponent("notes"))
        let meta = try store.createNote(fromDecryptedAudio: Data("ogg".utf8), sessionId: 9, duration: 3)
        try store.writeTranscript(noteId: meta.id, text: "hello")
        try store.writeSummary(noteId: meta.id, text: "sum")

        let exportRoot = root.appendingPathComponent("export")
        try FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: true)

        var settings = ExportSettings.load(keyVault: KeyVault(service: "com.local.plaudlocal.tests.export"))
        settings.autoExportEnabled = true
        var exporter = Exporter(settings: settings)
        exporter.localFolderOverride = exportRoot

        let result = try await exporter.export(meta, store: store)
        XCTAssertTrue(result.wroteLocal)
        let children = try FileManager.default.contentsOfDirectory(at: exportRoot, includingPropertiesForKeys: nil)
        XCTAssertEqual(children.count, 1)
        let package = children[0]
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.appendingPathComponent("audio.ogg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.appendingPathComponent("transcript.md").path))
    }
}
