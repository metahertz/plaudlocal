import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

enum SummaryResult: Equatable {
    case text(String)
    case unavailable(reason: String)
}

enum SummarizerError: Error, LocalizedError {
    case timedOut(seconds: Int)

    var errorDescription: String? {
        switch self {
        case .timedOut(let seconds):
            return "On-device summary timed out after \(seconds)s"
        }
    }
}

protocol Summarizing: Sendable {
    func summarize(transcript: String) async throws -> SummaryResult
    /// Same, for a transcript that belongs to the note in `noteDirectory`, so an engine can
    /// find work it already started for that note (see `RemoteJobRecord`). Engines that
    /// don't need the note use the default below.
    ///
    /// This must stay a protocol requirement: a method that exists only in an extension is
    /// picked at compile time, so a call through `any Summarizing` would always run the
    /// default and never reach an engine's own version.
    func summarize(transcript: String, noteDirectory: URL?) async throws -> SummaryResult
}

extension Summarizing {
    func summarize(transcript: String, noteDirectory: URL?) async throws -> SummaryResult {
        try await summarize(transcript: transcript)
    }
}

struct Summarizer: Summarizing {
    var forceUnavailable: Bool = false
    /// Per Foundation Models `respond` call. Long meetings need headroom; too-short
    /// timeouts were the main source of Sum: skipped.
    var perCallTimeoutSeconds: TimeInterval = 150
    /// Pause between FM calls so we don't trip on-device rate limits.
    var interCallDelayNanoseconds: UInt64 = 350_000_000

    func summarize(transcript: String) async throws -> SummaryResult {
        if forceUnavailable {
            return .unavailable(reason: "Forced unavailable for tests")
        }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .unavailable(reason: "Empty transcript")
        }
        if trimmed.hasPrefix("Transcript pending WhisperKit") {
            return .unavailable(reason: "Transcript is a placeholder — re-run transcription")
        }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return await summarizeWithFoundationModels(trimmed)
        }
        #endif
        return .unavailable(reason: "Apple Intelligence / Foundation Models not available on this device")
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private func summarizeWithFoundationModels(_ transcript: String) async -> SummaryResult {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            break
        case .unavailable(let reason):
            return .unavailable(reason: "Apple Intelligence unavailable (\(String(describing: reason)))")
        }

        if TranscriptChunker.needsChunking(transcript) {
            do {
                let text = try await summarizeChunked(transcript)
                if !text.isEmpty { return .text(text) }
            } catch {
                let fallback = await summarizeCompactFallback(transcript, priorError: error)
                if case .text = fallback { return fallback }
            }
            return await summarizeCompactFallback(transcript, priorError: nil)
        }

        do {
            let text = try await summarizeSinglePass(
                transcript,
                depth: .standard,
                maxOutputTokens: 900,
                shrinkOnContextError: true
            )
            return text.isEmpty
                ? .unavailable(reason: "Model returned an empty summary")
                : .text(text)
        } catch {
            do {
                let shorter = Self.fit(transcript, limit: 2_800)
                let text = try await summarizeSinglePass(
                    shorter,
                    depth: .compact,
                    maxOutputTokens: 600,
                    shrinkOnContextError: true
                )
                return text.isEmpty
                    ? .unavailable(reason: friendlyReason(error))
                    : .text(text)
            } catch {
                return await summarizeCompactFallback(transcript, priorError: error)
            }
        }
    }

    private enum SummaryDepth {
        case section
        case standard
        case synthesis
        case compact
    }

    @available(iOS 26.0, *)
    private func summarizeChunked(_ transcript: String) async throws -> String {
        // Conservative vs ~4096-token session window (instructions + prompt + output).
        let parts = TranscriptChunker.chunks(transcript, maxChars: 2_200, overlap: 160)
        var sectionNotes: [String] = []
        var lastError: Error?

        for (idx, part) in parts.enumerated() {
            if idx > 0 {
                try? await Task.sleep(nanoseconds: interCallDelayNanoseconds)
            }
            do {
                let note = try await summarizeSinglePass(
                    part,
                    depth: .section,
                    heading: "Section \(idx + 1) of \(parts.count)",
                    maxOutputTokens: 450,
                    shrinkOnContextError: true
                )
                if !note.isEmpty {
                    sectionNotes.append("### Section \(idx + 1)\n\(note)")
                }
            } catch {
                lastError = error
                try? await Task.sleep(nanoseconds: interCallDelayNanoseconds)
                do {
                    let note = try await summarizeSinglePass(
                        Self.fit(part, limit: 1_600),
                        depth: .compact,
                        heading: "Section \(idx + 1) of \(parts.count)",
                        maxOutputTokens: 300,
                        shrinkOnContextError: true
                    )
                    if !note.isEmpty {
                        sectionNotes.append("### Section \(idx + 1)\n\(note)")
                    }
                } catch {
                    lastError = error
                    continue
                }
            }
        }

        guard !sectionNotes.isEmpty else {
            if let lastError { throw lastError }
            return ""
        }

        var layer = sectionNotes
        while layer.count > 1 {
            let joined = layer.joined(separator: "\n\n")
            if joined.count <= 5_000 {
                try? await Task.sleep(nanoseconds: interCallDelayNanoseconds)
                do {
                    return try await summarizeSinglePass(
                        joined,
                        depth: .synthesis,
                        maxOutputTokens: 900,
                        shrinkOnContextError: true
                    )
                } catch {
                    return joined
                }
            }
            var next: [String] = []
            let groups = TranscriptChunker.chunks(joined, maxChars: 4_500, overlap: 80)
            for (idx, group) in groups.enumerated() {
                if idx > 0 {
                    try? await Task.sleep(nanoseconds: interCallDelayNanoseconds)
                }
                do {
                    let mid = try await summarizeSinglePass(
                        group,
                        depth: .synthesis,
                        heading: "Merged notes \(idx + 1) of \(groups.count)",
                        maxOutputTokens: 650,
                        shrinkOnContextError: true
                    )
                    if !mid.isEmpty { next.append(mid) }
                } catch {
                    next.append(group)
                }
            }
            if next.isEmpty { return joined }
            if next.count >= layer.count { return next.joined(separator: "\n\n") }
            layer = next
        }
        return layer.first ?? ""
    }

    @available(iOS 26.0, *)
    private func summarizeCompactFallback(
        _ transcript: String,
        priorError: Error?
    ) async -> SummaryResult {
        let sample = Self.representativeSample(transcript, limit: 3_000)
        do {
            let text = try await summarizeSinglePass(
                sample,
                depth: .compact,
                maxOutputTokens: 650,
                shrinkOnContextError: true
            )
            if text.isEmpty {
                return .unavailable(reason: priorError.map(friendlyReason) ?? "Model returned an empty summary")
            }
            let suffix = transcript.count > sample.count
                ? "\n\n(Note: summary sampled across the full transcript because the complete text exceeds the on-device model window.)"
                : ""
            return .text(text + suffix)
        } catch {
            // Last-ditch: even smaller sample, one more try.
            do {
                let tiny = Self.representativeSample(transcript, limit: 1_800)
                let text = try await summarizeSinglePass(
                    tiny,
                    depth: .compact,
                    maxOutputTokens: 400,
                    shrinkOnContextError: false
                )
                if text.isEmpty {
                    return .unavailable(reason: friendlyReason(error))
                }
                return .text(
                    text
                        + "\n\n(Note: summary used a reduced sample after repeated on-device model failures.)"
                )
            } catch {
                return .unavailable(reason: friendlyReason(priorError ?? error))
            }
        }
    }

    @available(iOS 26.0, *)
    private func summarizeSinglePass(
        _ body: String,
        depth: SummaryDepth,
        heading: String? = nil,
        maxOutputTokens: Int = 700,
        shrinkOnContextError: Bool
    ) async throws -> String {
        var payload = body
        var tokens = maxOutputTokens
        var attempts = 0
        var lastError: Error?

        while attempts < 3 {
            attempts += 1
            do {
                return try await respondOnce(
                    body: payload,
                    depth: depth,
                    heading: heading,
                    maxOutputTokens: tokens
                )
            } catch {
                lastError = error
                let kind = PipelineRetry.classify(error)
                switch kind {
                case .shrinkInput:
                    guard shrinkOnContextError, payload.count > 800 else { throw error }
                    payload = Self.fit(payload, limit: max(800, payload.count * 2 / 3))
                    tokens = max(250, tokens * 3 / 4)
                    try? await Task.sleep(nanoseconds: interCallDelayNanoseconds)
                    continue
                case .backoff:
                    try? await Task.sleep(nanoseconds: UInt64(attempts) * 800_000_000)
                    continue
                case .retryable:
                    try? await Task.sleep(nanoseconds: UInt64(attempts) * 400_000_000)
                    if attempts < 3 { continue }
                    throw error
                case .permanent:
                    throw error
                }
            }
        }
        throw lastError ?? SummarizerError.timedOut(seconds: Int(perCallTimeoutSeconds))
    }

    @available(iOS 26.0, *)
    private func respondOnce(
        body: String,
        depth: SummaryDepth,
        heading: String?,
        maxOutputTokens: Int
    ) async throws -> String {
        let instructions: String
        switch depth {
        case .section:
            instructions = """
                Take detailed notes on this section of a longer meeting.
                Cover each distinct topic with concrete detail (decisions, owners, dates, numbers).
                Use short paragraphs, one per topic. Do not invent facts. No preamble.
                """
        case .standard:
            instructions = """
                Write a thorough meeting summary for a 15–60 minute conversation.
                Multiple short paragraphs — one per major topic.
                Include decisions and next steps when stated. Do not invent facts. No preamble.
                """
        case .synthesis:
            instructions = """
                Synthesize section notes into one cohesive meeting summary.
                Keep coverage from every section. Multiple short paragraphs, one per major topic.
                Keep decisions and next steps explicit when present. Do not invent facts. No preamble.
                """
        case .compact:
            instructions = """
                Summarize this meeting material in several short paragraphs (one per major theme).
                Prefer concrete facts over generalities. Do not invent. No preamble.
                """
        }

        // Fresh session every call — avoids cumulative context-window blowups.
        let session = LanguageModelSession(instructions: instructions)
        let prompt: String
        if let heading {
            prompt = "\(heading)\n\n\(body)"
        } else {
            prompt = "Summarize this meeting transcript:\n\n\(body)"
        }
        let options = GenerationOptions(maximumResponseTokens: maxOutputTokens)
        let timeout = perCallTimeoutSeconds
        return try await PipelineRetry.withTimeout(seconds: timeout) {
            let response = try await session.respond(to: prompt, options: options)
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    @available(iOS 26.0, *)
    private func friendlyReason(_ error: Error) -> String {
        if let generation = error as? LanguageModelSession.GenerationError {
            switch generation {
            case .exceededContextWindowSize:
                return "On-device model context window exceeded"
            case .rateLimited:
                return "On-device model rate limited — try again in a moment"
            case .assetsUnavailable:
                return "Apple Intelligence assets unavailable"
            case .guardrailViolation:
                return "On-device model refused this content"
            case .decodingFailure:
                return "On-device model returned an unreadable response"
            case .unsupportedLanguageOrLocale:
                return "On-device model does not support this language"
            case .unsupportedGuide:
                return "On-device model rejected the generation guide"
            @unknown default:
                return error.localizedDescription
            }
        }
        return error.localizedDescription
    }
    #endif

    /// Head + middle + tail sample so long meetings keep closing actions/decisions.
    static func representativeSample(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let third = max(400, limit / 3)
        let head = String(text.prefix(third))
        let midStart = text.index(text.startIndex, offsetBy: max(0, (text.count - third) / 2))
        let midEnd = text.index(midStart, offsetBy: third, limitedBy: text.endIndex) ?? text.endIndex
        let mid = String(text[midStart..<midEnd])
        let tail = String(text.suffix(third))
        return head + "\n…\n" + mid + "\n…\n" + tail
    }

    static func fit(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n…"
    }
}
