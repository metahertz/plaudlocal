# Plaud Local iOS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a local-first iOS app that pulls Plaud Note Pro recordings over BLE (protocol 20), decrypts them, transcribes with WhisperKit, summarizes with Foundation Models when available, and auto-exports to Files and/or Nextcloud.

**Architecture:** SwiftUI shell over two cores — `DeviceSession` (auth keys, BLE, protocol crypto, PLAUD.AI decrypt) and `NotePipeline` (store, WhisperKit, optional Foundation Models, Files/WebDAV export). Protocol behavior follows plaude-archiver’s MIT-documented Note Pro flow.

**Tech Stack:** SwiftUI, CoreBluetooth, CryptoKit + Security (RSA PKCS#1), WhisperKit, FoundationModels (availability-gated), Keychain, WebDAV client (MIT), XCTest.

**Spec:** `docs/superpowers/specs/2026-11-05-plaud-local-ios-design.md`

## Global Constraints

- iOS deployment target 17.0; Xcode 16+
- Protocol 20 only in v1; protocol 30 → user-visible unsupported error
- No third-party upload of audio/transcripts except user-configured Nextcloud
- Secrets only in Keychain; never log private keys or session tokens
- Our code MIT; do not add GPL dependencies (no NextcloudKit)
- Bundle id `com.local.plaudlocal`; product name `Plaud Local`
- Upstream reference only: https://github.com/roopen219/plaude-archiver

## Review Focus

- Mid-download BLE drop: resume must continue from last good offset without corrupting the final `.ogg`
- Wrong / missing SN signature or RSA key: unlock fails with a clear “re-sign in / re-fetch keys” message, not a hang
- Protocol-30 advertisement: connect aborts before sending plaintext commands
- Empty Nextcloud password or invalid bookmark: export fails per-note without crashing the pipeline
- Foundation Models unavailable: transcript still saved; summary marked skipped; export still runs

## File Structure

```
PlaudLocal/
  PlaudLocalApp.swift
  Info.plist (+ NSBluetooth* usage strings)
  Features/
    Library/LibraryView.swift
    Device/DeviceView.swift
    Note/NoteDetailView.swift
    Settings/SettingsView.swift
  DeviceSession/
    PlaudAuthService.swift          # WKWebView cookie capture + sn-sign/gen_key
    KeyVault.swift                  # Keychain wrappers
    BLEClient.swift                 # CoreBluetooth scan/connect/notify/write
    ProtocolCodec.swift             # frame pack/unpack, cmd numbers
    SessionCrypto.swift             # proto-20 FE10/FE12 + ChaCha20-Poly1305 session
    FileDecryptor.swift             # PLAUD.AI → Ogg Opus
    DeviceSessionModel.swift        # UI-facing device state + download orchestration
  NotePipeline/
    NoteModels.swift                # NotePackage, Metadata
    NoteStore.swift                 # Documents/Notes layout
    Transcriber.swift               # WhisperKit wrapper
    Summarizer.swift                # FoundationModels wrapper + Unavailable
    NotePipeline.swift              # download → decrypt → ASR → summarize → export
    Exporter.swift                  # Files bookmark + WebDAV
    WebDAVClient.swift              # minimal PUT/MKCOL
  Resources/
    Assets.xcassets
PlaudLocalTests/
  ProtocolCodecTests.swift
  SessionCryptoTests.swift
  FileDecryptorTests.swift
  NoteStoreTests.swift
  ExporterTests.swift
  NotePipelineTests.swift
docs/...
README.md
```

---

### Task 1: Xcode project skeleton + KeyVault

**Files:**
- Create: `PlaudLocal.xcodeproj` (iOS App, SwiftUI, iOS 17)
- Create: `PlaudLocal/PlaudLocalApp.swift`
- Create: `PlaudLocal/Info.plist` (Bluetooth Always/When-In-Use usage descriptions)
- Create: `PlaudLocal/DeviceSession/KeyVault.swift`
- Create: `PlaudLocalTests/KeyVaultTests.swift`
- Create: `README.md`

**Interfaces:**
- Produces: `KeyVault` with `save(_ data: Data, account: String)`, `load(account: String) -> Data?`, `delete(account: String)`, accounts: `plaud.userToken`, `plaud.refreshToken`, `plaud.rsaPrivatePEM`, `plaud.rsaPublicPEM`, `plaud.snSign.<serial>`, `nextcloud.password`

- [ ] **Step 1: Generate the iOS app target**

```bash
cd /Users/matt.johnson/CursorCodeRepo/plaud-local
# Prefer xcodegen or a checked-in pbxproj; if using Xcode CLI scaffolding, create
# PlaudLocal iOS App, bundle com.local.plaudlocal, SwiftUI, iOS 17, include unit test target.
```

- [ ] **Step 2: Write failing `KeyVaultTests.test_roundTripSecret`**

```swift
func test_roundTripSecret() throws {
    let vault = KeyVault(service: "com.local.plaudlocal.tests")
    let payload = Data("secret-bytes".utf8)
    try vault.save(payload, account: "plaud.userToken")
    XCTAssertEqual(vault.load(account: "plaud.userToken"), payload)
    try vault.delete(account: "plaud.userToken")
    XCTAssertNil(vault.load(account: "plaud.userToken"))
}
```

- [ ] **Step 3: Implement `KeyVault` with Security keychain generic passwords**

- [ ] **Step 4: Run tests**

Run: `xcodebuild test -scheme PlaudLocal -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:PlaudLocalTests/KeyVaultTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add PlaudLocal PlaudLocalTests PlaudLocal.xcodeproj README.md
git commit -m "chore: scaffold Plaud Local iOS app and KeyVault"
```

---

### Task 2: ProtocolCodec + SessionCrypto (protocol 20 framing)

**Files:**
- Create: `PlaudLocal/DeviceSession/ProtocolCodec.swift`
- Create: `PlaudLocal/DeviceSession/SessionCrypto.swift`
- Create: `PlaudLocalTests/ProtocolCodecTests.swift`
- Create: `PlaudLocalTests/SessionCryptoTests.swift`
- Create: `PlaudLocalTests/Fixtures/` (synthetic vectors where needed)

**Interfaces:**
- Produces:
  - `enum PlaudCommand: UInt16` — handshake=`1`, getSessions=`26`, syncStart=`28`, syncStop=`29`
  - `ProtocolCodec.packCommand(_ cmd: UInt16, params: Data) -> Data` → `[0x01][cmd LE][params]` trimmed
  - `ProtocolCodec.parseNotify(_ data: Data) -> PlaudPacket` where `PlaudPacket` is `.command(cmd, fields)` | `.recordingData(sessionId?, offset, payload)` | `.raw(Data)`
  - `SessionCrypto.beginProtocol20(signature: Data, rsaPrivatePEM: String) async throws` consuming FE10/FE11/FE12 callbacks via injectible send/receive
  - `SessionCrypto.seal(_ plaintext: Data) throws -> Data` / `open(_ ciphertext: Data) throws -> Data` using fixed-nonce ChaCha20-Poly1305 over `seq u32 || packet`
  - `SessionCrypto.padBindToken(userId: String) -> String` — right-pad with `"0"` to 32 ASCII chars

- [ ] **Step 1: Write `ProtocolCodecTests.test_packHandshake`** asserting bytes match `01 01 00 02 00 00` + 32-char token for P=0

- [ ] **Step 2: Write `SessionCryptoTests.test_padBindToken`** and `test_sealOpen_roundTrip` with a known key/nonce/AAD

- [ ] **Step 3: Implement codec + crypto (RSA decrypt via SecKey; ChaCha20-Poly1305 via CryptoKit or verified Swift ChaCha)**

- [ ] **Step 4: Run tests — Expected: PASS

- [ ] **Step 5: Commit** `feat: add Plaud BLE protocol codec and protocol-20 session crypto`

---

### Task 3: FileDecryptor (PLAUD.AI → Ogg)

**Files:**
- Create: `PlaudLocal/DeviceSession/FileDecryptor.swift`
- Create: `PlaudLocalTests/FileDecryptorTests.swift`
- Create: `PlaudLocalTests/Fixtures/sample.plaud` (optional; if no real fixture, unit-test header parse + fake body with known key)

**Interfaces:**
- Consumes: RSA private PEM from KeyVault
- Produces: `FileDecryptor.decrypt(fileData: Data, privateKeyPEM: String) throws -> Data` (Ogg Opus bytes)
- Throws: `FileDecryptorError.badMagic`, `.unsupportedVersion(UInt16)` (reject version ≠ 1 in v1), `.rsaFailed`, `.integrityFailed`

- [ ] **Step 1: Write tests for magic/version parse and version-2 rejection**

- [ ] **Step 2: Implement header parse + RSA unwrap of content key + ChaCha20 body decrypt per spec**

- [ ] **Step 3: Run tests — Expected: PASS**

- [ ] **Step 4: Commit** `feat: decrypt PLAUD.AI recordings to Ogg Opus`

---

### Task 4: BLEClient + DeviceSessionModel (connect, list, download)

**Files:**
- Create: `PlaudLocal/DeviceSession/BLEClient.swift`
- Create: `PlaudLocal/DeviceSession/DeviceSessionModel.swift`
- Create: `PlaudLocal/DeviceSession/PlaudAuthService.swift`
- Create: `PlaudLocal/Features/Device/DeviceView.swift`
- Create: `PlaudLocalTests/DeviceSessionModelTests.swift` (mock BLE)

**Interfaces:**
- Consumes: `KeyVault`, `ProtocolCodec`, `SessionCrypto`, `FileDecryptor`
- Produces:
  - `BLEClient` — `scan()`, `connect(peripheralID:)`, `write(_ data: Data)`, `notifications: AsyncStream<Data>`
  - GATT constants: service `00001910-…`, notify `00002bb0-…`, write `00002bb1-…`
  - `DeviceSessionModel`: `@Published connectionState`, `deviceRecordings: [DeviceRecording]`, `download(recording:progress:) async throws -> URL` (encrypted file path), rejects protocol 30 during unlock
  - `PlaudAuthService.signIn() async throws` presents WKWebView, stores tokens, fetches sn-sign + gen_key into KeyVault

- [ ] **Step 1: Write `DeviceSessionModelTests.test_protocol30_aborts`** using a fake notify stream that starts with `0xFE30`

- [ ] **Step 2: Write `test_download_resume_offset`** verifying syncStart uses last offset after a simulated drop

- [ ] **Step 3: Implement BLEClient + DeviceSessionModel download/resume (`.part` sibling file)**

- [ ] **Step 4: Wire DeviceView (scan, connect, list, download buttons)**

- [ ] **Step 5: Run unit tests — Expected: PASS** (device hardware optional smoke later)

- [ ] **Step 6: Commit** `feat: BLE connect, session list, and resumable download`

---

### Task 5: NoteStore + pipeline models

**Files:**
- Create: `PlaudLocal/NotePipeline/NoteModels.swift`
- Create: `PlaudLocal/NotePipeline/NoteStore.swift`
- Create: `PlaudLocalTests/NoteStoreTests.swift`
- Create: `PlaudLocal/Features/Library/LibraryView.swift`
- Create: `PlaudLocal/Features/Note/NoteDetailView.swift`

**Interfaces:**
- Produces:
  - `struct NoteMetadata: Codable` — `id`, `sessionId`, `createdAt`, `durationSeconds`, `title`, `transcriptStatus`, `summaryStatus`, `exportStatus`, `audioFileName`
  - `NoteStore.createNote(fromDecryptedAudio: Data, sessionId: UInt32, duration: Int) throws -> NoteMetadata`
  - Layout: `Documents/Notes/<id>/audio.ogg`, `transcript.md`, `summary.md`, `metadata.json`
  - `NoteStore.allNotes() throws -> [NoteMetadata]`, `updateMetadata`

- [ ] **Step 1: Write `NoteStoreTests.test_createAndList`**

- [ ] **Step 2: Implement NoteStore + Library/Note views reading the store**

- [ ] **Step 3: Run tests — Expected: PASS**

- [ ] **Step 4: Commit** `feat: local note package store and library UI`

---

### Task 6: Transcriber + Summarizer

**Files:**
- Create: `PlaudLocal/NotePipeline/Transcriber.swift`
- Create: `PlaudLocal/NotePipeline/Summarizer.swift`
- Create: `PlaudLocalTests/SummarizerTests.swift`
- Modify: `PlaudLocal.xcodeproj` — SPM `https://github.com/argmaxinc/WhisperKit.git`

**Interfaces:**
- Produces:
  - `Transcriber.transcribe(audioURL: URL) async throws -> String`
  - `Summarizer.summarize(transcript: String) async throws -> SummaryResult` where `SummaryResult` is `.text(String)` | `.unavailable(reason: String)`
  - Summarizer must not throw when Foundation Models / Apple Intelligence missing — return `.unavailable`

- [ ] **Step 1: Write `SummarizerTests.test_unavailable_whenModelMissing`** (force unavailable path)

- [ ] **Step 2: Implement Summarizer with `#available` + `SystemLanguageModel` availability check**

- [ ] **Step 3: Implement Transcriber wrapping WhisperKit; document first-run model download in README**

- [ ] **Step 4: Run SummarizerTests — Expected: PASS** (WhisperKit covered by pipeline smoke / manual)

- [ ] **Step 5: Commit** `feat: on-device transcription and gated local summarization`

---

### Task 7: Exporter (Files bookmark + WebDAV)

**Files:**
- Create: `PlaudLocal/NotePipeline/WebDAVClient.swift`
- Create: `PlaudLocal/NotePipeline/Exporter.swift`
- Create: `PlaudLocal/Features/Settings/SettingsView.swift`
- Create: `PlaudLocalTests/ExporterTests.swift`
- Create: `PlaudLocalTests/WebDAVClientTests.swift` (URLProtocol stub)

**Interfaces:**
- Produces:
  - `WebDAVClient(baseURL:username:password:).ensureCollection(_ path:)` / `upload(data:toPath:)`
  - `Exporter.export(_ note: NoteMetadata, store: NoteStore) async throws -> ExportResult`
  - Reads Settings: security-scoped bookmark Data in UserDefaults/Keychain, Nextcloud base URL + username + KeyVault password + remote path, `autoExportEnabled: Bool`
  - Package remote/local name: `yyyyMMdd_HHmm_<sanitizedTitle>/`

- [ ] **Step 1: Write WebDAV stub test for MKCOL + PUT**

- [ ] **Step 2: Write `ExporterTests.test_filesExport_writesPackage`** using temp directory as bookmark target

- [ ] **Step 3: Implement WebDAVClient + Exporter + Settings UI**

- [ ] **Step 4: Run tests — Expected: PASS**

- [ ] **Step 5: Commit** `feat: export notes to Files folder and Nextcloud WebDAV`

---

### Task 8: NotePipeline orchestration + end-to-end wiring

**Files:**
- Create: `PlaudLocal/NotePipeline/NotePipeline.swift`
- Create: `PlaudLocalTests/NotePipelineTests.swift`
- Modify: Device download success → enqueue pipeline
- Modify: `PlaudLocalApp.swift` — tab root (Library / Device / Settings)

**Interfaces:**
- Consumes: DeviceSessionModel download URL, FileDecryptor, NoteStore, Transcriber, Summarizer, Exporter
- Produces: `NotePipeline.processDownloadedFile(_ url: URL, sessionId: UInt32, duration: Int) async` updating metadata statuses; if `autoExportEnabled`, call Exporter after transcript (and after summary attempt)

- [ ] **Step 1: Write `NotePipelineTests.test_skipsSummaryStillExports`** with fakes

- [ ] **Step 2: Implement orchestration + tab UI wiring**

- [ ] **Step 3: Run full unit test suite**

Run: `xcodebuild test -scheme PlaudLocal -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: all PASS

- [ ] **Step 4: Commit** `feat: wire download-to-export note pipeline`

- [ ] **Step 5: Update README with device test checklist** (sign-in → connect → download → transcript → export)

---

## Manual device verification (after Task 8)

On a physical iPhone + Note Pro (protocol 20):

1. Sign in once; confirm keys in Keychain (no token in logs).
2. Quit official Plaud app; wake Note Pro; connect in Plaud Local.
3. Download smallest recording; confirm playable audio in note detail.
4. Confirm transcript file non-empty.
5. On Apple Intelligence device: summary non-empty; otherwise summary skipped badge.
6. Configure Files folder + Nextcloud; toggle auto-export; confirm package layout matches spec.
