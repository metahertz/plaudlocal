# Plaud Local

Local-first iOS companion for Plaud Note Pro: BLE download (protocol 20), on-device decrypt, transcription pipeline, optional Apple Intelligence summarization, export to Files and Nextcloud WebDAV.

Not affiliated with Plaud. For personal interoperability with your own device and account.

## Requirements

- Xcode 16+ (tested with Xcode 27 / iOS 17 deployment target)
- Physical iPhone for BLE (simulator covers unit tests only)
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

- `DeviceSession` — Keychain, BLE, protocol codec, session crypto, PLAUD.AI decrypt
- `NotePipeline` — note store, transcriber, summarizer, Files/WebDAV export

## Current limits (v1)

- Protocol 30 (ECC) is detected and refused
- WhisperKit SPM is not yet linked; `Transcriber` is a file-presence stub until model packaging is wired (pipeline + export still run)
- Foundation Models summarization returns `.unavailable` when Apple Intelligence is missing
- Device delete and Wi-Fi fast transfer are out of scope

## Manual device checklist

1. Sign in once; confirm keys land in Keychain (no tokens in logs)
2. Quit the official Plaud app; wake Note Pro; connect in Plaud Local
3. Download a short recording; confirm decrypted audio in the note package
4. Confirm transcript file is written
5. On Apple Intelligence hardware: summary when implemented; otherwise skipped badge
6. Configure Files folder / Nextcloud; enable auto-export; confirm package layout

## License

MIT. Protocol reference: [plaude-archiver](https://github.com/roopen219/plaude-archiver) (MIT).
