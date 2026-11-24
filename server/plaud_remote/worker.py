"""Queue workers: take jobs and run transcription, then summarization."""

from __future__ import annotations

import logging
import threading
import time
from typing import Any

import json

from . import providers, speakers
from .providers import ProviderError
from .store import Store

log = logging.getLogger("plaud_remote.worker")

SUMMARY_NOT_CONFIGURED = "Summarization is not configured on the server"


def _document(job_id: str, store: Store) -> dict[str, Any] | None:
    """The job's stored speaker document (as saved after transcription), if any."""
    job = store.get_job(job_id) or {}
    try:
        value = json.loads(job.get("transcript_json") or "null")
    except ValueError:
        return None
    return value if isinstance(value, dict) else None


class WorkerPool:
    def __init__(self, store: Store, workers: int = 1, backoff_base: float = 15.0, poll_interval: float = 1.0):
        self.store = store
        self.backoff_base = backoff_base
        self.poll_interval = poll_interval
        self._stop = threading.Event()
        self._wake = threading.Event()
        self._threads = [
            threading.Thread(target=self._run, name=f"worker-{i}", daemon=True) for i in range(max(1, workers))
        ]
        self._threads.append(threading.Thread(target=self._purge_loop, name="purge", daemon=True))

    def start(self) -> None:
        requeued = self.store.requeue_interrupted()
        if requeued:
            log.info("Re-queued %d job(s) interrupted by a restart", requeued)
        for thread in self._threads:
            thread.start()

    def stop(self, timeout: float = 5.0) -> None:
        self._stop.set()
        self._wake.set()
        for thread in self._threads:
            if thread.is_alive():
                thread.join(timeout)

    def wake(self) -> None:
        """Called when a job is submitted so it starts without waiting for the next poll."""
        self._wake.set()

    def _run(self) -> None:
        while not self._stop.is_set():
            try:
                job = self.store.claim_next_job()
            except Exception:  # keep the worker alive across storage hiccups
                log.exception("Could not claim a job")
                job = None
            if job is None:
                self._wake.wait(self.poll_interval)
                self._wake.clear()
                continue
            try:
                self.process(job)
            except Exception as error:  # a bug must not leave the job stuck in progress
                log.exception("Job %s crashed", job["id"])
                self.store.update_job(job["id"], status="failed", error=f"Internal error: {error}")

    def _purge_loop(self) -> None:
        while not self._stop.is_set():
            try:
                removed = self.store.purge_expired()
                if removed:
                    log.info("Removed %d expired job(s)", removed)
            except Exception:
                log.exception("Purge failed")
            self._stop.wait(3600)

    # ---- pipeline -------------------------------------------------------

    def process(self, job: dict[str, Any]) -> None:
        settings = self.store.settings()
        max_attempts = settings["queue"]["max_attempts"]
        job_id = job["id"]
        transcript = job["transcript"]

        if job["kind"] == "audio" and transcript is None:
            try:
                transcript, document = self._transcribe(job, settings["transcription"])
            except ProviderError as error:
                self._fail_or_retry(job, str(error), error.retryable, max_attempts)
                return
            # Saved together, once: the app stores this exact text and compares it later.
            self.store.update_job(
                job_id, transcript=transcript, status="summarizing",
                transcript_json=json.dumps(document) if document is not None else None,
            )
            log.info("Job %s transcribed (%d characters)", job_id, len(transcript))

        if not job["want_summary"]:
            # The app asked for the transcript only (it summarizes on-device, or not at all).
            self._finish(job, settings, summary=None, summary_error=None)
            return

        summary_config = settings["summarization"]
        if not Store.is_configured(summary_config):
            self._finish(job, settings, summary=None, summary_error=SUMMARY_NOT_CONFIGURED)
            return

        self.store.update_job(job_id, status="summarizing")
        document = _document(job_id, self.store)
        if document is not None and summary_config["suggest_names"] and not job.get("names_checked"):
            # Once per job (the flag survives retries), outside the summary's attempts; never raises.
            document = speakers.suggest_names(summary_config, transcript or "", document)
            self.store.update_job(job_id, transcript_json=json.dumps(document), names_checked=1)
        try:
            summary = providers.summarize(
                summary_config, transcript or "", job["title"], context=speakers.names_hint(document, suggestions=summary_config["suggest_names"])
            )
        except ProviderError as error:
            if error.retryable and job["attempts"] < max_attempts:
                self._requeue(job, str(error))
            elif job["kind"] == "audio":
                # The transcript is still worth returning; the app can summarize on-device.
                self._finish(job, settings, summary=None, summary_error=str(error))
            else:
                self.store.update_job(job_id, status="failed", error=str(error))
                log.warning("Job %s failed: %s", job_id, error)
            return
        self._finish(job, settings, summary=summary, summary_error=None)

    def _transcribe(self, job: dict[str, Any], config: dict[str, Any]) -> tuple[str, dict[str, Any] | None]:
        """(transcript text, issue #12 document or None for providers without speakers)."""
        if not Store.is_configured(config):
            raise ProviderError("Transcription is not configured on the server")
        if not job["audio_path"]:
            raise ProviderError("The uploaded audio is no longer on the server")
        if config.get("provider") == speakers.PROVIDER:
            return speakers.transcribe(config, job["audio_path"])
        return providers.transcribe(config, job["audio_path"], job["filename"], job["content_type"]), None

    def _fail_or_retry(self, job: dict[str, Any], message: str, retryable: bool, max_attempts: int) -> None:
        if retryable and job["attempts"] < max_attempts:
            self._requeue(job, message)
        else:
            self.store.update_job(job["id"], status="failed", error=message)
            log.warning("Job %s failed: %s", job["id"], message)

    def _requeue(self, job: dict[str, Any], message: str) -> None:
        delay = min(self.backoff_base * (2 ** (job["attempts"] - 1)), 300.0)
        self.store.update_job(
            job["id"], status="queued", next_attempt_at=time.time() + delay, error=message
        )
        log.info("Job %s will retry in %.0fs: %s", job["id"], delay, message)

    def _finish(self, job: dict[str, Any], settings: dict[str, Any], *, summary: str | None, summary_error: str | None) -> None:
        self.store.update_job(
            job["id"], status="done", summary=summary, summary_error=summary_error, error=None
        )
        if not settings["queue"]["keep_audio"]:
            self.store.delete_audio(job)
        log.info("Job %s done%s", job["id"], f" (no summary: {summary_error})" if summary_error else "")
