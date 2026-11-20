import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Shared retry / error-classification helpers for ASR and on-device summarization.
enum PipelineRetry {
    enum Kind: Equatable {
        case retryable
        case shrinkInput
        case backoff
        case permanent
    }

    static func classify(_ error: Error) -> Kind {
        if error is CancellationError { return .permanent }
        if let summarizer = error as? SummarizerError {
            switch summarizer {
            case .timedOut: return .retryable
            }
        }
        if let transcriber = error as? TranscriberError {
            switch transcriber {
            case .emptyTranscript, .unsupportedAudio: return .retryable
            case .speechUnavailable, .whisperKitUnavailable, .missingAudio: return .permanent
            }
        }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *),
           let generation = error as? LanguageModelSession.GenerationError {
            switch generation {
            case .exceededContextWindowSize:
                return .shrinkInput
            case .rateLimited:
                return .backoff
            case .decodingFailure:
                return .retryable
            case .assetsUnavailable:
                return .backoff
            case .guardrailViolation, .unsupportedLanguageOrLocale, .unsupportedGuide:
                return .permanent
            @unknown default:
                return .retryable
            }
        }
        #endif

        let ns = error as NSError
        // NSURLErrorTimedOut / generic transient codes
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorTimedOut {
            return .retryable
        }
        let desc = error.localizedDescription.lowercased()
        if desc.contains("timed out") || desc.contains("timeout") {
            return .retryable
        }
        if desc.contains("rate") && desc.contains("limit") {
            return .backoff
        }
        if desc.contains("context") || desc.contains("token") || desc.contains("too long") {
            return .shrinkInput
        }
        // Opaque FoundationModels "error N" — usually worth one retry then shrink.
        if desc.contains("foundationmodels") || desc.contains("generationerror") {
            return .retryable
        }
        return .retryable
    }

    static func isRetryable(_ error: Error) -> Bool {
        switch classify(error) {
        case .permanent: return false
        case .retryable, .shrinkInput, .backoff: return true
        }
    }

    /// Run `operation`, retrying on transient failures with optional input shrinking.
    static func run<T>(
        attempts: Int = 3,
        initialBackoffNanoseconds: UInt64 = 400_000_000,
        operation: (_ attempt: Int) async throws -> T
    ) async throws -> T {
        var backoff = initialBackoffNanoseconds
        var lastError: Error?
        for attempt in 1...max(1, attempts) {
            do {
                return try await operation(attempt)
            } catch {
                lastError = error
                let kind = classify(error)
                if kind == .permanent || attempt == attempts {
                    throw error
                }
                let sleepNs: UInt64
                switch kind {
                case .backoff:
                    sleepNs = backoff * 2
                case .shrinkInput, .retryable:
                    sleepNs = backoff
                case .permanent:
                    throw error
                }
                try? await Task.sleep(nanoseconds: sleepNs)
                backoff = min(backoff * 2, 4_000_000_000)
            }
        }
        throw lastError ?? CancellationError()
    }

    static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw SummarizerError.timedOut(seconds: Int(seconds))
            }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }
}
