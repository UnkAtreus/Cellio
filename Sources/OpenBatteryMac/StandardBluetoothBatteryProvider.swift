import Foundation
import CoreBluetooth
import OpenBatteryCore

/// GUI-only owner. Construction checks no hardware and requests no permission.
/// The CoreBluetooth manager is created lazily by the core authorization gate.
final class NativeStandardBluetoothBatteryProvider: StandardBluetoothBatteryProviding {
    let polling: StandardBluetoothBatteryProvider
    private var timer: Timer?
    init(settings: DeviceSettingsStore) {
        polling = StandardBluetoothBatteryProvider(settings: settings, authorization: {
            switch CBManager.authorization {
            case .allowedAlways: return .authorized
            case .notDetermined: return .notDetermined
            case .denied: return .denied
            case .restricted: return .restricted
            @unknown default: return .restricted
            }
        }, makeTransport: { CoreBluetoothBatteryTransport(delivery: $0) })
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak polling] _ in polling?.expire() }
    }
    func refresh() { polling.refresh() }
    func requestAccessFromUserAction() { polling.requestAccessFromUserAction() }
    func stop() { timer?.invalidate(); timer = nil; polling.stop() }
    deinit { timer?.invalidate() }
}

/// The only native Bluetooth boundary. It has no vendor, scan, serial, subscribe,
/// pairing, or cancel/disconnect code paths. All delegates run on the main queue.
private final class CoreBluetoothBatteryTransport: NSObject, StandardBluetoothBatteryTransport, CBCentralManagerDelegate, CBPeripheralDelegate {
    private enum Operation { case connecting, services, characteristics, read }
    private static let battery = CBUUID(string: "180F")
    private static let hid = CBUUID(string: "1812")
    private static let level = CBUUID(string: "2A19")
    private var central: CBCentralManager!
    private let delivery: (BluetoothBatteryTransportEvent) -> Void
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var services: [UUID: CBService] = [:]
    private var levels: [UUID: CBCharacteristic] = [:]
    private var pendingReads: [UUID: CBCharacteristic] = [:]
    private var operations: [UUID: Operation] = [:]
    private(set) var availability: BluetoothBatteryAvailability = .starting

    init(delivery: @escaping (BluetoothBatteryTransportEvent) -> Void) {
        self.delivery = delivery
        super.init()
        central = CBCentralManager(delegate: self, queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }
    func retrieveConnected() -> [BluetoothBatteryPeripheral] {
        guard availability == .poweredOn else { return [] }
        var seen = Set<UUID>()
        // These are separate queries: the API matches ANY supplied service. HID
        // retrieval alone never proves BAS provenance for an unfamiliar device.
        let batteryCandidates = central.retrieveConnectedPeripherals(withServices: [Self.battery])
        let legacyCandidates = central.retrieveConnectedPeripherals(withServices: [Self.hid])
            .filter { StandardBluetoothBatteryProfile.includes(name: $0.name) }
        return (batteryCandidates.map { ($0, BluetoothBatteryPeripheral.Provenance.batteryServiceRetrieval) }
            + legacyCandidates.map { ($0, BluetoothBatteryPeripheral.Provenance.unverified) }).compactMap { peripheral, provenance in
            guard seen.insert(peripheral.identifier).inserted else { return nil }
            // Keep the same object/delegate while an outstanding callback drains.
            if peripherals[peripheral.identifier] == nil { peripherals[peripheral.identifier] = peripheral }
            return BluetoothBatteryPeripheral(uuid: peripheral.identifier,
                name: peripherals[peripheral.identifier]?.name, provenance: provenance)
        }
    }
    func connect(_ uuid: UUID) {
        guard operations[uuid] == nil, let peripheral = peripherals[uuid] else { return }
        operations[uuid] = .connecting
        peripheral.delegate = self
        if peripheral.state == .connected {
            operations.removeValue(forKey: uuid)
            delivery(.connected(uuid))
        }
        else { central.connect(peripheral, options: nil) }
    }
    func discoverBatteryService(_ uuid: UUID) {
        guard operations[uuid] == nil, let peripheral = peripherals[uuid] else { return }
        operations[uuid] = .services
        services.removeValue(forKey: uuid); levels.removeValue(forKey: uuid)
        peripheral.discoverServices([Self.battery])
    }
    func discoverBatteryLevel(_ uuid: UUID) {
        guard operations[uuid] == nil, let peripheral = peripherals[uuid], let service = services[uuid] else { return }
        operations[uuid] = .characteristics
        peripheral.discoverCharacteristics([Self.level], for: service)
    }
    func readBatteryLevel(_ uuid: UUID) {
        guard operations[uuid] == nil, pendingReads[uuid] == nil,
              let peripheral = peripherals[uuid], let service = services[uuid], let characteristic = levels[uuid],
              characteristic.uuid == Self.level, characteristic.service?.uuid == Self.battery,
              characteristic.service === service,
              characteristic.properties.contains(.read) else { return }
        operations[uuid] = .read
        pendingReads[uuid] = characteristic
        peripheral.readValue(for: characteristic)
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: availability = .poweredOn
        case .poweredOff: availability = .poweredOff
        case .unauthorized: availability = .unauthorized
        case .unsupported: availability = .unsupported
        case .resetting: availability = .resetting
        case .unknown: availability = .unknown
        @unknown default: availability = .unknown
        }
        delivery(.availability(availability))
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripherals[peripheral.identifier] === peripheral, operations[peripheral.identifier] == .connecting else { return }
        operations.removeValue(forKey: peripheral.identifier)
        delivery(.connected(peripheral.identifier))
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripherals[peripheral.identifier] === peripheral, operations[peripheral.identifier] == .connecting else { return }
        operations.removeValue(forKey: peripheral.identifier)
        delivery(.connectionFailed(peripheral.identifier, error.map(String.init(describing:)) ?? "Connection unavailable"))
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripherals[peripheral.identifier] === peripheral else { return }
        // Keep the outstanding operation and its exact objects until its callback drains.
        delivery(.disconnected(peripheral.identifier))
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripherals[peripheral.identifier] === peripheral, operations[peripheral.identifier] == .services else { return }
        operations.removeValue(forKey: peripheral.identifier)
        let candidates = peripheral.services?.filter { $0.uuid == Self.battery } ?? []
        if candidates.count == 1, error == nil { services[peripheral.identifier] = candidates[0] }
        delivery(.services(peripheral.identifier, count: candidates.count, error: error.map(String.init(describing:))))
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripherals[peripheral.identifier] === peripheral, operations[peripheral.identifier] == .characteristics,
              services[peripheral.identifier] === service,
              service.uuid == Self.battery else { return }
        operations.removeValue(forKey: peripheral.identifier)
        let candidates = service.characteristics?.filter { $0.uuid == Self.level } ?? []
        let readable = candidates.count == 1 && candidates[0].properties.contains(.read)
        if readable, error == nil { levels[peripheral.identifier] = candidates[0] }
        delivery(.batteryLevels(peripheral.identifier, count: candidates.count, readable: readable, error: error.map(String.init(describing:))))
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripherals[peripheral.identifier] === peripheral, operations[peripheral.identifier] == .read,
              pendingReads[peripheral.identifier] === characteristic, levels[peripheral.identifier] === characteristic,
              services[peripheral.identifier] === characteristic.service,
              characteristic.uuid == Self.level, characteristic.service?.uuid == Self.battery else { return }
        operations.removeValue(forKey: peripheral.identifier)
        pendingReads.removeValue(forKey: peripheral.identifier)
        // characteristic.value is accessed only inside this matching explicit Read callback.
        delivery(.value(peripheral.identifier, characteristic.value, error: error.map(String.init(describing:))))
    }
}
