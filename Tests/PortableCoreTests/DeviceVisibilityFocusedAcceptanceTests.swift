import XCTest
import Foundation
@testable import OpenBatteryCore

/// Independent wire and durable store checks. No copied visibility predicate.
final class DeviceVisibilityFocusedAcceptanceTests: XCTestCase {
    private final class Storage: DeviceSettingsPersistence {
        var data: Data?
        var saves = 0, loads = 0
        var failRead = false, failSave = false, dropSave = false
        var corruptNextSave = false, refuseRollback = false
        func load() throws -> Data? { loads += 1; if failRead { throw DeviceSettingsError.invalidData }; return data }
        func save(_ value: Data) throws {
            saves += 1
            if failSave { throw DeviceSettingsError.saveFailed }
            if corruptNextSave {
                data = Data("unverified write".utf8); corruptNextSave = false
                if refuseRollback { failSave = true }
            } else if !dropSave { data = value }
        }
    }
    private func base() throws -> [String: Any] {
        let p = MemoryDeviceSettingsPersistence(), s: DeviceSettingsStore
        s = DeviceSettingsStore(persistence: p)
        s.discover(id: "exact", name: "QA exact", source: .standardBluetooth, componentIDs: ["left", "right"], kind: .earbuds)
        s.setMonitoring(false, for: "exact"); s.setMenuVisibility(false, for: "exact")
        s.setComponentSelected(false, component: "right", for: "exact")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(p.data)) as? [String: Any])
    }
    private func bytes(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }

    func testPresentMalformedOverlayMatrixBlocksEveryMutationAndPreservesBytes() throws {
        let invalid: [Any] = [NSNull(), [], "overlay", 1, true,
            [:] as [String: Any], ["version": 1], ["hiddenIDs": ["exact"]],
            ["version": 0, "hiddenIDs": []], ["version": 2, "hiddenIDs": []],
            ["version": true, "hiddenIDs": []], ["version": "1", "hiddenIDs": []],
            ["version": 1.5, "hiddenIDs": []], ["version": NSNull(), "hiddenIDs": []],
            ["version": 1, "hiddenIDs": NSNull()], ["version": 1, "hiddenIDs": "exact"],
            ["version": 1, "hiddenIDs": ["exact", 7]], ["version": 1, "hiddenIDs": ["exact", "exact"]],
            ["version": 1, "hiddenIDs": [""]], ["version": 1, "hiddenIDs": ["bad\nID"]],
            ["version": 1, "hiddenIDs": ["bad\u{0000}ID"]],
            ["version": 1, "hiddenIDs": [String(repeating: "x", count: 513)]],
            ["version": 1, "hiddenIDs": [String(repeating: "é", count: 257)]],
            ["version": 1, "hiddenIDs": (0...8192).map { "tombstone-\($0)" }],
            ["version": 1, "hiddenIDs": [], "future": true]]
        for (index, overlay) in invalid.enumerated() {
            var object = try base(); object["visibility"] = overlay
            let p = Storage(); p.data = try bytes(object); let original = p.data
            let s = DeviceSettingsStore(persistence: p), ctx = s.context()
            XCTAssertTrue(s.updatesBlocked, "overlay \(index)")
            XCTAssertNotNil(s.issue, "overlay \(index)")
            XCTAssertFalse(ctx.shouldQuery("unrelated"), "overlay \(index)")
            XCTAssertFalse(s.accepts("unrelated", from: ctx), "overlay \(index)")
            s.discover(id: "new", name: "new", source: .headset)
            s.setMonitoring(true, for: "exact"); s.setMenuVisibility(true, for: "exact")
            s.includeAllComponents(for: "exact"); s.retrySave()
            XCTAssertThrowsError(try s.visibilitySnapshot(for: "exact"))
            XCTAssertThrowsError(try s.previewLink(current: "exact", selected: ["new"], alerts: .init()))
            XCTAssertEqual(p.saves, 0, "overlay \(index) must not rewrite corrupt bytes")
            XCTAssertEqual(p.data, original)
        }
    }

    func testExactIDAndTombstoneBoundsAreAcceptedWithoutNameOrNormalizationMatching() throws {
        var object = try base()
        let ids = [String(repeating: "é", count: 256)] + (0..<8191).map { "unknown-\($0)" }
        object["visibility"] = ["version": 1, "hiddenIDs": ids]
        let p = MemoryDeviceSettingsPersistence(data: try bytes(object)), s: DeviceSettingsStore
        s = DeviceSettingsStore(persistence: p)
        XCTAssertFalse(s.updatesBlocked); XCTAssertNil(s.issue)
        XCTAssertEqual(Set(s.visibility.hiddenIDs), Set(ids))
        XCTAssertFalse(s.context().shouldQuery(ids[0]))
        XCTAssertTrue(s.context().shouldQuery(String(repeating: "e", count: 256)))
        s.discover(id: "new", name: "QA exact", source: .standardBluetooth)
        XCTAssertTrue(s.accepts("new", from: s.context()))
        let reloaded = DeviceSettingsStore(persistence: p)
        XCTAssertEqual(Set(reloaded.visibility.hiddenIDs), Set(ids))
        XCTAssertEqual(reloaded.hiddenDevices.count, 0, "tombstones are not invented catalog rows")
    }

    func testMissingOverlayV2AndLegacyV1PreserveRequestedPreferencesAndSelection() throws {
        var v2 = try base(); v2.removeValue(forKey: "visibility")
        let p = Storage(); p.data = try bytes(v2); let original = p.data
        let s = DeviceSettingsStore(persistence: p)
        XCTAssertFalse(s.updatesBlocked); XCTAssertTrue(s.hiddenDevices.isEmpty)
        XCTAssertEqual(s.devices.first?.preferences, DevicePreferences(monitorBattery: false, showInMenu: false))
        XCTAssertEqual(s.devices.first?.componentSelection, ComponentSelection(mode: .selected, ids: ["left"]))
        XCTAssertEqual(p.data, original); XCTAssertEqual(p.saves, 0)
        let legacy: [String: Any] = ["version": 1, "devices": [["id": "old", "name": "QA old", "source": "hidUnified", "preferences": ["monitorBattery": false, "showInMenu": true]]]]
        p.data = try bytes(legacy)
        let migrated = DeviceSettingsStore(persistence: p)
        XCTAssertFalse(migrated.updatesBlocked); XCTAssertTrue(migrated.hiddenDevices.isEmpty)
        XCTAssertEqual(migrated.preferences(for: "old"), .init(monitorBattery: false, showInMenu: true))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: XCTUnwrap(p.data)) as? [String: Any])?["version"] as? Int, 2)
        var invalidLegacy = legacy; invalidLegacy["visibility"] = ["version": 1, "hiddenIDs": ["old"]]
        let blocked = DeviceSettingsStore(persistence: MemoryDeviceSettingsPersistence(data: try bytes(invalidLegacy)))
        XCTAssertTrue(blocked.updatesBlocked, "overlay is defined only for v2")
    }

    func testLoadFailureAndExplicitResetAreFailClosedAndFenceOldContexts() throws {
        let p = Storage(); p.data = try bytes(base()); p.failRead = true
        let s = DeviceSettingsStore(persistence: p), old = s.context(), original = p.data
        XCTAssertTrue(s.updatesBlocked); XCTAssertFalse(s.accepts("new", from: old))
        s.retrySave(); XCTAssertEqual(p.saves, 0); XCTAssertEqual(p.data, original)
        p.failRead = false
        // Merely repairing IO or retrying is not consent to reset.
        s.retrySave(); XCTAssertTrue(s.updatesBlocked); XCTAssertEqual(p.data, original)
        s.reset()
        XCTAssertFalse(s.updatesBlocked); XCTAssertNil(s.issue); XCTAssertTrue(s.devices.isEmpty)
        XCTAssertTrue(s.visibility.hiddenIDs.isEmpty)
        XCTAssertFalse(s.accepts("new", from: old)); XCTAssertTrue(s.accepts("new", from: s.context()))
        XCTAssertEqual(p.saves, 1)
    }

    func testHideRestoreDurableRollbackReadbackVerificationAndFailureFence() throws {
        for mode in ["throw", "drop", "read"] {
            let p = Storage()
            let store = DeviceSettingsStore(persistence: p)
            store.discover(id: "a", name: "QA a", source: .hidUnified, componentIDs: ["battery"], kind: .mouse)
            store.discover(id: "u", name: "QA unrelated", source: .hidUnified)
            let old = store.context(), original = p.data, snapshot = try store.visibilitySnapshot(for: "a")
            p.failSave = mode == "throw"; p.dropSave = mode == "drop"; p.failRead = mode == "read"
            XCTAssertThrowsError(try store.setHidden(true, snapshot: snapshot), mode)
            XCTAssertFalse(store.isHidden("a"), mode); XCTAssertEqual(p.data, original, mode)
            XCTAssertEqual(store.preferences(for: "a"), .init(), mode)
            XCTAssertFalse(store.accepts("a", from: old), "failed transition still fences affected old work: \(mode)")
            XCTAssertEqual(store.accepts("u", from: old), mode != "read", "read failure must fail closed globally")
            if mode == "read" { XCTAssertTrue(store.updatesBlocked); continue }
            p.failSave = false; p.dropSave = false
            try store.setHidden(true, snapshot: store.visibilitySnapshot(for: "a"))
            XCTAssertTrue(DeviceSettingsStore(persistence: p).isHidden("a"))
            let hiddenBytes = p.data
            p.failSave = true
            XCTAssertThrowsError(try store.setHidden(false, snapshot: store.visibilitySnapshot(for: "a")))
            XCTAssertTrue(store.isHidden("a")); XCTAssertEqual(p.data, hiddenBytes)
            p.failSave = false
            try store.setHidden(false, snapshot: store.visibilitySnapshot(for: "a"))
            XCTAssertFalse(DeviceSettingsStore(persistence: p).isHidden("a"))
            XCTAssertFalse(store.accepts("a", from: old)); XCTAssertTrue(store.accepts("u", from: old))
        }
    }

    func testPostSaveMismatchRestoresVerifiedBytesOrFailsClosedWhenRollbackIsImpossible() throws {
        for rollbackFails in [false, true] {
            let p = Storage()
            let store = DeviceSettingsStore(persistence: p)
            store.discover(id: "a", name: "QA a", source: .hidUnified)
            let original = p.data, context = store.context()
            p.corruptNextSave = true; p.refuseRollback = rollbackFails
            XCTAssertThrowsError(try store.setHidden(true, snapshot: store.visibilitySnapshot(for: "a")))
            XCTAssertFalse(store.isHidden("a"), "unverified Hide never succeeds")
            XCTAssertEqual(store.updatesBlocked, rollbackFails)
            XCTAssertFalse(store.accepts("a", from: context), "attempted transition fences old work")
            if rollbackFails {
                XCTAssertFalse(store.context().shouldQuery("unrelated"))
                XCTAssertNotNil(store.issue)
            } else {
                XCTAssertEqual(p.data, original, "previous durable bytes restored and independently read back")
                XCTAssertTrue(store.accepts("unrelated", from: store.context()))
                XCTAssertFalse(DeviceSettingsStore(persistence: p).isHidden("a"))
            }
        }
    }

    func testFailedExplicitResetCannotUnblockUnreadableVisibilityDocument() throws {
        var object = try base(); object["visibility"] = ["version": 99, "hiddenIDs": ["exact"]]
        let p = Storage(); p.data = try bytes(object); let original = p.data
        let store = DeviceSettingsStore(persistence: p)
        XCTAssertTrue(store.updatesBlocked)
        p.failSave = true
        store.reset()
        XCTAssertEqual(p.data, original, "failed Reset leaves the corrupt persisted visibility bytes in place")
        XCTAssertNotNil(store.issue)
        XCTAssertTrue(store.updatesBlocked, "failed Reset must retain recovery until replacement is durably saved")
        XCTAssertFalse(store.context().shouldQuery("new-route"), "failed Reset must not admit acquisition under an unreadable visibility policy")
        XCTAssertFalse(store.accepts("new-route", from: store.context()), "failed Reset must not admit raw readings while original overlay remains unreadable")
    }

    func testRestoringWholeCurrentGroupKeepsUnrelatedHistoricalTombstones() throws {
        let p = Storage(); var doc = try base()
        doc["visibility"] = ["version": 1, "hiddenIDs": ["exact", "unrelated-historic"]]
        p.data = try bytes(doc)
        let s = DeviceSettingsStore(persistence: p)
        try s.setHidden(false, snapshot: s.visibilitySnapshot(for: "exact"))
        XCTAssertFalse(s.isHidden("exact")); XCTAssertTrue(s.isHidden("unrelated-historic"))
        XCTAssertEqual(s.visibility.hiddenIDs, ["unrelated-historic"])
        XCTAssertEqual(s.preferences(for: "exact"), .init(monitorBattery: false, showInMenu: false))
        XCTAssertEqual(s.devices.first?.kind, .earbuds)
        XCTAssertFalse(s.context().shouldQuery("exact"), "restore respects saved monitoring off")
    }
}
