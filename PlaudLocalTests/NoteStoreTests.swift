import XCTest
@testable import PlaudLocal

final class NoteStoreTests: XCTestCase {
    func test_createAndList() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = NoteStore(root: root)
        let meta = try store.createNote(
            fromDecryptedAudio: Data("ogg".utf8),
            sessionId: 42,
            duration: 7
        )
        XCTAssertEqual(meta.sessionId, 42)
        let listed = try store.allNotes()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].id, meta.id)
        let audioURL = store.noteDirectory(id: meta.id).appendingPathComponent("audio.ogg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertTrue(store.containsSession(42))
        XCTAssertFalse(store.containsSession(99))
        XCTAssertEqual(try store.note(forSessionId: 42)?.id, meta.id)
    }
}
