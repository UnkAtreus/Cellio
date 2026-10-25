import XCTest
@testable import OpenBatteryCore

final class StandardBluetoothBatteryTests: XCTestCase {
    private final class Clock: BatteryClock {
        var time = Date(timeIntervalSince1970: 1_800_000_000)
        func now() -> Date { time }
        func advance(_ seconds: TimeInterval = 1) { time.addTimeInterval(seconds) }
    }
    private final class Transport: StandardBluetoothBatteryTransport {
        var availability: BluetoothBatteryAvailability = .poweredOn
        var connected: [BluetoothBatteryPeripheral] = []
        var commands: [String] = []
        var delivery: ((BluetoothBatteryTransportEvent) -> Void)?
        func retrieveConnected() -> [BluetoothBatteryPeripheral] { commands.append("retrieve"); return connected }
        func connect(_ uuid: UUID) { commands.append("connect:\(uuid)") }
        func discoverBatteryService(_ uuid: UUID) { commands.append("service:\(uuid)") }
        func discoverBatteryLevel(_ uuid: UUID) { commands.append("level:\(uuid)") }
        func readBatteryLevel(_ uuid: UUID) { commands.append("read:\(uuid)") }
        var readCount: Int { commands.filter { $0.hasPrefix("read:") }.count }
        var connectionCount: Int { commands.filter { $0.hasPrefix("connect:") }.count }
        func send(_ event: BluetoothBatteryTransportEvent) { delivery?(event) }
    }
    private final class Fixture {
        let uuid = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let clock = Clock()
        let settings = DeviceSettingsStore()
        let transport = Transport()
        var authorization: BluetoothBatteryAuthorization = .authorized
        var factories = 0
        var updates: [StandardBluetoothBatteryUpdate] = []
        var reducer = BatteryReducer()
        var provider: StandardBluetoothBatteryProvider!
        var id: String { StandardBluetoothBatteryProfile.identity(uuid) }
        var record: BatteryRecord? { reducer.records[ComponentID(device: id)] }
        init() {
            transport.connected = [BluetoothBatteryPeripheral(uuid: uuid, name: "Maxfit8")]
            provider = StandardBluetoothBatteryProvider(settings: settings, clock: clock, timeout: 15,
                authorization: { [unowned self] in self.authorization },
                makeTransport: { [unowned self] delivery in
                    self.factories += 1; self.transport.delivery = delivery; return self.transport
                })
            provider.completion = { [unowned self] update in
                self.updates.append(update)
                if let o = update.observation, self.settings.accepts(o.id.device, from: update.context) {
                    self.reducer.apply(o, now: self.clock.now())
                }
            }
        }
        func beginRead() {
            provider.refresh()
            transport.send(.connected(uuid))
            transport.send(.services(uuid, count: 1, error: nil))
            transport.send(.batteryLevels(uuid, count: 1, readable: true, error: nil))
        }
        func valid(_ byte: UInt8 = 65) {
            beginRead(); clock.advance()
            transport.send(.value(uuid, Data([byte]), error: nil))
        }
    }

    func testStrictDecoderAndLiteralProfile() {
        XCTAssertEqual(StandardBluetoothBatteryProfile.percent(Data([0])), 0)
        XCTAssertEqual(StandardBluetoothBatteryProfile.percent(Data([100])), 100)
        for bytes: [UInt8] in [[], [101], [255], [0, 0], [65, 0]] {
            XCTAssertNil(StandardBluetoothBatteryProfile.percent(Data(bytes)))
        }
        for name in ["Maxfit8", "MAXFIT8", "mAxFiT8"] { XCTAssertTrue(StandardBluetoothBatteryProfile.includes(name: name)) }
        for name in [nil, "Maxfit80", " Maxfit8", "Maxfit8 ", "My Maxfit8", "DMK921", "HS_DG_WH_V01"] {
            XCTAssertFalse(StandardBluetoothBatteryProfile.includes(name: name))
        }
    }

    func testOpaqueStableUUIDIdentityAndIndependentSameNameDevices() {
        let f = Fixture(), second = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        XCTAssertEqual(f.id, StandardBluetoothBatteryProfile.identity(f.uuid))
        XCTAssertTrue(f.id.hasPrefix("standard-bluetooth-"))
        XCTAssertFalse(f.id.contains(f.uuid.uuidString.lowercased()))
        XCTAssertNotEqual(f.id, StandardBluetoothBatteryProfile.identity(second))
        f.transport.connected.append(BluetoothBatteryPeripheral(uuid: second, name: "MAXFIT8"))
        f.transport.connected.append(BluetoothBatteryPeripheral(uuid: UUID(), name: "DMK921"))
        f.provider.refresh()
        XCTAssertEqual(f.settings.devices.count, 2)
        XCTAssertEqual(f.transport.connectionCount, 2)
        XCTAssertTrue(f.settings.devices.allSatisfy { $0.source == .standardBluetooth })
    }

    func testNoAutomaticConsentAtConstructionRefreshResumeOrDeniedExplicitAction() {
        let f = Fixture(); f.authorization = .notDetermined
        XCTAssertEqual(f.factories, 0)
        for _ in 0..<3 { f.provider.refresh(); f.provider.expire() }
        XCTAssertEqual(f.factories, 0)
        XCTAssertNil(f.record)
        XCTAssertEqual(f.provider.presentationState.authorization, .notDetermined)
        XCTAssertFalse(f.provider.presentationState.awaitingPermission)
        XCTAssertTrue(f.transport.commands.isEmpty, "Passive inspection must not request permission or perform Bluetooth operations")
        f.authorization = .denied; f.provider.requestAccessFromUserAction()
        XCTAssertEqual(f.factories, 0)
        XCTAssertTrue(f.updates.last?.status.contains("denied") == true)
        f.authorization = .restricted; f.provider.requestAccessFromUserAction()
        XCTAssertEqual(f.factories, 0)
        f.authorization = .notDetermined; f.provider.requestAccessFromUserAction()
        XCTAssertEqual(f.factories, 1)
        XCTAssertTrue(f.transport.commands.isEmpty, "Creating a manager for consent does not yet permit battery operations")
        f.authorization = .authorized; f.transport.send(.availability(.poweredOn))
        XCTAssertEqual(f.transport.connectionCount, 1)
    }

    func testAuthorizedManagerInitializationWaitsForPoweredOn() {
        let f = Fixture(); f.transport.availability = .starting
        f.provider.refresh()
        XCTAssertEqual(f.factories, 1); XCTAssertTrue(f.transport.commands.isEmpty)
        f.transport.availability = .poweredOn; f.transport.send(.availability(.poweredOn))
        XCTAssertEqual(f.transport.connectionCount, 1)
        f.provider.refresh(); XCTAssertEqual(f.transport.connectionCount, 1)
    }

    func testValidReadHasCallbackTimeUnknownChargingAndNoSensorTimesIncludingZero() throws {
        let f = Fixture()
        f.beginRead()
        XCTAssertNil(f.record, "Discovery is not a battery quantity")
        let readTime = f.clock.now(); f.clock.advance(7)
        f.transport.send(.value(f.uuid, Data([0]), error: nil))
        let r = try XCTUnwrap(f.record)
        XCTAssertEqual(r.observation.quantity, .reportedPercent(0))
        XCTAssertEqual(r.observation.observedAt, f.clock.now())
        XCTAssertNotEqual(r.observation.observedAt, readTime)
        XCTAssertEqual(r.observation.collectedAt, f.clock.now())
        XCTAssertNil(r.observation.measuredAt); XCTAssertNil(r.observation.sampleMeasuredAt)
        XCTAssertEqual(r.observation.charge, .unknown)
        XCTAssertEqual(r.observation.connection, .connected)
        XCTAssertEqual(r.observation.source, .standardBluetooth)
        XCTAssertEqual(r.observation.quantity.display, "0%")
        XCTAssertFalse(r.retained); XCTAssertFalse(r.isStale(at: f.clock.now()))
        XCTAssertTrue(r.isStale(at: f.clock.now().addingTimeInterval(121)))
    }

    func testMalformedAndReadErrorRetainOriginalZeroAndOriginalObservationTime() throws {
        let f = Fixture(); f.valid(0)
        let original = try XCTUnwrap(f.record?.observation.observedAt)
        for payload: Data? in [Data(), Data([101]), Data([255]), Data([65, 0]), nil] {
            f.clock.advance(); f.beginRead(); f.clock.advance()
            f.transport.send(.value(f.uuid, payload, error: nil))
            XCTAssertEqual(f.record?.observation.quantity, .reportedPercent(0))
            XCTAssertEqual(f.record?.observation.observedAt, original)
            XCTAssertEqual(f.record?.lastAttempt, f.clock.now())
            XCTAssertEqual(f.record?.retained, true)
            XCTAssertTrue(f.record?.error?.contains("Invalid Battery Level") == true)
        }
        f.beginRead(); f.clock.advance()
        f.transport.send(.value(f.uuid, Data([99]), error: "Read not permitted"))
        XCTAssertEqual(f.record?.observation.quantity, .reportedPercent(0))
        XCTAssertEqual(f.record?.observation.observedAt, original)
        XCTAssertEqual(f.record?.lastAttempt, f.clock.now())
        XCTAssertTrue(f.record?.error?.contains("read failed") == true)
    }

    func testMissingAmbiguousUnreadableAndServiceErrorsDoNotRead() {
        let uuid = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let cases: [(BluetoothBatteryTransportEvent, Bool, String)] = [
            (.services(uuid, count: 0, error: nil), false, "Service (180F) unavailable"),
            (.services(uuid, count: 2, error: nil), false, "multiple Battery Service"),
            (.services(uuid, count: 1, error: "Service denied"), false, "discovery failed"),
            (.batteryLevels(uuid, count: 0, readable: false, error: nil), true, "Readable standard"),
            (.batteryLevels(uuid, count: 1, readable: false, error: nil), true, "Readable standard"),
            (.batteryLevels(uuid, count: 2, readable: true, error: nil), true, "multiple Battery Level"),
            (.batteryLevels(uuid, count: 1, readable: true, error: "Denied"), true, "discovery failed")
        ]
        for (event, needsService, message) in cases {
            let f = Fixture()
            f.provider.refresh(); f.transport.send(.connected(f.uuid))
            if needsService { f.transport.send(.services(f.uuid, count: 1, error: nil)) }
            f.clock.advance(); f.transport.send(event)
            XCTAssertEqual(f.transport.readCount, 0, message)
            XCTAssertEqual(f.record?.observation.quantity, .unknown, message)
            XCTAssertNil(f.record?.observation.observedAt, message)
            XCTAssertTrue(f.record?.error?.contains(message) == true, message)
        }
    }

    func testTimeoutQuarantinesReadUntilLateCallbackDrainsThenOnlyNewReadIsFresh() throws {
        let f = Fixture(); f.valid()
        let baseline = try XCTUnwrap(f.record?.observation.observedAt)
        f.beginRead(); let before = f.transport.readCount
        f.clock.advance(16); f.provider.expire()
        XCTAssertTrue(f.record?.error?.contains("read timed out") == true)
        let failedAt = f.record?.lastAttempt
        for _ in 0..<3 { f.clock.advance(); f.provider.refresh() }
        XCTAssertEqual(f.transport.readCount, before)
        f.transport.send(.value(f.uuid, Data([1]), error: nil))
        XCTAssertEqual(f.record?.observation.quantity, .reportedPercent(65))
        XCTAssertEqual(f.record?.observation.observedAt, baseline)
        XCTAssertEqual(f.record?.lastAttempt, failedAt, "Late read is ignored rather than a new failed or valid attempt")
        f.beginRead(); f.clock.advance()
        f.transport.send(.value(f.uuid, Data([100]), error: nil))
        XCTAssertEqual(f.transport.readCount, before + 1)
        XCTAssertEqual(f.record?.observation.quantity, .reportedPercent(100))
        XCTAssertEqual(f.record?.observation.observedAt, f.clock.now())
        XCTAssertNil(f.record?.error)
    }

    func testCallbackAtDeadlineCannotSlipPastTimer() {
        let f = Fixture(); f.beginRead(); f.clock.advance(15)
        f.transport.send(.value(f.uuid, Data([65]), error: nil))
        XCTAssertEqual(f.record?.observation.quantity, .unknown)
        XCTAssertNil(f.record?.observation.observedAt)
        XCTAssertTrue(f.record?.error?.contains("timed out") == true)
    }

    func testDiscoveryTimeoutCannotAdvanceOldCallbackIntoNewRead() {
        let f = Fixture(); f.provider.refresh(); f.transport.send(.connected(f.uuid))
        f.clock.advance(16); f.provider.expire(); f.provider.refresh()
        XCTAssertEqual(f.transport.connectionCount, 1)
        f.transport.send(.services(f.uuid, count: 1, error: nil))
        XCTAssertEqual(f.transport.readCount, 0)
        XCTAssertFalse(f.transport.commands.contains { $0.hasPrefix("level:") })
        f.beginRead(); XCTAssertEqual(f.transport.readCount, 1)
    }

    func testPolicyOffOnAndResetFenceInFlightReadAndPreventReplay() {
        for reset in [false, true] {
            let f = Fixture(); f.valid(10); let prior = f.record?.observation.observedAt
            f.beginRead()
            if reset { f.settings.reset() }
            else { f.settings.setMonitoring(false, for: f.id); f.settings.setMonitoring(true, for: f.id) }
            f.provider.refresh()
            let count = f.transport.readCount, observations = f.updates.filter { $0.observation != nil }.count
            f.transport.send(.value(f.uuid, Data([1]), error: nil))
            XCTAssertEqual(f.record?.observation.observedAt, prior)
            XCTAssertEqual(f.updates.filter { $0.observation != nil }.count, observations)
            f.beginRead(); XCTAssertEqual(f.transport.readCount, count + 1)
        }
    }

    func testPausedDeviceAndBlockedSettingsDoNotQueryOrApplyCallbacks() {
        let f = Fixture(); f.valid()
        f.settings.setMonitoring(false, for: f.id)
        let count = f.transport.connectionCount
        f.provider.refresh(); f.transport.send(.value(f.uuid, Data([1]), error: nil))
        XCTAssertEqual(f.transport.connectionCount, count)
        XCTAssertEqual(f.record?.observation.quantity, .reportedPercent(65))
        let blocked = DeviceSettingsStore(persistence: MemoryDeviceSettingsPersistence(data: Data()))
        var factories = 0
        let provider = StandardBluetoothBatteryProvider(settings: blocked, authorization: { .authorized }, makeTransport: { _ in factories += 1; return Transport() })
        provider.refresh(); provider.requestAccessFromUserAction()
        XCTAssertEqual(factories, 0)
    }

    func testStopFencesPendingReadStatusAuthorizationAndRefresh() {
        let f = Fixture(); f.valid(); f.beginRead()
        f.provider.stop(); let prior = f.updates.count, commands = f.transport.commands
        f.clock.advance(20); f.provider.expire(); f.provider.refresh(); f.provider.requestAccessFromUserAction()
        f.transport.send(.value(f.uuid, Data([1]), error: nil))
        f.transport.send(.availability(.poweredOff))
        XCTAssertEqual(f.updates.count, prior); XCTAssertEqual(f.transport.commands, commands)
        XCTAssertEqual(f.record?.observation.quantity, .reportedPercent(65))
        let fresh = Fixture(); fresh.authorization = .notDetermined; fresh.provider.stop(); fresh.provider.requestAccessFromUserAction()
        XCTAssertEqual(fresh.factories, 0)
    }

    func testAuthorizationRevokedDuringReadCannotProduceFreshValue() {
        for refreshDenied in [false, true] {
            let f = Fixture(); f.valid(); let observed = f.record?.observation.observedAt
            f.beginRead(); f.authorization = .denied
            if refreshDenied { f.provider.refresh() }
            f.clock.advance(); f.transport.send(.value(f.uuid, Data([1]), error: nil))
            XCTAssertEqual(f.record?.observation.quantity, .reportedPercent(65))
            XCTAssertEqual(f.record?.observation.observedAt, observed)
            XCTAssertEqual(f.factories, 1)
            f.authorization = .authorized; f.beginRead(); f.clock.advance()
            f.transport.send(.value(f.uuid, Data([64]), error: nil))
            XCTAssertEqual(f.record?.observation.quantity, .reportedPercent(64))
        }
    }

    func testPoweredOffMissingPeripheralConnectionFailureAndDisconnectRetainKnownReading() {
        let f = Fixture(); f.valid(); let observed = f.record?.observation.observedAt
        f.clock.advance(); f.transport.availability = .poweredOff; f.transport.send(.availability(.poweredOff))
        XCTAssertTrue(f.record?.error?.contains("powered off") == true)
        f.transport.availability = .poweredOn; f.transport.connected = []; f.provider.refresh()
        XCTAssertTrue(f.record?.error?.contains("No already-connected") == true)
        f.transport.connected = [BluetoothBatteryPeripheral(uuid: f.uuid, name: "Maxfit8")]
        f.provider.refresh(); f.transport.send(.connectionFailed(f.uuid, "Denied"))
        XCTAssertTrue(f.record?.error?.contains("connection failed") == true)
        f.beginRead(); let count = f.transport.readCount
        f.transport.send(.disconnected(f.uuid)); f.provider.refresh()
        XCTAssertEqual(f.transport.readCount, count)
        f.transport.send(.value(f.uuid, Data([1]), error: nil))
        XCTAssertEqual(f.record?.observation.quantity, .reportedPercent(65))
        XCTAssertEqual(f.record?.observation.observedAt, observed)
        XCTAssertEqual(f.record?.retained, true)
    }

    func testLowBatteryUsesHostReadAgeUnknownChargingAndExistingReplayPermissionGates() throws {
        let f = Fixture(); f.valid(10)
        let low = try XCTUnwrap(f.record)
        XCTAssertNil(LowBatteryAlertPolicy.ineligibility(low, monitoring: true, now: f.clock.now()))
        XCTAssertNotNil(LowBatteryAlertPolicy.ineligibility(low, monitoring: false, now: f.clock.now()))
        XCTAssertNotNil(LowBatteryAlertPolicy.ineligibility(low, monitoring: true, now: f.clock.now().addingTimeInterval(121)))
        var unknown = low; unknown.observation.quantity = .unknown
        XCTAssertNotNil(LowBatteryAlertPolicy.ineligibility(unknown, monitoring: true, now: f.clock.now()))
        var retained = low; retained.retained = true
        XCTAssertNotNil(LowBatteryAlertPolicy.ineligibility(retained, monitoring: true, now: f.clock.now()))
        let policy = LowBatteryAlertPolicy(persistence: MemoryAlertPersistence())
        var config = policy.configuration; config.enabled = true; XCTAssertTrue(policy.configure(config))
        XCTAssertTrue(policy.process(records: [low], devices: f.settings.devices, authorized: false, now: f.clock.now()).isEmpty)
        policy.baseline([low], now: f.clock.now())
        XCTAssertTrue(policy.process(records: [low], devices: f.settings.devices, authorized: true, now: f.clock.now()).isEmpty)
        f.clock.advance(); f.valid(9)
        XCTAssertEqual(policy.process(records: [try XCTUnwrap(f.record)], devices: f.settings.devices, authorized: true, now: f.clock.now()).count, 1)
        XCTAssertTrue(policy.process(records: [try XCTUnwrap(f.record)], devices: f.settings.devices, authorized: true, now: f.clock.now()).isEmpty)
    }
}
