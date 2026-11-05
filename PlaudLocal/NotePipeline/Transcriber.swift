import Foundation

protocol Transcribing: Sendable {
    func transcribe(audioURL: URL) async throws -> String
}

/// Placeholder on-device transcriber. WhisperKit is wired when the SPM package is available;
/// until then this returns a deterministic stub so the pipeline can be exercised offline.
struct Transcriber: Transcribing {
    func transcribe(audioURL: URL) async throws -> String {
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw TranscriberError.missingAudio
        }
        // Ruling: ship pipeline with a file-presence stub; integrate WhisperKit package in a follow-up
        // once SPM resolution is verified on this machine. See README.
        return "Transcript pending WhisperKit model download for \(audioURL.lastPathComponent)."
    }
}

enum TranscriberError: Error {
    case missingAudio
}
