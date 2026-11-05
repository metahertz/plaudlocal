import Foundation

struct NotePipeline {
    var store: NoteStore
    var transcriber: any Transcribing
    var summarizer: any Summarizing
    var exporter: Exporter
    var decrypt: (Data, String) throws -> Data = FileDecryptor.decrypt
    var privateKeyPEMProvider: () -> String? = {
        guard let data = KeyVault().load(account: "plaud.rsaPrivatePEM") else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func processDownloadedFile(_ url: URL, sessionId: UInt32, duration: Int) async throws -> NoteMetadata {
        let encrypted = try Data(contentsOf: url)
        guard let pem = privateKeyPEMProvider() else {
            throw FileDecryptorError.needsReSignIn
        }
        let audio: Data
        do {
            audio = try decrypt(encrypted, pem)
        } catch FileDecryptorError.needsReSignIn, FileDecryptorError.rsaFailed {
            throw FileDecryptorError.needsReSignIn
        }

        var meta = try store.createNote(fromDecryptedAudio: audio, sessionId: sessionId, duration: duration)

        meta.transcriptStatus = .running
        try store.updateMetadata(meta)
        let audioURL = store.noteDirectory(id: meta.id).appendingPathComponent(meta.audioFileName)
        let transcript = try await transcriber.transcribe(audioURL: audioURL)
        try store.writeTranscript(noteId: meta.id, text: transcript)
        meta.transcriptStatus = .done
        try store.updateMetadata(meta)

        meta.summaryStatus = .running
        try store.updateMetadata(meta)
        switch try await summarizer.summarize(transcript: transcript) {
        case let .text(summary):
            try store.writeSummary(noteId: meta.id, text: summary)
            meta.summaryStatus = .done
        case .unavailable:
            meta.summaryStatus = .skipped
        }
        try store.updateMetadata(meta)

        if exporter.settings.autoExportEnabled {
            meta.exportStatus = .running
            try store.updateMetadata(meta)
            do {
                let result = try await exporter.export(meta, store: store)
                meta.exportStatus = (result.wroteLocal || result.wroteRemote) ? .done : .skipped
            } catch {
                meta.exportStatus = .failed
            }
            try store.updateMetadata(meta)
        }

        return meta
    }
}
