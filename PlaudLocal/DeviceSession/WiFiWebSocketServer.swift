import CryptoKit
import Foundation
import Network

/// Minimal WebSocket server on TCP :8081 for Plaud SoftAP Fast Transfer.
/// Device connects as client; we speak standard RFC6455 binary frames.
final class WiFiWebSocketServer: @unchecked Sendable {
    private let port: NWEndpoint.Port
    private var listener: NWListener?
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.local.plaudlocal.wifi.ws")
    private var rxBuffer = Data()
    /// Frames are delivered through one ordered stream + one consumer task. A Task per frame
    /// let frames overtake each other, which the sequence-checked crypto then rejected.
    private var frameContinuation: AsyncStream<Data>.Continuation?
    private var frameTask: Task<Void, Never>?
    private var acceptContinuation: CheckedContinuation<Void, Error>?
    private(set) var isClientConnected = false

    init(port: UInt16 = 8081) {
        self.port = NWEndpoint.Port(rawValue: port)!
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: port)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in
            self?.queue.async { self?.accept(conn) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let err) = state {
                self?.queue.async {
                    self?.failAccept(err)
                }
            }
        }
        listener.start(queue: queue)
    }

    func waitForClient(timeout: TimeInterval) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.queue.async {
                    if self.isClientConnected {
                        cont.resume()
                        return
                    }
                    self.acceptContinuation = cont
                    // Timeout resumes the continuation directly; nothing else has to finish first.
                    self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                        self?.failAccept(
                            WiFiTransferError.timeout("Device did not connect to Wi‑Fi transfer port")
                        )
                    }
                }
            }
        } onCancel: {
            self.cancelWaitForClient(CancellationError())
        }
    }

    /// Abort a pending `waitForClient` (user cancel / task cancellation).
    func cancelWaitForClient(_ error: Error) {
        queue.async { self.failAccept(error) }
    }

    func setBinaryHandler(_ handler: @escaping (Data) async -> Void) {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let task = Task {
            for await payload in stream {
                await handler(payload)
            }
        }
        queue.async {
            self.frameContinuation?.finish()
            self.frameTask?.cancel()
            self.frameContinuation = continuation
            self.frameTask = task
        }
    }

    func sendBinary(_ payload: Data) {
        queue.async {
            guard let connection = self.connection else { return }
            let frame = Self.encodeServerBinaryFrame(payload)
            connection.send(content: frame, completion: .contentProcessed { _ in })
        }
    }

    func stop() {
        queue.async {
            self.connection?.cancel()
            self.connection = nil
            self.listener?.cancel()
            self.listener = nil
            self.isClientConnected = false
            self.rxBuffer.removeAll()
            self.frameContinuation?.finish()
            self.frameContinuation = nil
            self.frameTask = nil
            if let cont = self.acceptContinuation {
                self.acceptContinuation = nil
                cont.resume(throwing: CancellationError())
            }
        }
    }

    // MARK: - Accept / handshake

    private func accept(_ conn: NWConnection) {
        if connection != nil {
            conn.cancel()
            return
        }
        connection = conn
        rxBuffer.removeAll()
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                self.queue.async {
                    self.isClientConnected = false
                    if self.connection === conn {
                        self.connection = nil
                    }
                }
            default:
                break
            }
        }
        conn.start(queue: queue)
        receive(on: conn)
    }

    private func failAccept(_ error: Error) {
        if let cont = acceptContinuation {
            acceptContinuation = nil
            cont.resume(throwing: error)
        }
    }

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                if let data, !data.isEmpty {
                    self.rxBuffer.append(data)
                    self.pump(conn)
                }
                if isComplete || error != nil {
                    self.isClientConnected = false
                    if self.connection === conn {
                        self.connection = nil
                    }
                    return
                }
                self.receive(on: conn)
            }
        }
    }

    private func pump(_ conn: NWConnection) {
        if !isClientConnected {
            if let range = rxBuffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = rxBuffer.subdata(in: 0..<range.upperBound)
                rxBuffer.removeSubrange(0..<range.upperBound)
                guard let header = String(data: headerData, encoding: .utf8),
                      let key = Self.secWebSocketKey(from: header) else {
                    conn.cancel()
                    return
                }
                let accept = Self.acceptKey(for: key)
                let response = """
                HTTP/1.1 101 Switching Protocols\r
                Upgrade: websocket\r
                Connection: Upgrade\r
                Sec-WebSocket-Accept: \(accept)\r
                \r\n
                """
                conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in })
                isClientConnected = true
                if let cont = acceptContinuation {
                    acceptContinuation = nil
                    cont.resume()
                }
            } else {
                return
            }
        }

        while let (payload, consumed) = Self.decodeClientFrame(from: rxBuffer) {
            rxBuffer.removeSubrange(0..<consumed)
            if let payload {
                frameContinuation?.yield(payload)
            }
        }
    }

    // MARK: - Framing

    private static func secWebSocketKey(from headers: String) -> String? {
        for line in headers.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            if parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "sec-websocket-key" {
                return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func acceptKey(for clientKey: String) -> String {
        let combined = Data((clientKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)
        let digest = Insecure.SHA1.hash(data: combined)
        return Data(digest).base64EncodedString()
    }

    static func encodeServerBinaryFrame(_ payload: Data) -> Data {
        var out = Data([0x82])
        let len = payload.count
        if len < 126 {
            out.append(UInt8(len))
        } else if len <= Int(UInt16.max) {
            out.append(126)
            out.append(UInt8((len >> 8) & 0xff))
            out.append(UInt8(len & 0xff))
        } else {
            out.append(127)
            var be = UInt64(len).bigEndian
            withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
        }
        out.append(payload)
        return out
    }

    static func decodeClientFrame(from buffer: Data) -> (Data?, Int)? {
        guard buffer.count >= 2 else { return nil }
        let b0 = buffer[0]
        let b1 = buffer[1]
        let opcode = b0 & 0x0f
        let masked = (b1 & 0x80) != 0
        var len = Int(b1 & 0x7f)
        var offset = 2
        if len == 126 {
            guard buffer.count >= 4 else { return nil }
            len = (Int(buffer[2]) << 8) | Int(buffer[3])
            offset = 4
        } else if len == 127 {
            guard buffer.count >= 10 else { return nil }
            len = 0
            for i in 0..<8 { len = (len << 8) | Int(buffer[2 + i]) }
            offset = 10
        }
        let maskLen = masked ? 4 : 0
        guard buffer.count >= offset + maskLen + len else { return nil }
        var payload = Data(buffer[(offset + maskLen)..<(offset + maskLen + len)])
        if masked {
            let mask = buffer.subdata(in: offset..<(offset + 4))
            for i in 0..<payload.count {
                payload[i] ^= mask[i % 4]
            }
        }
        let consumed = offset + maskLen + len
        switch opcode {
        case 0x1, 0x2:
            return (payload, consumed)
        default:
            return (nil, consumed)
        }
    }
}
