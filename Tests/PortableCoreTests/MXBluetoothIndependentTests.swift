import Foundation
import XCTest
import OpenBatteryCore

final class MXBluetoothIndependentTests: XCTestCase {
    private struct Document: Encodable {
        let version: Int
        let devices: [KnownBatteryDevice]
    }
    private final class Storage: DeviceSettingsPersistence {
        var bytes: Data?
        var failLoad = false
        var failSave = false
        var saves = 0
        init(_ bytes: Data?) { self.bytes = bytes }
        func load() throws -> Data? { if failLoad { throw DeviceSettingsError.invalidData }; return bytes }
        func save(_ data: Data) throws { saves += 1; if failSave { throw DeviceSettingsError.saveFailed }; bytes = data }
    }
    private func descriptor(input: Bool = true, output: Bool = true) throws -> HIDDescriptor {
        var bytes: [UInt8] = [0x06,0x00,0xff,0x09,0x01,0xa1,0x01,0x85,0x10,0x75,0x08,0x95,0x06]
        if input { bytes += [0x81,0x02] }
        if output { bytes += [0x91,0x02] }
        bytes += [0xc0]
        return try HIDDescriptor(Data(bytes))
    }
    private func device(_ id: String, monitor: Bool = true, visible: Bool = true, selected: String = "left") -> KnownBatteryDevice {
        KnownBatteryDevice(id: id, name: "Same accessory", source: .hidUnified,
                           preferences: .init(monitorBattery: monitor, showInMenu: visible),
                           knownComponentIDs: ["left", "right"], componentSelection: .init(mode: .selected, ids: [selected]))
    }
    private func data(_ devices: [KnownBatteryDevice], version: Int = 2) throws -> Data {
        try JSONEncoder().encode(Document(version: version, devices: devices))
    }
    func testThirdOfficialSDKSpellingAndExactNegativeBoundaries() {
        XCTAssertEqual(HIDRoutingPlan.targets(transport: "BluetoothLowEnergy", channelIdentity: "opaque-1"),
                       [HIDRoutingTarget(wireAddress: 255, logicalID: "opaque-1-1")])
        for transport in ["bluetoothLowEnergy", " BluetoothLowEnergy", "BluetoothLowEnergy ", "BluetoothLowEnergyExtra", "XBluetoothLowEnergy", "Bluetooth LowEnergy", "unknown"] {
            XCTAssertFalse(HIDRoutingPlan.isDirectBluetooth(transport: transport), transport)
            XCTAssertEqual(HIDRoutingPlan.targets(transport: transport, channelIdentity: "opaque").map(\.wireAddress), [1,2,3,4,5,6], transport)
        }
    }
    func testNoArchivalWithoutBothExactTransportAndBidirectionalDescriptor() throws {
        let bytes = try data([device("gate-2", monitor: false)])
        let storage = Storage(bytes), store = DeviceSettingsStore(persistence: Storage(bytes))
        let checked = DeviceSettingsStore(persistence: storage)
        for transport in ["USB", "unknown", "bluetooth", "BluetoothLowEnergy "] {
            XCTAssertFalse(checked.archiveDirectBluetoothAliases(transport: transport, channelIdentity: "gate", descriptor: try descriptor()))
        }
        for transport in ["Bluetooth Low Energy", "Bluetooth", "BluetoothLowEnergy"] {
            XCTAssertFalse(checked.archiveDirectBluetoothAliases(transport: transport, channelIdentity: "gate", descriptor: try descriptor(output: false)))
            XCTAssertFalse(checked.archiveDirectBluetoothAliases(transport: transport, channelIdentity: "gate", descriptor: try descriptor(input: false)))
        }
        XCTAssertEqual(checked.devices, store.devices)
        XCTAssertTrue(checked.directBluetoothAliasArchives.isEmpty)
        XCTAssertEqual(storage.bytes, bytes)
        XCTAssertEqual(storage.saves, 0)
        XCTAssertTrue(checked.archiveDirectBluetoothAliases(transport: "BluetoothLowEnergy", channelIdentity: "gate", descriptor: try descriptor()))
        XCTAssertTrue(checked.isArchivedAlias("gate-2"))
    }
    func testOriginalRecordsAndCanonicalChoicesSurviveConservativeMigrationAndReload() throws {
        let canonical = device("opaque-1", selected: "right")
        let originals = [device("opaque-2", monitor: false), device("opaque-4", visible: false, selected: "right")]
        let unrelated = [device("receiver-2"), device("other-2", monitor: false)]
        let storage = Storage(try data([canonical] + originals + unrelated))
        let store = DeviceSettingsStore(persistence: storage), old = store.context()
        XCTAssertTrue(store.archiveDirectBluetoothAliases(transport: "Bluetooth", channelIdentity: "opaque", descriptor: try descriptor()))
        XCTAssertEqual(store.directBluetoothAliasArchives, [.init(channelIdentity: "opaque", devices: originals)])
        var expected = canonical; expected.preferences = .init(monitorBattery: false, showInMenu: false)
        XCTAssertEqual(store.devices.first { $0.id == canonical.id }, expected)
        for original in unrelated { XCTAssertEqual(store.devices.first { $0.id == original.id }, original) }
        XCTAssertFalse(store.accepts(canonical.id, from: old))
        store.setMonitoring(true, for: canonical.id)
        XCTAssertFalse(store.accepts(canonical.id, from: old), "resume must not rebase an old collection")
        XCTAssertTrue(store.accepts(canonical.id, from: store.context()))
        let reloaded = DeviceSettingsStore(persistence: Storage(storage.bytes))
        XCTAssertFalse(reloaded.updatesBlocked)
        XCTAssertEqual(reloaded.directBluetoothAliasArchives, store.directBluetoothAliasArchives)
        XCTAssertEqual(reloaded.devices, store.devices)
        XCTAssertEqual(reloaded.devices.first { $0.id == canonical.id }?.componentSelection, canonical.componentSelection)
    }
    func testAbsentCanonicalKeepsAliasOriginalsAndDoesNotInventComponents() throws {
        let original = device("absent-5", monitor: false, visible: false, selected: "right")
        let store = DeviceSettingsStore(persistence: Storage(try data([original])))
        XCTAssertTrue(store.archiveDirectBluetoothAliases(transport: "Bluetooth Low Energy", channelIdentity: "absent", descriptor: try descriptor()))
        let canonical = try XCTUnwrap(store.devices.first { $0.id == "absent-1" })
        XCTAssertEqual(canonical.preferences, original.preferences)
        XCTAssertEqual(canonical.knownComponentIDs, [])
        XCTAssertEqual(canonical.componentSelection, .init())
        XCTAssertEqual(store.directBluetoothAliasArchives.first?.devices, [original])
    }
    func testCanonicalPauseAndHiddenPoliciesAreNeverEnabledByEnabledAliases() throws {
        for canonical in [device("policy-1", monitor: false), device("policy-1", visible: false)] {
            let store = DeviceSettingsStore(persistence: Storage(try data([canonical, device("policy-2")])))
            XCTAssertTrue(store.archiveDirectBluetoothAliases(transport: "Bluetooth", channelIdentity: "policy", descriptor: try descriptor()))
            XCTAssertEqual(store.devices.first { $0.id == canonical.id }, canonical)
        }
    }
    func testExactSuffixBoundariesAndEmptyEvidenceTombstonesLateDiscovery() throws {
        let ids = ["edge-1-1", "edge-1-20", "edge-1-02", "edge-1-7", "edge-1-2-child", "edge-1-2 ", "edge-10-2", "EDGE-1-2", "receiver-6"]
        let entries = ids.map { device($0) }
        let storage = Storage(try data(entries)), store = DeviceSettingsStore(persistence: Storage(try data(entries)))
        let checked = DeviceSettingsStore(persistence: storage), old = checked.context()
        XCTAssertTrue(checked.archiveDirectBluetoothAliases(transport: "BluetoothLowEnergy", channelIdentity: "edge-1", descriptor: try descriptor()))
        XCTAssertEqual(checked.devices, store.devices)
        XCTAssertEqual(checked.directBluetoothAliasArchives, [.init(channelIdentity: "edge-1", devices: [])])
        for id in ["edge-1-2", "edge-1-3", "edge-1-4", "edge-1-5", "edge-1-6"] {
            checked.discover(id: id, name: "Late discovery", source: .hidUnified, componentIDs: ["battery"])
            XCTAssertTrue(checked.isArchivedAlias(id))
            XCTAssertFalse(checked.context().shouldQuery(id))
            XCTAssertFalse(checked.accepts(id, from: old))
            XCTAssertFalse(checked.accepts(id, from: checked.context()))
            XCTAssertEqual(checked.preferences(for: id), .init(monitorBattery: false, showInMenu: false))
            XCTAssertFalse(checked.showsComponent("battery", for: id))
        }
        XCTAssertEqual(checked.devices, store.devices)
        for id in ids { XCTAssertFalse(checked.isArchivedAlias(id)); XCTAssertTrue(checked.accepts(id, from: old)) }
        let reloaded = DeviceSettingsStore(persistence: Storage(storage.bytes))
        XCTAssertTrue(reloaded.isArchivedAlias("edge-1-6"))
        XCTAssertEqual(reloaded.devices, checked.devices)
    }
    func testV1AndV2ReloadDisconnectedAndPriorSerializationShape() throws {
        for version in [1, 2] {
            let original = device("legacy-3", monitor: false, visible: false)
            let storage = Storage(try data([original], version: version))
            let store = DeviceSettingsStore(persistence: storage)
            XCTAssertFalse(store.updatesBlocked)
            let loaded = store.devices
            XCTAssertFalse(loaded.isEmpty)
            let before = try XCTUnwrap(storage.bytes)
            XCTAssertNil((try JSONSerialization.jsonObject(with: before) as? [String: Any])?["directBluetoothAliasArchives"])
            XCTAssertTrue(store.archiveDirectBluetoothAliases(transport: "BluetoothLowEnergy", channelIdentity: "legacy", descriptor: try descriptor()))
            let reloaded = DeviceSettingsStore(persistence: Storage(storage.bytes))
            XCTAssertFalse(reloaded.updatesBlocked)
            XCTAssertEqual(reloaded.directBluetoothAliasArchives.first?.devices, loaded)
            XCTAssertFalse(reloaded.context().shouldQuery("legacy-3"))
            XCTAssertFalse(reloaded.preferences(for: "legacy-1").monitorBattery)
            XCTAssertFalse(reloaded.preferences(for: "legacy-1").showInMenu)
        }
    }
    func testBlockedCorruptAndOverlappingArchiveDocumentsNeverWrite() throws {
        let entry = device("blocked-2")
        var overlap = try XCTUnwrap(try JSONSerialization.jsonObject(with: data([entry])) as? [String: Any])
        overlap["directBluetoothAliasArchives"] = [["channelIdentity": "blocked", "devices": []]]
        for bytes in [Data("corrupt".utf8), try JSONSerialization.data(withJSONObject: overlap)] {
            let storage = Storage(bytes), store = DeviceSettingsStore(persistence: Storage(bytes))
            let checked = DeviceSettingsStore(persistence: storage)
            XCTAssertTrue(checked.updatesBlocked)
            XCTAssertFalse(checked.archiveDirectBluetoothAliases(transport: "Bluetooth", channelIdentity: "blocked", descriptor: try descriptor()))
            checked.discover(id: "blocked-1", name: "Late", source: .hidUnified)
            checked.retrySave()
            XCTAssertEqual(storage.bytes, bytes); XCTAssertEqual(storage.saves, 0)
            XCTAssertFalse(checked.context().shouldQuery("blocked-1")); XCTAssertNotNil(checked.issue)
            XCTAssertEqual(checked.devices, store.devices)
        }
        let unreadable = Storage(try data([entry])); unreadable.failLoad = true
        let blocked = DeviceSettingsStore(persistence: unreadable)
        XCTAssertFalse(blocked.archiveDirectBluetoothAliases(transport: "Bluetooth", channelIdentity: "blocked", descriptor: try descriptor()))
        XCTAssertTrue(blocked.updatesBlocked); XCTAssertEqual(unreadable.saves, 0)
    }
    func testFailedSaveRetainsDurableBytesPendingOriginalsAndSuccessfulRetry() throws {
        let original = device("retry-2", monitor: false, visible: false, selected: "right")
        let bytes = try data([device("retry-1"), original])
        let storage = Storage(bytes); storage.failSave = true
        let store = DeviceSettingsStore(persistence: storage), old = store.context()
        XCTAssertTrue(store.archiveDirectBluetoothAliases(transport: "Bluetooth", channelIdentity: "retry", descriptor: try descriptor()))
        XCTAssertEqual(storage.bytes, bytes)
        XCTAssertTrue(store.issue?.contains("not saved") == true)
        XCTAssertEqual(store.directBluetoothAliasArchives.first?.devices, [original])
        XCTAssertFalse(store.accepts("retry-2", from: old)); XCTAssertFalse(store.context().shouldQuery("retry-1"))
        XCTAssertFalse(store.preferences(for: "retry-1").showInMenu)
        let writes = storage.saves
        XCTAssertTrue(store.archiveDirectBluetoothAliases(transport: "BluetoothLowEnergy", channelIdentity: "retry", descriptor: try descriptor()))
        XCTAssertEqual(storage.saves, writes, "duplicate evidence must preserve pending originals")
        storage.failSave = false; store.retrySave()
        XCTAssertNil(store.issue); XCTAssertNotEqual(storage.bytes, bytes)
        let reloaded = DeviceSettingsStore(persistence: Storage(storage.bytes))
        XCTAssertFalse(reloaded.updatesBlocked)
        XCTAssertEqual(reloaded.directBluetoothAliasArchives, store.directBluetoothAliasArchives)
        XCTAssertEqual(reloaded.devices, store.devices)
    }
}
