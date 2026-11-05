import CoreBluetooth
import Foundation

struct DiscoveredPeripheral: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int
}

protocol BLEClienting: AnyObject {
    var discovered: AsyncStream<DiscoveredPeripheral> { get }
    func scan(duration: TimeInterval) async
    func stopScan()
    func connect(peripheralID: UUID) async throws
    func write(_ data: Data) async throws
    func notifications() -> AsyncStream<Data>
}

enum BLEClientError: Error {
    case bluetoothUnavailable
    case notConnected
    case peripheralNotFound
    case characteristicMissing
}

final class BLEClient: NSObject, BLEClienting {
    static let serviceUUID = CBUUID(string: "1910")
    static let notifyUUID = CBUUID(string: "2BB0")
    static let writeUUID = CBUUID(string: "2BB1")
    /// Plaud manufacturer company ID from Note Pro advertisements.
    static let plaudCompanyID: UInt16 = 0x005D

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var knownPeripherals: [UUID: CBPeripheral] = [:]
    private var writeChar: CBCharacteristic?
    private var notifyContinuation: AsyncStream<Data>.Continuation?
    private var discoverContinuation: AsyncStream<DiscoveredPeripheral>.Continuation?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var readyContinuation: CheckedContinuation<Void, Never>?

    private(set) lazy var discovered: AsyncStream<DiscoveredPeripheral> = {
        AsyncStream { continuation in
            self.discoverContinuation = continuation
        }
    }()

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func scan(duration: TimeInterval = 12) async {
        if central.state != .poweredOn {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                readyContinuation = cont
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.readyContinuation?.resume()
                    self?.readyContinuation = nil
                }
            }
        }
        guard central.state == .poweredOn else { return }

        // Note Pro often omits 1910 from the advertisement. Scan broadly, then filter.
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        stopScan()
    }

    func stopScan() {
        central.stopScan()
    }

    func connect(peripheralID: UUID) async throws {
        stopScan()
        guard let peripheral = knownPeripherals[peripheralID]
                ?? central.retrievePeripherals(withIdentifiers: [peripheralID]).first else {
            throw BLEClientError.peripheralNotFound
        }
        self.peripheral = peripheral
        knownPeripherals[peripheralID] = peripheral
        peripheral.delegate = self
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connectContinuation = cont
            central.connect(peripheral, options: nil)
        }
    }

    func write(_ data: Data) async throws {
        guard let peripheral, let writeChar else { throw BLEClientError.notConnected }
        let type: CBCharacteristicWriteType = writeChar.properties.contains(.write)
            ? .withResponse : .withoutResponse
        peripheral.writeValue(data, for: writeChar, type: type)
    }

    func notifications() -> AsyncStream<Data> {
        AsyncStream { continuation in
            self.notifyContinuation = continuation
        }
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

        // Manufacturer data: company ID 0x005D (little-endian bytes 0x5D 0x00)
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
        guard looksLikePlaud(peripheral, advertisementData: advertisementData) else { return }
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? "Plaud device"
        discoverContinuation?.yield(
            DiscoveredPeripheral(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
        )
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectContinuation?.resume(throwing: error ?? BLEClientError.bluetoothUnavailable)
        connectContinuation = nil
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        notifyContinuation?.finish()
        notifyContinuation = nil
    }
}

extension BLEClient: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            connectContinuation?.resume(throwing: BLEClientError.characteristicMissing)
            connectContinuation = nil
            return
        }
        peripheral.discoverCharacteristics([Self.notifyUUID, Self.writeUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        writeChar = service.characteristics?.first(where: { $0.uuid == Self.writeUUID })
        if let notify = service.characteristics?.first(where: { $0.uuid == Self.notifyUUID }) {
            peripheral.setNotifyValue(true, for: notify)
        }
        if writeChar != nil {
            connectContinuation?.resume()
            connectContinuation = nil
        } else {
            connectContinuation?.resume(throwing: BLEClientError.characteristicMissing)
            connectContinuation = nil
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else { return }
        notifyContinuation?.yield(value)
    }
}
