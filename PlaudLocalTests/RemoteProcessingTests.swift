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
            baseURL: URL(string: "https://server.test")!,
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

    private func job(_ status: String, id: String = "job-1", transcript: String? = nil, summary: String? = nil,
                     error: String? = nil, summaryError: String? = nil) -> [String: Any] {
        var body: [String: Any] = ["id": id, "status": status]
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

    /// URLSession hands a stubbed request's body over as a stream, not `httpBody`.
    private func readAll(_ stream: InputStream) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        stream.open()
        defer { stream.close() }
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private func queryValue(_ name: String, in request: URLRequest) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == name })?.value
    }

    // MARK: - Settings

    func test_server_url_is_normalized_and_validated() {
        XCTAssertEqual(
            RemoteProcessingSettings.normalizedURL(" https://192.168.1.20:8443/ ")?.absoluteString,
            "https://192.168.1.20:8443"
        )
        XCTAssertEqual(
            RemoteProcessingSettings.normalizedURL("https://plaud.example.com/remote//")?.absoluteString,
            "https://plaud.example.com/remote"
        )
        XCTAssertNil(RemoteProcessingSettings.normalizedURL(""))
        XCTAssertNil(RemoteProcessingSettings.normalizedURL("192.168.1.20:8080"))
        XCTAssertNil(RemoteProcessingSettings.normalizedURL("ftp://example.com"))
        // Plain HTTP is refused: recordings and the token must not travel unencrypted.
        XCTAssertNil(RemoteProcessingSettings.normalizedURL("http://192.168.1.20:8080"))
    }

    func test_client_requires_enabled_url_and_token() {
        var settings = RemoteProcessingSettings(
            enabled: true, serverURL: URL(string: "https://server.test")!, fallbackOnDevice: true, token: "t"
        )
        XCTAssertNotNil(settings.client)
        settings.token = ""
        XCTAssertNil(settings.client)
        XCTAssertNil(settings.connection)
        settings.token = "t"
        settings.enabled = false
        XCTAssertNil(settings.client)
        XCTAssertNotNil(settings.connection, "a configured server stays usable for one-off runs")
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

        let transcript = try await RemoteTranscriber(client: client, polling: fastPolling)
            .transcribe(audioURL: audio)
        XCTAssertEqual(transcript, "Hello from the server.")

        let summary = try await RemoteSummarizer(client: client, polling: fastPolling)
            .summarize(transcript: transcript, noteDirectory: audio.deletingLastPathComponent())
        XCTAssertEqual(summary, .text("A greeting."))

        let posts = requests.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(posts.count, 1, "the summary must reuse the upload's job")
        let upload = try XCTUnwrap(posts.first)
        XCTAssertEqual(upload.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
        XCTAssertEqual(upload.value(forHTTPHeaderField: "Content-Type"), "audio/ogg")
        XCTAssertEqual(queryValue("client_ref", in: upload), "note-abc")
        XCTAssertEqual(queryValue("title", in: upload), "Mon 3 Nov, 10:15")
        XCTAssertNil(queryValue("force", in: upload))
        XCTAssertNil(queryValue("summarize", in: upload))
    }

    func test_transcript_only_upload_tells_the_server_to_skip_the_summary() async throws {
        let audio = try makeNoteAudio()
        stub { [self] method, _ in
            method == "POST" ? (202, job("queued")) : (200, job("done", transcript: "Only text."))
        }
        let transcript = try await RemoteTranscriber(
            client: makeClient(), polling: fastPolling, wantSummary: false
        ).transcribe(audioURL: audio)
        XCTAssertEqual(transcript, "Only text.")
        let upload = try XCTUnwrap(requests.first(where: { $0.httpMethod == "POST" }))
        XCTAssertEqual(queryValue("summarize", in: upload), "0")
        let record = RemoteJobRecord.read(in: audio.deletingLastPathComponent(), server: makeClient().baseURL)
        XCTAssertEqual(record?.wantSummary, false, "the record notes that this job has no summary to offer")
    }

    // MARK: - Resuming after a relaunch

    /// Writes the record a previous launch would have left behind.
    private func rememberJob(for audio: URL) {
        RemoteJobRecord(server: "https://server.test", jobId: "job-1", wantSummary: true)
            .write(in: audio.deletingLastPathComponent())
    }

    func test_transcriber_saves_the_job_before_polling_and_resumes_it_without_uploading() async throws {
        let audio = try makeNoteAudio()
        var transcribing = true
        stub { [self] method, _ in
            if method == "POST" { return (202, job("queued")) }
            return transcribing ? (200, job("transcribing")) : (200, job("done", transcript: "Resumed."))
        }
        // First launch: the app is "killed" (polling gives up) while the server is still working.
        var polling = fastPolling
        polling.transcriptTimeout = 0.05
        _ = try? await RemoteTranscriber(client: makeClient(), polling: polling).transcribe(audioURL: audio)
        XCTAssertNotNil(RemoteJobRecord.read(in: audio.deletingLastPathComponent(), server: makeClient().baseURL))

        // Next launch: the job finished meanwhile; no second upload.
        transcribing = false
        requests = []
        let text = try await RemoteTranscriber(client: makeClient(), polling: fastPolling).transcribe(audioURL: audio)
        XCTAssertEqual(text, "Resumed.")
        XCTAssertFalse(requests.contains { $0.httpMethod == "POST" }, "a known job must not be uploaded again")
    }

    func test_transcriber_uploads_again_when_the_server_forgot_the_job() async throws {
        let audio = try makeNoteAudio()
        rememberJob(for: audio)
        var posted = false
        stub { [self] method, _ in
            if method == "POST" { posted = true; return (202, job("queued")) }
            return posted ? (200, job("done", transcript: "Fresh.")) : (404, ["error": "Job not found"])
        }
        let text = try await RemoteTranscriber(client: makeClient(), polling: fastPolling).transcribe(audioURL: audio)
        XCTAssertEqual(text, "Fresh.")
        XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 1)
    }

    func test_summarizer_reuses_the_upload_job_after_a_relaunch() async throws {
        let audio = try makeNoteAudio()
        rememberJob(for: audio)
        stub { [self] method, path in
            if method == "GET", path == "/api/v1/jobs/job-1" {
                return (200, job("done", transcript: " Saved text. ", summary: "From the upload."))
            }
            return (404, ["error": "unexpected \(method) \(path)"])
        }
        // Called the way the pipeline calls it: through `any Summarizing`, wrapped in the fallback.
        let summarizer: any Summarizing = FallbackSummarizer(
            primary: RemoteSummarizer(client: makeClient(), polling: fastPolling),
            fallback: StubSummarizer(result: .text("on-device summary"))
        )
        let result = try await summarizer.summarize(
            transcript: "Saved text.", noteDirectory: audio.deletingLastPathComponent()
        )
        XCTAssertEqual(result, .text("From the upload."))
        XCTAssertFalse(requests.contains { $0.httpMethod == "POST" }, "no second summary job")
    }

    func test_summarizer_ignores_a_job_whose_transcript_differs() async throws {
        // The remote transcription timed out and the note holds an on-device transcript instead.
        let audio = try makeNoteAudio()
        rememberJob(for: audio)
        stub { [self] method, path in
            if method == "GET", path == "/api/v1/jobs/job-1" {
                return (200, job("done", transcript: "Server's text.", summary: "Summary of the server's text."))
            }
            if method == "POST", path == "/api/v1/jobs/text" { return (202, job("queued", id: "job-2")) }
            return (200, job("done", id: "job-2", transcript: "On-device text.", summary: "Summary of the note."))
        }
        let result = try await RemoteSummarizer(client: makeClient(), polling: fastPolling)
            .summarize(transcript: "On-device text.", noteDirectory: audio.deletingLastPathComponent())
        XCTAssertEqual(result, .text("Summary of the note."))
        let text = try XCTUnwrap(requests.first { $0.url?.path == "/api/v1/jobs/text" })
        let body = try XCTUnwrap(text.httpBody ?? text.httpBodyStream.map(readAll))
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(fields["client_ref"] as? String, "note-abc", "text jobs carry the note's reference")
        XCTAssertEqual(fields["title"] as? String, "Mon 3 Nov, 10:15")
    }

    func test_summarizer_forgets_a_job_whose_summary_failed() async throws {
        let audio = try makeNoteAudio()
        rememberJob(for: audio)
        stub { [self] _, _ in (200, job("done", transcript: "T.", summaryError: "model timed out")) }
        let result = try await RemoteSummarizer(client: makeClient(), polling: fastPolling)
            .summarize(transcript: "T.", noteDirectory: audio.deletingLastPathComponent())
        XCTAssertEqual(result, .unavailable(reason: "model timed out"))
        XCTAssertNil(
            RemoteJobRecord.read(in: audio.deletingLastPathComponent(), server: makeClient().baseURL),
            "a job that will never have a summary must not be reused"
        )
    }

    func test_force_asks_the_server_for_a_fresh_run() async throws {
        let audio = try makeNoteAudio()
        stub { [self] method, _ in
            method == "POST" ? (202, job("queued")) : (200, job("done", transcript: "Text.", summary: "S."))
        }
        _ = try await RemoteTranscriber(
            client: makeClient(), polling: fastPolling, force: true
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
            client: makeClient(), polling: fastPolling
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
            client: makeClient(), polling: fastPolling
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
            _ = try await RemoteTranscriber(client: makeClient(), polling: fastPolling)
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
            _ = try await RemoteTranscriber(client: makeClient(), polling: fastPolling)
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
            _ = try await RemoteTranscriber(client: makeClient(), polling: polling)
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
            primary: RemoteTranscriber(client: makeClient(), polling: fastPolling),
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
            primary: RemoteSummarizer(client: makeClient(), polling: fastPolling),
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
            primary: RemoteSummarizer(client: makeClient(), polling: fastPolling),
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
