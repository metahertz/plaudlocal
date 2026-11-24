import Foundation

// Optional hand-off of transcription and summarization to a self-hosted
// "Plaud Remote" server (see server/ in this repo). The server queues each
// recording and runs it against the models configured in its web UI.
// The app only connects to it over HTTPS.

// MARK: - Settings

struct RemoteProcessingSettings {
    static let enabledKey = "remote.enabled"
    static let serverURLKey = "remote.serverURL"
    static let fallbackKey = "remote.fallbackOnDevice"
    static let transcribeKey = "remote.transcribe"
    static let summarizeKey = "remote.summarize"
    static let tokenAccount = "remote.apiToken"

    var enabled: Bool
    var serverURL: URL?
    /// Use on-device transcription / summarization when the server can't do the job.
    var fallbackOnDevice: Bool
    var token: String?
    /// Per-stage switches for remote mode; a stage that is off runs on-device.
    var transcribeRemotely = true
    var summarizeRemotely = true

    static func load(defaults: UserDefaults = .standard, keyVault: KeyVault = KeyVault()) -> RemoteProcessingSettings {
        RemoteProcessingSettings(
            enabled: defaults.bool(forKey: enabledKey),
            serverURL: normalizedURL(defaults.string(forKey: serverURLKey) ?? ""),
            fallbackOnDevice: defaults.object(forKey: fallbackKey) as? Bool ?? true,
            token: keyVault.load(account: tokenAccount).flatMap { String(data: $0, encoding: .utf8) },
            transcribeRemotely: defaults.object(forKey: transcribeKey) as? Bool ?? true,
            summarizeRemotely: defaults.object(forKey: summarizeKey) as? Bool ?? true
        )
    }

    /// Accepts only https URLs with a host; trailing slashes are dropped.
    static func normalizedURL(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else {
            return nil
        }
        return url
    }

    /// A client whenever the server address and token are set, whatever the mode.
    var connection: RemoteProcessingClient? {
        guard let serverURL, let token, !token.isEmpty else { return nil }
        return RemoteProcessingClient(baseURL: serverURL, token: token)
    }

    /// A client only when remote mode is switched on.
    var client: RemoteProcessingClient? { enabled ? connection : nil }
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
    /// With `summarize` off the server stops after the transcript.
    func submitAudio(
        fileURL: URL, clientRef: String, title: String, force: Bool = false, summarize: Bool = true
    ) async throws -> RemoteJob {
        var query = [
            URLQueryItem(name: "client_ref", value: clientRef),
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "filename", value: fileURL.lastPathComponent),
        ]
        if force { query.append(URLQueryItem(name: "force", value: "1")) }
        if !summarize { query.append(URLQueryItem(name: "summarize", value: "0")) }
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

/// The server job working on a note, saved in the note's directory as `remote-job.json`.
///
/// Why it exists: the app only polls the server while it is running, and iOS suspends or
/// kills it during long jobs. Without a saved record, the next launch would re-upload the
/// whole recording, and if the transcript was already saved, ask the server to summarize
/// it a second time. With it, the app asks the server for the job it already started:
///
/// - `RemoteTranscriber` writes the record as soon as the upload returns, before polling,
///   and on the next run resumes that job instead of uploading again.
/// - `RemoteSummarizer` reuses the same job's summary, so one upload covers both stages,
///   in the same launch or a later one.
///
/// The record goes away with the note (the whole directory is deleted) and is not part of
/// any export. A missing, unreadable or other-server record just means "no known job".
struct RemoteJobRecord: Codable, Equatable {
    static let fileName = "remote-job.json"

    /// `RemoteProcessingClient.baseURL`, so a record from another server is ignored.
    var server: String
    var jobId: String
    /// Whether the job was asked to summarize as well as transcribe.
    var wantSummary: Bool

    /// The note's record for `server`, if there is one.
    static func read(in noteDirectory: URL, server: URL) -> RemoteJobRecord? {
        let url = noteDirectory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(RemoteJobRecord.self, from: data),
              record.server == server.absoluteString else {
            return nil
        }
        return record
    }

    /// Best effort: if the write fails, the next run uploads again, as it would without a record.
    func write(in noteDirectory: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: noteDirectory.appendingPathComponent(Self.fileName), options: .atomic)
    }

    static func delete(in noteDirectory: URL) {
        try? FileManager.default.removeItem(at: noteDirectory.appendingPathComponent(fileName))
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
    var polling = RemotePolling()
    /// Ask the server for a fresh run even if it has results for this audio.
    var force = false
    /// Off when the summary will be made on-device (or not at all).
    var wantSummary = true

    func transcribe(audioURL: URL) async throws -> String {
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw TranscriberError.missingAudio
        }
        let noteDirectory = audioURL.deletingLastPathComponent()

        let started: RemoteJob
        if !force, let known = try await knownJob(in: noteDirectory) {
            started = known
        } else {
            started = try await client.submitAudio(
                fileURL: audioURL,
                clientRef: noteDirectory.lastPathComponent,
                title: Self.recordingLabel(in: noteDirectory),
                force: force,
                summarize: wantSummary
            )
            // Saved before polling, so a kill while the server works can still be resumed.
            RemoteJobRecord(server: client.baseURL.absoluteString, jobId: started.id, wantSummary: wantSummary)
                .write(in: noteDirectory)
        }

        let job = try await polling.wait(
            for: started, client: client, timeout: polling.transcriptTimeout, what: "transcription"
        ) { !($0.transcript ?? "").isEmpty }
        let transcript = (job.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { throw TranscriberError.emptyTranscript }
        return transcript
    }

    /// The job this note already has on the server, or nil when the audio must be uploaded.
    /// A job the server no longer has (purged, or its data wiped) or one that failed is
    /// forgotten. Other errors (bad token, network, server busy) are thrown and the record
    /// is kept, so a retry resumes the job instead of uploading the recording again.
    private func knownJob(in noteDirectory: URL) async throws -> RemoteJob? {
        guard let record = RemoteJobRecord.read(in: noteDirectory, server: client.baseURL),
              record.wantSummary == wantSummary else {
            return nil
        }
        do {
            let job = try await client.job(id: record.jobId)
            if job.status == "failed" {
                RemoteJobRecord.delete(in: noteDirectory)
                return nil
            }
            return job
        } catch RemoteProcessingError.server(404, _) {
            RemoteJobRecord.delete(in: noteDirectory)
            return nil
        }
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
    var polling = RemotePolling()
    var force = false

    func summarize(transcript: String) async throws -> SummaryResult {
        try await summarize(transcript: transcript, noteDirectory: nil)
    }

    func summarize(transcript: String, noteDirectory: URL?) async throws -> SummaryResult {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unavailable(reason: "Empty transcript") }

        let first: RemoteJob
        let reused: Bool
        if let noteDirectory, let known = try await knownJob(for: trimmed, in: noteDirectory) {
            // The job that transcribed this recording is also summarizing it.
            first = known
            reused = true
        } else {
            first = try await client.submitTranscript(
                trimmed,
                clientRef: noteDirectory?.lastPathComponent ?? "",
                title: noteDirectory.map(RemoteTranscriber.recordingLabel(in:)) ?? "",
                force: force
            )
            reused = false
        }
        let job = try await polling.wait(
            for: first, client: client, timeout: polling.summaryTimeout, what: "summary"
        ) { $0.status == "done" }

        if let summary = job.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            return .text(summary)
        }
        if reused, let noteDirectory {
            // The server finished this job without a summary (its model call failed, say), and
            // it never will have one. Forget it so a later pass submits the transcript instead.
            RemoteJobRecord.delete(in: noteDirectory)
        }
        return .unavailable(reason: job.summaryError ?? "The remote server returned no summary")
    }

    /// The note's server job, if it can supply the summary for `transcript`.
    private func knownJob(for transcript: String, in noteDirectory: URL) async throws -> RemoteJob? {
        guard let record = RemoteJobRecord.read(in: noteDirectory, server: client.baseURL),
              record.wantSummary else {
            return nil
        }
        let job: RemoteJob
        do {
            job = try await client.job(id: record.jobId)
        } catch RemoteProcessingError.server(404, _) {
            RemoteJobRecord.delete(in: noteDirectory)
            return nil
        }
        if job.status == "failed" {
            RemoteJobRecord.delete(in: noteDirectory)
            return nil
        }
        // Only a job that produced this exact transcript may supply its summary. After an
        // on-device fallback the note holds a different transcript, and the server job's
        // summary would describe text the note doesn't contain. Both sides trim whitespace,
        // so a job that did produce it compares equal.
        guard job.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) == transcript else {
            return nil
        }
        return job
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
        try await summarize(transcript: transcript, noteDirectory: nil)
    }

    /// Passes the note directory on to the primary (remote) engine.
    func summarize(transcript: String, noteDirectory: URL?) async throws -> SummaryResult {
        do {
            let result = try await primary.summarize(transcript: transcript, noteDirectory: noteDirectory)
            if case .text = result { return result }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // fall through to the on-device summarizer
        }
        return try await fallback.summarize(transcript: transcript)
    }
}
