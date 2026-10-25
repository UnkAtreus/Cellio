import XCTest
@testable import OpenBatteryCore

final class MenuBarFocusedAcceptanceTests: XCTestCase {
    private final class Disk: MenuBarPersistence {
        var data: Data?, writes = 0, reads = 0
        var failRead = false, ignoreWrite = false, breakReadback = false, failRollback = false
        func load() throws -> Data? {
            reads += 1
            if failRead || (breakReadback && writes == 1) { throw MenuBarStorageError.unavailable }
            return data
        }
        func save(_ next: Data?) throws {
            writes += 1
            if failRollback && writes > 1 { throw MenuBarStorageError.saveFailed }
            if !ignoreWrite { data = next }
        }
    }
    private func config() -> MenuBarConfiguration {
        var c = MenuBarConfiguration()
        c.pins = [MenuBarPin(deviceID: "mouse", componentID: "battery", sourceMembers: ["route"], deviceName: "QA Mouse")]
        return c
    }
    func testStrictSchemaRejectsWrongTypesEnumsKeysAndBoundedIdentities() throws {
        let original = config()
        let good = try JSONEncoder().encode(original)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: good) as? [String: Any])
        for (key, value): (String, Any) in [("version", true), ("version", 1.0), ("display", "donut"), ("separator", "dots"), ("pins", NSNull()), ("extra", 1)] {
            var changed = raw; changed[key] = value
            // JSONSerialization canonicalizes 1.0 to integer 1; preserve JSON number spelling.
            let bytes = key == "version" && !(value is Bool) ? Data(String(decoding: good, as: UTF8.self).replacingOccurrences(of: "\"version\":1", with: "\"version\":1.5").utf8) : try JSONSerialization.data(withJSONObject: changed)
            XCTAssertThrowsError(try MenuBarConfiguration.decode(bytes), key)
        }
        for members in [[], ["route", "route"], ["bad\nroute"], [String(repeating: "x", count: 513)]] {
            var changed = config()
            changed.pins = [MenuBarPin(deviceID: "mouse", componentID: "battery", sourceMembers: members, deviceName: "Mouse")]
            XCTAssertThrowsError(try changed.validate())
        }
        XCTAssertThrowsError(try MenuBarConfiguration.decode(Data(repeating: 32, count: 65_537)))
        XCTAssertEqual(try MenuBarConfiguration.decode(good), original)
    }
    func testAbsentAndUnreadableLaunchDoNotWriteOrNormalize() {
        let disk = Disk(), defaults = MenuBarConfigurationStore(persistence: disk)
        XCTAssertEqual(defaults.configuration, MenuBarConfiguration()); XCTAssertEqual(disk.writes, 0)
        disk.data = Data("unreadable original bytes".utf8)
        let original = disk.data, recovery = MenuBarConfigurationStore(persistence: disk)
        XCTAssertTrue(recovery.unavailable); XCTAssertFalse(recovery.hasVerifiedLayout)
        XCTAssertEqual(recovery.configuration.pins.count, 0)
        XCTAssertFalse(recovery.reload()); XCTAssertEqual(disk.data, original); XCTAssertEqual(disk.writes, 0)
        XCTAssertThrowsError(try recovery.commit(config())); XCTAssertEqual(disk.writes, 0)
    }
    func testReadbackFailureRollsBackAbsentKeyAndRollbackFailureBlocks() throws {
        let disk = Disk(), store = MenuBarConfigurationStore(persistence: disk)
        disk.breakReadback = true
        XCTAssertThrowsError(try store.commit(config()))
        XCTAssertNil(disk.data); XCTAssertEqual(disk.writes, 2)
        XCTAssertFalse(store.unavailable); XCTAssertEqual(store.configuration, MenuBarConfiguration())
        let broken = Disk(), blocked = MenuBarConfigurationStore(persistence: broken)
        broken.breakReadback = true; broken.failRollback = true
        XCTAssertThrowsError(try blocked.commit(config()))
        XCTAssertTrue(blocked.unavailable); XCTAssertEqual(blocked.configuration, MenuBarConfiguration())
        XCTAssertThrowsError(try blocked.commit(config()))
    }
    func testExternalCorruptionReadFailureAndFailedResetRetainLastVerifiedLayout() throws {
        let disk = Disk(), initial = config()
        disk.data = try JSONEncoder().encode(initial)
        let store = MenuBarConfigurationStore(persistence: disk)
        disk.failRead = true
        XCTAssertFalse(store.reload()); XCTAssertEqual(store.configuration, initial)
        disk.failRead = false; disk.data = Data("corrupt".utf8)
        var next = initial; next.separator = .line
        XCTAssertThrowsError(try store.commit(next)); XCTAssertEqual(disk.writes, 0)
        XCTAssertTrue(store.unavailable); XCTAssertEqual(store.configuration, initial)
        disk.ignoreWrite = true
        XCTAssertThrowsError(try store.commit(MenuBarConfiguration(), resetting: true))
        XCTAssertTrue(store.unavailable); XCTAssertEqual(store.configuration, initial)
        XCTAssertEqual(disk.data, Data("corrupt".utf8))
        disk.ignoreWrite = false
        try store.commit(MenuBarConfiguration(), resetting: true)
        XCTAssertFalse(store.unavailable); XCTAssertEqual(store.configuration, MenuBarConfiguration())
    }
    func testBudgetUsesOrderedPrefixAndHiddenExclusionWithHonestIconFallback() {
        var c = MenuBarConfiguration()
        c.pins = ["case", "left", "right"].map { MenuBarPin(deviceID: "pods", componentID: $0, sourceMembers: ["pods"], deviceName: "QA Pods") }
        let settings = DeviceSettingsStore(persistence: MemoryDeviceSettingsPersistence())
        let pins = MenuBarPinPolicy.resolve(c, settings: settings)
        let all = MenuBarLayout.project(pins, budget: 10_000)
        XCTAssertLessThanOrEqual(all.width, 280); XCTAssertEqual(all.displayedIDs, c.pins.map(\.id)); XCTAssertEqual(all.overflow, 0)
        // Native Case alone is 119pt; its reserved +2 field adds 26pt: 145pt whole.
        let narrow = MenuBarLayout.project(pins, budget: 140)
        XCTAssertEqual(narrow.displayedIDs, []); XCTAssertEqual(narrow.overflow, 0)
        XCTAssertEqual(narrow.width, 26); XCTAssertLessThanOrEqual(narrow.width, 140)
        let limited = MenuBarLayout.project(pins, budget: 145)
        XCTAssertEqual(limited.displayedIDs, [c.pins[0].id]); XCTAssertEqual(limited.overflow, 2); XCTAssertLessThanOrEqual(limited.width, 145)
        XCTAssertEqual(limited.width, 145)
        for budget: Double? in [nil, .nan, .infinity, -1, 23, 100] {
            let layout = MenuBarLayout.project(pins, budget: budget)
            XCTAssertEqual(layout.displayedIDs, []); XCTAssertEqual(layout.overflow, 0)
            XCTAssertGreaterThan(layout.width, 0); XCTAssertLessThanOrEqual(layout.width, 280)
        }
        var hidden = pins; hidden[0].state = .hidden
        let visible = MenuBarLayout.project(hidden, budget: 140)
        XCTAssertEqual(visible.displayedIDs, [c.pins[1].id]); XCTAssertEqual(visible.overflow, 1)
        XCTAssertEqual(c.pins.map(\.componentID), ["case", "left", "right"])
    }
}
