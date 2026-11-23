import XCTest
@testable import PlaudLocal

final class RemoteProcessingTests: XCTestCase {
    private var requests: [URLRequest] = []

    override func tearDown() {
        StubURLProtocol.handler = nil
        requests = []
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeClient() -> RemoteProcessingClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return RemoteProcessingClient(
            baseURL: URL(string: "http://server.test:8080")!,
            token: "secret-token",
            session: URLSession(configuration: config)
        )
    }

    private let fastPolling = RemotePolling(intervalNanoseconds: 1_000_000)

    /// Routes stubbed requests; `respond` returns a status code and JSON body.
    private func stub(_ respond: @escaping (_ method: String, _ path: String) -> (Int, [String: Any])) {
        StubURLProtocol.handler = { [weak self] request in
            self?.requests.append(request)
            let (status, body) = respond(request.httpMethod ?? "GET", request.url?.path ?? "")
            let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }
    }

    private func job(_ status: String, transcript: String? = nil, summary: String? = nil,
                     error: String? = nil, summaryError: String? = nil) -> [String: Any] {
        var body: [String: Any] = ["id": "job-1", "status": status]
        body["transcript"] = transcript ?? NSNull()
        body["summary"] = summary ?? NSNull()
        body["error"] = error ?? NSNull()
        body["summary_error"] = summaryError ?? NSNull()
        return body
    }

    private func makeNoteAudio(label: String = "Mon 3 Nov, 10:15") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("note-abc", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let audio = dir.appendingPathComponent("audio.ogg")
        try Data("OggS-fake-audio".utf8).write(to: audio)
        let metadata = try JSONSerialization.data(withJSONObject: ["recordingLabel": label])
        try metadata.write(to: dir.appendingPathComponent("metadata.json"))
        return audio
    }

    private func queryValue(_ name: String, in request: URLRequest) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == name })?.value
    }

    // MARK: - Settings

    func test_server_url_is_normalized_and_validated() {
        XCTAssertEqual(
            RemoteProcessingSettings.normalizedURL(" http://192.168.1.20:8080/ ")?.absoluteString,
            "http://192.168.1.20:8080"
        )
        XCTAssertEqual(
            RemoteProcessingSettings.normalizedURL("https://plaud.example.com/remote//")?.absoluteString,
            "https://plaud.example.com/remote"
        )
        XCTAssertNil(RemoteProcessingSettings.normalizedURL(""))
        XCTAssertNil(RemoteProcessingSettings.normalizedURL("192.168.1.20:8080"))
        XCTAssertNil(RemoteProcessingSettings.normalizedURL("ftp://example.com"))
    }

    func test_client_requires_enabled_url_and_token() {
        var settings = RemoteProcessingSettings(
            enabled: true, serverURL: URL(string: "http://server.test")!, fallbackOnDevice: true, token: "t"
        )
        XCTAssertNotNil(settings.client)
        settings.token = ""
        XCTAssertNil(settings.client)
        settings.token = "t"
        settings.enabled = false
        XCTAssertNil(settings.client)
    }

    // MARK: - Transcribe + summarize

    func test_one_upload_serves_transcript_and_summary() async throws {
        let audio = try makeNoteAudio()
        var polls = 0
        stub { [self] method, path in
            if method == "POST", path == "/api/v1/jobs" { return (202, job("queued")) }
            if method == "GET", path == "/api/v1/jobs/job-1" {
                polls += 1
                switch polls {
                case 1: return (200, job("transcribing"))
                case 2: return (200, job("summarizing", transcript: " Hello from the server. "))
                case 3: return (200, job("summarizing", transcript: " Hello from the server. "))
                default: return (200, job("done", transcript: " Hello from the server. ", summary: "A greeting."))
                }
            }
            return (404, ["error": "unexpected \(method) \(path)"])
        }
        let client = makeClient()
        let registry = RemoteJobRegistry()

        let transcript = try await RemoteTranscriber(client: client, registry: registry, polling: fastPolling)
            .transcribe(audioURL: audio)
        XCTAssertEqual(transcript, "Hello from the server.")

        let summary = try await RemoteSummarizer(client: client, registry: registry, polling: fastPolling)
            .summarize(transcript: transcript)
        XCTAssertEqual(summary, .text("A greeting."))

        let posts = requests.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(posts.count, 1, "the summary must reuse the upload's job")
        let upload = try XCTUnwrap(posts.first)
        XCTAssertEqual(upload.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
        XCTAssertEqual(upload.value(forHTTPHeaderField: "Content-Type"), "audio/ogg")
        XCTAssertEqual(queryValue("client_ref", in: upload), "note-abc")
        XCTAssertEqual(queryValue("title", in: upload), "Mon 3 Nov, 10:15")
        XCTAssertNil(queryValue("force", in: upload))
    }

    func test_force_asks_the_server_for_a_fresh_run() async throws {
        let audio = try makeNoteAudio()
        stub { [self] method, _ in
            method == "POST" ? (202, job("queued")) : (200, job("done", transcript: "Text.", summary: "S."))
        }
        _ = try await RemoteTranscriber(
            client: makeClient(), registry: RemoteJobRegistry(), polling: fastPolling, force: true
        ).transcribe(audioURL: audio)
        let upload = try XCTUnwrap(requests.first(where: { $0.httpMethod == "POST" }))
        XCTAssertEqual(queryValue("force", in: upload), "1")
    }

    func test_summarizer_submits_transcript_when_no_job_is_known() async throws {
        stub { [self] method, path in
            if method == "POST", path == "/api/v1/jobs/text" { return (202, job("queued")) }
            if method == "GET" { return (200, job("done", transcript: "Existing text.", summary: "Short.")) }
            return (404, [:])
        }
        let result = try await RemoteSummarizer(
            client: makeClient(), registry: RemoteJobRegistry(), polling: fastPolling
        ).summarize(transcript: "Existing text.")
        XCTAssertEqual(result, .text("Short."))
        XCTAssertEqual(requests.first?.url?.path, "/api/v1/jobs/text")
    }

    func test_done_job_without_summary_is_unavailable_with_the_servers_reason() async throws {
        stub { [self] method, _ in
            method == "POST"
                ? (202, job("queued"))
                : (200, job("done", transcript: "T.", summaryError: "Summarization is not configured on the server"))
        }
        let result = try await RemoteSummarizer(
            client: makeClient(), registry: RemoteJobRegistry(), polling: fastPolling
        ).summarize(transcript: "T.")
        XCTAssertEqual(result, .unavailable(reason: "Summarization is not configured on the server"))
    }

    // MARK: - Failures

    func test_failed_job_throws_the_servers_error() async throws {
        let audio = try makeNoteAudio()
        stub { [self] method, _ in
            method == "POST" ? (202, job("queued")) : (200, job("failed", error: "model exploded"))
        }
        do {
            _ = try await RemoteTranscriber(client: makeClient(), registry: RemoteJobRegistry(), polling: fastPolling)
                .transcribe(audioURL: audio)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? RemoteProcessingError, .jobFailed("model exploded"))
            XCTAssertEqual(PipelineRetry.classify(error), .permanent)
        }
    }

    func test_rejected_token_is_reported_and_not_retried() async throws {
        let audio = try makeNoteAudio()
        stub { _, _ in (401, ["error": "Missing or invalid API token"]) }
        do {
            _ = try await RemoteTranscriber(client: makeClient(), registry: RemoteJobRegistry(), polling: fastPolling)
                .transcribe(audioURL: audio)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? RemoteProcessingError, .unauthorized)
            XCTAssertEqual(PipelineRetry.classify(error), .permanent)
        }
        XCTAssertEqual(requests.count, 1)
    }

    func test_server_error_message_is_surfaced_and_retryable() async throws {
        stub { _, _ in (503, ["error": "busy"]) }
        do {
            _ = try await makeClient().health()
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? RemoteProcessingError, .server(status: 503, message: "busy"))
            XCTAssertEqual(PipelineRetry.classify(error), .retryable)
        }
    }

    func test_polling_times_out() async throws {
        let audio = try makeNoteAudio()
        stub { [self] method, _ in method == "POST" ? (202, job("queued")) : (200, job("transcribing")) }
        var polling = fastPolling
        polling.transcriptTimeout = 0.05
        do {
            _ = try await RemoteTranscriber(client: makeClient(), registry: RemoteJobRegistry(), polling: polling)
                .transcribe(audioURL: audio)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? RemoteProcessingError, .timedOut("transcription"))
        }
    }

    // MARK: - Fallback

    func test_transcriber_falls_back_to_on_device_when_the_server_fails() async throws {
        let audio = try makeNoteAudio()
        stub { _, _ in (500, ["error": "down"]) }
        let transcriber = FallbackTranscriber(
            primary: RemoteTranscriber(client: makeClient(), registry: RemoteJobRegistry(), polling: fastPolling),
            fallback: FakeTranscriber(text: "on-device text")
        )
        let text = try await transcriber.transcribe(audioURL: audio)
        XCTAssertEqual(text, "on-device text")
    }

    func test_summarizer_falls_back_when_the_server_has_no_summary() async throws {
        stub { [self] method, _ in
            method == "POST" ? (202, job("queued")) : (200, job("done", transcript: "T.", summaryError: "nope"))
        }
        let summarizer = FallbackSummarizer(
            primary: RemoteSummarizer(client: makeClient(), registry: RemoteJobRegistry(), polling: fastPolling),
            fallback: StubSummarizer(result: .text("on-device summary"))
        )
        let result = try await summarizer.summarize(transcript: "T.")
        XCTAssertEqual(result, .text("on-device summary"))
    }

    func test_summarizer_keeps_the_remote_summary_when_present() async throws {
        stub { [self] method, _ in
            method == "POST" ? (202, job("queued")) : (200, job("done", transcript: "T.", summary: "remote summary"))
        }
        let summarizer = FallbackSummarizer(
            primary: RemoteSummarizer(client: makeClient(), registry: RemoteJobRegistry(), polling: fastPolling),
            fallback: StubSummarizer(result: .text("on-device summary"))
        )
        let result = try await summarizer.summarize(transcript: "T.")
        XCTAssertEqual(result, .text("remote summary"))
    }
}

private struct StubSummarizer: Summarizing {
    let result: SummaryResult
    func summarize(transcript: String) async throws -> SummaryResult { result }
}
