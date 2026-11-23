"""SQLite persistence: settings and the job queue."""

from __future__ import annotations

import copy
import hashlib
import json
import os
import secrets
import sqlite3
import threading
import time
import uuid
from pathlib import Path
from typing import Any

DEFAULT_SYSTEM_PROMPT = (
    "You summarize transcripts of voice recordings and meetings. "
    "Write a clear, faithful summary in Markdown: a one-paragraph overview, "
    "then key points, decisions, and action items (with owners when stated). "
    "Use only what the transcript says; do not invent names, dates or facts."
)

DEFAULT_SETTINGS: dict[str, dict[str, Any]] = {
    "transcription": {
        "base_url": "",
        "api_key": "",
        "model": "",
        "language": "",
        "prompt": "",
        "timeout_seconds": 3600,
    },
    "summarization": {
        "base_url": "",
        "api_key": "",
        "model": "",
        "system_prompt": DEFAULT_SYSTEM_PROMPT,
        "temperature": 0.2,
        "max_chunk_chars": 24000,
        "timeout_seconds": 600,
    },
    "queue": {
        "max_attempts": 3,
        "keep_audio": False,
        "retention_days": 30,
    },
}

# Settings that change what a job produces. Secrets and timeouts are excluded,
# so rotating a key does not invalidate previous results.
_RESULT_KEYS = {
    "transcription": ("base_url", "model", "language", "prompt"),
    "summarization": ("base_url", "model", "system_prompt", "temperature", "max_chunk_chars"),
}

ACTIVE_STATUSES = ("queued", "transcribing", "summarizing")

_SCHEMA = """
CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS jobs (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    client_ref TEXT NOT NULL DEFAULT '',
    title TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    next_attempt_at REAL NOT NULL DEFAULT 0,
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL,
    filename TEXT NOT NULL DEFAULT '',
    content_type TEXT NOT NULL DEFAULT '',
    audio_path TEXT,
    audio_bytes INTEGER NOT NULL DEFAULT 0,
    input_hash TEXT NOT NULL,
    config_hash TEXT NOT NULL,
    transcript TEXT,
    summary TEXT,
    error TEXT,
    summary_error TEXT,
    want_summary INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX IF NOT EXISTS jobs_queue ON jobs (status, next_attempt_at, created_at);
CREATE INDEX IF NOT EXISTS jobs_dedupe ON jobs (kind, input_hash, config_hash);
"""


def hash_password(password: str, salt: bytes | None = None) -> str:
    salt = salt or secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, 200_000)
    return f"{salt.hex()}:{digest.hex()}"


def verify_password(password: str, stored: str) -> bool:
    try:
        salt_hex, digest_hex = stored.split(":", 1)
        expected = hashlib.pbkdf2_hmac("sha256", password.encode(), bytes.fromhex(salt_hex), 200_000)
    except ValueError:
        return False
    return secrets.compare_digest(expected.hex(), digest_hex)


class Store:
    """Thread-safe store; each thread gets its own SQLite connection."""

    def __init__(self, data_dir: str | os.PathLike[str]):
        self.data_dir = Path(data_dir)
        self.audio_dir = self.data_dir / "audio"
        self.audio_dir.mkdir(parents=True, exist_ok=True)
        self._db_path = self.data_dir / "plaud-remote.sqlite3"
        self._local = threading.local()
        self._claim_lock = threading.Lock()
        self._connections: list[sqlite3.Connection] = []
        self._connections_lock = threading.Lock()
        with self._conn() as conn:
            conn.executescript(_SCHEMA)
            columns = {row["name"] for row in conn.execute("PRAGMA table_info(jobs)")}
            if "want_summary" not in columns:  # databases created before per-job options
                conn.execute("ALTER TABLE jobs ADD COLUMN want_summary INTEGER NOT NULL DEFAULT 1")

    def _conn(self) -> sqlite3.Connection:
        conn = getattr(self._local, "conn", None)
        if conn is None:
            # Each thread uses only its own connection; check_same_thread is off so close() can end them all.
            conn = sqlite3.connect(self._db_path, timeout=30, check_same_thread=False)
            conn.row_factory = sqlite3.Row
            conn.execute("PRAGMA journal_mode=WAL")
            self._local.conn = conn
            with self._connections_lock:
                self._connections.append(conn)
        return conn

    def close(self) -> None:
        """Close every connection. Call only after the workers and server have stopped."""
        with self._connections_lock:
            for conn in self._connections:
                conn.close()
            self._connections.clear()
        self._local = threading.local()

    # ---- settings -------------------------------------------------------

    def _get_raw(self, key: str) -> Any:
        row = self._conn().execute("SELECT value FROM settings WHERE key = ?", (key,)).fetchone()
        return json.loads(row["value"]) if row else None

    def _set_raw(self, key: str, value: Any) -> None:
        with self._conn() as conn:
            conn.execute(
                "INSERT INTO settings (key, value) VALUES (?, ?) "
                "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                (key, json.dumps(value)),
            )

    def settings(self) -> dict[str, dict[str, Any]]:
        """Full settings, including secrets, with defaults filled in."""
        merged = copy.deepcopy(DEFAULT_SETTINGS)
        saved = self._get_raw("config") or {}
        for section, values in saved.items():
            if section in merged and isinstance(values, dict):
                for key, value in values.items():
                    if key in merged[section]:
                        merged[section][key] = value
        return merged

    def public_settings(self) -> dict[str, dict[str, Any]]:
        """Settings safe to send to the browser: API keys replaced by a flag."""
        settings = self.settings()
        for section in ("transcription", "summarization"):
            key = settings[section].pop("api_key", "")
            settings[section]["api_key_set"] = bool(key)
        return settings

    def update_settings(self, patch: dict[str, Any]) -> dict[str, dict[str, Any]]:
        """Apply a partial update. A missing or null api_key keeps the stored one."""
        current = self.settings()
        for section, defaults in DEFAULT_SETTINGS.items():
            incoming = patch.get(section)
            if not isinstance(incoming, dict):
                continue
            for key, default in defaults.items():
                if key not in incoming:
                    continue
                value = incoming[key]
                if key == "api_key" and value is None:
                    continue
                current[section][key] = _coerce(section, key, value, default)
        self._set_raw("config", current)
        return current

    def config_hash(self) -> str:
        settings = self.settings()
        relevant = {s: {k: settings[s][k] for k in keys} for s, keys in _RESULT_KEYS.items()}
        return hashlib.sha256(json.dumps(relevant, sort_keys=True).encode()).hexdigest()

    @staticmethod
    def is_configured(section: dict[str, Any]) -> bool:
        return bool(section.get("base_url")) and bool(section.get("model"))

    def app_token(self) -> str:
        token = self._get_raw("app_token")
        if not token:
            token = self.regenerate_app_token()
        return token

    def regenerate_app_token(self) -> str:
        token = secrets.token_urlsafe(32)
        self._set_raw("app_token", token)
        return token

    def admin_password_hash(self) -> str | None:
        return self._get_raw("admin_password_hash")

    def set_admin_password(self, password: str) -> None:
        self._set_raw("admin_password_hash", hash_password(password))

    # ---- jobs -----------------------------------------------------------

    def create_job(
        self,
        *,
        kind: str,
        input_hash: str,
        client_ref: str = "",
        title: str = "",
        filename: str = "",
        content_type: str = "",
        audio_path: str | None = None,
        audio_bytes: int = 0,
        transcript: str | None = None,
        want_summary: bool = True,
    ) -> dict[str, Any]:
        now = time.time()
        job_id = uuid.uuid4().hex
        with self._conn() as conn:
            conn.execute(
                "INSERT INTO jobs (id, kind, client_ref, title, status, created_at, updated_at, "
                "filename, content_type, audio_path, audio_bytes, input_hash, config_hash, transcript, "
                "want_summary) VALUES (?, ?, ?, ?, 'queued', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    job_id, kind, client_ref[:200], title[:300], now, now, filename[:200],
                    content_type[:100], audio_path, audio_bytes, input_hash, self.config_hash(),
                    transcript, int(want_summary),
                ),
            )
        return self.get_job(job_id)  # type: ignore[return-value]

    def find_reusable_job(self, kind: str, input_hash: str, want_summary: bool = True) -> dict[str, Any] | None:
        """An in-flight or cleanly finished job for the same input and model settings.

        A job that skipped the summary cannot serve a request that wants one.
        """
        row = self._conn().execute(
            "SELECT * FROM jobs WHERE kind = ? AND input_hash = ? AND config_hash = ? "
            "AND want_summary >= ? "
            "AND (status IN ('queued', 'transcribing', 'summarizing') "
            "     OR (status = 'done' AND summary_error IS NULL)) "
            "ORDER BY created_at DESC LIMIT 1",
            (kind, input_hash, self.config_hash(), int(want_summary)),
        ).fetchone()
        return dict(row) if row else None

    def get_job(self, job_id: str) -> dict[str, Any] | None:
        row = self._conn().execute("SELECT * FROM jobs WHERE id = ?", (job_id,)).fetchone()
        return dict(row) if row else None

    def list_jobs(self, limit: int = 100) -> list[dict[str, Any]]:
        rows = self._conn().execute(
            "SELECT * FROM jobs ORDER BY created_at DESC LIMIT ?", (limit,)
        ).fetchall()
        return [dict(r) for r in rows]

    def counts(self) -> dict[str, int]:
        rows = self._conn().execute("SELECT status, COUNT(*) AS n FROM jobs GROUP BY status").fetchall()
        return {r["status"]: r["n"] for r in rows}

    def update_job(self, job_id: str, **fields: Any) -> None:
        fields["updated_at"] = time.time()
        columns = ", ".join(f"{name} = ?" for name in fields)
        with self._conn() as conn:
            conn.execute(f"UPDATE jobs SET {columns} WHERE id = ?", (*fields.values(), job_id))

    def claim_next_job(self) -> dict[str, Any] | None:
        """Atomically take the oldest due queued job and mark it in progress."""
        with self._claim_lock:
            conn = self._conn()
            now = time.time()
            row = conn.execute(
                "SELECT * FROM jobs WHERE status = 'queued' AND next_attempt_at <= ? "
                "ORDER BY created_at LIMIT 1",
                (now,),
            ).fetchone()
            if row is None:
                return None
            status = "transcribing" if row["kind"] == "audio" and row["transcript"] is None else "summarizing"
            with conn:
                conn.execute(
                    "UPDATE jobs SET status = ?, attempts = attempts + 1, updated_at = ? WHERE id = ?",
                    (status, now, row["id"]),
                )
            return self.get_job(row["id"])

    def requeue_interrupted(self) -> int:
        """Jobs left mid-flight by a restart go back to the queue without losing an attempt."""
        with self._conn() as conn:
            cur = conn.execute(
                "UPDATE jobs SET status = 'queued', next_attempt_at = 0, "
                "attempts = MAX(attempts - 1, 0), updated_at = ? "
                "WHERE status IN ('transcribing', 'summarizing')",
                (time.time(),),
            )
            return cur.rowcount

    def retry_job(self, job_id: str) -> dict[str, Any] | None:
        job = self.get_job(job_id)
        if job is None or job["status"] in ACTIVE_STATUSES:
            return job
        if job["kind"] == "audio" and job["transcript"] is None and not self._audio_exists(job):
            return None
        self.update_job(
            job_id, status="queued", attempts=0, next_attempt_at=0, error=None,
            summary=None, summary_error=None,
        )
        return self.get_job(job_id)

    @staticmethod
    def _audio_exists(job: dict[str, Any]) -> bool:
        return bool(job.get("audio_path")) and os.path.exists(job["audio_path"])

    def delete_audio(self, job: dict[str, Any]) -> None:
        path = job.get("audio_path")
        if path:
            try:
                os.remove(path)
            except FileNotFoundError:
                pass
            self.update_job(job["id"], audio_path=None)

    def delete_job(self, job_id: str) -> bool:
        job = self.get_job(job_id)
        if job is None:
            return False
        if job.get("audio_path"):
            try:
                os.remove(job["audio_path"])
            except FileNotFoundError:
                pass
        with self._conn() as conn:
            conn.execute("DELETE FROM jobs WHERE id = ?", (job_id,))
        return True

    def purge_expired(self) -> int:
        days = self.settings()["queue"]["retention_days"]
        if days <= 0:
            return 0
        cutoff = time.time() - days * 86400
        rows = self._conn().execute(
            "SELECT id FROM jobs WHERE status IN ('done', 'failed') AND updated_at < ?", (cutoff,)
        ).fetchall()
        for row in rows:
            self.delete_job(row["id"])
        return len(rows)


def _coerce(section: str, key: str, value: Any, default: Any) -> Any:
    """Coerce an incoming setting to the type of its default, within sane bounds."""
    if isinstance(default, bool):
        return bool(value)
    if isinstance(default, int):
        number = int(value)
        bounds = {
            "timeout_seconds": (5, 6 * 3600),
            "max_chunk_chars": (2000, 400_000),
            "max_attempts": (1, 10),
            "retention_days": (0, 3650),
        }
        low, high = bounds.get(key, (0, 10**9))
        return max(low, min(high, number))
    if isinstance(default, float):
        return max(0.0, min(2.0, float(value)))
    text = str(value).strip() if key != "system_prompt" and key != "prompt" else str(value)
    if key == "base_url":
        text = text.rstrip("/")
        if text and not text.lower().startswith(("http://", "https://")):
            raise ValueError(f"{section} base URL must start with http:// or https://")
    return text
