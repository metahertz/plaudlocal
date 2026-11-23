import SwiftUI

struct LibraryView: View {
    @State private var notes: [NoteMetadata] = []
    @State private var errorMessage: String?
    @State private var isSelecting = false
    @State private var selection = Set<String>()
    @State private var confirmDeleteAll = false
    @State private var resumeTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                if notes.isEmpty {
                    ContentUnavailableView(
                        "No notes yet",
                        systemImage: "waveform",
                        description: Text("Download a recording from the Device tab.")
                    )
                } else if isSelecting {
                    List(selection: $selection) {
                        ForEach(notes) { note in
                            noteRow(note)
                                .tag(note.id)
                        }
                    }
                    .environment(\.editMode, .constant(.active))
                } else {
                    List {
                        ForEach(notes) { note in
                            NavigationLink(value: note) {
                                noteRow(note)
                            }
                        }
                        .onDelete(perform: deleteNotes)
                    }
                    .navigationDestination(for: NoteMetadata.self) { note in
                        NoteDetailView(noteId: note.id)
                    }
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !notes.isEmpty {
                        Button(isSelecting ? "Done" : "Select") {
                            withAnimation {
                                isSelecting.toggle()
                                if !isSelecting { selection.removeAll() }
                            }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isSelecting, !notes.isEmpty {
                        Menu {
                            Button("Delete Selected", role: .destructive) {
                                deleteSelected()
                            }
                            .disabled(selection.isEmpty)
                            Button("Delete All…", role: .destructive) {
                                confirmDeleteAll = true
                            }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .task {
                reload()
                await resumeInterruptedPipeline()
            }
            .refreshable {
                reload()
                await resumeInterruptedPipeline()
            }
            .alert("Error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .confirmationDialog(
                "Delete all \(notes.count) notes?",
                isPresented: $confirmDeleteAll,
                titleVisibility: .visible
            ) {
                Button("Delete All", role: .destructive) { deleteAll() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    @ViewBuilder
    private func noteRow(_ note: NoteMetadata) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(note.libraryHeadline).font(.headline)
            if note.briefStatus == .done, note.title != note.recordingLabel {
                Text(note.recordingLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text(note.recordingDate.formatted(date: .abbreviated, time: .shortened))
                Text("·")
                Text(durationLabel(note.durationSeconds))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                statusChip("ASR", note.transcriptStatus)
                statusChip("Sum", note.summaryStatus)
                statusChip("Poster", note.briefStatus)
                statusChip("Exp", note.exportStatus)
            }
        }
    }

    private func reload() {
        do {
            let store = NoteStore()
            var loaded = try store.allNotes()
            for i in loaded.indices where loaded[i].durationSeconds <= 0 {
                let url = store.audioURL(for: loaded[i])
                if let secs = AudioDuration.seconds(at: url) {
                    loaded[i].durationSeconds = secs
                    try? store.updateMetadata(loaded[i])
                }
            }
            notes = loaded
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Clear stuck `.running` chips after jetsam/kill, then finish summary/poster for notes that already have a transcript.
    private func resumeInterruptedPipeline() async {
        resumeTask?.cancel()
        let store = NoteStore()
        let pending = PipelineRecovery.recoverInterrupted(store: store)
        reload()
        guard !pending.isEmpty else { return }

        resumeTask = Task {
            var settings = ExportSettings.load()
            settings.autoExportEnabled = UserDefaults.standard.bool(forKey: "export.autoEnabled")
            let pipeline = NotePipeline(
                store: store,
                transcriber: PipelineEngines.transcriber(),
                summarizer: PipelineEngines.summarizer(),
                exporter: Exporter(settings: settings),
                options: PipelineOptions.load()
            )
            for note in pending {
                if Task.isCancelled { break }
                _ = try? await pipeline.enrichImportedNote(note)
                await MainActor.run { reload() }
            }
        }
        await resumeTask?.value
    }

    private func deleteNotes(at offsets: IndexSet) {
        let store = NoteStore()
        for index in offsets {
            do {
                try store.deleteNote(id: notes[index].id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        selection.removeAll()
        reload()
    }

    private func deleteSelected() {
        let store = NoteStore()
        for id in selection {
            do {
                try store.deleteNote(id: id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        selection.removeAll()
        isSelecting = false
        reload()
    }

    private func deleteAll() {
        let store = NoteStore()
        for note in notes {
            do {
                try store.deleteNote(id: note.id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        selection.removeAll()
        isSelecting = false
        reload()
    }

    private func durationLabel(_ seconds: Int) -> String {
        if seconds <= 0 { return "0s" }
        let m = seconds / 60
        let s = seconds % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
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
