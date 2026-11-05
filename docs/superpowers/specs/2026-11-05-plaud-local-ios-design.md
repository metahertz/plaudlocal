# Plaud Local — Design

**Product:** Local-first iOS companion for Plaud Note Pro  
**Date:** 2026-11-05  
**Decision:** Option A — BLE companion (port of plaude-archiver protocol)

## Intent

Pull recordings off a Plaud Note Pro over Bluetooth LE, decrypt them on-device, transcribe locally, summarize locally when possible, and auto-export Markdown + audio to a Files folder and/or Nextcloud — without depending on Plaud’s cloud for day-to-day use after the one-time key fetch.

## Goals

1. Connect to a paired Note Pro over BLE, list recordings, download with resume, decrypt to playable Ogg Opus.
2. Transcribe each recording on-device (WhisperKit).
3. Summarize on-device when Apple Intelligence / Foundation Models is available; otherwise leave summary empty and show a clear “unavailable” state (no forced cloud LLM).
4. Persist a local library of note packages (`audio` + `transcript` + optional `summary` + metadata).
5. Auto-export completed notes to a user-chosen Files folder (security-scoped bookmark) and/or a Nextcloud WebDAV endpoint.
6. One-time Plaud web login only to obtain device SN signature + E2EE RSA key pair; thereafter operate offline for download/transcribe/summarize/export (except Nextcloud upload).

## Non-goals

- Official Plaud affiliation, App Store listing readiness, or reverse-engineering beyond personal interoperability.
- Protocol-30 (ECC) first-class support in v1 (detect and show “unsupported firmware”; protocol-20 only).
- Speaker diarization, meeting templates, or chat-with-recording.
- Cloud re-transcription via Plaud, OpenAI, or other hosted APIs in v1.
- Wi-Fi fast-transfer protocol.
- Deleting recordings from the device by default (opt-in later; v1 is download-only).

## Anti-goals

- Shipping an app that silently uploads audio or transcripts to any third party.
- Requiring the official Plaud app to stay open or for the device to Wi-Fi sync before notes appear.
- GPL-entangling the app binary via NextcloudKit; prefer MIT/Apache WebDAV client for export.

## Constraints

| Constraint | Value |
|---|---|
| Platform | iOS 17.0+ (WhisperKit floor); Foundation Models used only when `#available` / runtime-capable |
| Language | Swift 5.9+ / SwiftUI |
| BLE | CoreBluetooth; background BLE optional later, foreground first |
| Protocol | Tinnotech GATT `1910` / `2BB0` / `2BB1`; protocol **20** unlock (RSA + ChaCha20-Poly1305) per plaude-archiver |
| Audio out | Decrypted Ogg Opus (re-encode to m4a optional for Files/AVFoundation friendliness) |
| ASR | WhisperKit (`argmaxinc/WhisperKit`), model downloaded on first use, cached in app container |
| Summarize | `FoundationModels.SystemLanguageModel` when available; else skip |
| Secrets | Keychain for Plaud session cookies/tokens, RSA private key, SN signature, Nextcloud app password |
| Export local | Security-scoped bookmark to a folder; write `YYYYMMDD_HHMM_title/{audio,transcript.md,summary.md,metadata.json}` |
| Export Nextcloud | WebDAV PUT to configured base path; same package layout |
| License of our code | MIT |
| Upstream reference | https://github.com/roopen219/plaude-archiver (MIT) — reimplement / adapt, do not vend GPL deps |

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ SwiftUI App                                                  │
│  Library · Device · Note Detail · Settings                   │
└───────────────┬─────────────────────────────┬───────────────┘
                │                             │
┌───────────────▼───────────────┐ ┌───────────▼───────────────┐
│ DeviceSession                 │ │ NotePipeline              │
│  BLEClient (CoreBluetooth)    │ │  Transcriber (WhisperKit) │
│  ProtocolCodec                │ │  Summarizer (Foundation)  │
│  SessionCrypto (proto 20)     │ │  NoteStore (FileManager)  │
│  FileDecryptor (PLAUD.AI)     │ │  Exporter (Files/WebDAV)  │
│  KeyVault (Keychain)          │ └───────────────────────────┘
│  PlaudAuth (WKWebView, once)  │
└───────────────────────────────┘
```

**Data flow**

1. Settings → Sign in (WKWebView `web.plaud.ai`) → capture `pld_ut` / refresh → fetch `sn-sign` + `gen_key` → Keychain.
2. Device tab → scan/connect → FE10 signature → FE12 session secret → handshake with bind token → list sessions (cmd 26).
3. Download (cmd 28/29) → resume via `.part` → decrypt PLAUD.AI → write `.ogg` into NoteStore.
4. NotePipeline: WhisperKit → `transcript.md` → optional Foundation Models → `summary.md`.
5. Exporter: if bookmark and/or Nextcloud configured, copy package atomically; mark exported in metadata.

## UX (v1 screens)

1. **Library** — list of local notes (title, date, duration, sync badges: transcribed / summarized / exported).
2. **Device** — connection state, battery if available, recording list on device, Download / Download all.
3. **Note** — player, transcript, summary, Export now, open in Files.
4. **Settings** — Plaud account (sign in / sign out), Whisper model, export folder picker, Nextcloud URL/user/app-password/path, auto-export toggle.

## Builder calls (defaults)

- App display name: **Plaud Local**
- Bundle id: `com.local.plaudlocal` (replaceable)
- Min iOS: **17.0**
- Whisper default model: WhisperKit recommended compressed large-v3 turbo variant for device, with `tiny` for simulator/debug
- Auto-export runs after summary step (or after transcript if summary unavailable)
- No device delete in v1
- Protocol-30: hard fail with actionable message

## Success

A Note Pro on protocol 20, already bound to the user’s Plaud account: open app → one-time sign-in → connect → download one recording → local transcript appears → if Apple Intelligence available, summary appears → package lands in chosen Files folder and/or Nextcloud path without further cloud dependency for the audio path.
