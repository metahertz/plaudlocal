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
        let meta = NoteMetadata(
            id: id,
            sessionId: sessionId,
            createdAt: Date(),
            durationSeconds: duration,
            title: "Recording \(sessionId)",
            transcriptStatus: .pending,
            summaryStatus: .pending,
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
}
