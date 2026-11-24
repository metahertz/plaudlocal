# Plaud Local

Local-first iPhone companion for Plaud Note Pro: BLE download (protocol 20), Wi-Fi Fast Transfer, on-device decrypt, on-device transcription (Apple Speech or WhisperKit), optional Apple Intelligence summaries, meeting briefs and posters, export to Files and Nextcloud WebDAV. Optionally, recordings can instead be sent to a self-hosted server for transcription and summarization with larger models.

Not affiliated with Plaud. For personal interoperability with your own device and account.

## Requirements

- Xcode 27+ (the pinned Swift packages need Swift tools 6.4; iOS 17 deployment target)
- Physical iPhone for BLE (simulator covers unit tests only); the app is iPhone-only, portrait
- Note Pro on **protocol 20** firmware
- One-time Plaud web login to fetch SN signature + E2EE RSA key

## Build

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate
open PlaudLocal.xcodeproj
```

## Tests

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild test -scheme PlaudLocal -destination 'platform=iOS Simulator,name=iPhone 17'
```

The optional server has its own tests, which need only Python:

```bash
cd server
python -m unittest discover -s tests -v
```

## Architecture

- `DeviceSession` — Keychain, BLE, protocol codec, session crypto, Wi-Fi Fast Transfer, PLAUD.AI decrypt
- `NotePipeline` — note store, transcriber, summarizer, brief and poster builder, Files/WebDAV export
- `Features` — SwiftUI screens: Device, Library, Note, Settings
- `server/` — optional self-hosted Plaud Remote server (Docker); see [server/README.md](server/README.md)

## Processing modes

Settings → Processing chooses what happens to each new recording:

- **On this iPhone** (default): transcription and summary run on-device.
- **Remote server**: the audio is uploaded to a Plaud Remote server (see `server/`), which runs models you host or subscribe to and returns the text. The app connects over HTTPS only. Transcription and summary can each be kept on the iPhone, and "Use on-device AI if the server fails" processes a recording locally when the server can't.
- **Audio only**: no AI; the decrypted audio is exported for your own tools.

For remote summaries, the server's model needs a large enough context window to read a whole meeting at once; see [Summary model](server/README.md#summary-model): the default 200,000-character limit is sized for a model with a 64k-token context, and it suggests a model to start with.

In either AI mode, "Summarize" and "Build brief and poster" switch those steps off. The brief, poster and export always run on the phone. Once a server is set up, "Transcribe & summarize" on a note lets you send that one note to the server or keep it on the iPhone, whatever the mode.

## Current limits

- Protocol 30 (ECC) is detected and refused
- Transcription defaults to Apple Speech; WhisperKit is opt-in in Settings and downloads its model on first use
- Foundation Models summarization returns `.unavailable` when Apple Intelligence is missing
- Wi-Fi Fast Transfer needs a manual join: the app shows the Note Pro hotspot's SSID and password, and you join it in Settings (automatic joining needs the Hotspot Configuration entitlement, which is not enabled)
- Deleting recordings from the device is opt-in ("Delete from device after download")
- Remote server: the app collects results only while it is open; the server keeps working, and the app picks the result up the next time it processes that note. Each note remembers its server job in `remote-job.json`, so that pick-up is a status check, not a second upload or a second summary
- Remote server: the address must be `https://` with a certificate the iPhone trusts (a self-signed one needs its root installed and trusted on the phone)
- Remote server: the app and server are covered by unit tests on each side but have not yet been run against each other

## Manual device checklist

1. Sign in once; confirm keys land in Keychain (no tokens in logs)
2. Quit the official Plaud app; wake Note Pro; connect in Plaud Local
3. Download a short recording; confirm decrypted audio in the note package
4. Confirm transcript file is written
5. On Apple Intelligence hardware: confirm a summary is written; otherwise skipped badge
6. Configure Files folder / Nextcloud; enable auto-export; confirm package layout
7. Remote server (optional): run `server/`, set up its endpoints, and enter its address and token under Settings → Processing → Remote server; "Save and test connection" should report both stages ready
8. In Remote server mode, download a recording; confirm the job appears on the server's web page and the transcript and summary land in the note
9. Stop the server and download another; with the fallback on, confirm the note is processed on-device instead

## License

MIT. Protocol reference: [plaude-archiver](https://github.com/roopen219/plaude-archiver) (MIT).
