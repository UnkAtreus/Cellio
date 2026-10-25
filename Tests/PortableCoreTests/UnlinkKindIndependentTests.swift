import XCTest
@testable import OpenBatteryCore

final class UnlinkKindIndependentTests: XCTestCase {
    func testUnlinkRetainsTypedKindInPersistedMenuProjectionWithoutReadings() throws {
        let cases: [(name: String, routeKind: PhysicalDeviceKind, projectedKind: PhysicalDeviceKind?)] = [
            ("PRO X 2", .headset, .headset),
            ("Established keyboard", .keyboard, .keyboard),
            ("Unknown accessory", .unknown, nil)
        ]

        for (index, scenario) in cases.enumerated() {
            let storage = MemoryDeviceSettingsPersistence()
            let settings = DeviceSettingsStore(persistence: storage)
            let bluetoothID = "bluetooth-\(index)"
            let receiverID = "receiver-\(index)"
            let source: BatterySource = scenario.routeKind == .headset ? .systemReport : .hidUnified

            settings.discover(id: bluetoothID, name: scenario.name, source: source,
                              componentIDs: ["battery"], kind: scenario.routeKind)
            settings.discover(id: receiverID, name: "Receiver route", source: source,
                              componentIDs: ["battery"], kind: scenario.routeKind)
            settings.rememberRoute(.init(id: bluetoothID,
                metadata: .init(type: .bluetooth, kind: scenario.routeKind, topology: "independent fixture")))
            settings.rememberRoute(.init(id: receiverID,
                metadata: .init(type: .wirelessReceiver, kind: scenario.routeKind, topology: "independent fixture")))

            try settings.commitLink(settings.previewLink(current: bluetoothID, selected: [receiverID], alerts: .init()), alerts: .init())
            let detachedID = "detached-\(index)"
            XCTAssertEqual(try settings.unlink(member: bluetoothID, from: bluetoothID, newID: detachedID), detachedID)

            let reloaded = DeviceSettingsStore(persistence: MemoryDeviceSettingsPersistence(data: storage.data))
            XCTAssertEqual(reloaded.devices.first { $0.id == detachedID }?.kind, scenario.projectedKind,
                           "catalog retains the established kind after unlink and reload")
            let projection = BatteryMenuDevicePresentation.groups(records: [], settings: reloaded,
                at: Date(timeIntervalSince1970: 0))
            XCTAssertEqual(projection.first { $0.id == detachedID }?.kind, scenario.projectedKind,
                           "public menu projection retains the kind for \(scenario.name)")
        }
    }
}
