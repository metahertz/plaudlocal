import AVFoundation
import Foundation

enum AudioDuration {
    /// Best-effort duration in whole seconds from a playable audio file.
    static func seconds(at url: URL) -> Int? {
        if let player = try? AVAudioPlayer(contentsOf: url) {
            let d = player.duration
            if d.isFinite, d > 0.5 {
                return max(1, Int(d.rounded()))
            }
        }
        let asset = AVURLAsset(url: url)
        let d = asset.duration
        if d.isValid, !d.isIndefinite {
            let secs = CMTimeGetSeconds(d)
            if secs.isFinite, secs > 0.5 {
                return max(1, Int(secs.rounded()))
            }
        }
        return nil
    }

    /// Prefer PLAUD header duration; fall back to measuring the decrypted audio file.
    static func resolve(headerSeconds: Int?, audioURL: URL) -> Int {
        if let headerSeconds, headerSeconds > 0 { return headerSeconds }
        return seconds(at: audioURL) ?? 0
    }
}
