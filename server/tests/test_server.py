"""Tests for the server: request handling, the queue and the model calls.

Requests go through the real HTTP handler over in-memory streams, and model
endpoints are replaced at the single network call in `providers`, so the
suite needs no open ports. One smoke test also runs over a real socket when
the environment allows binding one.

Run from the server/ directory:  python -m unittest discover -s tests -v
"""

from __future__ import annotations

import base64
import http.client
import io
import json
import os
import tempfile
import threading
import time
import types
import unittest
import urllib.error
import urllib.request
from unittest import mock

from plaud_remote import providers
from plaud_remote.__main__ import build
from plaud_remote.web import Handler, Server
from plaud_remote.worker import SUMMARY_NOT_CONFIGURED

ADMIN_PASSWORD = "test-admin-password"
AUDIO = b"OggS" + bytes(range(256)) * 8


class FakeModels:
    """A stand-in for an OpenAI-compatible endpoint with scriptable failures."""

    base_url = "http://models.test/v1"

    def __init__(self) -> None:
        self.transcribe_failures: list[int] = []  # status codes to return before succeeding
        self.chat_failures: list[int] = []
        self.transcript = "Alice agreed to send the report on Friday."
        self.chat_reply = "<think>scratch work</think>Summary: Alice sends the report Friday."
        self.transcribe_calls = 0
        self.chat_requests: list[dict] = []
        self.last_upload = b""
        self.last_auth = ""

    def urlopen(self, request: urllib.request.Request, timeout: float) -> bytes:
        url = request.full_url
        self.last_auth = request.get_header("Authorization", "")

        def fail(status: int) -> None:
            raise urllib.error.HTTPError(url, status, "scripted", None, io.BytesIO(b'{"error": "scripted failure"}'))

        if not url.startswith(self.base_url):
            raise urllib.error.URLError("unknown host")
        if url.endswith("/models"):
            return json.dumps({"data": [{"id": "whisper-test"}, {"id": "chat-test"}]}).encode()
        if url.endswith("/audio/transcriptions"):
            self.transcribe_calls += 1
            self.last_upload = request.data
            if self.transcribe_failures:
                fail(self.transcribe_failures.pop(0))
            return json.dumps({"text": self.transcript}).encode()
        if url.endswith("/chat/completions"):
            self.chat_requests.append(json.loads(request.data))
            if self.chat_failures:
                fail(self.chat_failures.pop(0))
            return json.dumps({"choices": [{"message": {"content": self.chat_reply}}]}).encode()
        fail(404)
        raise AssertionError("unreachable")


class _MemorySocket:
    """Just enough of a socket for BaseHTTPRequestHandler and HTTPResponse."""

    def __init__(self, incoming: bytes) -> None:
        self._incoming = incoming
        self.sent = bytearray()

    def makefile(self, mode: str, *_: object) -> io.BytesIO:
        return io.BytesIO(self._incoming)

    def sendall(self, data: bytes) -> None:
        self.sent += data

    def settimeout(self, _: object) -> None:
        pass


class ServerTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.fake = FakeModels()
        patcher = mock.patch.object(providers, "_urlopen", self.fake.urlopen)
        patcher.start()
        self.addCleanup(patcher.stop)

        self.app, self.pool, self.store = build(
            self.tmp.name, admin_password=ADMIN_PASSWORD, max_upload_mb=1, backoff_base=0.05, poll_interval=0.05,
        )
        self.pool.start()
        self.addCleanup(self.store.close)
        self.addCleanup(self.pool.stop)
        self.token = self.store.app_token()

    # ---- helpers --------------------------------------------------------

    def request(self, method, path, *, body=None, headers=None, auth="app"):
        headers = dict(headers or {})
        if auth == "app":
            headers["Authorization"] = f"Bearer {self.token}"
        elif auth == "admin":
            headers["Authorization"] = "Basic " + base64.b64encode(f"admin:{ADMIN_PASSWORD}".encode()).decode()
            if method != "GET":
                headers.setdefault("X-Requested-With", "plaud-remote")
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
            headers.setdefault("Content-Type", "application/json")
        if body is not None:
            headers["Content-Length"] = str(len(body))
        headers["Connection"] = "close"
        raw = f"{method} {path} HTTP/1.1\r\nHost: test\r\n".encode()
        raw += "".join(f"{k}: {v}\r\n" for k, v in headers.items()).encode() + b"\r\n" + (body or b"")

        sock = _MemorySocket(raw)
        Handler(sock, ("127.0.0.1", 0), types.SimpleNamespace(app=self.app))
        response = http.client.HTTPResponse(_MemorySocket(bytes(sock.sent)), method=method)
        response.begin()
        payload = response.read()
        self.last_headers = dict(response.getheaders())
        try:
            return response.status, json.loads(payload or b"{}")
        except json.JSONDecodeError:
            return response.status, {"raw": payload.decode("utf-8", "replace")}

    def configure(self, transcription=True, summarization=True, **queue):
        patch: dict = {"queue": queue} if queue else {}
        if transcription:
            patch["transcription"] = {"base_url": self.fake.base_url, "model": "whisper-test", "api_key": "sk-speech"}
        if summarization:
            patch["summarization"] = {"base_url": self.fake.base_url, "model": "chat-test", "api_key": "sk-chat"}
        status, _ = self.request("PUT", "/admin/api/settings", body=patch, auth="admin")
        self.assertEqual(status, 200)

    def upload(self, audio=AUDIO, query="?client_ref=note-1&title=Weekly%20sync&filename=audio.ogg"):
        return self.request("POST", "/api/v1/jobs" + query, body=audio, headers={"Content-Type": "audio/ogg"})

    def wait_for(self, job_id, statuses=("done", "failed"), timeout=10):
        deadline = time.time() + timeout
        while time.time() < deadline:
            status, job = self.request("GET", f"/api/v1/jobs/{job_id}")
            self.assertEqual(status, 200)
            if job["status"] in statuses:
                return job
            time.sleep(0.05)
        self.fail(f"job {job_id} did not reach {statuses}; last status {job['status']}")


class AuthTests(ServerTestCase):
    def test_healthz_is_open_and_api_needs_token(self):
        self.assertEqual(self.request("GET", "/healthz", auth=None)[0], 200)
        self.assertEqual(self.request("GET", "/api/v1/health", auth=None)[0], 401)
        status, _ = self.request("GET", "/api/v1/health", auth=None, headers={"Authorization": "Bearer wrong"})
        self.assertEqual(status, 401)
        status, health = self.request("GET", "/api/v1/health")
        self.assertEqual(status, 200)
        self.assertEqual((health["transcription"], health["summarization"]), (False, False))

    def test_admin_needs_password_and_csrf_header(self):
        self.assertEqual(self.request("GET", "/admin/api/settings", auth=None)[0], 401)
        self.assertEqual(self.request("GET", "/", auth=None)[0], 401)
        bad = "Basic " + base64.b64encode(b"admin:nope").decode()
        self.assertEqual(self.request("GET", "/admin/api/settings", auth=None, headers={"Authorization": bad})[0], 401)
        # App token must not open the admin API, and vice versa.
        self.assertEqual(self.request("GET", "/admin/api/settings")[0], 401)
        self.assertEqual(self.request("GET", "/api/v1/health", auth="admin")[0], 401)
        status, _ = self.request(
            "PUT", "/admin/api/settings", body={"queue": {"max_attempts": 2}}, auth="admin",
            headers={"X-Requested-With": "something-else"},
        )
        self.assertEqual(status, 403)

    def test_settings_never_return_api_keys(self):
        self.configure()
        status, settings = self.request("GET", "/admin/api/settings", auth="admin")
        self.assertEqual(status, 200)
        self.assertNotIn("api_key", settings["transcription"])
        self.assertTrue(settings["transcription"]["api_key_set"])
        self.assertNotIn("sk-speech", json.dumps(settings))
        # Saving without a key keeps the stored one.
        self.request("PUT", "/admin/api/settings", body={"transcription": {"model": "whisper-2"}}, auth="admin")
        self.assertEqual(self.store.settings()["transcription"]["api_key"], "sk-speech")
        self.assertEqual(self.store.settings()["transcription"]["model"], "whisper-2")

    def test_invalid_base_url_is_rejected(self):
        status, body = self.request(
            "PUT", "/admin/api/settings", body={"transcription": {"base_url": "file:///etc/passwd"}}, auth="admin"
        )
        self.assertEqual(status, 400)
        self.assertIn("http", body["error"])

    def test_regenerating_token_revokes_the_old_one(self):
        status, body = self.request("POST", "/admin/api/token/regenerate", body={}, auth="admin")
        self.assertEqual(status, 200)
        self.assertNotEqual(body["token"], self.token)
        self.assertEqual(self.request("GET", "/api/v1/health")[0], 401)


class JobTests(ServerTestCase):
    def test_audio_job_is_transcribed_and_summarized(self):
        self.configure()
        status, job = self.upload()
        self.assertEqual(status, 202)
        self.assertEqual(job["title"], "Weekly sync")
        done = self.wait_for(job["id"])
        self.assertEqual(done["status"], "done")
        self.assertEqual(done["transcript"], self.fake.transcript)
        self.assertEqual(done["summary"], "Summary: Alice sends the report Friday.")  # <think> block removed
        self.assertIsNone(done["summary_error"])
        self.assertIn(AUDIO, self.fake.last_upload)
        self.assertEqual(self.fake.last_auth, "Bearer sk-chat")
        self.assertIn("Weekly sync", self.fake.chat_requests[-1]["messages"][1]["content"])
        # Audio is removed once the job is finished.
        self.assertEqual(os.listdir(self.store.audio_dir), [])

    def test_same_audio_reuses_the_job_unless_forced(self):
        self.configure()
        _, first = self.upload()
        self.wait_for(first["id"])
        status, again = self.upload()
        self.assertEqual((status, again["id"]), (200, first["id"]))
        self.assertEqual(self.fake.transcribe_calls, 1)
        status, forced = self.upload(query="?force=1")
        self.assertEqual(status, 202)
        self.assertNotEqual(forced["id"], first["id"])
        self.wait_for(forced["id"])
        # Changing the model makes earlier results stale.
        self.request("PUT", "/admin/api/settings", body={"summarization": {"model": "chat-2"}}, auth="admin")
        status, fresh = self.upload()
        self.assertEqual(status, 202)
        self.wait_for(fresh["id"])

    def test_transient_transcription_failure_is_retried(self):
        self.configure()
        self.fake.transcribe_failures = [503]
        _, job = self.upload()
        done = self.wait_for(job["id"])
        self.assertEqual(done["status"], "done")
        self.assertEqual(done["attempts"], 2)
        self.assertEqual(self.fake.transcribe_calls, 2)

    def test_permanent_transcription_failure_fails_without_retry(self):
        self.configure()
        self.fake.transcribe_failures = [400]
        _, job = self.upload()
        failed = self.wait_for(job["id"])
        self.assertEqual(failed["status"], "failed")
        self.assertIn("HTTP 400", failed["error"])
        self.assertEqual(self.fake.transcribe_calls, 1)
        # Audio is kept so the job can be retried from the web UI.
        self.assertEqual(len(os.listdir(self.store.audio_dir)), 1)
        status, _ = self.request("POST", f"/admin/api/jobs/{job['id']}/retry", body={}, auth="admin")
        self.assertEqual(status, 200)
        self.assertEqual(self.wait_for(job["id"])["status"], "done")

    def test_summary_failure_still_returns_the_transcript(self):
        self.configure(max_attempts=2)
        self.fake.chat_failures = [500, 500, 500]
        _, job = self.upload()
        done = self.wait_for(job["id"])
        self.assertEqual(done["status"], "done")
        self.assertEqual(done["transcript"], self.fake.transcript)
        self.assertIsNone(done["summary"])
        self.assertIn("HTTP 500", done["summary_error"])
        self.assertEqual(self.fake.transcribe_calls, 1)  # the retry did not transcribe again
        # A job that ended without a summary is not reused.
        self.fake.chat_failures = []
        status, again = self.upload()
        self.assertEqual(status, 202)
        self.assertEqual(self.wait_for(again["id"])["summary"], "Summary: Alice sends the report Friday.")

    def test_transcription_only_when_summarization_is_not_configured(self):
        self.configure(summarization=False)
        _, job = self.upload()
        done = self.wait_for(job["id"])
        self.assertEqual(done["status"], "done")
        self.assertEqual(done["summary_error"], SUMMARY_NOT_CONFIGURED)
        self.assertEqual(self.fake.chat_requests, [])

    def test_transcript_only_upload_skips_the_summary(self):
        self.configure()
        status, job = self.upload(query="?summarize=0")
        self.assertEqual(status, 202)
        done = self.wait_for(job["id"])
        self.assertEqual((done["status"], done["summary"], done["summary_error"]), ("done", None, None))
        self.assertFalse(done["want_summary"])
        self.assertEqual(self.fake.chat_requests, [])
        # It can serve another transcript-only request, but not one that wants a summary.
        self.assertEqual(self.upload(query="?summarize=0")[1]["id"], job["id"])
        status, full = self.upload()
        self.assertEqual(status, 202)
        full_done = self.wait_for(full["id"])
        self.assertEqual(full_done["summary"], "Summary: Alice sends the report Friday.")
        # A finished full job covers a later transcript-only request.
        self.assertEqual(self.upload(query="?summarize=0")[1]["id"], full["id"])

    def test_upload_is_refused_when_transcription_is_not_configured(self):
        status, body = self.upload()
        self.assertEqual(status, 409)
        self.assertIn("not configured", body["error"])
        self.assertEqual(os.listdir(self.store.audio_dir), [])

    def test_upload_limits(self):
        self.configure()
        self.assertEqual(self.upload(audio=b"")[0], 400)
        self.assertEqual(self.upload(audio=b"x" * (1024 * 1024 + 1))[0], 413)
        self.assertEqual(self.last_headers.get("Connection"), "close")  # the body was not read
        self.assertEqual(os.listdir(self.store.audio_dir), [])

    def test_text_job_summarizes_an_existing_transcript(self):
        self.configure(transcription=False)
        status, job = self.request(
            "POST", "/api/v1/jobs/text", body={"transcript": "Bob will call the vendor.", "title": "Call"}
        )
        self.assertEqual(status, 202)
        done = self.wait_for(job["id"])
        self.assertEqual(done["status"], "done")
        self.assertEqual(done["kind"], "text")
        self.assertIn("Bob will call the vendor.", self.fake.chat_requests[-1]["messages"][1]["content"])
        self.assertEqual(self.fake.transcribe_calls, 0)
        self.assertEqual(self.request("POST", "/api/v1/jobs/text", body={"transcript": "  "})[0], 400)

    def test_text_job_fails_when_the_model_keeps_failing(self):
        self.configure(transcription=False, max_attempts=1)
        self.fake.chat_failures = [500]
        _, job = self.request("POST", "/api/v1/jobs/text", body={"transcript": "Some words."})
        self.assertEqual(self.wait_for(job["id"])["status"], "failed")

    def test_long_transcripts_are_summarized_in_parts(self):
        self.configure(transcription=False)
        self.request("PUT", "/admin/api/settings", body={"summarization": {"max_chunk_chars": 2000}}, auth="admin")
        transcript = " ".join(f"Sentence number {i} is here." for i in range(250))
        _, job = self.request("POST", "/api/v1/jobs/text", body={"transcript": transcript})
        self.assertEqual(self.wait_for(job["id"])["status"], "done")
        parts = len(providers.split_transcript(transcript, 2000))
        self.assertGreater(parts, 1)
        self.assertEqual(len(self.fake.chat_requests), parts + 1)  # one per part, then the merge

    def test_admin_can_list_and_delete_jobs(self):
        self.configure()
        _, job = self.upload()
        self.wait_for(job["id"])
        status, listing = self.request("GET", "/admin/api/jobs", auth="admin")
        self.assertEqual(status, 200)
        self.assertEqual([j["id"] for j in listing["jobs"]], [job["id"]])
        self.assertNotIn("transcript", listing["jobs"][0])
        self.assertEqual(self.request("DELETE", f"/admin/api/jobs/{job['id']}", auth="admin")[0], 200)
        self.assertEqual(self.request("GET", f"/api/v1/jobs/{job['id']}")[0], 404)

    def test_connection_tests(self):
        self.configure()
        status, result = self.request("POST", "/admin/api/test/transcription", body={}, auth="admin")
        self.assertEqual((status, result["ok"]), (200, True))
        status, result = self.request("POST", "/admin/api/test/summarization", body={}, auth="admin")
        self.assertEqual((status, result["ok"]), (200, True))
        self.request("PUT", "/admin/api/settings", body={"transcription": {"model": "missing"}}, auth="admin")
        _, result = self.request("POST", "/admin/api/test/transcription", body={}, auth="admin")
        self.assertFalse(result["ok"])
        self.assertIn("whisper-test", result["detail"])


class RestartTests(unittest.TestCase):
    def test_interrupted_jobs_are_requeued(self):
        with tempfile.TemporaryDirectory() as tmp:
            _, _, store = build(tmp, admin_password=ADMIN_PASSWORD)
            self.addCleanup(store.close)
            job = store.create_job(kind="text", input_hash="h", transcript="words")
            claimed = store.claim_next_job()
            self.assertEqual((claimed["status"], claimed["attempts"]), ("summarizing", 1))
            self.assertEqual(store.requeue_interrupted(), 1)
            again = store.get_job(job["id"])
            self.assertEqual((again["status"], again["attempts"]), ("queued", 0))

    def test_generated_admin_password_is_stored_hashed(self):
        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch("builtins.print") as printed:
                app, _, store = build(tmp)
            self.addCleanup(store.close)
            generated = printed.call_args.args[0].split("password '")[1].split("'")[0]
            self.assertNotIn(generated, store.admin_password_hash())
            self.assertTrue(app.check_admin(generated))
            self.assertFalse(app.check_admin("wrong"))
            with mock.patch("builtins.print") as printed:
                build(tmp)[2].close()  # a second start must not replace or reprint the password
            printed.assert_not_called()


class SocketSmokeTest(unittest.TestCase):
    def test_serves_over_a_real_socket(self):
        with tempfile.TemporaryDirectory() as tmp:
            app, _, store = build(tmp, admin_password=ADMIN_PASSWORD)
            self.addCleanup(store.close)
            try:
                server = Server(("127.0.0.1", 0), app)
            except PermissionError:
                self.skipTest("this environment does not allow binding a socket")
            threading.Thread(target=server.serve_forever, daemon=True).start()
            try:
                url = f"http://127.0.0.1:{server.server_address[1]}"
                with urllib.request.urlopen(url + "/healthz", timeout=5) as response:
                    self.assertEqual(json.loads(response.read()), {"status": "ok"})
                page = urllib.request.Request(url + "/", headers={
                    "Authorization": "Basic " + base64.b64encode(f"admin:{ADMIN_PASSWORD}".encode()).decode()
                })
                with urllib.request.urlopen(page, timeout=5) as response:
                    self.assertIn(b"Plaud Remote", response.read())
            finally:
                server.shutdown()
                server.server_close()

    def test_finished_connections_do_not_leave_database_connections_open(self):
        # Each TCP connection runs on its own thread, and the store opens a SQLite
        # connection per thread. Those must be closed when the thread ends.
        with tempfile.TemporaryDirectory() as tmp:
            app, _, store = build(tmp, admin_password=ADMIN_PASSWORD)
            self.addCleanup(store.close)
            try:
                server = Server(("127.0.0.1", 0), app)
            except PermissionError:
                self.skipTest("this environment does not allow binding a socket")
            threading.Thread(target=server.serve_forever, daemon=True).start()
            try:
                port = server.server_address[1]
                before = len(store._connections)
                for _ in range(20):  # a wrong token still reads the store, so it counts too
                    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
                    conn.request("GET", "/api/v1/health", headers={"Authorization": "Bearer wrong"})
                    self.assertEqual(conn.getresponse().status, 401)
                    conn.close()
                deadline = time.monotonic() + 5  # handler threads finish just after replying
                while len(store._connections) > before and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertEqual(len(store._connections), before)
            finally:
                server.shutdown()
                server.server_close()


class MigrationTests(unittest.TestCase):
    def test_older_database_gains_the_want_summary_column(self):
        with tempfile.TemporaryDirectory() as tmp:
            _, _, store = build(tmp, admin_password=ADMIN_PASSWORD)
            job = store.create_job(kind="text", input_hash="h", transcript="words")
            store._conn().execute("ALTER TABLE jobs DROP COLUMN want_summary")
            store._conn().commit()
            store.close()
            _, _, reopened = build(tmp, admin_password=ADMIN_PASSWORD)
            self.addCleanup(reopened.close)
            self.assertEqual(reopened.get_job(job["id"])["want_summary"], 1)


class SplitTests(unittest.TestCase):
    def test_split_keeps_all_text_and_respects_the_limit(self):
        text = "First paragraph. It has two sentences.\n\nSecond paragraph!\n" + "x" * 50
        chunks = providers.split_transcript(text, 30)
        self.assertEqual("".join(chunks), text)
        self.assertTrue(all(len(c) <= 30 for c in chunks))
        self.assertEqual(providers.split_transcript("short", 30), ["short"])


if __name__ == "__main__":
    unittest.main()
