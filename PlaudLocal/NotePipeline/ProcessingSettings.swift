import Foundation

/// Where a new recording's AI work happens.
enum ProcessingMode: String, CaseIterable, Identifiable {
    /// Transcribe and summarize on this iPhone.
    case onDevice
    /// Send the audio to a Plaud Remote server.
    case remote
    /// No AI: just decrypt and export the audio.
    case audioOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onDevice: return "On this iPhone"
        case .remote: return "Remote server"
        case .audioOnly: return "Audio only"
        }
    }

    var detail: String {
        switch self {
        case .onDevice:
            return "Recordings are transcribed and summarized on this iPhone. Nothing leaves the device unless you export it."
        case .remote:
            return "Recordings are uploaded to your Plaud Remote server, which runs the models you set up there and returns the text."
        case .audioOnly:
            return "No transcription or summary. Recordings are decrypted and exported as audio for your own tools. You can still process a single note from its page."
        }
    }

    // The mode is stored as the two switches the pipeline already reads, so
    // existing installs keep their behaviour.

    static func current(defaults: UserDefaults = .standard) -> ProcessingMode {
        if defaults.bool(forKey: ExportSettings.audioOnlyModeKey) { return .audioOnly }
        if defaults.bool(forKey: RemoteProcessingSettings.enabledKey) { return .remote }
        return .onDevice
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(self == .audioOnly, forKey: ExportSettings.audioOnlyModeKey)
        defaults.set(self == .remote, forKey: RemoteProcessingSettings.enabledKey)
    }
}

/// Which optional pipeline steps run, in either AI mode.
struct PipelineOptions: Equatable {
    static let summarizeKey = "pipeline.summarize"
    /// Builds the brief (key kept from when this switch also controlled the poster).
    static let posterKey = "pipeline.poster"
    static let posterImageKey = "pipeline.posterImage"

    static let summaryOffReason = "Summaries are turned off in Settings"

    var summarize = true
    /// Build the brief (title, "At a glance", action items). The brief also gives the note its
    /// title; without it the note keeps its recording label. (Named for when it also meant the poster.)
    var buildPoster = true
    /// Also render the poster image from the brief. Ignored when the brief is off.
    var posterImage = true

    static func load(defaults: UserDefaults = .standard) -> PipelineOptions {
        PipelineOptions(
            summarize: defaults.object(forKey: summarizeKey) as? Bool ?? true,
            buildPoster: defaults.object(forKey: posterKey) as? Bool ?? true,
            posterImage: defaults.object(forKey: posterImageKey) as? Bool ?? true
        )
    }

    /// Whether a note's brief step still has work to do under these options.
    func briefNeeded(for meta: NoteMetadata) -> Bool {
        meta.briefStatus != .done || (buildPoster && posterImage && meta.posterFileName == nil)
    }
}

/// A one-off choice of engine for a single note, regardless of the saved mode.
enum EngineOverride {
    case onDevice
    case remote
}

/// Picks the transcription and summarization engines from the current settings.
enum PipelineEngines {
    static func transcriber(
        remote: RemoteProcessingSettings = .load(),
        options: PipelineOptions = .load(),
        override: EngineOverride? = nil,
        force: Bool = false
    ) -> any Transcribing {
        let onDevice = Transcriber(engine: TranscriptionSettings.engine)
        guard override != .onDevice,
              let client = remote.connection,
              override == .remote || (remote.enabled && remote.transcribeRemotely) else {
            return onDevice
        }
        // Don't spend server time on a summary the app won't use.
        let wantSummary = options.summarize && (override == .remote || remote.summarizeRemotely)
        let remoteEngine = RemoteTranscriber(client: client, force: force, wantSummary: wantSummary)
        if remote.fallbackOnDevice {
            return FallbackTranscriber(primary: remoteEngine, fallback: onDevice)
        }
        return remoteEngine
    }

    static func summarizer(
        remote: RemoteProcessingSettings = .load(),
        override: EngineOverride? = nil,
        force: Bool = false
    ) -> any Summarizing {
        let onDevice = Summarizer()
        guard override != .onDevice,
              let client = remote.connection,
              override == .remote || (remote.enabled && remote.summarizeRemotely) else {
            return onDevice
        }
        let remoteEngine = RemoteSummarizer(client: client, force: force)
        if remote.fallbackOnDevice {
            return FallbackSummarizer(primary: remoteEngine, fallback: onDevice)
        }
        return remoteEngine
    }

    /// Name of the transcription engine for status messages.
    static func transcriberTitle(
        remote: RemoteProcessingSettings = .load(),
        override: EngineOverride? = nil
    ) -> String {
        let usesRemote = override != .onDevice
            && remote.connection != nil
            && (override == .remote || (remote.enabled && remote.transcribeRemotely))
        return usesRemote ? "remote server" : TranscriptionSettings.engine.title
    }
}
