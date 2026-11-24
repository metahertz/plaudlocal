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

extension NoteStoreTests {
    private func makeStore() throws -> (NoteStore, NoteMetadata) {
        let store = NoteStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        return (store, try store.createNote(fromDecryptedAudio: Data("OggS".utf8), sessionId: 1_730_000_500, duration: 5))
    }

    func test_rename_sets_the_title_and_the_library_shows_it() throws {
        let (store, meta) = try makeStore()
        let renamed = try store.renameNote(id: meta.id, to: "  Budget review with Priya ")
        XCTAssertEqual(renamed.title, "Budget review with Priya")
        XCTAssertTrue(renamed.titleSetByUser)
        XCTAssertEqual(renamed.libraryHeadline, "Budget review with Priya", "shown even before a brief exists")
    }

    func test_a_pass_holding_old_metadata_cannot_overwrite_a_typed_title() throws {
        let (store, meta) = try makeStore()
        var stale = meta              // a pipeline pass that started before the rename
        try store.renameNote(id: meta.id, to: "My title")
        stale.title = "Brief's generated title"
        stale.briefStatus = .done
        try store.updateMetadata(stale)
        let current = try XCTUnwrap(try store.allNotes().first { $0.id == meta.id })
        XCTAssertEqual(current.title, "My title")
        XCTAssertTrue(current.titleSetByUser)
        XCTAssertEqual(current.briefStatus, .done, "the pass's other changes still land")
    }

    func test_a_pass_that_saw_an_earlier_rename_cannot_undo_a_later_one_or_a_reset() throws {
        let (store, meta) = try makeStore()
        let snapshot = try store.renameNote(id: meta.id, to: "First name")   // a pass reads this
        try store.renameNote(id: meta.id, to: "Second name")
        try store.updateMetadata(snapshot)
        XCTAssertEqual(try store.allNotes().first { $0.id == meta.id }?.title, "Second name")
        try store.renameNote(id: meta.id, to: "")
        try store.updateMetadata(snapshot)
        let reset = try XCTUnwrap(try store.allNotes().first { $0.id == meta.id })
        XCTAssertFalse(reset.titleSetByUser)
        XCTAssertEqual(reset.title, meta.recordingLabel)
    }

    func test_empty_rename_goes_back_to_the_briefs_title_when_there_is_one() throws {
        let (store, meta) = try makeStore()
        try store.writeBrief(noteId: meta.id, brief: MeetingBrief(title: "Budget sync", topics: [], actionItems: []))
        try store.renameNote(id: meta.id, to: "Typed")
        XCTAssertEqual(try store.renameNote(id: meta.id, to: "").title, "Budget sync")
    }

    func test_saving_the_automatic_title_unchanged_does_not_lock_it() throws {
        let (store, meta) = try makeStore()
        let saved = try store.renameNote(id: meta.id, to: meta.libraryHeadline)
        XCTAssertFalse(saved.titleSetByUser)
    }

    func test_empty_rename_goes_back_to_the_automatic_title() throws {
        let (store, meta) = try makeStore()
        try store.renameNote(id: meta.id, to: "Typed")
        let reverted = try store.renameNote(id: meta.id, to: "   ")
        XCTAssertFalse(reverted.titleSetByUser)
        XCTAssertEqual(reverted.title, meta.recordingLabel)
    }

    func test_older_metadata_without_the_flag_still_loads() throws {
        let (store, meta) = try makeStore()
        let url = store.noteDirectory(id: meta.id).appendingPathComponent("metadata.json")
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object.removeValue(forKey: "titleSetByUser")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        XCTAssertEqual(try store.allNotes().first { $0.id == meta.id }?.titleSetByUser, false)
    }
}

extension NoteStoreTests {
    private func noteWithSpeakers() throws -> (NoteStore, NoteMetadata) {
        let store = NoteStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let meta = try store.createNote(fromDecryptedAudio: Data("OggS".utf8), sessionId: 1_730_000_600, duration: 5)
        var s2 = TranscriptDocument.Speaker(id: "S2")
        s2.suggestion = .init(name: "Priya", source: "llm", confidence: 0.8, evidence: "answers")
        let doc = TranscriptDocument(version: 1, speakers: [.init(id: "S1"), s2],
                                     segments: [.init(speaker: "S1", text: "Budget?"), .init(speaker: "S2", text: "Four percent over.")])
        try doc.write(in: store.noteDirectory(id: meta.id))
        try store.writeTranscript(noteId: meta.id, text: doc.rendered())
        return (store, meta)
    }

    func test_naming_a_speaker_updates_the_document_and_the_transcript() throws {
        let (store, meta) = try noteWithSpeakers()
        let doc = try store.renameSpeaker(noteId: meta.id, speakerId: "S2", to: " Priya ")
        XCTAssertEqual(doc.speakers[1].userName, "Priya")
        XCTAssertEqual(doc.speakers[1].suggestion?.name, "Priya", "the suggestion is kept alongside the name")
        XCTAssertEqual(store.readTranscriptDocument(noteId: meta.id)?.speakers[1].nameSource, "user")
        XCTAssertEqual(store.readTranscript(noteId: meta.id), "Speaker 1: Budget?\n\nPriya: Four percent over.")
        XCTAssertEqual(doc.anonymousRendering(), "Speaker 1: Budget?\n\nSpeaker 2: Four percent over.",
                       "naming doesn't change the anonymous text the job-reuse check compares")
    }

    func test_an_empty_name_goes_back_to_speaker_n() throws {
        let (store, meta) = try noteWithSpeakers()
        try store.renameSpeaker(noteId: meta.id, speakerId: "S1", to: "Laura")
        let doc = try store.renameSpeaker(noteId: meta.id, speakerId: "S1", to: "  ")
        XCTAssertNil(doc.speakers[0].name)
        XCTAssertNil(doc.speakers[0].nameSource)
        XCTAssertEqual(store.readTranscript(noteId: meta.id), "Speaker 1: Budget?\n\nSpeaker 2: Four percent over.")
    }

    func test_renaming_a_speaker_without_a_document_fails_cleanly() throws {
        let store = NoteStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let meta = try store.createNote(fromDecryptedAudio: Data("OggS".utf8), sessionId: 1_730_000_601, duration: 5)
        XCTAssertThrowsError(try store.renameSpeaker(noteId: meta.id, speakerId: "S1", to: "X"))
    }

    func test_renaming_an_unknown_speaker_fails() throws {
        let (store, meta) = try noteWithSpeakers()
        XCTAssertThrowsError(try store.renameSpeaker(noteId: meta.id, speakerId: "S9", to: "X"))
    }
}
