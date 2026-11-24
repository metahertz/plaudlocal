"""HTTP layer: the app-facing API, the admin API and the configuration page."""

from __future__ import annotations

import base64
import hashlib
import json
import logging
import os
import secrets
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from importlib import resources
from typing import Any
from urllib.parse import parse_qs, urlsplit

from . import __version__, providers, speakers
from .providers import ProviderError
from .store import Store, verify_password
from .worker import WorkerPool

log = logging.getLogger("plaud_remote.web")

MAX_JSON_BYTES = 8 * 1024 * 1024
CSRF_HEADER = "X-Requested-With"
CSRF_VALUE = "plaud-remote"


class HTTPError(Exception):
    def __init__(self, status: int, message: str, headers: dict[str, str] | None = None):
        super().__init__(message)
        self.status = status
        self.message = message
        self.headers = headers or {}


class Application:
    """Shared state for request handlers."""

    def __init__(
        self,
        store: Store,
        pool: WorkerPool,
        admin_password: str | None = None,
        max_upload_bytes: int = 500 * 1024 * 1024,
    ):
        self.store = store
        self.pool = pool
        self.admin_password = admin_password or None
        self.max_upload_bytes = max_upload_bytes
        self.index_html = resources.files("plaud_remote").joinpath("static/index.html").read_bytes()
        self._verified_admin: set[str] = set()

    def check_admin(self, password: str) -> bool:
        if self.admin_password is not None:
            return secrets.compare_digest(password.encode(), self.admin_password.encode())
        fingerprint = hashlib.sha256(password.encode()).hexdigest()
        if fingerprint in self._verified_admin:
            return True
        stored = self.store.admin_password_hash()
        if stored and verify_password(password, stored):
            self._verified_admin = {fingerprint}
            return True
        return False


def _document(raw: str | None) -> Any:
    """The stored transcript document, or None if there is none or it can't be read."""
    if not raw:
        return None
    try:
        return json.loads(raw)
    except ValueError:
        return None


def public_job(job: dict[str, Any], include_text: bool = True) -> dict[str, Any]:
    out = {
        "id": job["id"],
        "kind": job["kind"],
        "status": job["status"],
        "title": job["title"],
        "client_ref": job["client_ref"],
        "attempts": job["attempts"],
        "created_at": job["created_at"],
        "updated_at": job["updated_at"],
        "audio_bytes": job["audio_bytes"],
        "error": job["error"],
        "summary_error": job["summary_error"],
        "want_summary": bool(job["want_summary"]),
        "has_transcript": job["transcript"] is not None,
        "has_summary": job["summary"] is not None,
    }
    if include_text:
        out["transcript"] = job["transcript"]
        out["summary"] = job["summary"]
        document = _document(job.get("transcript_json"))
        if document is not None:  # speaker transcripts only; absent for plain jobs
            out["transcript_json"] = document
    return out


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = f"plaud-remote/{__version__}"
    sys_version = ""
    timeout = 120  # seconds of socket inactivity before a connection is dropped

    @property
    def app(self) -> Application:
        return self.server.app  # type: ignore[attr-defined]

    def log_message(self, format: str, *args: Any) -> None:  # noqa: A002 - stdlib signature
        log.info("%s %s", self.address_string(), format % args)

    def do_GET(self) -> None:  # noqa: N802 - stdlib naming
        self._dispatch("GET")

    def do_POST(self) -> None:  # noqa: N802
        self._dispatch("POST")

    def do_PUT(self) -> None:  # noqa: N802
        self._dispatch("PUT")

    def do_DELETE(self) -> None:  # noqa: N802
        self._dispatch("DELETE")

    # ---- plumbing -------------------------------------------------------

    def _dispatch(self, method: str) -> None:
        self._body_consumed = False
        try:
            url = urlsplit(self.path)
            self._route(method, url.path.rstrip("/") or "/", parse_qs(url.query))
        except HTTPError as error:
            self._send_json(error.status, {"error": error.message}, error.headers)
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True
        except Exception:
            log.exception("Unhandled error for %s %s", method, self.path)
            self._send_json(500, {"error": "Internal server error"})

    def _send(self, status: int, body: bytes, content_type: str, headers: dict[str, str] | None = None) -> None:
        if not self._body_consumed and int(self.headers.get("Content-Length") or 0) > 0:
            # We answered without reading the request body; the connection can't be reused.
            self.close_connection = True
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        if self.close_connection:
            self.send_header("Connection", "close")
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def _send_json(self, status: int, payload: Any, headers: dict[str, str] | None = None) -> None:
        self._send(status, json.dumps(payload).encode(), "application/json", headers)

    def _content_length(self) -> int:
        raw = self.headers.get("Content-Length")
        if raw is None:
            raise HTTPError(411, "Content-Length is required")
        try:
            length = int(raw)
        except ValueError:
            raise HTTPError(400, "Invalid Content-Length") from None
        if length < 0:
            raise HTTPError(400, "Invalid Content-Length")
        return length

    def _read_json(self) -> dict[str, Any]:
        length = self._content_length()
        if length > MAX_JSON_BYTES:
            raise HTTPError(413, "Request body is too large")
        raw = self.rfile.read(length)
        self._body_consumed = True
        try:
            data = json.loads(raw.decode("utf-8")) if raw else {}
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise HTTPError(400, "Request body must be JSON") from None
        if not isinstance(data, dict):
            raise HTTPError(400, "Request body must be a JSON object")
        return data

    # ---- auth -----------------------------------------------------------

    def _require_app(self) -> None:
        header = self.headers.get("Authorization", "")
        scheme, _, token = header.partition(" ")
        expected = self.app.store.app_token()
        if scheme.lower() != "bearer" or not secrets.compare_digest(token.strip().encode(), expected.encode()):
            raise HTTPError(401, "Missing or invalid API token", {"WWW-Authenticate": "Bearer"})

    def _require_admin(self, method: str) -> None:
        challenge = {"WWW-Authenticate": 'Basic realm="Plaud Remote", charset="UTF-8"'}
        header = self.headers.get("Authorization", "")
        scheme, _, encoded = header.partition(" ")
        if scheme.lower() != "basic" or not encoded:
            raise HTTPError(401, "Sign in required", challenge)
        try:
            user, _, password = base64.b64decode(encoded.strip()).decode("utf-8").partition(":")
        except (ValueError, UnicodeDecodeError):
            raise HTTPError(401, "Sign in required", challenge) from None
        if user != "admin" or not self.app.check_admin(password):
            time.sleep(0.5)  # slow down password guessing
            raise HTTPError(401, "Wrong username or password", challenge)
        # Browsers attach Basic credentials to cross-site requests. Requiring a custom
        # header forces a CORS preflight, which this server never approves.
        if method != "GET" and self.headers.get(CSRF_HEADER) != CSRF_VALUE:
            raise HTTPError(403, f"Missing {CSRF_HEADER} header")

    # ---- routing --------------------------------------------------------

    def _route(self, method: str, path: str, query: dict[str, list[str]]) -> None:
        store = self.app.store
        parts = [p for p in path.split("/") if p]

        if method == "GET" and path == "/healthz":
            self._send_json(200, {"status": "ok"})
            return

        if parts[:2] == ["api", "v1"]:
            self._require_app()
            rest = parts[2:]
            if method == "GET" and rest == ["health"]:
                settings = store.settings()
                self._send_json(200, {
                    "status": "ok",
                    "version": __version__,
                    "transcription": Store.is_configured(settings["transcription"]),
                    "summarization": Store.is_configured(settings["summarization"]),
                })
            elif method == "POST" and rest == ["jobs"]:
                self._submit_audio(query)
            elif method == "POST" and rest == ["jobs", "text"]:
                self._submit_text()
            elif method == "GET" and len(rest) == 2 and rest[0] == "jobs":
                self._send_json(200, public_job(self._job_or_404(rest[1])))
            elif method == "DELETE" and len(rest) == 2 and rest[0] == "jobs":
                self._job_or_404(rest[1])
                store.delete_job(rest[1])
                self._send_json(200, {"deleted": True})
            else:
                raise HTTPError(404, "Not found")
            return

        if path == "/" or parts[:1] == ["admin"]:
            self._require_admin(method)
            if method == "GET" and path == "/":
                self._send(200, self.app.index_html, "text/html; charset=utf-8", {
                    "Content-Security-Policy": (
                        "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; "
                        "connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
                    ),
                    "Referrer-Policy": "no-referrer",
                })
                return
            if parts[:2] == ["admin", "api"]:
                self._admin(method, parts[2:])
                return

        raise HTTPError(404, "Not found")

    def _job_or_404(self, job_id: str) -> dict[str, Any]:
        job = self.app.store.get_job(job_id)
        if job is None:
            raise HTTPError(404, "No such job")
        return job

    # ---- app API --------------------------------------------------------

    def _submit_audio(self, query: dict[str, list[str]]) -> None:
        store = self.app.store
        length = self._content_length()
        if length == 0:
            raise HTTPError(400, "The request body must be the audio file")
        if length > self.app.max_upload_bytes:
            raise HTTPError(413, f"Audio is larger than the {self.app.max_upload_bytes // (1024 * 1024)} MB limit")
        if not Store.is_configured(store.settings()["transcription"]):
            self._drain(length)  # let the client finish sending so it can read the answer
            raise HTTPError(409, "Transcription is not configured on the server")

        def param(name: str) -> str:
            return (query.get(name) or [""])[0]

        temp_path = store.audio_dir / f"upload-{uuid.uuid4().hex}.bin"
        digest = hashlib.sha256()
        remaining = length
        keep_file = False
        try:
            with open(temp_path, "wb") as out:
                while remaining > 0:
                    chunk = self.rfile.read(min(1024 * 1024, remaining))
                    if not chunk:
                        raise HTTPError(400, "Upload ended before the declared length")
                    out.write(chunk)
                    digest.update(chunk)
                    remaining -= len(chunk)
            self._body_consumed = True

            input_hash = digest.hexdigest()
            want_summary = param("summarize") not in ("0", "false")
            if param("force") not in ("1", "true"):
                existing = store.find_reusable_job("audio", input_hash, want_summary)
                if existing is not None:
                    self._send_json(200, public_job(existing))
                    return
            job = store.create_job(
                kind="audio",
                input_hash=input_hash,
                client_ref=param("client_ref"),
                title=param("title"),
                filename=param("filename") or "audio.ogg",
                content_type=self.headers.get("Content-Type", "audio/ogg").split(";")[0].strip(),
                audio_path=str(temp_path),
                audio_bytes=length,
                want_summary=want_summary,
            )
            keep_file = True
        finally:
            if not keep_file and temp_path.exists():
                os.remove(temp_path)
        self.app.pool.wake()
        self._send_json(202, public_job(job))

    def _drain(self, length: int) -> None:
        remaining = length
        while remaining > 0:
            chunk = self.rfile.read(min(1024 * 1024, remaining))
            if not chunk:
                break
            remaining -= len(chunk)
        self._body_consumed = remaining == 0

    def _submit_text(self) -> None:
        store = self.app.store
        body = self._read_json()
        transcript = body.get("transcript")
        if not isinstance(transcript, str) or not transcript.strip():
            raise HTTPError(400, "transcript is required")
        if not Store.is_configured(store.settings()["summarization"]):
            raise HTTPError(409, "Summarization is not configured on the server")
        document = body.get("transcript_json")
        if document is not None and not speakers.valid_document(document):
            raise HTTPError(400, "transcript_json must be a version 1 transcript document (see issue #12)")
        document_json = json.dumps(document, sort_keys=True) if document is not None else None
        # The document is part of the input, so a request with one never reuses a job without.
        # Without one, the hash is the transcript's alone, as before.
        hashed = transcript.encode("utf-8")
        if document_json is not None:
            hashed += b"\x00" + document_json.encode("utf-8")
        input_hash = hashlib.sha256(hashed).hexdigest()
        if not body.get("force"):
            existing = store.find_reusable_job("text", input_hash)
            if existing is not None:
                self._send_json(200, public_job(existing))
                return
        job = store.create_job(
            kind="text",
            input_hash=input_hash,
            client_ref=str(body.get("client_ref") or ""),
            title=str(body.get("title") or ""),
            transcript=transcript,
            transcript_json=document_json,
        )
        self.app.pool.wake()
        self._send_json(202, public_job(job))

    # ---- admin API ------------------------------------------------------

    def _admin(self, method: str, rest: list[str]) -> None:
        store = self.app.store

        if rest == ["settings"] and method == "GET":
            self._send_json(200, store.public_settings())
        elif rest == ["settings"] and method == "PUT":
            try:
                store.update_settings(self._read_json())
            except (ValueError, TypeError) as error:
                raise HTTPError(400, str(error)) from None
            self._send_json(200, store.public_settings())
        elif rest == ["token"] and method == "GET":
            self._send_json(200, {"token": store.app_token()})
        elif rest == ["token", "regenerate"] and method == "POST":
            self._read_json()
            self._send_json(200, {"token": store.regenerate_app_token()})
        elif rest == ["status"] and method == "GET":
            settings = store.settings()
            self._send_json(200, {
                "version": __version__,
                "transcription": Store.is_configured(settings["transcription"]),
                "summarization": Store.is_configured(settings["summarization"]),
                "counts": store.counts(),
            })
        elif rest == ["jobs"] and method == "GET":
            self._send_json(200, {"jobs": [public_job(j, include_text=False) for j in store.list_jobs()]})
        elif len(rest) == 2 and rest[0] == "jobs" and method == "GET":
            self._send_json(200, public_job(self._job_or_404(rest[1])))
        elif len(rest) == 2 and rest[0] == "jobs" and method == "DELETE":
            self._job_or_404(rest[1])
            store.delete_job(rest[1])
            self._send_json(200, {"deleted": True})
        elif len(rest) == 3 and rest[0] == "jobs" and rest[2] == "retry" and method == "POST":
            self._read_json()
            self._job_or_404(rest[1])
            job = store.retry_job(rest[1])
            if job is None:
                raise HTTPError(409, "The audio for this job was deleted; upload the recording again")
            self.app.pool.wake()
            self._send_json(200, public_job(job))
        elif len(rest) == 2 and rest[0] == "test" and method == "POST":
            self._read_json()
            self._send_json(200, self._test(rest[1]))
        else:
            raise HTTPError(404, "Not found")

    def _test(self, which: str) -> dict[str, Any]:
        settings = self.app.store.settings()
        if which not in ("transcription", "summarization"):
            raise HTTPError(404, "Not found")
        config = settings[which]
        if not Store.is_configured(config):
            return {"ok": False, "detail": "Set a base URL and model first"}
        try:
            if which == "summarization":
                reply = providers.chat(
                    {**config, "timeout_seconds": 60}, "You are a connection test.", "Reply with the single word: ready"
                )
                return {"ok": True, "detail": f"Model replied: {reply[:120]}"}
            models = providers.list_models(config)
            if models and config["model"] not in models:
                return {
                    "ok": False,
                    "detail": f"Reached the endpoint, but it does not list model “{config['model']}”. "
                              f"It lists: {', '.join(models[:12])}",
                }
            return {"ok": True, "detail": "Endpoint reachable" + (" and model found" if models else "")}
        except ProviderError as error:
            return {"ok": False, "detail": str(error)}


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address: tuple[str, int], app: Application):
        super().__init__(address, Handler)
        self.app = app

    def process_request_thread(self, request, client_address) -> None:
        try:
            super().process_request_thread(request, client_address)
        finally:
            # Each TCP connection gets its own thread, and the store gives each thread its
            # own SQLite connection; close it here or it stays open until the server stops.
            self.app.store.release_thread_connection()
