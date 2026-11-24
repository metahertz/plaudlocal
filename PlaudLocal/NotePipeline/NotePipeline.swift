import Foundation

struct NotePipeline {
    var store: NoteStore
    var transcriber: any Transcribing
    var summarizer: any Summarizing
    var briefBuilder: any BriefBuilding = BriefBuilder()
    var exporter: Exporter
    var decrypt: (Data, String) throws -> Data = FileDecryptor.decrypt
    var privateKeyPEMProvider: () -> String? = {
        guard let data = KeyVault().load(account: "plaud.rsaPrivatePEM") else { return nil }
        return String(data: data, encoding: .utf8)
    }
    /// Optional steps; the defaults run everything.
    var options = PipelineOptions()

    /// Decrypt and add to Library only (no ASR yet). Safe to call for every download
    /// before kicking off slow transcription so batch imports aren't blocked on the first note.
    func importDownloadedFile(_ url: URL, sessionId: UInt32, duration: Int = 0) async throws -> NoteMetadata {
        if let existing = try store.note(forSessionId: sessionId) {
            return existing
        }

        let encrypted = try Data(contentsOf: url)
        guard FileDecryptor.isPlaudContainer(encrypted) else {
            throw FileDecryptorError.badMagic
        }
        guard let pem = privateKeyPEMProvider() else {
            throw FileDecryptorError.needsReSignIn
        }
        let headerDuration = duration > 0 ? duration : (FileDecryptor.durationSeconds(in: encrypted) ?? 0)
        let audio: Data
        do {
            audio = try decrypt(encrypted, pem)
        } catch FileDecryptorError.needsReSignIn, FileDecryptorError.rsaFailed {
            throw FileDecryptorError.needsReSignIn
        }

        var meta = try store.createNote(
            fromDecryptedAudio: audio,
            sessionId: sessionId,
            duration: headerDuration
        )

        let audioURL = store.noteDirectory(id: meta.id).appendingPathComponent(meta.audioFileName)
        let measured = AudioDuration.resolve(headerSeconds: headerDuration, audioURL: audioURL)
        if measured != meta.durationSeconds {
            meta.durationSeconds = measured
            try store.updateMetadata(meta)
        }
        return meta
    }

    /// Transcribe / summarize / poster / export for a note already in the Library.
    /// Reuses an on-disk transcript when present so a killed ASR/summary pass can resume
    /// at summarization instead of getting stuck on `.running` forever.
    /// When `audioOnlyMode` is on (or the note was imported that way), skips on-device AI and exports raw audio.
    func enrichImportedNote(_ imported: NoteMetadata) async throws -> NoteMetadata {
        // One enrichment per note at a time: Device-tab imports and Library recovery
        // would otherwise run ASR/summary/poster twice and race on the note's files.
        guard PipelineActivity.shared.begin(imported.id) else {
            return currentMetadata(for: imported)
        }
        defer { PipelineActivity.shared.end(imported.id) }

        // The caller's copy may predate work another pass has since finished.
        var meta = currentMetadata(for: imported)

        if exporter.settings.audioOnlyMode || meta.audioOnlyExport {
            return try await exportAudioOnly(meta)
        }

        let existingTranscript = store.readTranscript(noteId: meta.id)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let transcript: String
        if let existingTranscript, !existingTranscript.isEmpty,
           meta.transcriptStatus == .done || meta.transcriptStatus == .running {
            transcript = existingTranscript
            if meta.transcriptStatus != .done {
                meta.transcriptStatus = .done
                try store.updateMetadata(meta)
            }
        } else {
            let audioURL = store.audioURL(for: meta)
            meta.transcriptStatus = .running
            try store.updateMetadata(meta)
            do {
                transcript = try await PipelineRetry.run(attempts: 2) { _ in
                    try await transcriber.transcribe(audioURL: audioURL)
                }
                try store.writeTranscript(noteId: meta.id, text: transcript)
                meta.transcriptStatus = .done
                try store.updateMetadata(meta)
            } catch {
                // A cancelled pass (Library re-appearing or pull-to-refresh cancels the running
                // recovery) didn't fail: leave it pending so the next visit resumes it, rather
                // than spending the once-per-launch retry that failed transcriptions get.
                meta.transcriptStatus = (error is CancellationError || Task.isCancelled) ? .pending : .failed
                try? store.updateMetadata(meta)
                throw error
            }
        }

        var summaryText = store.readSummary(noteId: meta.id)
        let summaryDone = meta.summaryStatus == .done
            && PipelineRecovery.isUsableSummary(summaryText)

        if !summaryDone, !options.summarize {
            if meta.summaryStatus != .skipped {
                try markSummaryTurnedOff(&meta)
            }
            summaryText = nil
        } else if !summaryDone {
            meta.summaryStatus = .running
            try store.updateMetadata(meta)
            let result = await summarizeWithRetry(transcript: transcript, noteId: meta.id)
            switch result {
            case let .text(summary):
                try store.writeSummary(noteId: meta.id, text: summary)
                summaryText = summary
                meta.summaryStatus = .done
            case let .unavailable(reason):
                try store.writeSummary(noteId: meta.id, text: "Summary unavailable: \(reason)")
                summaryText = nil
                meta.summaryStatus = .skipped
            }
            try store.updateMetadata(meta)
        }

        if meta.briefStatus != .done || meta.posterFileName == nil {
            if options.buildPoster {
                meta = try await buildBriefAndPoster(
                    meta: meta,
                    transcript: transcript,
                    summary: summaryText
                )
            } else if meta.briefStatus != .skipped {
                meta.briefStatus = .skipped
                try store.updateMetadata(meta)
            }
        }

        if exporter.settings.autoExportEnabled, meta.exportStatus != .done {
            meta.exportStatus = .running
            try store.updateMetadata(meta)
            do {
                let result = try await exporter.export(meta, store: store)
                meta.exportStatus = (result.wroteLocal || result.wroteRemote) ? .done : .skipped
            } catch {
                meta.exportStatus = .failed
            }
            try store.updateMetadata(meta)
        }

        return meta
    }

    func processDownloadedFile(_ url: URL, sessionId: UInt32, duration: Int) async throws -> NoteMetadata {
        let meta = try await importDownloadedFile(url, sessionId: sessionId, duration: duration)
        return try await enrichImportedNote(meta)
    }

    private func currentMetadata(for meta: NoteMetadata) -> NoteMetadata {
        (try? store.allNotes().first(where: { $0.id == meta.id })) ?? meta
    }

    static let audioOnlyTranscriptPlaceholder =
        "On-device transcription skipped. Raw audio was exported for external AI processing."

    /// Skip ASR/summary/poster and push decrypted audio (+ metadata) to Nextcloud / local export.
    /// Never replaces work that already exists: a note transcribed before audio-only mode was
    /// switched on keeps its transcript, summary and poster.
    func exportAudioOnly(_ meta: NoteMetadata) async throws -> NoteMetadata {
        var meta = meta
        meta.audioOnlyExport = true

        let transcript = store.readTranscript(noteId: meta.id)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasRealTranscript = !transcript.isEmpty
            && transcript != Self.audioOnlyTranscriptPlaceholder
            && meta.transcriptStatus != .skipped
        if hasRealTranscript {
            meta.transcriptStatus = .done
        } else {
            meta.transcriptStatus = .skipped
            try store.writeTranscript(noteId: meta.id, text: Self.audioOnlyTranscriptPlaceholder)
        }

        let hasRealSummary = meta.summaryStatus == .done
            && PipelineRecovery.isUsableSummary(store.readSummary(noteId: meta.id))
        if !hasRealSummary {
            meta.summaryStatus = .skipped
            try store.writeSummary(
                noteId: meta.id,
                text: "Summary unavailable: Audio-only export — on-device AI skipped; process this recording with your own tools."
            )
        }

        if !(meta.briefStatus == .done && meta.posterFileName != nil) {
            meta.briefStatus = .skipped
        }
        let readme = """
            Plaud Local — audio-only export
            ================================
            Recording: \(meta.recordingLabel)
            Session: \(meta.sessionId)
            Duration: \(meta.durationSeconds)s

            On-device transcription and summarization were skipped.
            Use audio.ogg with your preferred (larger) AI / ASR toolchain.
            """
        try readme.write(
            to: store.noteDirectory(id: meta.id).appendingPathComponent("README.txt"),
            atomically: true,
            encoding: .utf8
        )
        try store.updateMetadata(meta)

        meta.exportStatus = .running
        try store.updateMetadata(meta)
        do {
            // Audio-only mode always attempts export (that is the point of the setting).
            let result = try await exporter.export(meta, store: store)
            meta.exportStatus = (result.wroteLocal || result.wroteRemote) ? .done : .skipped
        } catch {
            meta.exportStatus = .failed
        }
        try store.updateMetadata(meta)
        return meta
    }

    /// Re-run transcription, summary, brief, and poster on an existing library note.
    /// Manual reprocess always runs transcription and summary, even if the note was imported as audio-only.
    func reprocess(noteId: String) async throws -> NoteMetadata {
        guard var meta = try store.allNotes().first(where: { $0.id == noteId }) else {
            throw NoteStoreError.notFound
        }
        let audioURL = store.audioURL(for: meta)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw TranscriberError.missingAudio
        }
        // Mark the note busy so Library recovery doesn't treat this live run as a crashed one.
        let began = PipelineActivity.shared.begin(noteId)
        defer { if began { PipelineActivity.shared.end(noteId) } }

        meta.audioOnlyExport = false
        meta.transcriptStatus = .running
        meta.summaryStatus = .pending
        meta.briefStatus = .pending
        try store.updateMetadata(meta)

        do {
            let transcript = try await transcriber.transcribe(audioURL: audioURL)
            try store.writeTranscript(noteId: meta.id, text: transcript)
            meta.transcriptStatus = .done
            try store.updateMetadata(meta)

            var summaryText: String?
            if options.summarize {
                meta.summaryStatus = .running
                try store.updateMetadata(meta)
                switch await summarizeWithRetry(transcript: transcript, noteId: meta.id) {
                case let .text(summary):
                    try store.writeSummary(noteId: meta.id, text: summary)
                    summaryText = summary
                    meta.summaryStatus = .done
                case let .unavailable(reason):
                    try store.writeSummary(noteId: meta.id, text: "Summary unavailable: \(reason)")
                    meta.summaryStatus = .skipped
                }
                try store.updateMetadata(meta)
            } else if PipelineRecovery.isUsableSummary(store.readSummary(noteId: meta.id)) {
                // Summaries are off: keep the one this note already has rather than erasing it.
                summaryText = store.readSummary(noteId: meta.id)
                meta.summaryStatus = .done
                try store.updateMetadata(meta)
            } else {
                try markSummaryTurnedOff(&meta)
            }

            guard options.buildPoster else {
                meta.briefStatus = meta.posterFileName == nil ? .skipped : .done
                try store.updateMetadata(meta)
                return meta
            }
            return try await buildBriefAndPoster(meta: meta, transcript: transcript, summary: summaryText)
        } catch {
            meta.transcriptStatus = .failed
            try? store.updateMetadata(meta)
            throw error
        }
    }

    private func markSummaryTurnedOff(_ meta: inout NoteMetadata) throws {
        try store.writeSummary(noteId: meta.id, text: "Summary unavailable: \(PipelineOptions.summaryOffReason)")
        meta.summaryStatus = .skipped
        try store.updateMetadata(meta)
    }

    /// One opaque `.unavailable` with a retryable reason gets a second full pass after backoff.
    /// The note directory lets the remote engine reuse the server job that transcribed this note.
    private func summarizeWithRetry(transcript: String, noteId: String) async -> SummaryResult {
        let noteDirectory = store.noteDirectory(id: noteId)
        do {
            let first = try await summarizer.summarize(transcript: transcript, noteDirectory: noteDirectory)
            if case let .unavailable(reason) = first,
               PipelineRecovery.isRetryableSkipReason("Summary unavailable: \(reason)") {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                return try await summarizer.summarize(transcript: transcript, noteDirectory: noteDirectory)
            }
            return first
        } catch {
            if PipelineRetry.isRetryable(error) {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                do {
                    return try await summarizer.summarize(transcript: transcript, noteDirectory: noteDirectory)
                } catch {
                    return .unavailable(reason: error.localizedDescription)
                }
            }
            return .unavailable(reason: error.localizedDescription)
        }
    }

    /// Rebuild brief + poster from existing transcript/summary files.
    func rebuildPoster(noteId: String) async throws -> NoteMetadata {
        guard var meta = try store.allNotes().first(where: { $0.id == noteId }) else {
            throw NoteStoreError.notFound
        }
        guard let transcript = store.readTranscript(noteId: noteId), !transcript.isEmpty else {
            throw BriefBuilderError.empty
        }
        let summary = store.readSummary(noteId: noteId)
        let began = PipelineActivity.shared.begin(noteId)
        defer { if began { PipelineActivity.shared.end(noteId) } }
        return try await buildBriefAndPoster(meta: meta, transcript: transcript, summary: summary)
    }

    private func buildBriefAndPoster(
        meta: NoteMetadata,
        transcript: String,
        summary: String?
    ) async throws -> NoteMetadata {
        var meta = meta
        meta.briefStatus = .running
        try store.updateMetadata(meta)

        do {
            let brief = try await briefBuilder.build(transcript: transcript, summary: summary)
            try store.writeBrief(noteId: meta.id, brief: brief)
            meta.title = brief.title

            let fileName = BriefBuilder.posterFileName(sessionId: meta.sessionId, title: brief.title)
            let png = try await renderPosterPNG(brief: brief, recordingDate: meta.recordingDate)
            try store.writePoster(noteId: meta.id, fileName: fileName, pngData: png)
            meta.posterFileName = fileName
            meta.briefStatus = .done
            try store.updateMetadata(meta)
            return meta
        } catch {
            meta.briefStatus = .failed
            try? store.updateMetadata(meta)
            // Brief/poster failure should not fail the whole import after transcript succeeded.
            return meta
        }
    }

    private func renderPosterPNG(brief: MeetingBrief, recordingDate: Date) async throws -> Data {
        try await MainActor.run {
            try PosterRenderer.pngData(brief: brief, recordingDate: recordingDate)
        }
    }
}
