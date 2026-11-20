import XCTest
@testable import PlaudLocal

final class ExporterTests: XCTestCase {
    func test_filesExport_writesPackage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = NoteStore(root: root.appendingPathComponent("notes"))
        var meta = try store.createNote(fromDecryptedAudio: Data("ogg".utf8), sessionId: 1_730_000_000, duration: 3)
        try store.writeTranscript(noteId: meta.id, text: "hello")
        try store.writeSummary(noteId: meta.id, text: "sum")
        let brief = MeetingBrief(
            kind: "Launch review",
            title: "Launch Review",
            subtitle: "Team sync on beta readiness and owners.",
            decisions: ["Ship Friday"],
            topics: [
                MeetingTopic(
                    name: "Launch",
                    tag: "Delivery",
                    summary: "Ready to ship",
                    points: [MeetingTopicPoint(title: "Checklist", detail: "Alice owns release steps")]
                ),
            ],
            actionItems: [MeetingActionItem(task: "Send checklist", owner: "Alice", ownerRole: "PM")]
        )
        try store.writeBrief(noteId: meta.id, brief: brief)
        let posterName = BriefBuilder.posterFileName(sessionId: meta.sessionId, title: brief.title)
        try store.writePoster(noteId: meta.id, fileName: posterName, pngData: Data([0x89, 0x50, 0x4E, 0x47]))
        meta.title = brief.title
        meta.posterFileName = posterName
        meta.briefStatus = .done
        try store.updateMetadata(meta)

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
        XCTAssertTrue(package.lastPathComponent.contains("Launch"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.appendingPathComponent("audio.ogg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.appendingPathComponent("transcript.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.appendingPathComponent("brief.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.appendingPathComponent(posterName).path))
    }
}
