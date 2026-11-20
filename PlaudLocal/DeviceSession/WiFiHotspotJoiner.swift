import Foundation

/// SoftAP join helper.
///
/// Official Plaud Fast Transfer opens a device SoftAP; the phone joins it.
/// `NEHotspotConfiguration` needs the Hotspot Configuration entitlement, which
/// personal Apple Developer teams cannot use — so we show SSID/password and wait
/// for a manual join in Settings while our WebSocket server listens on :8081.
enum WiFiHotspotJoiner {
    static func manualJoinMessage(ssid: String, password: String) -> String {
        "Join Wi‑Fi “\(ssid)” (password \(password)) in Settings, then return. Transfer starts automatically."
    }
}
