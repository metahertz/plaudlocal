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
        var meta = meta
        // `renameNote` is the only way to change a title the user set. A pipeline pass holds the
        // metadata it read when it started, so whenever either that copy or the file has a user
        // title, the file's title and flag stand: the pass can't write the brief's title over a
        // rename, or an earlier rename over a later one or a reset. With neither set, the pass's
        // title (the brief's) is written as before.
        if let current = metadata(id: meta.id), current.titleSetByUser || meta.titleSetByUser {
            meta.title = current.title
            meta.titleSetByUser = current.titleSetByUser
        }
        try writeMetadata(meta)
    }

    /// Sets the note's title as the user typed it. An empty title goes back to the automatic one
    /// (the brief's title, else the recording label).
    @discardableResult
    func renameNote(id: String, to title: String) throws -> NoteMetadata {
        guard var meta = metadata(id: id) else { throw NoteStoreError.notFound }
        let typed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !meta.titleSetByUser, typed == meta.libraryHeadline {
            return meta  // saved unchanged: keep following the automatic title
        }
        if typed.isEmpty {
            meta.title = loadBrief(noteId: id)?.title ?? meta.recordingLabel
            meta.titleSetByUser = false
        } else {
            meta.title = typed
            meta.titleSetByUser = true
        }
        try writeMetadata(meta)
        return meta
    }

    private func metadata(id: String) -> NoteMetadata? {
        let url = noteDirectory(id: id).appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(NoteMetadata.self, from: data)
    }

    private func writeMetadata(_ meta: NoteMetadata) throws {
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
