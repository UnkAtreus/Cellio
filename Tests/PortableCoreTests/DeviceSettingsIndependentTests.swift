import XCTest
import Foundation
@testable import OpenBatteryCore

private final class DeviceSettingsFailingPersistence: DeviceSettingsPersistence {
    var bytes: Data?
    var failLoad = false
    var failSave = false
    init(_ bytes: Data? = nil) { self.bytes = bytes }
    func load() throws -> Data? { if failLoad { throw DeviceSettingsError.invalidData }; return bytes }
    func save(_ data: Data) throws { if failSave { throw DeviceSettingsError.saveFailed }; bytes = data }
}

final class DeviceSettingsIndependentTests: XCTestCase {
    func testDefaultsLogicalIdentityComponentsAndIndependentPreferences() throws {
        let storage = MemoryDeviceSettingsPersistence()
        let store = DeviceSettingsStore(persistence: storage)
        store.discover(id: "receiver-1", name: "Same name", source: .hidUnified)
        store.discover(id: "receiver-10", name: "Same name", source: .hidUnified)
        XCTAssertEqual(store.preferences(for: "receiver-1"), DevicePreferences())
        XCTAssertEqual(store.preferences(for: "receiver-10"), DevicePreferences())
        let components = ["left", "right", "case"].map { ComponentID(device: "receiver-1", component: $0) }
        XCTAssertTrue(components.allSatisfy { store.preferences(for: $0.device).monitorBattery })
        store.setMonitoring(false, for: "receiver-1")
        store.setMenuVisibility(false, for: "receiver-10")
        XCTAssertFalse(store.preferences(for: components[0].device).monitorBattery)
        XCTAssertTrue(store.preferences(for: "receiver-1").showInMenu)
        XCTAssertTrue(store.preferences(for: "receiver-10").monitorBattery)
        XCTAssertFalse(store.preferences(for: "receiver-10").showInMenu)
        let context = store.context()
        XCTAssertFalse(store.accepts("receiver-1", from: context))
        XCTAssertTrue(store.accepts("receiver-10", from: context))
        store.setMenuVisibility(false, for: "receiver-1")
        XCTAssertTrue(store.accepts("receiver-10", from: context), "visibility does not invalidate battery collection")
    }

    func testPersistenceReloadCatalogAndPausedHiddenKnownDevices() throws {
        let storage = MemoryDeviceSettingsPersistence()
        let first = DeviceSettingsStore(persistence: storage)
        first.discover(id: "hid-slot-1", name: "Known", source: .hidLegacy)
        first.setMonitoring(false, for: "hid-slot-1")
        first.setMenuVisibility(false, for: "hid-slot-1")
        let reloaded = DeviceSettingsStore(persistence: MemoryDeviceSettingsPersistence(data: storage.data))
        XCTAssertEqual(reloaded.devices.count, 1)
        XCTAssertEqual(reloaded.devices[0].id, "hid-slot-1")
        XCTAssertEqual(reloaded.devices[0].source, .hidLegacy)
        XCTAssertEqual(reloaded.preferences(for: "hid-slot-1"), DevicePreferences(monitorBattery: false, showInMenu: false))
        XCTAssertEqual(reloaded.readingStatus(for: "hid-slot-1", hasReading: true, age: "12m old"), "Monitoring off · Last reading · 12m old")
        XCTAssertEqual(reloaded.readingStatus(for: "hid-slot-1", hasReading: false, age: ""), "Monitoring off · No reading")
    }

    func testMalformedAndFutureDocumentsAreUntouchedBlockedUntilExplicitReset() throws {
        for bytes in [Data("{broken".utf8), Data(#"{"version":99,"devices":[]}"#.utf8)] {
            let storage = MemoryDeviceSettingsPersistence(data: bytes)
            let store = DeviceSettingsStore(persistence: storage)
            XCTAssertTrue(store.updatesBlocked)
            XCTAssertNotNil(store.issue)
            XCTAssertEqual(storage.data, bytes)
            let context = store.context()
            XCTAssertFalse(store.accepts("new-device", from: context))
            store.discover(id: "new-device", name: "New", source: nil)
            XCTAssertTrue(store.devices.isEmpty)
            XCTAssertEqual(storage.data, bytes)
            store.reset()
            XCTAssertFalse(store.updatesBlocked)
            XCTAssertNil(store.issue)
            XCTAssertNotEqual(storage.data, bytes, "only explicit reset may replace the malformed document")
            XCTAssertNotNil(storage.data)
            store.discover(id: "new-device", name: "New", source: nil)
            XCTAssertEqual(store.devices.map(\.id), ["new-device"])
        }
    }

    func testSaveFailureIsVisibleAndRetryPersists() {
        let storage = DeviceSettingsFailingPersistence()
        let store = DeviceSettingsStore(persistence: storage)
        storage.failSave = true
        store.discover(id: "save-test", name: "Save", source: .headset)
        XCTAssertFalse(store.updatesBlocked)
        XCTAssertTrue(store.issue?.contains("not saved") == true)
        storage.failSave = false
        store.retrySave()
        XCTAssertNil(store.issue)
        XCTAssertNotNil(storage.bytes)
    }

    func testDisableThenEnableRejectsOldContextButKeepsUnrelatedDeviceEligible() {
        let store = DeviceSettingsStore()
        store.discover(id: "A", name: "A", source: .hidUnified)
        store.discover(id: "B", name: "B", source: .headset)
        let old = store.context()
        store.setMonitoring(false, for: "A")
        store.setMonitoring(true, for: "A")
        XCTAssertFalse(store.accepts("A", from: old))
        XCTAssertTrue(store.accepts("B", from: old))
        let fresh = store.context()
        XCTAssertTrue(store.accepts("A", from: fresh))
    }

    func testQASuiteSyntaxIsValidatedWithoutOpeningPersistence() throws {
        let valid = ["--device-settings-suite", "org.openbattery.qa.device_settings-42"]
        XCTAssertEqual(try DeviceSettingsStore.qaSuite(arguments: valid), valid[1])
        XCTAssertNil(try DeviceSettingsStore.qaSuite(arguments: ["--other", "value"]))
        for invalid in [
            ["--device-settings-suite"],
            ["--device-settings-suite", "org.openbattery.qa.good", "--device-settings-suite", "org.openbattery.qa.other"],
            ["--device-settings-suite", "org.openbattery.qa."],
            ["--device-settings-suite", "org.openbattery.qa.-bad"],
            ["--device-settings-suite", "org.openbattery.qa.bad/name"],
            ["--device-settings-suite", "org.openbattery.other"]
        ] {
            XCTAssertThrowsError(try DeviceSettingsStore.qaSuite(arguments: invalid))
        }
    }

    func testMalformedAndLoadFailurePreservePersistenceAcrossSettersAndRetry() {
        let malformed = Data(#"{"version":1,"devices":[{"id":"","name":"bad"}]}"#.utf8)
        let storage = DeviceSettingsFailingPersistence(malformed)
        let store = DeviceSettingsStore(persistence: storage)
        XCTAssertTrue(store.updatesBlocked)
        store.discover(id: "valid", name: "Valid", source: .headset)
        store.setMonitoring(false, for: "valid")
        store.setMenuVisibility(false, for: "valid")
        store.retrySave()
        XCTAssertEqual(storage.bytes, malformed)

        let failing = DeviceSettingsFailingPersistence()
        failing.failLoad = true
        let failedLoad = DeviceSettingsStore(persistence: failing)
        XCTAssertTrue(failedLoad.updatesBlocked)
        failedLoad.discover(id: "valid", name: "Valid", source: .headset)
        failedLoad.setMonitoring(false, for: "valid")
        failedLoad.retrySave()
        XCTAssertNil(failing.bytes)
    }
}
