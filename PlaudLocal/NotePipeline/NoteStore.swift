import Foundation

enum NoteStoreError: Error {
    case notFound
    case io(Error)
}

struct NoteStore {
    let root: URL

    init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            self.root = docs.appendingPathComponent("Notes", isDirectory: true)
        }
    }

    func createNote(fromDecryptedAudio audio: Data, sessionId: UInt32, duration: Int) throws -> NoteMetadata {
        let id = UUID().uuidString
        let dir = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let audioName = "audio.ogg"
        try audio.write(to: dir.appendingPathComponent(audioName))
        let titleDate = Date(timeIntervalSince1970: TimeInterval(sessionId))
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let label = formatter.string(from: titleDate)
        let meta = NoteMetadata(
            id: id,
            sessionId: sessionId,
            createdAt: Date(),
            durationSeconds: duration,
            title: label,
            recordingLabel: label,
            transcriptStatus: .pending,
            summaryStatus: .pending,
            briefStatus: .pending,
            exportStatus: .pending,
            audioFileName: audioName
        )
        try updateMetadata(meta)
        return meta
    }

    func noteDirectory(id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    func updateMetadata(_ meta: NoteMetadata) throws {
        let url = noteDirectory(id: meta.id).appendingPathComponent("metadata.json")
        let data = try JSONEncoder().encode(meta)
        try data.write(to: url, options: .atomic)
    }

    func allNotes() throws -> [NoteMetadata] {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dirs = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return try dirs.compactMap { dir -> NoteMetadata? in
            let metaURL = dir.appendingPathComponent("metadata.json")
            guard FileManager.default.fileExists(atPath: metaURL.path) else { return nil }
            let data = try Data(contentsOf: metaURL)
            return try JSONDecoder().decode(NoteMetadata.self, from: data)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    func note(forSessionId sessionId: UInt32) throws -> NoteMetadata? {
        try allNotes().first { $0.sessionId == sessionId }
    }

    func containsSession(_ sessionId: UInt32) -> Bool {
        (try? note(forSessionId: sessionId)) != nil
    }

    func knownSessionIds() -> Set<UInt32> {
        Set((try? allNotes().map(\.sessionId)) ?? [])
    }

    func writeTranscript(noteId: String, text: String) throws {
        try text.write(
            to: noteDirectory(id: noteId).appendingPathComponent("transcript.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    func writeSummary(noteId: String, text: String) throws {
        try text.write(
            to: noteDirectory(id: noteId).appendingPathComponent("summary.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    func writeBrief(noteId: String, brief: MeetingBrief) throws {
        let data = try JSONEncoder().encode(brief)
        try data.write(
            to: noteDirectory(id: noteId).appendingPathComponent("brief.json"),
            options: .atomic
        )
    }

    func loadBrief(noteId: String) -> MeetingBrief? {
        let url = noteDirectory(id: noteId).appendingPathComponent("brief.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MeetingBrief.self, from: data)
    }

    func writePoster(noteId: String, fileName: String, pngData: Data) throws {
        let dir = noteDirectory(id: noteId)
        // Remove any previous poster files so renames don't leave orphans.
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension.lowercased() == "png" {
                try? FileManager.default.removeItem(at: file)
            }
        }
        try pngData.write(to: dir.appendingPathComponent(fileName), options: .atomic)
    }

    func posterURL(for meta: NoteMetadata) -> URL? {
        guard let name = meta.posterFileName else { return nil }
        let url = noteDirectory(id: meta.id).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The note's speaker transcript (issue #12), if it has one.
    func readTranscriptDocument(noteId: String) -> TranscriptDocument? {
        TranscriptDocument.read(in: noteDirectory(id: noteId))
    }

    /// Keeps `transcript.json` in step with the `transcript` just stored as `transcript.md`.
    ///
    /// A pending document (written by the transcription engine) is installed only if its unnamed
    /// rendering is exactly this transcript; an existing document is kept only if it still renders
    /// to it (with or without the user's names). Anything else is removed, so the document never
    /// describes a different transcript: on-device runs, the on-device fallback, older servers,
    /// overlapping passes over one note, or a pass killed between writing the text and the document.
    func commitTranscriptDocument(noteId: String, transcript: String) {
        let dir = noteDirectory(id: noteId)
        let pendingURL = dir.appendingPathComponent(TranscriptDocument.pendingFileName)
        let finalURL = dir.appendingPathComponent(TranscriptDocument.fileName)
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if let pending = TranscriptDocument.read(in: dir, fileName: TranscriptDocument.pendingFileName),
           pending.anonymousRendering() == text {
            try? FileManager.default.removeItem(at: finalURL)
            try? FileManager.default.moveItem(at: pendingURL, to: finalURL)
            return
        }
        try? FileManager.default.removeItem(at: pendingURL)
        if let existing = TranscriptDocument.read(in: dir),
           existing.anonymousRendering() == text || existing.rendered() == text {
            return
        }
        try? FileManager.default.removeItem(at: finalURL)
    }

    /// Before a transcription pass, or after a failed one: drop a document left from an earlier pass.
    func discardPendingTranscriptDocument(noteId: String) {
        try? FileManager.default.removeItem(
            at: noteDirectory(id: noteId).appendingPathComponent(TranscriptDocument.pendingFileName)
        )
    }

    func readTranscript(noteId: String) -> String? {
        try? String(
            contentsOf: noteDirectory(id: noteId).appendingPathComponent("transcript.md"),
            encoding: .utf8
        )
    }

    func readSummary(noteId: String) -> String? {
        try? String(
            contentsOf: noteDirectory(id: noteId).appendingPathComponent("summary.md"),
            encoding: .utf8
        )
    }

    func deleteNote(id: String) throws {
        let dir = noteDirectory(id: id)
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw NoteStoreError.notFound
        }
        try FileManager.default.removeItem(at: dir)
    }

    func audioURL(for meta: NoteMetadata) -> URL {
        noteDirectory(id: meta.id).appendingPathComponent(meta.audioFileName)
    }
}
