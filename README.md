# Plaud Local

Local-first iPhone companion for Plaud Note Pro: BLE download (protocol 20), Wi-Fi Fast Transfer, on-device decrypt, on-device transcription (Apple Speech or WhisperKit), optional Apple Intelligence summaries, meeting briefs and posters, export to Files and Nextcloud WebDAV.

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

## Architecture

- `DeviceSession` — Keychain, BLE, protocol codec, session crypto, Wi-Fi Fast Transfer, PLAUD.AI decrypt
- `NotePipeline` — note store, transcriber, summarizer, brief and poster builder, Files/WebDAV export
- `Features` — SwiftUI screens: Device, Library, Note, Settings
- `server/` — optional self-hosted Plaud Remote server (Docker); see [server/README.md](server/README.md)

## Remote processing (optional)

By default everything runs on the iPhone. If you run the Plaud Remote server from `server/`, the app can instead upload each recording to it for transcription and summarization with models you host or subscribe to. Turn it on under Settings → Remote processing with the server's address and API token. The transcript and summary come back into the note; the brief, poster and export still run on the phone. With "Use on-device AI if the server fails" on, a recording is processed locally when the server can't do it.

## Current limits

- Protocol 30 (ECC) is detected and refused
- Transcription defaults to Apple Speech; WhisperKit is opt-in in Settings and downloads its model on first use
- Foundation Models summarization returns `.unavailable` when Apple Intelligence is missing
- Wi-Fi Fast Transfer needs a manual join: the app shows the Note Pro hotspot's SSID and password, and you join it in Settings (automatic joining needs the Hotspot Configuration entitlement, which is not enabled)
- Deleting recordings from the device is opt-in ("Delete from device after download")

## Manual device checklist

1. Sign in once; confirm keys land in Keychain (no tokens in logs)
2. Quit the official Plaud app; wake Note Pro; connect in Plaud Local
3. Download a short recording; confirm decrypted audio in the note package
4. Confirm transcript file is written
5. On Apple Intelligence hardware: confirm a summary is written; otherwise skipped badge
6. Configure Files folder / Nextcloud; enable auto-export; confirm package layout

## License

MIT. Protocol reference: [plaude-archiver](https://github.com/roopen219/plaude-archiver) (MIT).
