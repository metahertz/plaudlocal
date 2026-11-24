import Foundation

/// In-process registry of notes with a pipeline pass currently running.
/// A `.running` status on disk only means "crashed" when nothing in this process owns the note.
final class PipelineActivity: @unchecked Sendable {
    static let shared = PipelineActivity()

    private let lock = NSLock()
    private var active = Set<String>()
    private var retriedFailures = Set<String>()

    /// Returns false when another pass already owns the note.
    func begin(_ noteId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return active.insert(noteId).inserted
    }

    func end(_ noteId: String) {
        lock.lock()
        defer { lock.unlock() }
        active.remove(noteId)
    }

    func isActive(_ noteId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return active.contains(noteId)
    }

    /// True the first time it is asked about a note in this launch — bounds automatic
    /// retries of non-transient failures to one per launch instead of one per Library visit.
    func claimFailureRetry(_ noteId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return retriedFailures.insert(noteId).inserted
    }
}

/// Clears pipeline statuses left stuck at `.running` after jetsam / kill / suspension,
/// and queues notes that still need ASR / summary / poster.
enum PipelineRecovery {
    /// Fix metadata that no longer matches on-disk artifacts, and return notes that still need enrichment.
    @discardableResult
    static func recoverInterrupted(store: NoteStore = NoteStore()) -> [NoteMetadata] {
        guard let notes = try? store.allNotes() else { return [] }
        var needsEnrichment: [NoteMetadata] = []

        for note in notes {
            // A pass is live in this process: its `.running` statuses are real, not leftovers.
            if PipelineActivity.shared.isActive(note.id) { continue }

            var meta = note
            var changed = false

            let transcript = store.readTranscript(noteId: meta.id)
            let hasTranscript = !(transcript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            let summary = store.readSummary(noteId: meta.id)
            let hasUsableSummary = isUsableSummary(summary)
            let hasAudio = FileManager.default.fileExists(atPath: store.audioURL(for: meta).path)

            if meta.transcriptStatus == .running {
                // Prefer resuming from a partial/full transcript over marking failed.
                meta.transcriptStatus = hasTranscript ? .done : (hasAudio ? .pending : .failed)
                changed = true
            }

            if meta.summaryStatus == .running {
                // Don't stamp "skipped/interrupted" — leave pending so auto-retry can finish.
                // Only keep .done when the text looks like a finished summary (not mid-chunk notes).
                if hasUsableSummary {
                    meta.summaryStatus = .done
                } else {
                    meta.summaryStatus = .pending
                }
                changed = true
            }

            if meta.briefStatus == .running {
                meta.briefStatus = meta.posterFileName == nil ? .pending : .done
                changed = true
            }

            if meta.exportStatus == .running {
                meta.exportStatus = .pending
                changed = true
            }

            // Retryable skips (timeouts / rate limits / interrupted) should be tried again.
            if meta.summaryStatus == .skipped, isRetryableSkipReason(summary) {
                meta.summaryStatus = .pending
                changed = true
            }

            if meta.transcriptStatus == .failed, hasAudio {
                meta.transcriptStatus = .pending
                changed = true
            }

            if changed {
                try? store.updateMetadata(meta)
            }

            // Audio-only notes are finished after export; don't kick ASR/summary recovery.
            if meta.audioOnlyExport {
                if meta.exportStatus != .done, ExportSettings.load().hasExportDestination {
                    needsEnrichment.append(meta)
                }
                continue
            }

            let wantsTranscript = hasAudio
                && (meta.transcriptStatus == .pending || meta.transcriptStatus == .failed)
            let transcriptReady = meta.transcriptStatus == .done && hasTranscript
            // Retryable skips were reset to .pending above; a permanent skip stays skipped.
            let wantsSummary = transcriptReady
                && (meta.summaryStatus == .pending
                    || (meta.summaryStatus == .done && !hasUsableSummary))
            let wantsBrief = transcriptReady && meta.briefStatus == .pending
            // Failed poster / unusable-summary leftovers get one automatic retry per launch,
            // not one on every Library appearance.
            //
            // "Summaries are turned off" is the user's choice, not a failure. Retrying it would
            // re-run these notes at every launch, and summarize the whole library at once the
            // moment the switch goes back on (in remote mode, uploading every old transcript).
            let summaryTurnedOff = summary?.contains(PipelineOptions.summaryOffReason) == true
            let hasStaleFailure = transcriptReady
                && (meta.briefStatus == .failed || (meta.summaryStatus == .skipped && !summaryTurnedOff))
            if wantsTranscript || wantsSummary || wantsBrief {
                needsEnrichment.append(meta)
            } else if hasStaleFailure, PipelineActivity.shared.claimFailureRetry(meta.id) {
                needsEnrichment.append(meta)
            }
        }

        return needsEnrichment
    }

    /// Finished summaries are prose; mid-flight chunk notes look like `### Section N`.
    static func isUsableSummary(_ text: String?) -> Bool {
        guard let text else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("Summary unavailable:") { return false }
        // Incomplete map-reduce dumps are mostly section headers — re-run summarization.
        let sectionHeaders = trimmed.components(separatedBy: "### Section").count - 1
        if sectionHeaders >= 2, !trimmed.contains("Meeting Summary"), trimmed.count < 2_500 {
            return false
        }
        return true
    }

    static func isRetryableSkipReason(_ summary: String?) -> Bool {
        guard let summary, summary.hasPrefix("Summary unavailable:") else { return false }
        let reason = summary.lowercased()
        let markers = [
            "timed out", "timeout", "rate limit", "rate limited", "interrupted",
            "context window", "assets unavailable", "unreadable", "try again",
            "empty summary", "foundationmodels", "generationerror"
        ]
        return markers.contains { reason.contains($0) }
    }
}
