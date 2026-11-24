import Foundation

struct ExportResult: Equatable {
    var wroteLocal: Bool
    var wroteRemote: Bool
}

struct ExportSettings {
    static let audioOnlyModeKey = "export.audioOnlyMode"

    var localFolderBookmark: Data?
    var nextcloudBaseURL: URL?
    var nextcloudUsername: String?
    var nextcloudRemotePath: String
    var autoExportEnabled: Bool
    /// Decrypt + upload raw audio; skip on-device transcription / summary / poster.
    var audioOnlyMode: Bool
    var keyVault: KeyVault

    static func load(defaults: UserDefaults = .standard, keyVault: KeyVault = KeyVault()) -> ExportSettings {
        ExportSettings(
            localFolderBookmark: defaults.data(forKey: "export.localBookmark"),
            nextcloudBaseURL: defaults.string(forKey: "export.nextcloudURL").flatMap(URL.init(string:)),
            nextcloudUsername: defaults.string(forKey: "export.nextcloudUser"),
            nextcloudRemotePath: defaults.string(forKey: "export.nextcloudPath") ?? "PlaudLocal",
            autoExportEnabled: defaults.bool(forKey: "export.autoEnabled"),
            audioOnlyMode: defaults.bool(forKey: audioOnlyModeKey),
            keyVault: keyVault
        )
    }

    var hasExportDestination: Bool {
        if localFolderBookmark != nil { return true }
        guard let base = nextcloudBaseURL,
              let user = nextcloudUsername, !user.isEmpty,
              let pass = keyVault.load(account: "nextcloud.password"),
              !pass.isEmpty else {
            return false
        }
        return base.scheme != nil
    }
}

struct Exporter {
    var settings: ExportSettings
    var webDAVFactory: (URL, String, String) -> WebDAVClient = { base, user, pass in
        WebDAVClient(baseURL: base, username: user, password: pass)
    }
    /// Override for tests: treat this directory as the Files bookmark target.
    var localFolderOverride: URL?

    func export(_ note: NoteMetadata, store: NoteStore) async throws -> ExportResult {
        let packageName = packageFolderName(for: note)
        let noteDir = store.noteDirectory(id: note.id)
        let files = packageFileNames(for: note)
        var wroteLocal = false
        var wroteRemote = false

        if let destRoot = try resolveLocalFolder() {
            let dest = destRoot.appendingPathComponent(packageName, isDirectory: true)
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            try copyPackage(files: files, from: noteDir, to: dest)
            wroteLocal = true
        }

        if let base = settings.nextcloudBaseURL,
           let user = settings.nextcloudUsername,
           let passData = settings.keyVault.load(account: "nextcloud.password"),
           let pass = String(data: passData, encoding: .utf8),
           !pass.isEmpty {
            let client = webDAVFactory(base, user, pass)
            let remoteRoot = settings.nextcloudRemotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            try await client.ensureCollection(remoteRoot)
            try await client.ensureCollection("\(remoteRoot)/\(packageName)")
            for name in files {
                let file = noteDir.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                let data = try Data(contentsOf: file)
                try await client.upload(data: data, toPath: "\(remoteRoot)/\(packageName)/\(name)")
            }
            wroteRemote = true
        }

        return ExportResult(wroteLocal: wroteLocal, wroteRemote: wroteRemote)
    }

    func packageFolderName(for note: NoteMetadata) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        df.dateFormat = "yyyyMMdd_HHmm"
        let stamp = df.string(from: note.recordingDate)
        let safe = BriefBuilder.sanitizeFileComponent(note.title)
        return "\(stamp)_\(safe)"
    }

    func packageFileNames(for note: NoteMetadata) -> [String] {
        if settings.audioOnlyMode || note.audioOnlyExport {
            return ["audio.ogg", "metadata.json", "README.txt"]
        }
        var names = ["audio.ogg", "transcript.md", TranscriptDocument.fileName, "summary.md", "brief.json", "metadata.json"]
        if let poster = note.posterFileName {
            names.append(poster)
        }
        return names
    }

    private func resolveLocalFolder() throws -> URL? {
        if let localFolderOverride { return localFolderOverride }
        guard let bookmark = settings.localFolderBookmark else { return nil }
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        _ = url.startAccessingSecurityScopedResource()
        return url
    }

    private func copyPackage(files: [String], from source: URL, to dest: URL) throws {
        for name in files {
            let src = source.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
            let dst = dest.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: dst.path) {
                try FileManager.default.removeItem(at: dst)
            }
            try FileManager.default.copyItem(at: src, to: dst)
        }
    }
}
