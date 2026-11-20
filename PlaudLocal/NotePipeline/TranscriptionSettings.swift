import Foundation

enum TranscriptionEngine: String, CaseIterable, Identifiable {
    /// Apple SpeechAnalyzer / SpeechTranscriber (on-device).
    case apple
    /// WhisperKit (on-device Core ML model, downloaded on first use).
    case whisperKit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: return "Apple Speech"
        case .whisperKit: return "WhisperKit"
        }
    }

    var detail: String {
        switch self {
        case .apple: return "Built-in on-device SpeechAnalyzer"
        case .whisperKit: return "Downloads a Whisper model on first use"
        }
    }
}

enum TranscriptionSettings {
    static let engineKey = "asr.engine"

    static var engine: TranscriptionEngine {
        get {
            let raw = UserDefaults.standard.string(forKey: engineKey) ?? TranscriptionEngine.apple.rawValue
            return TranscriptionEngine(rawValue: raw) ?? .apple
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: engineKey)
        }
    }
}
