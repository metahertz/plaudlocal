import SwiftUI

struct LibraryView: View {
    @State private var notes: [NoteMetadata] = []
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if notes.isEmpty {
                    ContentUnavailableView(
                        "No notes yet",
                        systemImage: "waveform",
                        description: Text("Download a recording from the Device tab.")
                    )
                } else {
                    List(notes) { note in
                        NavigationLink(value: note) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(note.title).font(.headline)
                                Text(note.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                HStack(spacing: 8) {
                                    statusChip("ASR", note.transcriptStatus)
                                    statusChip("Sum", note.summaryStatus)
                                    statusChip("Exp", note.exportStatus)
                                }
                            }
                        }
                    }
                    .navigationDestination(for: NoteMetadata.self) { note in
                        NoteDetailView(noteId: note.id)
                    }
                }
            }
            .navigationTitle("Library")
            .task { reload() }
            .refreshable { reload() }
            .alert("Error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func reload() {
        do {
            notes = try NoteStore().allNotes()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func statusChip(_ label: String, _ status: PipelineStatus) -> some View {
        Text("\(label): \(status.rawValue)")
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15))
            .clipShape(Capsule())
    }
}
