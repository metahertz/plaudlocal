import Foundation

// Optional hand-off of transcription and summarization to a self-hosted
// "Plaud Remote" server (see server/ in this repo). The server queues each
// recording and runs it against the models configured in its web UI.

// MARK: - Settings

struct RemoteProcessingSettings {
    static let enabledKey = "remote.enabled"
    static let serverURLKey = "remote.serverURL"
    static let fallbackKey = "remote.fallbackOnDevice"
    static let tokenAccount = "remote.apiToken"

    var enabled: Bool
    var serverURL: URL?
    /// Use on-device transcription / summarization when the server can't do the job.
    var fallbackOnDevice: Bool
    var token: String?

    static func load(defaults: UserDefaults = .standard, keyVault: KeyVault = KeyVault()) -> RemoteProcessingSettings {
        RemoteProcessingSettings(
            enabled: defaults.bool(forKey: enabledKey),
            serverURL: normalizedURL(defaults.string(forKey: serverURLKey) ?? ""),
            fallbackOnDevice: defaults.object(forKey: fallbackKey) as? Bool ?? true,
            token: keyVault.load(account: tokenAccount).flatMap { String(data: $0, encoding: .utf8) }
        )
    }

    /// Accepts only http(s) URLs with a host; trailing slashes are dropped.
    static func normalizedURL(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            return nil
        }
        return url
    }

    /// A client when remote processing is switched on and fully configured.
    var client: RemoteProcessingClient? {
        guard enabled, let serverURL, let token, !token.isEmpty else { return nil }
        return RemoteProcessingClient(baseURL: serverURL, token: token)
    }
}

// MARK: - Errors

enum RemoteProcessingError: Error, LocalizedError, Equatable {
    case unauthorized
    case server(status: Int, message: String)
    case jobFailed(String)
    case timedOut(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "The remote server rejected the API token — check it in Settings"
        case let .server(status, message):
            return message.isEmpty ? "Remote server error (HTTP \(status))" : "Remote server: \(message)"
        case let .jobFailed(message):
            return "Remote processing failed: \(message)"
        case let .timedOut(what):
            return "Remote \(what) is taking too long — it will continue on the server"
        case .invalidResponse:
            return "The remote server sent a response this app does not understand"
        }
    }

    /// Whether trying the same request again could help.
    var isTransient: Bool {
        switch self {
        case .unauthorized, .jobFailed, .invalidResponse: return false
        case .timedOut: return true
        case let .server(status, _): return status == 408 || status == 429 || status >= 500
        }
    }
}

// MARK: - Client

struct RemoteHealth: Decodable, Equatable {
    var version: String
    var transcription: Bool
    var summarization: Bool
}

struct RemoteJob: Decodable, Equatable {
    var id: String
    var status: String
    var transcript: String?
    var summary: String?
    var error: String?
    var summaryError: String?

    enum CodingKeys: String, CodingKey {
        case id, status, transcript, summary, error
        case summaryError = "summary_error"
    }

    var isFinished: Bool { status == "done" || status == "failed" }
}

struct RemoteProcessingClient: Sendable {
    var baseURL: URL
    var token: String
    var session: URLSession = .shared

    func health() async throws -> RemoteHealth {
        try await send(makeRequest("GET", path: "api/v1/health"))
    }

    /// Upload a recording. The server returns the existing job when it already has this
    /// audio queued or finished with the same model settings, unless `force` is set.
    func submitAudio(fileURL: URL, clientRef: String, title: String, force: Bool = false) async throws -> RemoteJob {
        var query = [
            URLQueryItem(name: "client_ref", value: clientRef),
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "filename", value: fileURL.lastPathComponent),
        ]
        if force { query.append(URLQueryItem(name: "force", value: "1")) }
        var request = makeRequest("POST", path: "api/v1/jobs", query: query)
        request.setValue("audio/ogg", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 900
        let (data, response) = try await session.upload(for: request, fromFile: fileURL)
        return try decode(data, response)
    }

    /// Ask the server to summarize a transcript the app already has.
    func submitTranscript(_ transcript: String, clientRef: String, title: String, force: Bool = false) async throws -> RemoteJob {
        var request = makeRequest("POST", path: "api/v1/jobs/text")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "transcript": transcript, "client_ref": clientRef, "title": title, "force": force,
        ] as [String: Any])
        return try await send(request)
    }

    func job(id: String) async throws -> RemoteJob {
        try await send(makeRequest("GET", path: "api/v1/jobs/\(id)"))
    }

    private func makeRequest(_ method: String, path: String, query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        return try decode(data, response)
    }

    private func decode<T: Decodable>(_ data: Data, _ response: URLResponse) throws -> T {
        guard let http = response as? HTTPURLResponse else { throw RemoteProcessingError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw RemoteProcessingError.unauthorized }
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw RemoteProcessingError.server(status: http.statusCode, message: message ?? "")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw RemoteProcessingError.invalidResponse
        }
    }
}

// MARK: - Pipeline stages

/// Lets the summary stage find the server job that produced a transcript, so one
/// upload covers both stages.
final class RemoteJobRegistry: @unchecked Sendable {
    static let shared = RemoteJobRegistry()

    private let lock = NSLock()
    private var jobIDs: [String: String] = [:]
    private var order: [String] = []

    func remember(jobID: String, forTranscript transcript: String) {
        lock.lock(); defer { lock.unlock() }
        let key = Self.key(transcript)
        if jobIDs[key] == nil { order.append(key) }
        jobIDs[key] = jobID
        while order.count > 32 { jobIDs[order.removeFirst()] = nil }
    }

    func jobID(forTranscript transcript: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return jobIDs[Self.key(transcript)]
    }

    private static func key(_ transcript: String) -> String {
        "\(transcript.utf8.count):\(transcript.hashValue)"
    }
}

/// How long and how often to poll the server for a job.
struct RemotePolling: Sendable {
    var intervalNanoseconds: UInt64 = 3_000_000_000
    var transcriptTimeout: TimeInterval = 2 * 60 * 60
    var summaryTimeout: TimeInterval = 30 * 60
    /// Consecutive failed status checks tolerated (brief network drops) before giving up.
    var maxConsecutiveErrors = 5

    /// Poll `jobID` until `isReady` accepts it. Throws when the job fails or `timeout` passes.
    func wait(
        for first: RemoteJob,
        client: RemoteProcessingClient,
        timeout: TimeInterval,
        what: String,
        until isReady: (RemoteJob) -> Bool
    ) async throws -> RemoteJob {
        var job = first
        var errors = 0
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if isReady(job) { return job }
            if job.status == "failed" {
                throw RemoteProcessingError.jobFailed(job.error ?? "unknown error")
            }
            guard Date() < deadline else { throw RemoteProcessingError.timedOut(what) }
            try await Task.sleep(nanoseconds: intervalNanoseconds)
            do {
                job = try await client.job(id: job.id)
                errors = 0
            } catch let error as RemoteProcessingError where !error.isTransient {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                errors += 1
                if errors > maxConsecutiveErrors { throw error }
            }
        }
    }
}

struct RemoteTranscriber: Transcribing {
    var client: RemoteProcessingClient
    var registry: RemoteJobRegistry = .shared
    var polling = RemotePolling()
    /// Ask the server for a fresh run even if it has results for this audio.
    var force = false

    func transcribe(audioURL: URL) async throws -> String {
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw TranscriberError.missingAudio
        }
        let noteDirectory = audioURL.deletingLastPathComponent()
        let submitted = try await client.submitAudio(
            fileURL: audioURL,
            clientRef: noteDirectory.lastPathComponent,
            title: Self.recordingLabel(in: noteDirectory),
            force: force
        )
        let job = try await polling.wait(
            for: submitted, client: client, timeout: polling.transcriptTimeout, what: "transcription"
        ) { !($0.transcript ?? "").isEmpty }
        let transcript = (job.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { throw TranscriberError.emptyTranscript }
        registry.remember(jobID: job.id, forTranscript: transcript)
        return transcript
    }

    /// The note's label, so jobs are recognisable in the server's web UI.
    static func recordingLabel(in noteDirectory: URL) -> String {
        let url = noteDirectory.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }
        return (object["recordingLabel"] as? String) ?? (object["title"] as? String) ?? ""
    }
}

struct RemoteSummarizer: Summarizing {
    var client: RemoteProcessingClient
    var registry: RemoteJobRegistry = .shared
    var polling = RemotePolling()
    var force = false

    func summarize(transcript: String) async throws -> SummaryResult {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unavailable(reason: "Empty transcript") }

        let first: RemoteJob
        if let jobID = registry.jobID(forTranscript: trimmed) {
            // The job that transcribed this recording is also summarizing it.
            first = try await client.job(id: jobID)
        } else {
            first = try await client.submitTranscript(trimmed, clientRef: "", title: "", force: force)
        }
        let job = try await polling.wait(
            for: first, client: client, timeout: polling.summaryTimeout, what: "summary"
        ) { $0.status == "done" }

        if let summary = job.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            return .text(summary)
        }
        return .unavailable(reason: job.summaryError ?? "The remote server returned no summary")
    }
}

/// Tries the remote server first, then the on-device engine.
struct FallbackTranscriber: Transcribing {
    var primary: any Transcribing
    var fallback: any Transcribing

    func transcribe(audioURL: URL) async throws -> String {
        do {
            return try await primary.transcribe(audioURL: audioURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return try await fallback.transcribe(audioURL: audioURL)
        }
    }
}

struct FallbackSummarizer: Summarizing {
    var primary: any Summarizing
    var fallback: any Summarizing

    func summarize(transcript: String) async throws -> SummaryResult {
        do {
            let result = try await primary.summarize(transcript: transcript)
            if case .text = result { return result }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // fall through to the on-device summarizer
        }
        return try await fallback.summarize(transcript: transcript)
    }
}

// MARK: - Engine selection

/// Picks the transcription and summarization engines from the current settings.
enum PipelineEngines {
    static func transcriber(
        remote: RemoteProcessingSettings = .load(),
        force: Bool = false
    ) -> any Transcribing {
        let onDevice = Transcriber(engine: TranscriptionSettings.engine)
        guard let client = remote.client else { return onDevice }
        let remoteEngine = RemoteTranscriber(client: client, force: force)
        if remote.fallbackOnDevice {
            return FallbackTranscriber(primary: remoteEngine, fallback: onDevice)
        }
        return remoteEngine
    }

    static func summarizer(
        remote: RemoteProcessingSettings = .load(),
        force: Bool = false
    ) -> any Summarizing {
        let onDevice = Summarizer()
        guard let client = remote.client else { return onDevice }
        let remoteEngine = RemoteSummarizer(client: client, force: force)
        if remote.fallbackOnDevice {
            return FallbackSummarizer(primary: remoteEngine, fallback: onDevice)
        }
        return remoteEngine
    }

    /// Name of the transcription engine for status messages.
    static var transcriberTitle: String {
        RemoteProcessingSettings.load().client != nil ? "remote server" : TranscriptionSettings.engine.title
    }
}
