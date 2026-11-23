"""Queue workers: take jobs and run transcription, then summarization."""

from __future__ import annotations

import logging
import threading
import time
from typing import Any

from . import providers
from .providers import ProviderError
from .store import Store

log = logging.getLogger("plaud_remote.worker")

SUMMARY_NOT_CONFIGURED = "Summarization is not configured on the server"


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
                transcript = self._transcribe(job, settings["transcription"])
            except ProviderError as error:
                self._fail_or_retry(job, str(error), error.retryable, max_attempts)
                return
            self.store.update_job(job_id, transcript=transcript, status="summarizing")
            log.info("Job %s transcribed (%d characters)", job_id, len(transcript))

        summary_config = settings["summarization"]
        if not Store.is_configured(summary_config):
            self._finish(job, settings, summary=None, summary_error=SUMMARY_NOT_CONFIGURED)
            return

        self.store.update_job(job_id, status="summarizing")
        try:
            summary = providers.summarize(summary_config, transcript or "", job["title"])
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

    def _transcribe(self, job: dict[str, Any], config: dict[str, Any]) -> str:
        if not Store.is_configured(config):
            raise ProviderError("Transcription is not configured on the server")
        if not job["audio_path"]:
            raise ProviderError("The uploaded audio is no longer on the server")
        return providers.transcribe(config, job["audio_path"], job["filename"], job["content_type"])

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
