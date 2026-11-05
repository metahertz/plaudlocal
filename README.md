# Plaud Local

Local-first iOS companion for Plaud Note Pro: BLE download, on-device transcription, optional Apple Intelligence summarization, export to Files and Nextcloud.

Not affiliated with Plaud. For personal interoperability with your own device and account.

## Requirements

- Xcode 16+
- iOS 17+ device (BLE + WhisperKit)
- Note Pro on protocol 20 firmware

## Build

```bash
xcodegen generate
open PlaudLocal.xcodeproj
```

## Tests

```bash
xcodebuild test -scheme PlaudLocal -destination 'platform=iOS Simulator,name=iPhone 17'
```
