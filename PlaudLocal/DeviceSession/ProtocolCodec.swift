import Foundation

enum PlaudCommand: UInt16 {
    case handshake = 1
    case getSessions = 26
    case syncStart = 28
    case syncStop = 29
}

enum PlaudPacket {
    case command(cmd: UInt16, fields: Data)
    case recordingData(sessionId: UInt32?, offset: UInt32, payload: Data)
    case raw(Data)
}

enum ProtocolCodec {
    static func packCommand(_ cmd: UInt16, params: Data) -> Data {
        var out = Data([0x01])
        out.append(contentsOf: withUnsafeBytes(of: cmd.littleEndian) { Data($0) })
        out.append(params)
        while out.count > 3, out.last == 0 {
            out.removeLast()
        }
        return out
    }

    static func parseNotify(_ data: Data) -> PlaudPacket {
        guard !data.isEmpty else { return .raw(data) }
        switch data[0] {
        case 0x01:
            guard data.count >= 3 else { return .raw(data) }
            let cmd = UInt16(data[1]) | (UInt16(data[2]) << 8)
            let fields = data.count > 3 ? data.subdata(in: 3..<data.count) : Data()
            return .command(cmd: cmd, fields: fields)
        case 0x02:
            // Protocol >= 7 includes sessionId before offset.
            if data.count >= 10 {
                let sessionId = readUInt32(data, at: 1)
                let offset = readUInt32(data, at: 5)
                let len = Int(data[9])
                let start = 10
                let end = min(start + len, data.count)
                return .recordingData(sessionId: sessionId, offset: offset, payload: data.subdata(in: start..<end))
            }
            if data.count >= 6 {
                let offset = readUInt32(data, at: 1)
                let len = Int(data[5])
                let start = 6
                let end = min(start + len, data.count)
                return .recordingData(sessionId: nil, offset: offset, payload: data.subdata(in: start..<end))
            }
            return .raw(data)
        default:
            return .raw(data)
        }
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
