import CoreBluetooth
import Foundation

struct DiscoveredPeripheral: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int
    let serial: String?
}

protocol BLEClienting: AnyObject {
    var discovered: AsyncStream<DiscoveredPeripheral> { get }
    /// Packets dropped because session decrypt/replay failed (diagnostic).
    var decryptDropCount: Int { get }
    var isLinkConnected: Bool { get }
    func scan(duration: TimeInterval) async
    func stopScan()
    func connect(peripheralID: UUID) async throws
    func disconnect()
    func write(_ data: Data) async throws
    func nextPacket(timeout: TimeInterval) async throws -> Data
    func clearPacketBuffer()
    /// Put a packet back at the front of the buffer (e.g. data that arrived while waiting for an ACK).
    func requeue(_ packet: Data)
    func setSession(_ crypto: SessionCrypto?)
    /// Current BLE session key material, if unlocked.
    var sessionMaterial: SessionKeyMaterial? { get }
    func serial(for peripheralID: UUID) -> String?
    /// Resolve a previously-seen peripheral without scanning (connected or retrieved by id).
    func resolveSavedPeripheral(id: UUID) -> UUID?
    /// Legacy stream of decrypted notifications (finishes on disconnect).
    func notifications() -> AsyncStream<Data>
}

enum BLEClientError: Error, LocalizedError {
    case bluetoothUnavailable
    case notConnected
    case peripheralNotFound
    case characteristicMissing
    case notifyNotEnabled
    case timeout
    case superseded

    var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable: return "Bluetooth unavailable"
        case .notConnected: return "Not connected"
        case .peripheralNotFound: return "Device not found"
        case .characteristicMissing: return "Plaud GATT characteristics missing"
        case .notifyNotEnabled: return "Device did not enable notifications"
        case .timeout: return "Timed out waiting for the device"
        case .superseded: return "Request superseded"
        }
    }
}

final class BLEClient: NSObject, BLEClienting {
    static let serviceUUID = CBUUID(string: "1910")
    static let notifyUUID = CBUUID(string: "2BB0")
    static let writeUUID = CBUUID(string: "2BB1")
    /// Plaud manufacturer company ID from Note Pro advertisements.
    static let plaudCompanyID: UInt16 = 0x005D

    /// Dedicated CB queue — keeping CoreBluetooth off the main thread avoids download
    /// UI/file work starving notifications (which caused offset gaps + resume storms).
    private let bleQueue = DispatchQueue(label: "com.local.plaudlocal.ble.central")
    private static let bleQueueKey = DispatchSpecificKey<UInt8>()
    private let packetLock = NSLock()

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var knownPeripherals: [UUID: CBPeripheral] = [:]
    private var serialByID: [UUID: String] = [:]
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var discoverContinuation: AsyncStream<DiscoveredPeripheral>.Continuation?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    /// Bumped per connect attempt so a stale timeout can't fail a newer attempt.
    private var connectGeneration: UInt64 = 0
    /// CoreBluetooth never times out `central.connect`; bound it so auto-connect can fall back to scanning.
    private static let connectTimeout: TimeInterval = 20
    private var readyContinuation: CheckedContinuation<Void, Never>?
    private var notifyEnabled = false

    private var packetBuffer: [Data] = []
    /// Single-flight packet waiter. Generation prevents a cancelled timeout from
    /// resuming a newer continuation (EXC_BAD_ACCESS / double-resume).
    private var packetWaiter: CheckedContinuation<Data, Error>?
    private var packetWaiterGeneration: UInt64 = 0
    private var packetTimeoutWork: DispatchWorkItem?
    private var notifyStreamContinuation: AsyncStream<Data>.Continuation?
    private var session: SessionCrypto?
    /// Serializes seal/open so CB notify floods and event-acks cannot clobber send/recv seq.
    private let sessionQueue = DispatchQueue(label: "com.local.plaudlocal.ble.session")
    private var writeChain: Task<Void, Never>?
    private(set) var decryptDropCount: Int = 0

    private(set) lazy var discovered: AsyncStream<DiscoveredPeripheral> = {
        AsyncStream { continuation in
            self.discoverContinuation = continuation
        }
    }()

    override init() {
        super.init()
        bleQueue.setSpecific(key: Self.bleQueueKey, value: 1)
        central = CBCentralManager(delegate: self, queue: bleQueue)
    }

    /// Run `body` on the CoreBluetooth queue. Safe to call from bleQueue (re-entrant).
    private func onBleQueue(_ body: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: Self.bleQueueKey) != nil {
            body()
        } else {
            bleQueue.async(execute: body)
        }
    }

    private func onBleQueueSync(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: Self.bleQueueKey) != nil {
            body()
        } else {
            bleQueue.sync(execute: body)
        }
    }

    func serial(for peripheralID: UUID) -> String? {
        serialByID[peripheralID]
    }

    var isLinkConnected: Bool {
        peripheral?.state == .connected && writeChar != nil && notifyEnabled
    }

    func setSession(_ crypto: SessionCrypto?) {
        sessionQueue.sync {
            session = crypto
            decryptDropCount = 0
        }
    }

    var sessionMaterial: SessionKeyMaterial? {
        sessionQueue.sync { session?.material }
    }

    func clearPacketBuffer() {
        onBleQueueSync {
            self.packetLock.lock()
            self.packetBuffer.removeAll()
            self.packetLock.unlock()
            self.failWaiter(BLEClientError.superseded)
        }
    }

    func requeue(_ packet: Data) {
        onBleQueueSync {
            self.packetLock.lock()
            self.packetBuffer.insert(packet, at: 0)
            self.packetLock.unlock()
        }
    }

    func disconnect() {
        stopScan()
        clearPacketBuffer()
        setSession(nil)
        notifyEnabled = false
        onBleQueue { [weak self] in
            guard let self else { return }
            self.failWaiter(BLEClientError.notConnected)
            self.finishConnect(throwing: BLEClientError.notConnected)
            if let peripheral = self.peripheral, peripheral.state != .disconnected {
                self.central.cancelPeripheralConnection(peripheral)
            }
            self.writeChar = nil
            self.notifyChar = nil
            self.peripheral = nil
        }
    }

    func scan(duration: TimeInterval = 12) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            bleQueue.async {
                if self.central.state == .poweredOn {
                    cont.resume()
                    return
                }
                self.readyContinuation = cont
                self.bleQueue.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self else { return }
                    self.readyContinuation?.resume()
                    self.readyContinuation = nil
                }
            }
        }
        let poweredOn: Bool = await withCheckedContinuation { cont in
            bleQueue.async { cont.resume(returning: self.central.state == .poweredOn) }
        }
        guard poweredOn else { return }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            bleQueue.async {
                self.central.scanForPeripherals(
                    withServices: nil,
                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
                )
                cont.resume()
            }
        }
        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        stopScan()
    }

    func stopScan() {
        bleQueue.async { self.central.stopScan() }
    }

    /// Prefer an already-connected link to `id`, then CoreBluetooth's retrieved peripheral for `id`.
    /// Never substitutes a different device: the caller's serial / sn-sign are tied to `id`.
    func resolveSavedPeripheral(id: UUID) -> UUID? {
        // retrieve* APIs are safe to call from any thread for identity lookup.
        let held = central.retrieveConnectedPeripherals(withServices: [Self.serviceUUID])
        if let match = held.first(where: { $0.identifier == id }) {
            knownPeripherals[match.identifier] = match
            return match.identifier
        }
        if let retrieved = central.retrievePeripherals(withIdentifiers: [id]).first {
            knownPeripherals[retrieved.identifier] = retrieved
            return retrieved.identifier
        }
        if let cached = knownPeripherals[id] {
            return cached.identifier
        }
        return nil
    }

    func connect(peripheralID: UUID) async throws {
        stopScan()
        clearPacketBuffer()
        // Protocol 20 session keys are per-link and must NOT be reused across reconnects.
        setSession(nil)
        notifyEnabled = false
        writeChain = nil

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            bleQueue.async {
                self.writeChar = nil
                self.notifyChar = nil
                // A previous attempt that never completed must not be left suspended.
                self.finishConnect(throwing: BLEClientError.superseded)

                let resolvedID = self.resolveSavedPeripheral(id: peripheralID) ?? peripheralID
                guard let peripheral = self.knownPeripherals[resolvedID]
                        ?? self.central.retrievePeripherals(withIdentifiers: [resolvedID]).first else {
                    cont.resume(throwing: BLEClientError.peripheralNotFound)
                    return
                }
                self.peripheral = peripheral
                self.knownPeripherals[peripheral.identifier] = peripheral
                peripheral.delegate = self
                self.connectContinuation = cont
                self.connectGeneration &+= 1
                let generation = self.connectGeneration
                self.bleQueue.asyncAfter(deadline: .now() + Self.connectTimeout) { [weak self] in
                    guard let self, self.connectGeneration == generation,
                          self.connectContinuation != nil else { return }
                    // Cancel the pending connection so it can't complete behind our back later.
                    self.central.cancelPeripheralConnection(peripheral)
                    self.finishConnect(throwing: BLEClientError.timeout)
                }

                if peripheral.state == .connected {
                    peripheral.discoverServices([Self.serviceUUID])
                } else {
                    self.central.connect(peripheral, options: nil)
                }
            }
        }
    }

    func write(_ data: Data) async throws {
        // Serialize seals so sendSeq stays monotonic even when event-acks overlap commands.
        let previous = writeChain
        let op = Task<Void, Error> {
            _ = await previous?.value
            try await self.writeNow(data)
        }
        writeChain = Task { _ = await op.result }
        try await op.value
    }

    private func writeNow(_ data: Data) async throws {
        let payload: Data = try sessionQueue.sync {
            if var crypto = session {
                let sealed = try crypto.seal(data)
                session = crypto
                return sealed
            }
            return data
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            bleQueue.async {
                guard let peripheral = self.peripheral,
                      let writeChar = self.writeChar,
                      peripheral.state == .connected else {
                    cont.resume(throwing: BLEClientError.notConnected)
                    return
                }
                let type: CBCharacteristicWriteType = writeChar.properties.contains(.writeWithoutResponse)
                    ? .withoutResponse
                    : .withResponse
                // If MTU is still negotiating, skip oversized writes rather than busy-wait on main.
                let mtu = peripheral.maximumWriteValueLength(for: type)
                if payload.count > mtu, mtu > 0 {
                    // Still try — CoreBluetooth will fragment or the device negotiated a larger ATT MTU.
                }
                peripheral.writeValue(payload, for: writeChar, type: type)
                cont.resume()
            }
        }
    }

    func nextPacket(timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            // All install/resume of the waiter happens on bleQueue so a stale
            // timeout can never race a newer wait (crash in _swift_release_dealloc).
            self.bleQueue.async {
                self.failWaiter(BLEClientError.superseded)

                self.packetLock.lock()
                if !self.packetBuffer.isEmpty {
                    let pkt = self.packetBuffer.removeFirst()
                    self.packetLock.unlock()
                    cont.resume(returning: pkt)
                    return
                }
                self.packetLock.unlock()

                guard self.peripheral?.state == .connected else {
                    cont.resume(throwing: BLEClientError.notConnected)
                    return
                }

                self.packetWaiterGeneration &+= 1
                let generation = self.packetWaiterGeneration
                let item = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    // Timeout callback may run after cancel; only the matching generation resumes.
                    self.bleQueue.async {
                        guard self.packetWaiterGeneration == generation else { return }
                        self.failWaiter(BLEClientError.timeout)
                    }
                }
                self.packetWaiter = cont
                self.packetTimeoutWork = item
                self.bleQueue.asyncAfter(deadline: .now() + timeout, execute: item)
            }
        }
    }

    func notifications() -> AsyncStream<Data> {
        AsyncStream { continuation in
            self.notifyStreamContinuation = continuation
        }
    }

    private func incoming(_ pkt: Data) {
        // Event pushes (cmd 19) are not answers to a request — ack and skip the waiter.
        if pkt.count >= 3, pkt[0] == 0x01,
           ProtocolCodec.commandID(of: pkt) == PlaudCommand.event.rawValue {
            if pkt.count >= 8, pkt[7] == 1 {
                let type = UInt16(pkt[3]) | (UInt16(pkt[4]) << 8)
                let seq = UInt16(pkt[5]) | (UInt16(pkt[6]) << 8)
                let ack = ProtocolCodec.packCommand(
                    PlaudCommand.event.rawValue,
                    params: ProtocolCodec.u16le(type) + ProtocolCodec.u16le(seq)
                )
                // Go through the serialized write chain (never seal off to the side).
                Task { try? await self.write(ack) }
            }
            notifyStreamContinuation?.yield(pkt)
            return
        }

        // CB callbacks already hop onto bleQueue; keep resume on that queue.
        let cont = takeWaiter()
        if let cont {
            cont.resume(returning: pkt)
        } else {
            packetLock.lock()
            packetBuffer.append(pkt)
            // Bound the buffer so a stalled consumer cannot OOM the app mid-transfer.
            if packetBuffer.count > 4_000 {
                packetBuffer.removeFirst(packetBuffer.count - 4_000)
            }
            packetLock.unlock()
        }
        notifyStreamContinuation?.yield(pkt)
    }

    /// Clear and return the current waiter (if any). Must run on `bleQueue`.
    private func takeWaiter() -> CheckedContinuation<Data, Error>? {
        packetTimeoutWork?.cancel()
        packetTimeoutWork = nil
        packetWaiterGeneration &+= 1
        let cont = packetWaiter
        packetWaiter = nil
        return cont
    }

    private func failWaiter(_ error: Error) {
        if let cont = takeWaiter() {
            cont.resume(throwing: error)
        }
    }

    /// Resume the pending `connect` exactly once. Must run on `bleQueue`.
    private func finishConnect(throwing error: Error? = nil) {
        guard let cont = connectContinuation else { return }
        connectContinuation = nil
        connectGeneration &+= 1
        if let error {
            cont.resume(throwing: error)
        } else {
            cont.resume()
        }
    }

    /// Manufacturer data serial (uppercase hex). Matches plaude-archiver heuristics.
    static func serial(fromManufacturerData data: Data) -> String? {
        let models = ["881", "888", "880", "882", "860"]
        let b = [UInt8](data)
        if b.count > 4 {
            let vAt = 3 + Int(b[2])
            if vAt < b.count {
                let sAt = vAt + 1 + Int(b[vAt])
                if sAt < b.count {
                    let sl = Int(b[sAt])
                    if sl >= 8, sl <= 10, sAt + 1 + sl <= b.count {
                        let s = b[(sAt + 1)..<(sAt + 1 + sl)].map { String(format: "%02X", $0) }.joined()
                        if models.contains(where: { s.hasPrefix($0) }) { return s }
                    }
                }
            }
        }
        let hex = data.map { String(format: "%02X", $0) }.joined()
        var i = hex.startIndex
        while let end = hex.index(i, offsetBy: 16, limitedBy: hex.endIndex) {
            let window = String(hex[i..<end])
            if models.contains(where: { window.hasPrefix($0) }) { return window }
            guard let next = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) else { break }
            i = next
        }
        return nil
    }

    private func looksLikePlaud(_ peripheral: CBPeripheral, advertisementData: [String: Any]) -> Bool {
        let name = (peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? "").lowercased()
        if name.contains("plaud") || name.contains("note") { return true }

        if let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID],
           serviceUUIDs.contains(Self.serviceUUID) {
            return true
        }

        if let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
           mfg.count >= 2 {
            let company = UInt16(mfg[0]) | (UInt16(mfg[1]) << 8)
            if company == Self.plaudCompanyID { return true }
        }
        return false
    }
}

extension BLEClient: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            readyContinuation?.resume()
            readyContinuation = nil
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        knownPeripherals[peripheral.identifier] = peripheral
        if let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
           let serial = Self.serial(fromManufacturerData: mfg) {
            serialByID[peripheral.identifier] = serial
        }
        guard looksLikePlaud(peripheral, advertisementData: advertisementData) else { return }
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? "Plaud device"
        discoverContinuation?.yield(
            DiscoveredPeripheral(
                id: peripheral.identifier,
                name: name,
                rssi: RSSI.intValue,
                serial: serialByID[peripheral.identifier]
            )
        )
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finishConnect(throwing: error ?? BLEClientError.bluetoothUnavailable)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        failWaiter(BLEClientError.notConnected)
        // Dropped (or cancelled) mid-connect: don't leave `connect` suspended forever.
        if peripheral.identifier == self.peripheral?.identifier || self.peripheral == nil {
            finishConnect(throwing: error ?? BLEClientError.notConnected)
        }
        notifyStreamContinuation?.finish()
        notifyStreamContinuation = nil
        session = nil
        notifyEnabled = false
    }
}

extension BLEClient: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            finishConnect(throwing: BLEClientError.characteristicMissing)
            return
        }
        peripheral.discoverCharacteristics([Self.notifyUUID, Self.writeUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        writeChar = service.characteristics?.first(where: { $0.uuid == Self.writeUUID })
        notifyChar = service.characteristics?.first(where: { $0.uuid == Self.notifyUUID })
        guard writeChar != nil, let notify = notifyChar else {
            finishConnect(throwing: BLEClientError.characteristicMissing)
            return
        }
        // Must enable notifications before the first write or the unlock reply is lost.
        peripheral.setNotifyValue(true, for: notify)
        let generation = connectGeneration
        bleQueue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.connectGeneration == generation,
                  self.connectContinuation != nil, !self.notifyEnabled else { return }
            self.finishConnect(throwing: BLEClientError.notifyNotEnabled)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == Self.notifyUUID else { return }
        if let error {
            finishConnect(throwing: error)
            return
        }
        guard characteristic.isNotifying else { return }
        notifyEnabled = true
        finishConnect()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else { return }
        let plain: Data? = sessionQueue.sync {
            if var crypto = session {
                do {
                    let inner = try crypto.open(value)
                    session = crypto
                    return inner
                } catch {
                    decryptDropCount += 1
                    return nil
                }
            }
            return value
        }
        if let plain {
            incoming(plain)
        }
    }
}
