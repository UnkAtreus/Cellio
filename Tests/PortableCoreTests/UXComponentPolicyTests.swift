import XCTest
import Foundation
@testable import OpenBatteryCore

private final class UXFailingPersistence: DeviceSettingsPersistence {
    var bytes: Data?
    var failSave = false
    init(_ bytes: Data? = nil) { self.bytes = bytes }
    func load() throws -> Data? { bytes }
    func save(_ data: Data) throws {
        if failSave { throw DeviceSettingsError.saveFailed }
        bytes = data
    }
}

final class UXComponentPolicyTests: XCTestCase {
    func testCaseOnlySurvivesMasterCycleReloadAndKeepsCollectionMetadata() throws {
        let storage = MemoryDeviceSettingsPersistence()
        let store = DeviceSettingsStore(persistence: storage)
        store.discover(id: "pods", name: "Pods", source: .systemReport, componentIDs: ["left", "right", "case"])
        let before = store.context()
        store.setComponentSelected(false, component: "left", for: "pods")
        store.setComponentSelected(false, component: "right", for: "pods")
        XCTAssertEqual(store.devices[0].componentSelection, ComponentSelection(mode: .selected, ids: ["case"]))
        store.setMenuVisibility(false, for: "pods")
        store.setMenuVisibility(true, for: "pods")
        XCTAssertTrue(store.showsComponent("case", for: "pods"))
        XCTAssertFalse(store.showsComponent("left", for: "pods"))
        XCTAssertTrue(store.accepts("pods", from: before))
        let reloaded = DeviceSettingsStore(persistence: MemoryDeviceSettingsPersistence(data: storage.data))
        XCTAssertEqual(reloaded.devices[0].selectionSummary, "Case")
        XCTAssertEqual(reloaded.devices[0].knownComponentIDs, ["left", "right", "case"])
    }

    func testMenuPresentationNeverBorrowsAbsentCaseAndRetainsAbsentMetadata() {
        let store = DeviceSettingsStore()
        store.discover(id: "pods", name: "Pods", source: .systemReport, componentIDs: ["left", "right", "case"])
        store.setComponentSelected(false, component: "left", for: "pods")
        store.setComponentSelected(false, component: "right", for: "pods")
        let record = BatteryRecord(Observation(id: ComponentID(device: "pods", component: "left"), name: "Pods", source: .systemReport, connection: .connected, quantity: .reportedPercent(77), charge: .charging, observedAt: Date(timeIntervalSince1970: 1), measuredAt: Date(timeIntervalSince1970: 1), collectedAt: Date(timeIntervalSince1970: 1)))
        let menu = BatteryMenuDevicePresentation.groups(records: [record], settings: store, at: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(menu.map(\.id), ["pods"])
        XCTAssertEqual(menu[0].components.map(\.id), ["case"])
        XCTAssertNil(menu[0].components[0].reading)
        XCTAssertEqual(menu[0].components[0].value, "Not reported")
        XCTAssertNotEqual(menu[0].components[0].value, "77%")
        XCTAssertTrue(store.devices[0].knownComponentIDs.contains("case"))
    }

    func testCustomSelectionExcludesNewIDWhileExplicitAllIncludesItAndNamesAreIndependent() {
        let store = DeviceSettingsStore()
        store.discover(id: "one", name: "Twin", source: .headset, componentIDs: ["battery", "case"])
        store.discover(id: "two", name: "Twin", source: .headset, componentIDs: ["battery", "case"])
        store.setComponentSelected(false, component: "battery", for: "one")
        store.discover(id: "one", name: "Twin", source: .headset, componentIDs: ["left"])
        store.discover(id: "two", name: "Twin", source: .headset, componentIDs: ["left"])
        XCTAssertFalse(store.showsComponent("left", for: "one"))
        XCTAssertTrue(store.showsComponent("left", for: "two"))
        store.includeAllComponents(for: "one")
        XCTAssertTrue(store.showsComponent("left", for: "one"))
        XCTAssertEqual(store.devices.first { $0.id == "one" }?.selectionSummary, "All components")
        XCTAssertEqual(store.devices.count, 2)
    }

    func testEveryLegacyBooleanPairMigratesUnchangedAndLegacyBytesRemainUntouched() throws {
        for monitor in [false, true] {
            for visible in [false, true] {
                let legacy = Data("{\"version\":1,\"devices\":[{\"id\":\"legacy\",\"name\":\"Legacy\",\"source\":\"headset\",\"preferences\":{\"monitorBattery\":\(monitor),\"showInMenu\":\(visible)}}]}".utf8)
                let defaults = try XCTUnwrap(UserDefaults(suiteName: "org.openbattery.qa.ux.\(monitor)-\(visible)"))
                defaults.removePersistentDomain(forName: "org.openbattery.qa.ux.\(monitor)-\(visible)")
                defaults.set(legacy, forKey: DefaultsDeviceSettingsPersistence.legacyKey)
                let store = DeviceSettingsStore(persistence: DefaultsDeviceSettingsPersistence(defaults: defaults))
                XCTAssertEqual(store.preferences(for: "legacy"), DevicePreferences(monitorBattery: monitor, showInMenu: visible))
                XCTAssertEqual(defaults.data(forKey: DefaultsDeviceSettingsPersistence.legacyKey), legacy)
                XCTAssertEqual((try JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: DefaultsDeviceSettingsPersistence.key))) as? [String: Any])?["version"] as? Int, 2)
                defaults.removePersistentDomain(forName: "org.openbattery.qa.ux.\(monitor)-\(visible)")
            }
        }
    }

    func testCorruptOrUnknownV2BlocksWithoutLegacyFallbackOrOverwrite() throws {
        for bad in [Data("{broken".utf8), Data(#"{"version":99,"devices":[]}"#.utf8)] {
            let domain = "org.openbattery.qa.ux.blocked.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
            defaults.removePersistentDomain(forName: domain)
            let legacy = Data(#"{"version":1,"devices":[]}"#.utf8)
            defaults.set(legacy, forKey: DefaultsDeviceSettingsPersistence.legacyKey)
            defaults.set(bad, forKey: DefaultsDeviceSettingsPersistence.key)
            let store = DeviceSettingsStore(persistence: DefaultsDeviceSettingsPersistence(defaults: defaults))
            store.discover(id: "x", name: "X", source: nil)
            store.retrySave()
            XCTAssertTrue(store.updatesBlocked)
            XCTAssertEqual(defaults.data(forKey: DefaultsDeviceSettingsPersistence.key), bad)
            XCTAssertEqual(defaults.data(forKey: DefaultsDeviceSettingsPersistence.legacyKey), legacy)
            defaults.removePersistentDomain(forName: domain)
        }
    }

    func testSaveFailureKeepsHonestSessionSelectionAndRetryPersists() {
        let persistence = UXFailingPersistence()
        let store = DeviceSettingsStore(persistence: persistence)
        store.discover(id: "pods", name: "Pods", source: nil, componentIDs: ["left", "case"])
        persistence.failSave = true
        store.setComponentSelected(false, component: "left", for: "pods")
        XCTAssertFalse(store.updatesBlocked)
        XCTAssertTrue(store.issue?.contains("Changes aren’t saved") == true)
        XCTAssertTrue(store.showsComponent("case", for: "pods"))
        XCTAssertFalse(store.showsComponent("left", for: "pods"))
        persistence.failSave = false
        store.retrySave()
        XCTAssertNil(store.issue)
        let reloaded = DeviceSettingsStore(persistence: MemoryDeviceSettingsPersistence(data: persistence.bytes))
        XCTAssertTrue(reloaded.showsComponent("case", for: "pods"))
        XCTAssertFalse(reloaded.showsComponent("left", for: "pods"))
    }

    func testComponentBoundsAndNonemptySelectionAreValidated() throws {
        let base = #"{"version":2,"devices":[{"id":"x","name":"X","source":null,"preferences":{"monitorBattery":true,"showInMenu":true},"knownComponentIDs":["left","case"],"componentSelection":{"mode":"selected","ids":["case"]}}]}"#
        let valid = DeviceSettingsStore(persistence: MemoryDeviceSettingsPersistence(data: Data(base.utf8)))
        XCTAssertFalse(valid.updatesBlocked)
        for bad in [
            base.replacingOccurrences(of: "\"case\"]", with: "\"case\",\"case\"]"),
            base.replacingOccurrences(of: "\"ids\":[\"case\"]", with: "\"ids\":[]"),
            base.replacingOccurrences(of: "\"left\"", with: "\"\(String(repeating: "a", count: 129))\"")
        ] {
            let blocked = DeviceSettingsStore(persistence: MemoryDeviceSettingsPersistence(data: Data(bad.utf8)))
            XCTAssertTrue(blocked.updatesBlocked, bad)
        }
        let store = DeviceSettingsStore()
        store.discover(id: "x", name: "X", source: nil, componentIDs: ["case"])
        store.setComponentSelected(false, component: "case", for: "x")
        XCTAssertTrue(store.showsComponent("case", for: "x"), "the last selected component cannot be removed")
    }
}
