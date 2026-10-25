import XCTest
import Foundation
@testable import OpenBatteryCore

/// Independent contract tests for the approved v2 visibility wire overlay.
/// The fixture is produced by the real store, then only the wire field is injected.
final class DeviceVisibilityOverlayAcceptanceTests: XCTestCase {
    private func documentWithVisibility(hiddenIDs: [String]) throws -> Data {
        let memory = MemoryDeviceSettingsPersistence()
        let writer = DeviceSettingsStore(persistence: memory)
        for id in ["hidden-exact", "ordinary-eligible"] {
            writer.discover(id: id, name: id, source: .hidUnified)
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(memory.data)) as? [String: Any])
        object["visibility"] = ["version": 1, "hiddenIDs": hiddenIDs]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    func testInjectedHiddenExactIDIsExcludedFromRealQueryAndAcceptancePolicy() throws {
        let bytes = try documentWithVisibility(hiddenIDs: ["hidden-exact"])
        let store = DeviceSettingsStore(persistence: MemoryDeviceSettingsPersistence(data: bytes))
        let context = store.context()

        XCTAssertFalse(context.shouldQuery("hidden-exact"), "hidden exact route must not be queried")
        XCTAssertFalse(store.accepts("hidden-exact", from: context), "hidden route payload must not be accepted")
        XCTAssertTrue(context.shouldQuery("ordinary-eligible"), "unrelated eligible route remains queryable")
        XCTAssertTrue(store.accepts("ordinary-eligible", from: context), "unrelated eligible route remains accepted")
        XCTAssertEqual(store.preferences(for: "hidden-exact"), DevicePreferences(), "visibility must not rewrite requested preferences")
        XCTAssertFalse(store.updatesBlocked, "valid v1 visibility overlay is readable")
    }

    func testUnknownOrMalformedPresentVisibilityFailsClosedAndPreservesOriginalBytes() throws {
        let valid = try documentWithVisibility(hiddenIDs: ["hidden-exact"])
        let base = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        let badOverlays: [[String: Any]] = [
            ["version": 2, "hiddenIDs": ["hidden-exact"]],
            ["version": 1, "hiddenIDs": "hidden-exact"],
            ["version": 1, "hiddenIDs": ["hidden-exact", "hidden-exact"]],
            ["version": 1, "hiddenIDs": [""]]
        ]
        for overlay in badOverlays {
            var object = base
            object["visibility"] = overlay
            let original = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let persistence = MemoryDeviceSettingsPersistence(data: original)
            let store = DeviceSettingsStore(persistence: persistence)
            XCTAssertTrue(store.updatesBlocked, "invalid present visibility must block policy")
            XCTAssertFalse(store.accepts("ordinary-eligible", from: store.context()))
            store.discover(id: "new-route", name: "New", source: .headset)
            XCTAssertEqual(persistence.data, original, "invalid visibility bytes must not be overwritten")
            XCTAssertNotNil(store.issue)
        }
    }
}
