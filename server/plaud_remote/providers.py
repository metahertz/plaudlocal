"""Calls to OpenAI-compatible model endpoints (transcription and chat)."""

from __future__ import annotations

import json
import logging
import re
import socket
import urllib.error
import urllib.request
import uuid
from typing import Any

log = logging.getLogger("plaud_remote.providers")

_RETRYABLE_STATUS = {408, 425, 429, 500, 502, 503, 504}
_THINK_BLOCK = re.compile(r"<think>.*?</think>", re.DOTALL | re.IGNORECASE)


class ProviderError(Exception):
    """A model endpoint call failed. `retryable` marks transient failures."""

    def __init__(self, message: str, retryable: bool = False):
        super().__init__(message)
        self.retryable = retryable


def _urlopen(request: urllib.request.Request, timeout: float) -> bytes:
    """The one place that touches the network; tests replace it."""
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read()


def _request(
    url: str,
    *,
    api_key: str,
    body: bytes | None,
    content_type: str | None,
    timeout: float,
    method: str = "POST",
) -> bytes:
    headers = {"Accept": "application/json", "User-Agent": "plaud-remote"}
    if content_type:
        headers["Content-Type"] = content_type
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    request = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        return _urlopen(request, timeout)
    except urllib.error.HTTPError as error:
        detail = error.read(2000).decode("utf-8", "replace").strip()
        error.close()
        message = f"{url} returned HTTP {error.code}"
        if detail:
            message += f": {detail[:500]}"
        raise ProviderError(message, retryable=error.code in _RETRYABLE_STATUS) from None
    except (urllib.error.URLError, socket.timeout, TimeoutError, ConnectionError) as error:
        reason = getattr(error, "reason", error)
        raise ProviderError(f"Could not reach {url}: {reason}", retryable=True) from None


def _json(raw: bytes, url: str) -> Any:
    try:
        return json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise ProviderError(f"{url} returned a response that is not JSON") from None


def _multipart(fields: dict[str, str], filename: str, content_type: str, data: bytes) -> tuple[bytes, str]:
    boundary = f"plaudremote{uuid.uuid4().hex}"
    parts: list[bytes] = []
    for name, value in fields.items():
        parts.append(
            f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode()
        )
    safe_name = re.sub(r'[^A-Za-z0-9._-]', "_", filename) or "audio.ogg"
    parts.append(
        f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{safe_name}"\r\n'
        f"Content-Type: {content_type}\r\n\r\n".encode()
    )
    parts.append(data)
    parts.append(f"\r\n--{boundary}--\r\n".encode())
    return b"".join(parts), f"multipart/form-data; boundary={boundary}"


def transcribe(config: dict[str, Any], audio_path: str, filename: str, content_type: str) -> str:
    """POST the audio to `{base_url}/audio/transcriptions` and return the text."""
    url = f"{config['base_url']}/audio/transcriptions"
    fields = {"model": config["model"], "response_format": "json"}
    if config.get("language"):
        fields["language"] = config["language"]
    if config.get("prompt"):
        fields["prompt"] = config["prompt"]
    with open(audio_path, "rb") as handle:
        audio = handle.read()
    body, body_type = _multipart(fields, filename or "audio.ogg", content_type or "audio/ogg", audio)
    raw = _request(
        url, api_key=config.get("api_key", ""), body=body, content_type=body_type,
        timeout=config["timeout_seconds"],
    )
    try:
        payload = json.loads(raw.decode("utf-8"))
        text = payload.get("text") if isinstance(payload, dict) else None
    except (UnicodeDecodeError, json.JSONDecodeError):
        text = raw.decode("utf-8", "replace")  # some servers answer with plain text
    if not isinstance(text, str) or not text.strip():
        raise ProviderError("The transcription model returned no text")
    return text.strip()


def chat(config: dict[str, Any], system_prompt: str, user_text: str) -> str:
    """One chat completion against `{base_url}/chat/completions`."""
    url = f"{config['base_url']}/chat/completions"
    payload = {
        "model": config["model"],
        "temperature": config["temperature"],
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_text},
        ],
    }
    raw = _request(
        url, api_key=config.get("api_key", ""), body=json.dumps(payload).encode(),
        content_type="application/json", timeout=config["timeout_seconds"],
    )
    data = _json(raw, url)
    try:
        content = data["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError):
        raise ProviderError(f"{url} returned an unexpected response shape") from None
    if isinstance(content, list):  # content-part arrays
        content = "".join(part.get("text", "") for part in content if isinstance(part, dict))
    text = _THINK_BLOCK.sub("", content or "").strip()
    if not text:
        raise ProviderError("The summarization model returned no text", retryable=True)
    return text


def split_transcript(text: str, max_chars: int) -> list[str]:
    """Split on paragraph, then line, then sentence boundaries into chunks of at most max_chars."""
    if len(text) <= max_chars:
        return [text]
    chunks: list[str] = []
    current = ""
    for piece in re.split(r"(?<=\n)|(?<=[.!?]\s)", text):
        while len(piece) > max_chars:  # a single run with no boundaries
            head, piece = piece[:max_chars], piece[max_chars:]
            if current:
                chunks.append(current)
                current = ""
            chunks.append(head)
        if len(current) + len(piece) > max_chars and current:
            chunks.append(current)
            current = ""
        current += piece
    if current.strip():
        chunks.append(current)
    return chunks


def summarize(config: dict[str, Any], transcript: str, title: str = "", context: str = "") -> str:
    """Summarize a transcript in one pass when it fits `max_chunk_chars`.

    One pass is what produces a good meeting summary: the model sees the whole meeting and
    can connect the end to the beginning. Longer transcripts are summarized part by part,
    each part with as many summaries of the parts before it as fit within the limit, so
    later parts can still refer back; then the part summaries are merged.
    """
    system_prompt = config["system_prompt"]
    heading = f"Recording title: {title}\n\n" if title else ""
    if context:  # e.g. speaker names; a heading line, never part of the stored transcript
        heading += f"{context}\n\n"
    limit = config["max_chunk_chars"]
    if len(transcript) <= limit:
        return chat(config, system_prompt, f"{heading}Transcript:\n\n{transcript}")

    # Each part leaves a fifth of the limit for the summaries of the parts before it, so a
    # part's whole request still fits the model's context. When they don't all fit, the
    # oldest are left out first.
    chunks = split_transcript(transcript, part_chars(limit))
    log.warning(
        "Transcript of %d characters is longer than the %d-character summary limit; summarizing "
        "it in %d parts. Raise the limit (and the model's context window) to summarize it in one pass.",
        len(transcript), limit, len(chunks),
    )
    partials: list[str] = []
    for index, chunk in enumerate(chunks, start=1):
        earlier = _earlier_summaries(partials, budget=limit - len(chunk))
        task = f"{heading}This is part {index} of {len(chunks)} of a longer transcript. "
        task += "Summarize this part in detail, keeping names, numbers, decisions and action items"
        task += (
            ", and note where it continues or changes something from the earlier parts.\n\n" + earlier
            if earlier else ".\n\n"
        )
        partials.append(chat(config, system_prompt, f"{task}Transcript part:\n\n{chunk}"))
    combined = "\n\n".join(f"Part {i} summary:\n{p}" for i, p in enumerate(partials, start=1))
    return chat(
        config,
        system_prompt,
        f"{heading}Below are summaries of consecutive parts of one recording. "
        f"Merge them into a single summary of the whole recording, without mentioning the parts.\n\n{combined}",
    )


def part_chars(limit: int) -> int:
    """Transcript characters per part when a transcript has to be split (see summarize)."""
    return max(1, limit * 4 // 5)


def _earlier_summaries(partials: list[str], budget: int) -> str:
    """The most recent part summaries that fit in `budget` characters, oldest first."""
    kept: list[str] = []
    used = 0
    for number in range(len(partials), 0, -1):
        entry = f"Part {number} summary:\n{partials[number - 1]}\n\n"
        if used + len(entry) > budget:
            break
        kept.insert(0, entry)
        used += len(entry)
    return f"Summaries of the earlier parts, for context:\n\n{''.join(kept)}" if kept else ""


def list_models(config: dict[str, Any]) -> list[str]:
    """Reachability check: GET `{base_url}/models` and return the model ids."""
    url = f"{config['base_url']}/models"
    raw = _request(
        url, api_key=config.get("api_key", ""), body=None, content_type=None, timeout=15, method="GET"
    )
    data = _json(raw, url)
    items = data.get("data") if isinstance(data, dict) else data
    if not isinstance(items, list):
        return []
    return [str(item.get("id")) for item in items if isinstance(item, dict) and item.get("id")]
