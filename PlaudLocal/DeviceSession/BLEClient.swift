import CoreBluetooth
import Foundation

protocol BLEClienting: AnyObject {
    func scan() async
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

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyContinuation: AsyncStream<Data>.Continuation?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var readyContinuation: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func scan() async {
        if central.state != .poweredOn {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                readyContinuation = cont
            }
        }
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
    }

    func connect(peripheralID: UUID) async throws {
        guard let peripheral = central.retrievePeripherals(withIdentifiers: [peripheralID]).first else {
            throw BLEClientError.peripheralNotFound
        }
        self.peripheral = peripheral
        peripheral.delegate = self
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connectContinuation = cont
            central.connect(peripheral, options: nil)
        }
    }

    func write(_ data: Data) async throws {
        guard let peripheral, let writeChar else { throw BLEClientError.notConnected }
        peripheral.writeValue(data, for: writeChar, type: .withoutResponse)
    }

    func notifications() -> AsyncStream<Data> {
        AsyncStream { continuation in
            self.notifyContinuation = continuation
        }
    }
}

extension BLEClient: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            readyContinuation?.resume()
            readyContinuation = nil
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectContinuation?.resume(throwing: error ?? BLEClientError.bluetoothUnavailable)
        connectContinuation = nil
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
