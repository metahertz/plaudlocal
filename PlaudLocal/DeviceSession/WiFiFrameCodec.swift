import Foundation

/// Wi‑Fi Fast Transfer PDU types (matches Plaud SDK WifiRequest / WifiResponse).
enum WiFiPDUType: UInt16 {
    case universalErr = 0
    case handshake = 1
    case sayHello = 2
    case heartbeat = 3
    case wifiClose = 4
    case getFileList = 11
    case fileSync = 12
    case fileSyncContent = 13
    case fileDelete = 14
    case fileSyncStop = 15
}

struct WiFiPDU {
    var type: WiFiPDUType
    var json: [String: Any]
    /// Binary payload after the JSON (file list entries or sync content).
    var binary: Data

    /// Wire header: `[total_len u16][0x01][0x01][type u16][json_len u16][json…][binary…]`.
    func encode() throws -> Data {
        let jsonData = try JSONSerialization.data(withJSONObject: json, options: [])
        guard jsonData.count <= Int(UInt16.max) else {
            throw WiFiTransferError.protocolError("JSON too large")
        }
        let total = 8 + jsonData.count + binary.count
        guard total <= Int(UInt16.max) else {
            throw WiFiTransferError.protocolError("PDU too large")
        }
        var out = Data()
        out.append(ProtocolCodec.u16le(UInt16(total)))
        out.append(contentsOf: [0x01, 0x01])
        out.append(ProtocolCodec.u16le(type.rawValue))
        out.append(ProtocolCodec.u16le(UInt16(jsonData.count)))
        out.append(jsonData)
        out.append(binary)
        return out
    }

    static func decode(_ data: Data) throws -> WiFiPDU {
        guard data.count >= 8 else {
            throw WiFiTransferError.protocolError("PDU too short")
        }
        let total = Int(data[0]) | (Int(data[1]) << 8)
        let typeRaw = UInt16(data[4]) | (UInt16(data[5]) << 8)
        let jsonLen = Int(data[6]) | (Int(data[7]) << 8)
        guard let type = WiFiPDUType(rawValue: typeRaw) else {
            throw WiFiTransferError.protocolError("Unknown PDU type \(typeRaw)")
        }
        guard data.count >= 8 + jsonLen else {
            throw WiFiTransferError.protocolError("PDU truncated (json)")
        }
        let jsonSlice = data.subdata(in: 8..<(8 + jsonLen))
        let jsonObj: [String: Any]
        if jsonLen == 0 {
            jsonObj = [:]
        } else {
            let any = try JSONSerialization.jsonObject(with: jsonSlice, options: [])
            guard let dict = any as? [String: Any] else {
                throw WiFiTransferError.protocolError("JSON root is not an object")
            }
            jsonObj = dict
        }
        let binaryStart = 8 + jsonLen
        let binaryEnd = min(max(total, binaryStart), data.count)
        let binary = binaryStart < binaryEnd
            ? data.subdata(in: binaryStart..<binaryEnd)
            : Data()
        return WiFiPDU(type: type, json: jsonObj, binary: binary)
    }

    /// File-list binary after JSON: repeated `[sessionId u32][size u32]`.
    static func parseFileListBinary(_ binary: Data) -> [(sessionId: UInt32, size: UInt32)] {
        var entries: [(UInt32, UInt32)] = []
        var off = 0
        while off + 8 <= binary.count {
            let sid = UInt32(binary[off])
                | (UInt32(binary[off + 1]) << 8)
                | (UInt32(binary[off + 2]) << 16)
                | (UInt32(binary[off + 3]) << 24)
            let size = UInt32(binary[off + 4])
                | (UInt32(binary[off + 5]) << 8)
                | (UInt32(binary[off + 6]) << 16)
                | (UInt32(binary[off + 7]) << 24)
            entries.append((sid, size))
            off += 8
        }
        return entries
    }

    static func padToken(_ token: String) -> String {
        if token.count >= 32 { return String(token.prefix(32)) }
        return token + String(repeating: "0", count: 32 - token.count)
    }

    static func handshakeRequest(token: String, stamp: Int = Int(Date().timeIntervalSince1970)) -> WiFiPDU {
        WiFiPDU(
            type: .handshake,
            json: ["token": padToken(token), "stamp": stamp],
            binary: Data()
        )
    }

    static func helloAck(token: String) -> WiFiPDU {
        WiFiPDU(type: .sayHello, json: ["token": padToken(token)], binary: Data())
    }

    static func heartbeatPong(stamp: Int = Int(Date().timeIntervalSince1970)) -> WiFiPDU {
        WiFiPDU(type: .heartbeat, json: ["stamp": stamp], binary: Data())
    }

    static func getFileList(uid: Int = Int(Date().timeIntervalSince1970), start: Int = 0, single: Bool = false) -> WiFiPDU {
        WiFiPDU(
            type: .getFileList,
            json: ["uid": uid, "start": start, "single": single ? 1 : 0],
            binary: Data()
        )
    }

    static func fileSync(sessionId: UInt32, scene: Int = 1, start: Int = 0, end: Int = 0) -> WiFiPDU {
        WiFiPDU(
            type: .fileSync,
            json: [
                "session": Int(sessionId),
                "scene": scene,
                "start": start,
                "end": end,
            ],
            binary: Data()
        )
    }

    static func fileSyncStop(sessionId: UInt32, scene: Int = 1) -> WiFiPDU {
        WiFiPDU(
            type: .fileSyncStop,
            json: ["session": Int(sessionId), "scene": scene],
            binary: Data()
        )
    }

    static func fileDelete(sessionId: UInt32, scene: Int = 1) -> WiFiPDU {
        WiFiPDU(
            type: .fileDelete,
            json: ["session": Int(sessionId), "scene": scene],
            binary: Data()
        )
    }
}
