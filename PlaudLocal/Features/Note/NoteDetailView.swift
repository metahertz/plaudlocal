import SwiftUI

struct NoteDetailView: View {
    let noteId: String
    @State private var meta: NoteMetadata?
    @State private var transcript = ""
    @State private var summary = ""

    var body: some View {
        List {
            if let meta {
                Section("Info") {
                    LabeledContent("Title", value: meta.title)
                    LabeledContent("Duration", value: "\(meta.durationSeconds)s")
                    LabeledContent("Session", value: String(meta.sessionId))
                }
            }
            Section("Transcript") {
                Text(transcript.isEmpty ? "Not transcribed yet" : transcript)
                    .font(.body)
            }
            Section("Summary") {
                Text(summary.isEmpty ? "No summary" : summary)
                    .font(.body)
            }
        }
        .navigationTitle(meta?.title ?? "Note")
        .task { load() }
    }

    private func load() {
        let store = NoteStore()
        meta = try? store.allNotes().first(where: { $0.id == noteId })
        let dir = store.noteDirectory(id: noteId)
        transcript = (try? String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)) ?? ""
        summary = (try? String(contentsOf: dir.appendingPathComponent("summary.md"), encoding: .utf8)) ?? ""
    }
}
