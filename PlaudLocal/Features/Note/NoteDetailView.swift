import AVFoundation
import SwiftUI

struct NoteDetailView: View {
    let noteId: String
    @State private var meta: NoteMetadata?
    @State private var transcript = ""
    @State private var summary = ""
    @State private var brief: MeetingBrief?
    @State private var posterURL: URL?
    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var playError: String?
    @State private var audioBytes: Int = 0
    @State private var isReprocessing = false
    @State private var remoteAvailable = RemoteProcessingSettings.load().connection != nil
    @State private var isBuildingPoster = false
    @State private var statusMessage: String?
    @State private var sharePayload: SharePayload?
    @State private var showingRename = false
    @State private var renameText = ""
    @State private var speakerDocument: TranscriptDocument?
    @State private var renamingSpeakerId: String?
    @State private var showingSpeakerRename = false
    @State private var speakerNameText = ""
    @State private var speakerExport: Task<Void, Never>?

    var body: some View {
        List {
            if let meta {
                Section("Info") {
                    Button {
                        renameText = meta.titleSetByUser ? meta.title : meta.libraryHeadline
                        showingRename = true
                    } label: {
                        LabeledContent("Title") {
                            HStack(spacing: 6) {
                                Text(meta.title)
                                Image(systemName: "pencil").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    LabeledContent("Recording", value: meta.recordingLabel)
                    LabeledContent("Duration", value: "\(meta.durationSeconds)s")
                    LabeledContent("Audio", value: ByteCountFormatter.string(fromByteCount: Int64(audioBytes), countStyle: .file))
                    LabeledContent("ASR", value: meta.transcriptStatus.rawValue)
                    LabeledContent("Summary", value: meta.summaryStatus.rawValue)
                    LabeledContent("Poster", value: meta.briefStatus.rawValue)
                    if meta.audioOnlyExport {
                        Text("Imported as audio-only — transcription and summary were skipped.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Playback") {
                    if let playError {
                        Text(playError).foregroundStyle(.red).font(.footnote)
                    }
                    Button {
                        togglePlay()
                    } label: {
                        Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
                    }
                    .disabled(audioBytes == 0)
                }
            }

            if let brief {
                Section("At a glance") {
                    if let posterURL, let image = UIImage(contentsOfFile: posterURL.path) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    }
                    briefPreview(brief)
                    Button {
                        sharePoster()
                    } label: {
                        Label("Share poster", systemImage: "square.and.arrow.up")
                    }
                    .disabled(posterURL == nil)
                }
            }

            Section {
                if remoteAvailable {
                    // A server is set up: let this one note go either way, whatever the saved mode.
                    Menu {
                        Button {
                            Task { await reprocess(using: .onDevice) }
                        } label: {
                            Label("On this iPhone", systemImage: "iphone")
                        }
                        Button {
                            Task { await reprocess(using: .remote) }
                        } label: {
                            Label("On the remote server", systemImage: "server.rack")
                        }
                    } label: {
                        reprocessLabel
                    }
                    .disabled(isReprocessing || isBuildingPoster || audioBytes == 0)
                } else {
                    Button {
                        Task { await reprocess() }
                    } label: {
                        reprocessLabel
                    }
                    .disabled(isReprocessing || isBuildingPoster || audioBytes == 0)
                }

                Button {
                    Task { await rebuildPoster() }
                } label: {
                    if isBuildingPoster {
                        HStack {
                            ProgressView()
                            Text("Building poster…")
                        }
                    } else {
                        Label("Rebuild poster", systemImage: "doc.richtext")
                    }
                }
                .disabled(isReprocessing || isBuildingPoster || transcript.isEmpty)

                if let statusMessage {
                    Text(statusMessage).font(.footnote).foregroundStyle(.secondary)
                }
            }

            if let speakerDocument, !speakerDocument.speakers.isEmpty {
                Section {
                    ForEach(speakerDocument.speakers, id: \.id) { speaker in
                        speakerRow(speaker)
                    }
                } header: {
                    Text("Speakers")
                } footer: {
                    Text("Names are used in the transcript and when you share or export it. The summary and poster keep what they were made with. Transcribing again starts over with new speakers.")
                }
            }
            Section {
                Text(transcript.isEmpty ? "Not transcribed yet" : transcript)
                    .font(.body)
            } header: {
                sectionHeader("Transcript", sharing: transcript)
            }
            Section {
                Text(summary.isEmpty ? "No summary" : summary)
                    .font(.body)
            } header: {
                sectionHeader("Summary", sharing: summary)
            }
        }
        .navigationTitle(meta?.title ?? "Note")
        .task { load() }
        .alert("Name this speaker", isPresented: $showingSpeakerRename) {
            TextField("Name", text: $speakerNameText)
            Button("Save") { if let id = renamingSpeakerId { nameSpeaker(id, speakerNameText) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leave it empty to remove the name.")
        }
        .alert("Rename recording", isPresented: $showingRename) {
            TextField("Title", text: $renameText)
            Button("Save") {
                do {
                    meta = try NoteStore().renameNote(id: noteId, to: renameText)
                } catch {
                    statusMessage = error.localizedDescription
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leave it empty to go back to the automatic title.")
        }
        .onDisappear {
            player?.stop()
            isPlaying = false
        }
        .sheet(item: $sharePayload) { payload in
            ActivityView(items: payload.items)
        }
    }

    @ViewBuilder
    private func briefPreview(_ brief: MeetingBrief) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !brief.kind.isEmpty {
                Text(brief.kind)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(Capsule())
            }
            if !brief.subtitle.isEmpty {
                Text(brief.subtitle).font(.footnote).foregroundStyle(.secondary)
            }
            if !brief.decisions.isEmpty {
                labeledBullets("Decisions", brief.decisions)
            }
            if !brief.topics.isEmpty {
                Text("Topics").font(.subheadline.weight(.semibold))
                ForEach(brief.topics) { topic in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(topic.name).font(.body.weight(.semibold))
                            if !topic.tag.isEmpty {
                                Text(topic.tag)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(topic.summary).font(.footnote).foregroundStyle(.secondary)
                        ForEach(topic.points) { point in
                            Text("\(point.title): \(point.detail)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !brief.actionItems.isEmpty {
                Text("Next steps").font(.subheadline.weight(.semibold))
                ForEach(Array(brief.actionOwners.enumerated()), id: \.offset) { _, group in
                    VStack(alignment: .leading, spacing: 2) {
                        if let owner = group.owner {
                            Text(owner + (group.role.map { " · \($0)" } ?? ""))
                                .font(.caption.weight(.semibold))
                        }
                        ForEach(group.tasks, id: \.self) { task in
                            Text("○ \(task)").font(.footnote)
                        }
                    }
                }
            }
        }
    }

    private func labeledBullets(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            ForEach(items, id: \.self) { item in
                Text("• \(item)")
            }
        }
    }

    /// A section title with a share button (iOS share sheet: Copy, Messages, Mail, Notes, AirDrop…)
    /// once the section has text to share.
    @ViewBuilder
    private func sectionHeader(_ title: String, sharing text: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ShareLink(
                    item: text,
                    subject: Text("\(title): \(meta?.libraryHeadline ?? "Recording")"),
                    preview: SharePreview("\(title): \(meta?.libraryHeadline ?? "Recording")")
                ) {
                    Image(systemName: "square.and.arrow.up")
                        .imageScale(.large)
                        .frame(minWidth: 44, minHeight: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Share \(title.lowercased())")
            }
        }
    }

    @ViewBuilder
    private func speakerRow(_ speaker: TranscriptDocument.Speaker) -> some View {
        let label = "Speaker \(speaker.id.dropFirst())"
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(speaker.name ?? label).font(.body.weight(speaker.name == nil ? .regular : .semibold))
                if speaker.name != nil { Text(label).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(speaker.name == nil ? "Name" : "Rename") {
                    renamingSpeakerId = speaker.id
                    speakerNameText = speaker.name ?? speaker.suggestion?.name ?? ""
                    showingSpeakerRename = true
                }
                .buttonStyle(.borderless)
                .disabled(isReprocessing)
            }
            if speaker.userName == nil, let suggestion = speaker.suggestion {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Suggested: \(suggestion.name)" + (suggestion.confidence.map { String(format: " (%.0f%%)", $0 * 100) } ?? ""))
                            .font(.subheadline)
                        if let evidence = suggestion.evidence, !evidence.isEmpty {
                            Text(evidence).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Accept") { nameSpeaker(speaker.id, suggestion.name) }
                        .buttonStyle(.borderless)
                        .disabled(isReprocessing)
                }
            }
        }
    }

    private func nameSpeaker(_ speakerId: String, _ name: String) {
        let store = NoteStore()
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if speakerDocument?.speakers.first(where: { $0.id == speakerId })?.userName ?? "" == typed { return }
        do {
            speakerDocument = try store.renameSpeaker(noteId: noteId, speakerId: speakerId, to: name)
            transcript = store.readTranscript(noteId: noteId) ?? transcript
            exportIfAutomatic()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// With auto-export on, re-export the transcript files so the export carries the new names.
    /// Waits a moment so several quick renames make one upload. Audio-only exports have no
    /// transcript, so there's nothing to redo.
    private func exportIfAutomatic() {
        guard let meta else { return }
        var settings = ExportSettings.load()
        settings.autoExportEnabled = UserDefaults.standard.bool(forKey: "export.autoEnabled")
        guard settings.autoExportEnabled, !settings.audioOnlyMode, !meta.audioOnlyExport else { return }
        speakerExport?.cancel()
        speakerExport = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            let store = NoteStore()
            let snapshot = (try? store.allNotes().first { $0.id == noteId }) ?? meta
            let status: PipelineStatus
            do {
                let result = try await Exporter(settings: settings)
                    .export(snapshot, store: store, only: ["transcript.md", TranscriptDocument.fileName])
                status = (result.wroteLocal || result.wroteRemote) ? .done : .skipped
            } catch {
                status = .failed
                statusMessage = "Export of the renamed transcript failed: \(error.localizedDescription)"
            }
            // Re-read: a pipeline pass may have saved the note during the upload.
            guard var current = try? store.allNotes().first(where: { $0.id == noteId }) else { return }
            current.exportStatus = status
            try? store.updateMetadata(current)
        }
    }

    private func load() {
        let store = NoteStore()
        speakerDocument = store.readTranscriptDocument(noteId: noteId)
        var loaded = try? store.allNotes().first(where: { $0.id == noteId })
        transcript = store.readTranscript(noteId: noteId) ?? ""
        summary = store.readSummary(noteId: noteId) ?? ""
        brief = store.loadBrief(noteId: noteId)
        if var note = loaded {
            let url = store.audioURL(for: note)
            // Size and magic come from file attributes / a 4-byte read — never load the recording.
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            audioBytes = (attrs?[.size] as? NSNumber)?.intValue ?? 0
            if note.durationSeconds <= 0, let secs = AudioDuration.seconds(at: url) {
                note.durationSeconds = secs
                try? store.updateMetadata(note)
            }
            loaded = note
            posterURL = store.posterURL(for: note)
            if audioBytes == 0 {
                playError = "Audio file is empty — re-download from Device."
            } else if let handle = try? FileHandle(forReadingFrom: url) {
                let magic = try? handle.read(upToCount: 4)
                try? handle.close()
                if let magic, magic != Data("OggS".utf8) {
                    playError = "Audio is not Ogg Opus — re-download from Device."
                }
            }
        }
        meta = loaded
    }

    @ViewBuilder
    private var reprocessLabel: some View {
        if isReprocessing {
            HStack {
                ProgressView()
                Text("Transcribing…")
            }
        } else {
            Label("Transcribe & summarize", systemImage: "text.bubble")
        }
    }

    /// `engine` picks where this one run happens; nil follows the mode in Settings.
    private func reprocess(using engine: EngineOverride? = nil) async {
        isReprocessing = true
        statusMessage = "Running \(PipelineEngines.transcriberTitle(override: engine))…"
        defer { isReprocessing = false }
        do {
            var settings = ExportSettings.load()
            settings.autoExportEnabled = UserDefaults.standard.bool(forKey: "export.autoEnabled")
            let pipeline = NotePipeline(
                store: NoteStore(),
                transcriber: PipelineEngines.transcriber(override: engine, force: true),
                summarizer: PipelineEngines.summarizer(override: engine, force: true),
                exporter: Exporter(settings: settings),
                options: PipelineOptions.load()
            )
            let updated = try await pipeline.reprocess(noteId: noteId)
            meta = updated
            load()
            statusMessage = updated.briefStatus == .done
                ? "Transcript, summary, and poster updated"
                : "Transcript updated (summary \(updated.summaryStatus.rawValue), poster \(updated.briefStatus.rawValue))"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func rebuildPoster() async {
        isBuildingPoster = true
        statusMessage = "Building poster…"
        defer { isBuildingPoster = false }
        do {
            var settings = ExportSettings.load()
            settings.autoExportEnabled = false
            let pipeline = NotePipeline(
                store: NoteStore(),
                transcriber: PipelineEngines.transcriber(),
                summarizer: PipelineEngines.summarizer(),
                exporter: Exporter(settings: settings)
            )
            let updated = try await pipeline.rebuildPoster(noteId: noteId)
            meta = updated
            load()
            statusMessage = updated.briefStatus == .done ? "Poster updated" : "Poster \(updated.briefStatus.rawValue)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func sharePoster() {
        guard let posterURL else { return }
        sharePayload = SharePayload(items: [posterURL])
    }

    private func togglePlay() {
        if isPlaying {
            player?.pause()
            isPlaying = false
            return
        }
        guard let meta else { return }
        let url = NoteStore().audioURL(for: meta)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            if player == nil {
                player = try AVAudioPlayer(contentsOf: url)
                player?.prepareToPlay()
            }
            guard player?.play() == true else {
                playError = "Could not start playback"
                return
            }
            playError = nil
            isPlaying = true
        } catch {
            playError = error.localizedDescription
            isPlaying = false
        }
    }
}

private struct SharePayload: Identifiable {
    let id = UUID()
    let items: [Any]
}

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
