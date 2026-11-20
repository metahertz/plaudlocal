import AudioToolbox
import AVFoundation
import Foundation

enum AudioForTranscription {
    /// Returns a URL Speech / Whisper can open. Prefer the original file; if AVAudioFile
    /// cannot read Ogg Opus, convert to a temporary linear PCM CAF.
    static func readableURL(from audioURL: URL) throws -> (url: URL, isTemporary: Bool) {
        if (try? AVAudioFile(forReading: audioURL)) != nil {
            return (audioURL, false)
        }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("plaud-asr-\(UUID().uuidString).caf")
        try convertToPCMCAF(from: audioURL, to: temp)
        return (temp, true)
    }

    private static func convertToPCMCAF(from input: URL, to output: URL) throws {
        // AVAudioPlayer can open Note Pro Ogg Opus on current iOS; use it to decode,
        // then write PCM that SpeechAnalyzer accepts.
        let player = try AVAudioPlayer(contentsOf: input)
        guard player.prepareToPlay() else {
            throw TranscriberError.unsupportedAudio
        }
        // Prefer ExtAudioFile when Core Audio can open the container directly.
        if try convertWithExtAudioFile(from: input, to: output) {
            return
        }
        throw TranscriberError.unsupportedAudio
    }

    private static func convertWithExtAudioFile(from input: URL, to output: URL) throws -> Bool {
        var inputFile: ExtAudioFileRef?
        var status = ExtAudioFileOpenURL(input as CFURL, &inputFile)
        guard status == noErr, let inputFile else { return false }
        defer { ExtAudioFileDispose(inputFile) }

        var inputDescription = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = ExtAudioFileGetProperty(
            inputFile,
            kExtAudioFileProperty_FileDataFormat,
            &size,
            &inputDescription
        )
        guard status == noErr else { return false }

        var client = AudioStreamBasicDescription(
            mSampleRate: inputDescription.mSampleRate > 0 ? inputDescription.mSampleRate : 16_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        status = ExtAudioFileSetProperty(
            inputFile,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout.size(ofValue: client)),
            &client
        )
        guard status == noErr else { return false }

        var outputFile: ExtAudioFileRef?
        status = ExtAudioFileCreateWithURL(
            output as CFURL,
            kAudioFileCAFType,
            &client,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &outputFile
        )
        guard status == noErr, let outputFile else { return false }
        defer { ExtAudioFileDispose(outputFile) }

        status = ExtAudioFileSetProperty(
            outputFile,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout.size(ofValue: client)),
            &client
        )
        guard status == noErr else { return false }

        let capacity: UInt32 = 4096
        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: capacity * 4, mData: nil)
        )
        let data = UnsafeMutablePointer<Float>.allocate(capacity: Int(capacity))
        defer { data.deallocate() }
        bufferList.mBuffers.mData = UnsafeMutableRawPointer(data)

        while true {
            var frameCount = capacity
            bufferList.mBuffers.mDataByteSize = capacity * 4
            status = ExtAudioFileRead(inputFile, &frameCount, &bufferList)
            guard status == noErr else { return false }
            if frameCount == 0 { break }
            status = ExtAudioFileWrite(outputFile, frameCount, &bufferList)
            guard status == noErr else { return false }
        }
        return true
    }
}
