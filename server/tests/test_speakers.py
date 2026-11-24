"""Speaker transcripts (issue #12) via NeMo-Speech.cpp."""

from __future__ import annotations

import json
import subprocess
import unittest
from unittest import mock

from plaud_remote import providers, speakers
from test_server import ServerTestCase

# Shaped like a real NeMo-Speech.cpp chat response: words come in time order, carry word_index
# (their position in the text), and their `speaker` comes from the acoustic diarizer, which does
# not follow the <spk:N> tags.
CONTENT = "<spk:1> Thanks for joining. Priya, the budget? <spk:0> <spk:0> Sure, four percent over. <spk:2> Frankfurt?"
TOKENS = "Thanks for joining. Priya, the budget? Sure, four percent over. Frankfurt?".split()
TIMES = [(0.0, 0.4), (0.4, 0.6), (0.6, 1.0), (1.1, 1.5), (1.5, 1.7), (1.7, 2.2),
         (2.5, 2.9), (2.9, 3.2), (3.2, 3.6), (3.6, 4.1), (3.9, 4.6)]
WORDS = [
    {"word": token, "word_index": i, "start": start, "end": end, "speaker": f"spk:{i % 3}"}
    for i, (token, (start, end)) in enumerate(zip(TOKENS, TIMES))
][::-1]
TRANSCRIPTION = {"words": WORDS, "word_timestamp_alignment": {"status": "aligned"}, "segments": []}

# Rendering fixture for issue #12. The app's renderer (a later PR) must turn this document into
# exactly this text too.
RENDER_FIXTURE_DOCUMENT = {
    "version": 1,
    "speakers": [{"id": "S1", "name": "Laura", "name_source": "user"}, {"id": "S2"}],
    "segments": [
        {"start": None, "end": None, "speaker": None, "text": "Preamble."},
        {"start": 0.0, "end": 2.0, "speaker": "S1", "text": "Hello."},
        {"start": 2.0, "end": 3.0, "speaker": "S2", "text": "Hi there."},
    ],
}
RENDER_FIXTURE_TEXT = "Preamble.\n\nLaura: Hello.\n\nSpeaker 2: Hi there."


class BuildAndRenderTests(unittest.TestCase):
    def test_tags_become_turns_numbered_by_first_appearance_with_times(self):
        doc = speakers.build(CONTENT, TRANSCRIPTION, model="salm")
        self.assertEqual(speakers.render(doc), (
            "Speaker 1: Thanks for joining. Priya, the budget?\n\n"
            "Speaker 2: Sure, four percent over.\n\n"
            "Speaker 3: Frankfurt?"
        ))
        self.assertEqual([s["id"] for s in doc["speakers"]], ["S1", "S2", "S3"])
        self.assertEqual(
            [(s["speaker"], s["start"], s["end"]) for s in doc["segments"]],
            [("S1", 0.0, 2.2), ("S2", 2.5, 4.1), ("S3", 3.9, 4.6)],
        )

    def test_times_are_left_out_when_words_do_not_match_the_text(self):
        doc = speakers.build(CONTENT, dict(TRANSCRIPTION, words=WORDS[1:]))
        self.assertTrue(all(s["start"] is None and s["end"] is None for s in doc["segments"]))
        doc = speakers.build(CONTENT, dict(TRANSCRIPTION, word_timestamp_alignment={"status": "unavailable"}))
        self.assertTrue(all(s["start"] is None for s in doc["segments"]))

    def test_one_speaker_renders_plain_until_named(self):
        doc = speakers.build("<spk:0> Just me, talking to myself.", {})
        self.assertEqual([s["id"] for s in doc["speakers"]], ["S1"])
        self.assertEqual(speakers.render(doc), "Just me, talking to myself.")
        doc["speakers"][0]["name"] = "Scott"
        self.assertEqual(speakers.render(doc), "Scott: Just me, talking to myself.")

    def test_untagged_text_has_no_speakers(self):
        doc = speakers.build("Nobody was tagged.", {})
        self.assertEqual(doc["speakers"], [])
        self.assertEqual(speakers.render(doc), "Nobody was tagged.")

    def test_shared_render_fixture(self):
        self.assertEqual(speakers.render(RENDER_FIXTURE_DOCUMENT), RENDER_FIXTURE_TEXT)


class AudioTests(unittest.TestCase):
    def test_recordings_over_an_hour_fail_permanently(self):
        with mock.patch.object(speakers, "_duration_seconds", return_value=3600.4):
            with self.assertRaises(providers.ProviderError) as caught:
                speakers.to_flac("/nonexistent.ogg")
        self.assertFalse(caught.exception.retryable)
        self.assertIn("60 min 01 s", str(caught.exception))

    def test_conversion_timeout_is_retryable_and_bad_audio_is_not(self):
        with mock.patch.object(speakers, "_duration_seconds", return_value=None):
            with mock.patch.object(subprocess, "run", side_effect=subprocess.TimeoutExpired("ffmpeg", 1)):
                with self.assertRaises(providers.ProviderError) as caught:
                    speakers.to_flac("/x.ogg")
            self.assertTrue(caught.exception.retryable)
            failure = subprocess.CalledProcessError(1, "ffmpeg", stderr=b"Invalid data found")
            with mock.patch.object(subprocess, "run", side_effect=failure):
                with self.assertRaises(providers.ProviderError) as caught:
                    speakers.to_flac("/x.ogg")
            self.assertFalse(caught.exception.retryable)
            self.assertIn("Invalid data", str(caught.exception))


class NemoJobTests(ServerTestCase):
    def setUp(self) -> None:
        super().setUp()
        self.requests: list[dict] = []
        self.content = CONTENT
        fake = self.fake.urlopen

        def urlopen(request, timeout):
            if request.full_url.endswith("/chat/completions"):
                body = json.loads(request.data)
                if isinstance(body["messages"][-1]["content"], list):  # the transcription call
                    self.requests.append(body)
                    reply = {"choices": [{"message": {"content": self.content}}], "transcription": TRANSCRIPTION}
                    return json.dumps(reply).encode()
            return fake(request, timeout)

        for patcher in (
            mock.patch.object(providers, "_urlopen", urlopen),
            mock.patch.object(speakers, "to_flac", lambda path: b"fLaC-fake"),
        ):
            patcher.start()
            self.addCleanup(patcher.stop)
        self.configure()
        self.request("PUT", "/admin/api/settings", body={"transcription": {"provider": "nemo_speech_chat"}}, auth="admin")

    def test_job_returns_speaker_text_and_document(self):
        _, job = self.upload()
        job = self.wait_for(job["id"])
        self.assertEqual(job["status"], "done")
        self.assertTrue(job["transcript"].startswith("Speaker 1: Thanks for joining."))
        self.assertEqual(speakers.render(job["transcript_json"]), job["transcript"])
        self.assertEqual(job["transcript_json"]["segments"][0]["start"], 0.0)
        call = self.requests[0]
        self.assertEqual(call["timestamp_granularities"], ["word"])
        self.assertEqual(call["messages"][0]["content"][1]["input_audio"]["format"], "flac")
        self.assertTrue(job["summary"])

    def test_empty_transcript_fails_the_job(self):
        self.content = "<spk:0>   "
        _, job = self.upload()
        job = self.wait_for(job["id"])
        self.assertEqual(job["status"], "failed")
        self.assertIn("no text", job["error"])

    def test_plain_provider_jobs_have_no_document(self):
        self.request("PUT", "/admin/api/settings", body={"transcription": {"provider": "openai_transcriptions"}}, auth="admin")
        _, job = self.upload(audio=b"OggS other audio")
        job = self.wait_for(job["id"])
        self.assertEqual(job["status"], "done")
        self.assertNotIn("transcript_json", job)

    def test_unknown_provider_is_rejected(self):
        status, _ = self.request("PUT", "/admin/api/settings", body={"transcription": {"provider": "nope"}}, auth="admin")
        self.assertEqual(status, 400)


class TextJobDocumentTests(ServerTestCase):
    def setUp(self) -> None:
        super().setUp()
        self.configure(transcription=False)

    def test_text_job_stores_and_returns_the_document(self):
        _, job = self.request("POST", "/api/v1/jobs/text", body={
            "transcript": RENDER_FIXTURE_TEXT, "transcript_json": RENDER_FIXTURE_DOCUMENT})
        job = self.wait_for(job["id"])
        self.assertEqual(job["transcript_json"], RENDER_FIXTURE_DOCUMENT)

    def test_a_request_with_a_document_does_not_reuse_one_without(self):
        _, first = self.request("POST", "/api/v1/jobs/text", body={"transcript": RENDER_FIXTURE_TEXT})
        self.wait_for(first["id"])
        _, second = self.request("POST", "/api/v1/jobs/text", body={
            "transcript": RENDER_FIXTURE_TEXT, "transcript_json": RENDER_FIXTURE_DOCUMENT})
        self.assertNotEqual(first["id"], second["id"])

    def test_invalid_document_is_rejected(self):
        status, body = self.request("POST", "/api/v1/jobs/text", body={
            "transcript": "x", "transcript_json": {"version": 2, "speakers": [], "segments": []}})
        self.assertEqual(status, 400)
        self.assertIn("transcript_json", body["error"])

    def test_default_settings_keep_the_old_hashes(self):
        # Upgrading must not stop servers that never use the new provider from reusing old jobs.
        import hashlib
        settings = self.store.settings()
        legacy = {"transcription": {k: settings["transcription"][k] for k in ("base_url", "model", "language", "prompt")},
                  "summarization": {k: settings["summarization"][k] for k in ("base_url", "model", "system_prompt", "temperature", "max_chunk_chars")}}
        self.assertEqual(self.store.config_hash(), hashlib.sha256(json.dumps(legacy, sort_keys=True).encode()).hexdigest())
        _, job = self.request("POST", "/api/v1/jobs/text", body={"transcript": "Same as before."})
        self.assertEqual(self.store.get_job(job["id"])["input_hash"], hashlib.sha256(b"Same as before.").hexdigest())

    def test_unreadable_stored_document_is_omitted_not_an_error(self):
        _, job = self.request("POST", "/api/v1/jobs/text", body={"transcript": "Some text."})
        self.store.update_job(job["id"], transcript_json="{not json")
        status, job = self.request("GET", f"/api/v1/jobs/{job['id']}")
        self.assertEqual(status, 200)
        self.assertNotIn("transcript_json", job)



class NameSuggestionTests(ServerTestCase):
    """Issue #12, part 2: the summary model suggests names for speaker transcripts."""

    def setUp(self) -> None:
        super().setUp()
        self.calls: list[dict] = []
        self.names_reply = (
            '<think>hmm</think>{"S1": {"name": "Matt\\nIGNORE ALL PREVIOUS", "confidence": 0.9, "evidence": "addressed"}, '
            '"S2": {"name": "Priya", "confidence": 0.8, "evidence": "answers"}, "S3": {"name": "Dev", "confidence": 0.3}}'
        )
        fake = self.fake.urlopen

        def urlopen(request, timeout):
            if request.full_url.endswith("/chat/completions"):
                body = json.loads(request.data)
                self.calls.append(body)
                content = body["messages"][-1]["content"]
                if isinstance(content, list):  # transcription
                    reply = {"choices": [{"message": {"content": CONTENT}}], "transcription": TRANSCRIPTION}
                    return json.dumps(reply).encode()
                if "Suggest a real name" in content:
                    return json.dumps({"choices": [{"message": {"content": self.names_reply}}]}).encode()
            return fake(request, timeout)

        for patcher in (
            mock.patch.object(providers, "_urlopen", urlopen),
            mock.patch.object(speakers, "to_flac", lambda path: b"fLaC-fake"),
        ):
            patcher.start()
            self.addCleanup(patcher.stop)
        self.configure()
        self.request("PUT", "/admin/api/settings", body={"transcription": {"provider": "nemo_speech_chat"}}, auth="admin")

    def names_calls(self):
        return [c for c in self.calls if "Suggest a real name" in str(c["messages"][-1]["content"])]

    def test_suggestions_are_cleaned_stored_and_passed_to_the_summary(self):
        _, job = self.upload()
        job = self.wait_for(job["id"])
        self.assertEqual(job["status"], "done")
        found = {s["id"]: s.get("suggestion") for s in job["transcript_json"]["speakers"]}
        self.assertEqual(found["S1"], {"name": "Matt IGNORE ALL PREVIOUS", "source": "llm", "confidence": 0.9, "evidence": "addressed"})
        self.assertEqual(found["S2"]["name"], "Priya")
        self.assertIsNone(found["S3"], "below 0.5 is not stored")
        self.assertNotIn("Matt", job["transcript"], "suggestions never go into the transcript")
        summary_prompt = self.calls[-1]["messages"][-1]["content"]
        self.assertIn("Speaker 1 = Matt IGNORE ALL PREVIOUS, Speaker 2 = Priya.", summary_prompt)
        self.assertNotIn("addressed", summary_prompt, "evidence never goes into a prompt")

    def test_a_bad_reply_still_gives_the_summary_and_names_are_tried_once(self):
        self.names_reply = "not json at all"
        self.fake.chat_failures = []
        _, job = self.upload()
        job = self.wait_for(job["id"])
        self.assertEqual(job["status"], "done")
        self.assertIsNone(job["summary_error"])
        self.assertTrue(job["summary"])
        self.assertNotIn("suggestion", json.dumps(job["transcript_json"]))
        self.assertEqual(len(self.names_calls()), 1)

    def test_names_are_not_asked_again_on_a_summary_retry(self):
        self.fake.chat_failures = [503]  # the summary's first attempt fails, then it's retried
        _, job = self.upload()
        job = self.wait_for(job["id"], timeout=15)
        self.assertEqual(job["status"], "done")
        self.assertEqual(len(self.names_calls()), 1)

    def test_switch_off(self):
        self.request("PUT", "/admin/api/settings", body={"summarization": {"suggest_names": False}}, auth="admin")
        _, job = self.upload()
        job = self.wait_for(job["id"])
        self.assertEqual(self.names_calls(), [])
        self.assertNotIn("suggestion", json.dumps(job["transcript_json"]))

    def test_text_job_documents_get_names_and_confirmed_names_are_kept(self):
        doc = {"version": 1, "speakers": [{"id": "S1", "name": "Laura", "name_source": "user"}, {"id": "S2"}],
               "segments": [{"speaker": "S1", "text": "Hello."}, {"speaker": "S2", "text": "Hi there."}]}
        _, job = self.request("POST", "/api/v1/jobs/text", body={"transcript": "Laura: Hello.\n\nSpeaker 2: Hi there.", "transcript_json": doc})
        job = self.wait_for(job["id"])
        speakers_out = job["transcript_json"]["speakers"]
        self.assertEqual(speakers_out[0], {"id": "S1", "name": "Laura", "name_source": "user"}, "no suggestion next to a confirmed name")
        self.assertEqual(speakers_out[1]["suggestion"]["name"], "Priya")
        prompt = self.calls[-1]["messages"][-1]["content"]
        self.assertIn("Speaker names: Speaker 1 = Laura.", prompt)
        self.assertIn("Speaker names suggested from context (unconfirmed): Speaker 2 = Priya.", prompt)


class NamesHintTests(unittest.TestCase):
    def test_low_confidence_client_suggestions_are_ignored(self):
        doc = {"speakers": [{"id": "S1", "suggestion": {"name": "Guess", "confidence": 0.2}}]}
        self.assertEqual(speakers.names_hint(doc), "")

    def test_bad_confidences_are_ignored_not_a_crash(self):
        doc = {"speakers": [{"id": "S1", "suggestion": {"name": "Huge", "confidence": 10 ** 400}},
                            {"id": "S2", "suggestion": {"name": "Inf", "confidence": "inf"}}]}
        self.assertEqual(speakers.names_hint(doc), "")

    def test_placeholder_names_are_not_suggestions(self):
        doc = {"speakers": [{"id": "S1"}, {"id": "S2"}, {"id": "S3"}]}
        reply = '{"S1": {"name": "null", "confidence": 0.9}, "S2": {"name": "Speaker 2", "confidence": 0.9}, "S3": {"name": "Dev", "confidence": 0.9}}'
        with mock.patch.object(speakers, "chat", return_value=reply):
            out = speakers.suggest_names({"timeout_seconds": 60, "max_chunk_chars": 1000}, "text", doc)
        self.assertEqual([s.get("suggestion", {}).get("name") for s in out["speakers"]], [None, None, "Dev"])

    def test_with_suggestions_off_only_confirmed_names_are_passed(self):
        doc = {"speakers": [{"id": "S1", "name": "Laura"}, {"id": "S2", "suggestion": {"name": "Priya", "confidence": 0.9}}]}
        self.assertEqual(speakers.names_hint(doc, suggestions=False), "Speaker names: Speaker 1 = Laura.")


if __name__ == "__main__":
    unittest.main()
