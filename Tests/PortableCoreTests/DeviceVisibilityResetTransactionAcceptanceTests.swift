import Foundation
import XCTest
@testable import OpenBatteryCore

/// Independent Reset-specific transaction checks; all storage is memory-only.
final class DeviceVisibilityResetTransactionAcceptanceTests: XCTestCase {
    private final class Storage: DeviceSettingsPersistence {
        var data: Data?
        var mode = "normal"
        var writes = 0
        var readFaults = 0
        func load() throws -> Data? {
            if readFaults > 0 { readFaults -= 1; throw DeviceSettingsError.invalidData }
            return data
        }
        func save(_ proposed: Data) throws {
            writes += 1
            switch mode {
            case "throw": throw DeviceSettingsError.saveFailed
            case "drop": return
            case "corrupt": data = Data("corrupt replacement".utf8); mode = "normal"
            case "rollback-fails": data = Data("corrupt replacement".utf8); mode = "throw"
            case "readback": data = proposed; readFaults = 1; mode = "normal"
            case "partial-throw": data = Data("partial failed write".utf8); throw DeviceSettingsError.saveFailed
            default: data = proposed
            }
        }
    }

    func testReadableResetFailurePreservesHiddenCatalogPreferencesAndFencesOldWork() throws {
        for mode in ["throw", "drop", "corrupt", "rollback-fails", "readback", "partial-throw"] {
            let p = Storage(), s: DeviceSettingsStore
            s = DeviceSettingsStore(persistence: p)
            s.discover(id: "a", name: "QA retained", source: .hidUnified, componentIDs: ["left", "right"], kind: .earbuds)
            s.setMonitoring(false, for: "a"); s.setMenuVisibility(false, for: "a")
            s.setComponentSelected(false, component: "right", for: "a")
            try s.setHidden(true, snapshot: s.visibilitySnapshot(for: "a"))
            let original = p.data, devices = s.devices, visibility = s.visibility, old = s.context()
            p.mode = mode
            XCTAssertFalse(s.reset(), mode)
            XCTAssertEqual(s.devices, devices, mode)
            XCTAssertEqual(s.visibility, visibility, mode)
            XCTAssertNotNil(s.issue, mode)
            XCTAssertFalse(s.accepts("unrelated", from: old), mode)
            XCTAssertFalse(s.context().shouldQuery("a"), mode)
            let uncertain = ["drop", "corrupt", "rollback-fails", "readback", "partial-throw"].contains(mode)
            XCTAssertEqual(s.updatesBlocked, uncertain, mode)
            if mode != "rollback-fails" && mode != "partial-throw" { XCTAssertEqual(p.data, original, mode) }
            if uncertain {
                let writes = p.writes, retained = p.data
                s.retrySave(); s.discover(id: "forbidden", name: "forbidden", source: .hidUnified)
                XCTAssertEqual(p.writes, writes, mode); XCTAssertEqual(p.data, retained, mode)
                XCTAssertFalse(s.accepts("unrelated", from: s.context()), mode)
            }
            p.mode = "normal"
            XCTAssertTrue(s.reset(), mode)
            XCTAssertFalse(s.updatesBlocked, mode); XCTAssertNil(s.issue, mode)
            XCTAssertTrue(s.devices.isEmpty, mode); XCTAssertTrue(s.visibility.hiddenIDs.isEmpty, mode)
            XCTAssertTrue(s.accepts("unrelated", from: s.context()), mode)
            XCTAssertFalse(s.accepts("unrelated", from: old), mode)
            let reload = DeviceSettingsStore(persistence: p)
            XCTAssertFalse(reload.updatesBlocked, mode); XCTAssertTrue(reload.devices.isEmpty, mode)
        }
    }

    func testUnreadablePreimageResetRequiresVerifiedCommitAndExplicitRetry() throws {
        for mode in ["throw", "drop", "readback", "normal"] {
            let p = Storage(); p.data = Data("unreadable original".utf8)
            let s = DeviceSettingsStore(persistence: p), original = p.data, old = s.context()
            XCTAssertTrue(s.updatesBlocked)
            p.readFaults = 1; p.mode = mode
            let success = s.reset()
            XCTAssertEqual(success, mode == "normal", mode)
            XCTAssertFalse(s.accepts("new", from: old), mode)
            if success {
                XCTAssertFalse(s.updatesBlocked); XCTAssertTrue(s.accepts("new", from: s.context()))
            } else {
                XCTAssertTrue(s.updatesBlocked, mode); XCTAssertNotNil(s.issue, mode)
                XCTAssertFalse(s.context().shouldQuery("new"), mode)
                XCTAssertFalse(s.accepts("new", from: s.context()), mode)
                if mode == "throw" || mode == "drop" { XCTAssertEqual(p.data, original, mode) }
                let writes = p.writes; s.retrySave(); XCTAssertEqual(p.writes, writes, mode)
                p.mode = "normal"; XCTAssertTrue(s.reset(), mode)
                XCTAssertFalse(s.updatesBlocked, mode)
            }
        }
    }
}
