import AVFoundation
import Foundation
import Speech

#if canImport(WhisperKit)
import WhisperKit
#endif

protocol Transcribing: Sendable {
    func transcribe(audioURL: URL) async throws -> String
}

enum TranscriberError: Error, LocalizedError {
    case missingAudio
    case unsupportedAudio
    case speechUnavailable(String)
    case emptyTranscript
    case whisperKitUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .missingAudio: return "Audio file missing"
        case .unsupportedAudio: return "Could not decode audio for transcription"
        case .speechUnavailable(let s): return s
        case .emptyTranscript: return "Transcription produced no text"
        case .whisperKitUnavailable(let s): return s
        }
    }
}

/// On-device transcriber. Default engine is Apple SpeechAnalyzer; WhisperKit is opt-in in Settings.
struct Transcriber: Transcribing {
    var engine: TranscriptionEngine = TranscriptionSettings.engine
    /// Hard ceiling so SFSpeech / SpeechAnalyzer cannot hang the pipeline forever.
    var recognitionTimeoutSeconds: TimeInterval = 240

    func transcribe(audioURL: URL) async throws -> String {
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw TranscriberError.missingAudio
        }
        switch engine {
        case .apple:
            return try await transcribeWithAppleSpeechResilient(audioURL: audioURL)
        case .whisperKit:
            return try await PipelineRetry.run(attempts: 2) { _ in
                try await transcribeWithWhisperKit(audioURL: audioURL)
            }
        }
    }

    // MARK: - Apple Speech (resilient)

    private func transcribeWithAppleSpeechResilient(audioURL: URL) async throws -> String {
        var errors: [String] = []

        // Primary path with one automatic retry on transient failure.
        do {
            return try await PipelineRetry.run(attempts: 2, initialBackoffNanoseconds: 500_000_000) { _ in
                try await transcribeWithAppleSpeech(audioURL: audioURL)
            }
        } catch {
            errors.append(error.localizedDescription)
        }

        // Cross-fallback: if SpeechAnalyzer path failed, force SFSpeech (and vice versa).
        do {
            let text = try await transcribeWithSFSpeech(audioURL: audioURL)
            if !text.isEmpty { return text }
            errors.append("SFSpeech fallback returned empty text")
        } catch {
            errors.append("SFSpeech fallback: \(error.localizedDescription)")
        }

        if #available(iOS 26.0, *) {
            do {
                let text = try await PipelineRetry.withTimeout(seconds: recognitionTimeoutSeconds) {
                    try await self.transcribeWithSpeechAnalyzer(audioURL: audioURL)
                }
                if !text.isEmpty { return text }
            } catch {
                errors.append("SpeechAnalyzer retry: \(error.localizedDescription)")
            }
        }

        throw TranscriberError.speechUnavailable(
            errors.last ?? "Transcription failed after retries"
        )
    }

    private func transcribeWithAppleSpeech(audioURL: URL) async throws -> String {
        try await PipelineRetry.withTimeout(seconds: recognitionTimeoutSeconds) {
            if #available(iOS 26.0, *) {
                return try await self.transcribeWithSpeechAnalyzer(audioURL: audioURL)
            }
            return try await self.transcribeWithSFSpeech(audioURL: audioURL)
        }
    }

    @available(iOS 26.0, *)
    private func transcribeWithSpeechAnalyzer(audioURL: URL) async throws -> String {
        let prepared = try AudioForTranscription.readableURL(from: audioURL)
        defer {
            if prepared.isTemporary {
                try? FileManager.default.removeItem(at: prepared.url)
            }
        }

        guard SpeechTranscriber.isAvailable else {
            return try await transcribeWithDictationOrSFSpeech(audioURL: prepared.url)
        }

        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            throw TranscriberError.speechUnavailable("No SpeechTranscriber locale for \(Locale.current.identifier)")
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        async let transcriptTask: String = {
            var full = ""
            for try await result in transcriber.results {
                full += String(result.text.characters)
            }
            return full
        }()

        let file = try AVAudioFile(forReading: prepared.url)
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }

        let text = try await transcriptTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriberError.emptyTranscript }
        return text
    }

    @available(iOS 26.0, *)
    private func transcribeWithDictationOrSFSpeech(audioURL: URL) async throws -> String {
        if let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale.current) {
            let module = DictationTranscriber(locale: locale, preset: .longDictation)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await request.downloadAndInstall()
            }
            let analyzer = SpeechAnalyzer(modules: [module])
            async let transcriptTask: String = {
                var full = ""
                for try await result in module.results {
                    full += String(result.text.characters)
                }
                return full
            }()
            let file = try AVAudioFile(forReading: audioURL)
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            let text = try await transcriptTask.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return try await transcribeWithSFSpeech(audioURL: audioURL)
    }

    private func transcribeWithSFSpeech(audioURL: URL) async throws -> String {
        let prepared = try AudioForTranscription.readableURL(from: audioURL)
        defer {
            if prepared.isTemporary {
                try? FileManager.default.removeItem(at: prepared.url)
            }
        }

        guard let recognizer = SFSpeechRecognizer(locale: Locale.current), recognizer.isAvailable else {
            throw TranscriberError.speechUnavailable("Speech recognition unavailable for \(Locale.current.identifier)")
        }

        let auth = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard auth == .authorized else {
            throw TranscriberError.speechUnavailable("Speech recognition not authorized — enable it in Settings")
        }

        let request = SFSpeechURLRecognitionRequest(url: prepared.url)
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.shouldReportPartialResults = false

        // Timeout must resume this continuation (cancel alone would leak it and hang enrich).
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            final class Gate: @unchecked Sendable {
                var settled = false
                let lock = NSLock()
                func finish(_ body: () -> Void) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !settled else { return }
                    settled = true
                    body()
                }
            }
            let gate = Gate()
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    gate.finish { cont.resume(throwing: error) }
                    return
                }
                guard let result, result.isFinal else { return }
                let text = result.bestTranscription.formattedString
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                gate.finish {
                    if text.isEmpty {
                        cont.resume(throwing: TranscriberError.emptyTranscript)
                    } else {
                        cont.resume(returning: text)
                    }
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(recognitionTimeoutSeconds * 1_000_000_000))
                task.cancel()
                gate.finish {
                    cont.resume(throwing: SummarizerError.timedOut(seconds: Int(recognitionTimeoutSeconds)))
                }
            }
        }
    }

    // MARK: - WhisperKit

    private func transcribeWithWhisperKit(audioURL: URL) async throws -> String {
        #if canImport(WhisperKit)
        return try await WhisperKitEngine.shared.transcribe(audioURL: audioURL)
        #else
        throw TranscriberError.whisperKitUnavailable("WhisperKit is not linked in this build")
        #endif
    }
}

#if canImport(WhisperKit)
actor WhisperKitEngine {
    static let shared = WhisperKitEngine()
    private var kit: WhisperKit?

    func transcribe(audioURL: URL) async throws -> String {
        if kit == nil {
            // Base is a practical first-run size; downloads once into the app container.
            kit = try await WhisperKit(WhisperKitConfig(model: "base", verbose: false, download: true))
        }
        guard let kit else {
            throw TranscriberError.whisperKitUnavailable("Failed to load WhisperKit")
        }
        let results = try await kit.transcribe(audioPath: audioURL.path)
        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriberError.emptyTranscript }
        return text
    }
}
#endif
