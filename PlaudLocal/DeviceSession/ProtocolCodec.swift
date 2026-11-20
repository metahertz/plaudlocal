import Foundation

enum PlaudCommand: UInt16 {
    case handshake = 1
    case getSSN = 2
    /// Open device SoftAP for Wi‑Fi Fast Transfer (`isOTA u8` [+ optional 8-byte ASCII password]).
    case wifiOpen = 10
    /// Set websocket profile (URL / tokens) — point the device at the phone on LAN.
    case websocketSet = 0x11
    /// Test / nudge websocket client reconnect.
    case websocketTest = 0x12
    /// Close device SoftAP.
    case wifiClose = 13
    case getSessions = 26
    case syncStart = 28
    /// Device → app end-of-transfer tail; app → device stop request (same id).
    case syncTailOrStop = 29
    /// Delete recording on device (`session_id u32`). Response is `deleteFileRsp`.
    case deleteFile = 30
    case deleteFileRsp = 31
    case event = 19
    case fe10 = 0xFE10
    case fe11 = 0xFE11
    case fe12 = 0xFE12
    case fe30 = 0xFE30
}

enum PlaudPacket {
    case command(cmd: UInt16, fields: Data)
    case recordingData(sessionId: UInt32?, offset: UInt32, payload: Data)
    case fe(cmd: UInt16, total: Int, index: Int, payload: Data)
    case raw(Data)
}

enum ProtocolCodec {
    static func u16le(_ v: UInt16) -> Data {
        Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff)])
    }

    static func u32le(_ v: UInt32) -> Data {
        Data([
            UInt8(v & 0xff),
            UInt8((v >> 8) & 0xff),
            UInt8((v >> 16) & 0xff),
            UInt8((v >> 24) & 0xff),
        ])
    }

    /// `[0x01][cmd u16 LE][params]` — do not strip trailing zeros (bind token pads with `'0'`).
    static func packCommand(_ cmd: UInt16, params: Data = Data()) -> Data {
        var out = Data([0x01])
        out.append(u16le(cmd))
        out.append(params)
        return out
    }

    /// FE10/FE12 chunk: `[cmd u16][total u8][index u8][≤100 bytes]` (no 0x01 prefix).
    static func packFEChunk(_ cmd: UInt16, total: Int, index: Int, slice: Data) -> Data {
        var out = u16le(cmd)
        out.append(UInt8(total))
        out.append(UInt8(index))
        out.append(slice)
        return out
    }

    /// Handshake: `[02 00][second u8 if pv≥3][token padded to 16/32 with ASCII '0']`.
    static func packHandshake(token: String, portVersion: Int = 20, second: Bool = false) -> Data {
        let n = portVersion >= 9 ? 32 : 16
        var t = Array(token.utf8)
        if t.count < n {
            t += [UInt8](repeating: 0x30, count: n - t.count)
        }
        t = Array(t.prefix(n))
        var body: [UInt8] = [0x02, 0x00]
        if portVersion >= 3 {
            body.append(second ? 1 : 0)
        }
        return packCommand(PlaudCommand.handshake.rawValue, params: Data(body + t))
    }

    /// Get recording sessions (cmd 26): `[now u32][start u32][flag u8]`.
    static func packSessionList(start: UInt32 = 0, flag: UInt8 = 0) -> Data {
        let now = UInt32(Date().timeIntervalSince1970)
        return packCommand(
            PlaudCommand.getSessions.rawValue,
            params: u32le(now) + u32le(start) + Data([flag])
        )
    }

    /// Open SoftAP (cmd 10): `[isOTA u8]` or `[isOTA u8][password 8 ASCII]`.
    static func packWiFiOpen(isOTA: Bool = false, hotspotPassword: String? = nil) -> Data {
        var params = Data([isOTA ? 1 : 0])
        if let hotspotPassword {
            let ascii = Array(hotspotPassword.utf8)
            precondition(ascii.count == 8, "hotspot password must be exactly 8 ASCII bytes")
            params.append(contentsOf: ascii)
        }
        return packCommand(PlaudCommand.wifiOpen.rawValue, params: params)
    }

    /// Close SoftAP (cmd 13): `[isOTA u8]`.
    static func packWiFiClose(isOTA: Bool = false) -> Data {
        packCommand(PlaudCommand.wifiClose.rawValue, params: Data([isOTA ? 1 : 0]))
    }

    /// Parse bleWiFiOpen notify: status at byte 3, 12-byte ASCII password from byte 4.
    static func parseWiFiOpenResponse(_ packet: Data) -> (status: Int, password: String)? {
        guard packet.count >= 4, commandID(of: packet) == PlaudCommand.wifiOpen.rawValue else {
            return nil
        }
        let status = Int(packet[3])
        var password = ""
        if packet.count >= 16 {
            let raw = packet.subdata(in: 4..<16)
            password = String(bytes: raw, encoding: .ascii)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespaces))
                ?? ""
        }
        return (status, password)
    }

    /// Websocket profile types (SDK `WebsocketType`); wire value is raw+1.
    enum WebsocketProfileType: UInt8 {
        case url = 0
        case serToken = 1
        case devToken = 2
    }

    /// Set websocket profile (cmd 17): `[0x02][type+1 u8][content…]`.
    static func packSetWebsocketProfile(type: WebsocketProfileType, content: String) -> Data {
        var params = Data([0x02, type.rawValue &+ 1])
        params.append(Data(content.utf8))
        return packCommand(PlaudCommand.websocketSet.rawValue, params: params)
    }

    /// Nudge device to (re)connect its websocket client.
    static func packTestWebsocket() -> Data {
        packCommand(PlaudCommand.websocketTest.rawValue, params: Data())
    }

    static func commandID(of packet: Data) -> UInt16? {
        guard packet.count >= 3, packet[0] == 0x01 else { return nil }
        return UInt16(packet[1]) | (UInt16(packet[2]) << 8)
    }

    static func feCommandID(of packet: Data) -> UInt16? {
        guard packet.count >= 2 else { return nil }
        return UInt16(packet[0]) | (UInt16(packet[1]) << 8)
    }

    static func parseNotify(_ data: Data) -> PlaudPacket {
        guard !data.isEmpty else { return .raw(data) }

        // FE packets have no 0x01 prefix.
        if let fe = feCommandID(of: data),
           fe == PlaudCommand.fe10.rawValue
            || fe == PlaudCommand.fe11.rawValue
            || fe == PlaudCommand.fe12.rawValue
            || fe == PlaudCommand.fe30.rawValue {
            if data.count >= 4 {
                return .fe(
                    cmd: fe,
                    total: Int(data[2]),
                    index: Int(data[3]),
                    payload: data.count > 4 ? data.subdata(in: 4..<data.count) : Data()
                )
            }
            return .fe(cmd: fe, total: 0, index: 0, payload: Data())
        }

        switch data[0] {
        case 0x01:
            guard data.count >= 3 else { return .raw(data) }
            let cmd = UInt16(data[1]) | (UInt16(data[2]) << 8)
            let fields = data.count > 3 ? data.subdata(in: 3..<data.count) : Data()
            return .command(cmd: cmd, fields: fields)
        case 0x02:
            // Prefer session-id form (protocol ≥ 7); fall back to offset-only.
            if let parsed = parseRecordingData(data, expectedSession: nil, portVersion: 20) {
                return .recordingData(sessionId: parsed.sessionId, offset: parsed.offset, payload: parsed.payload)
            }
            return .raw(data)
        default:
            return .raw(data)
        }
    }

    /// Type-2 recording chunk. Matches plaude-archiver: session id present when `portVersion >= 7`.
    static func parseRecordingData(
        _ data: Data,
        expectedSession: UInt32?,
        portVersion: Int
    ) -> (sessionId: UInt32?, offset: UInt32, payload: Data)? {
        guard !data.isEmpty, data[0] == 0x02 else { return nil }
        var i = 1
        var sessionId: UInt32?
        if portVersion >= 7 {
            guard data.count >= 5 else { return nil }
            let sid = readUInt32(data, at: 1)
            if let expectedSession, sid != expectedSession { return nil }
            sessionId = sid
            i = 5
        }
        guard data.count >= i + 5 else { return nil }
        let offset = readUInt32(data, at: i)
        let n = Int(data[i + 4])
        let start = i + 5
        let end = min(start + n, data.count)
        let payload = start <= end ? data.subdata(in: start..<end) : Data()
        return (sessionId, offset, payload)
    }

    /// Sync-start (cmd 28) response status byte, or nil if packet is too short.
    static func syncStartStatus(of packet: Data) -> UInt8? {
        guard commandID(of: packet) == PlaudCommand.syncStart.rawValue, packet.count > 7 else {
            return nil
        }
        return packet[7]
    }

    /// Parse one cmd-26 reply into (total, index, entries). `portVersion` selects entry stride.
    static func parseSessionListPacket(
        _ packet: Data,
        portVersion: Int
    ) -> (total: Int?, index: Int, entries: [(sessionId: UInt32, size: UInt32)]) {
        guard packet.count >= 11, packet[0] == 0x01,
              commandID(of: packet) == PlaudCommand.getSessions.rawValue else {
            return (nil, 0, [])
        }
        let total = Int(packet[7]) | (Int(packet[8]) << 8)
        let index = Int(packet[9]) | (Int(packet[10]) << 8)
        let entry = portVersion == 1 ? 8 : (portVersion <= 6 ? 9 : 10)
        var entries: [(UInt32, UInt32)] = []
        var off = 11
        while off + entry <= packet.count {
            let sid = readUInt32(packet, at: off)
            let size = readUInt32(packet, at: off + 4)
            entries.append((sid, size))
            off += entry
        }
        return (total, index, entries)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
