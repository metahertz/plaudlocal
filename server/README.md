# Plaud Remote

A small self-hosted server that the Plaud Local app can send recordings to for
transcription and summarization with larger models than an iPhone can run.

It receives audio from the app, queues it, calls the model endpoints you
configure, and hands the transcript and summary back to the app. It runs no
models itself.

It is independent of the iOS code in this repository: one Docker container,
Python standard library only, no packages to install.

## Run it

```bash
cd server
PLAUD_REMOTE_ADMIN_PASSWORD='choose-a-password' docker compose up -d --build
```

Then open `http://<host>:8080` and sign in as `admin` with that password.
If you don't set a password, one is generated on first start and printed once
in the container log (`docker compose logs plaud-remote`).

The app only connects over **HTTPS**, so the server needs TLS before the app
can use it; see [HTTPS](#https) below.

Without Docker: `PLAUD_REMOTE_DATA_DIR=./data python -m plaud_remote` (Python 3.11+).

## Set it up

1. **Transcription**: the base URL and model of an OpenAI-compatible speech
   endpoint. The server posts each recording to `<base URL>/audio/transcriptions`.
   Examples: [Speaches](https://github.com/speaches-ai/speaches) or another
   faster-whisper server (`http://speaches:8000/v1`), or a hosted API.
2. **Summarization** (optional): the base URL and model of an OpenAI-compatible
   chat endpoint, called at `<base URL>/chat/completions`. Examples: Ollama
   (`http://ollama:11434/v1`), vLLM, LM Studio, or a hosted API. Leave it empty
   to return transcripts only; the app then summarizes on-device.
3. Use **Test connection** on each, then copy the **server address** and
   **API token** from the top of the page into the app: Settings → Processing →
   Remote server. The address must be the `https://` one.

Model endpoints must be reachable from inside the container. For a service on
the Docker host, use `http://host.docker.internal:<port>/v1` (on Linux, add
`extra_hosts: ["host.docker.internal:host-gateway"]` to the compose file).

## HTTPS

The app refuses plain `http://` addresses, so recordings and the token never
travel unencrypted. The certificate must be one the iPhone trusts: a public
one (for example Let's Encrypt), or a private CA whose root you have installed
and trusted on the phone. Two ways to provide it:

- **Reverse proxy (recommended)**: keep the container on plain HTTP and put a
  TLS-terminating proxy in front. With Caddy, the whole configuration is:

  ```
  plaud.example.com {
      reverse_proxy plaud-remote:8080
  }
  ```

  Allow large request bodies and long uploads in the proxy; recordings can be
  tens of megabytes.
- **Built in**: mount a certificate and key into the container and set
  `PLAUD_REMOTE_TLS_CERT` and `PLAUD_REMOTE_TLS_KEY` to their paths. The server
  then serves HTTPS itself on its port.

## How a recording is processed

1. The app uploads the audio (`POST /api/v1/jobs`) and gets a job back.
2. A worker transcribes it, then summarizes the transcript. Transcripts longer
   than the configured limit are summarized in parts and then merged.
3. The app polls the job (`GET /api/v1/jobs/<id>`) and stores the transcript
   and summary in the note. The brief, poster and export still run on the phone.

Behaviour worth knowing:

- **Retries**: failed model calls that look temporary (timeouts, HTTP 429/5xx)
  are retried with a growing delay, up to the configured number of attempts.
  A restart re-queues whatever was in progress without using up an attempt.
  A job that has been in progress at three restarts is failed instead, since it
  is probably what is stopping the server (for example, running out of memory on
  a very large recording). Retry in the web UI gives it a fresh start.
- **Summary failures don't lose the transcript**: the job finishes with the
  transcript and a reason, and the app falls back to on-device summarization.
- **No duplicate work**: uploading the same audio again returns the existing
  job while the model settings are unchanged. "Transcribe & summarize" in the
  app forces a fresh run.
- **Transcript-only jobs**: when the app will summarize on-device, or summaries
  are switched off in the app, it asks the server to skip the summary.
- **Audio is deleted** once a job finishes, unless you turn on "Keep the
  uploaded audio". Finished jobs are removed after 30 days by default.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `PLAUD_REMOTE_ADMIN_PASSWORD` | generated | Web UI password for user `admin` |
| `PLAUD_REMOTE_PORT` | `8080` | Port to listen on |
| `PLAUD_REMOTE_DATA_DIR` | `/data` | Database and uploaded audio |
| `PLAUD_REMOTE_TLS_CERT`, `PLAUD_REMOTE_TLS_KEY` | unset | Certificate chain and key files, to serve HTTPS directly |
| `PLAUD_REMOTE_MAX_UPLOAD_MB` | `500` | Largest accepted recording |
| `PLAUD_REMOTE_WORKERS` | `1` | Recordings processed at the same time |
| `PLAUD_REMOTE_LOG_LEVEL` | `INFO` | Log verbosity |

Everything else is set in the web UI and stored in the data volume.

## Security

- The app API needs the bearer token; the web UI and admin API need the admin
  password. Regenerating the token in the web UI revokes the old one.
- The app connects over HTTPS only; see [HTTPS](#https). Use the web UI over
  HTTPS too, since it sends the admin password with every request.
- Model API keys and the app token are stored in the data volume, unencrypted,
  and model keys are never sent back to the browser. Protect the volume
  accordingly.
- Recordings and transcripts leave the phone when this feature is on. They go
  to this server and to whichever model endpoints you configure.

## App API

All requests need `Authorization: Bearer <token>`.

| Request | Purpose |
|---|---|
| `GET /api/v1/health` | Version, and whether transcription and summarization are configured |
| `POST /api/v1/jobs?client_ref=&title=&filename=&force=&summarize=` | Upload audio as the raw request body; `summarize=0` returns the transcript only |
| `POST /api/v1/jobs/text` | Summarize an existing transcript: `{"transcript": "...", "title": "..."}` |
| `GET /api/v1/jobs/<id>` | Status, transcript, summary and errors |
| `DELETE /api/v1/jobs/<id>` | Remove a job and its data |

Job `status` is one of `queued`, `transcribing`, `summarizing`, `done`, `failed`.
`GET /healthz` needs no token and is used by the container health check.

## Tests

```bash
cd server
python -m unittest discover -s tests -v
```
