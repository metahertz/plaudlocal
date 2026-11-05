import Foundation

enum SummaryResult: Equatable {
    case text(String)
    case unavailable(reason: String)
}

protocol Summarizing: Sendable {
    func summarize(transcript: String) async throws -> SummaryResult
}

struct Summarizer: Summarizing {
    var forceUnavailable: Bool = false

    func summarize(transcript: String) async throws -> SummaryResult {
        if forceUnavailable {
            return .unavailable(reason: "Forced unavailable for tests")
        }
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .unavailable(reason: "Empty transcript")
        }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return await summarizeWithFoundationModels(transcript)
        }
        #endif
        return .unavailable(reason: "Apple Intelligence / Foundation Models not available on this device")
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private func summarizeWithFoundationModels(_ transcript: String) async -> SummaryResult {
        // Soft dependency: if the types are present but unavailable at runtime, degrade gracefully.
        return .unavailable(reason: "Foundation Models present but not configured in this build")
    }
    #endif
}
