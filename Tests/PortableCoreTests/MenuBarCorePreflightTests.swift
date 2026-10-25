import XCTest
@testable import OpenBatteryCore

final class MenuBarCorePreflightTests: XCTestCase {
    private final class Persistence: MenuBarPersistence {
        var data: Data?
        var failSave = false
        var ignoreSave = false
        init(_ data: Data? = nil) { self.data = data }
        func load() throws -> Data? { data }
        func save(_ next: Data?) throws {
            if failSave { throw MenuBarStorageError.saveFailed }
            if !ignoreSave { data = next }
        }
    }

    private func pin(_ device: String = "mouse", _ component: String = "battery") -> MenuBarPin {
        MenuBarPin(id: UUID().uuidString, deviceID: device, componentID: component,
                   sourceMembers: [device], deviceName: device)
    }

    func testAbsentStorageLoadsDefaultsAndInvalidCommitDoesNotWrite() throws {
        let persistence = Persistence()
        let store = MenuBarConfigurationStore(persistence: persistence)
        XCTAssertEqual(store.configuration, MenuBarConfiguration())
        XCTAssertTrue(store.hasVerifiedLayout)
        XCTAssertFalse(store.unavailable)

        var invalid = MenuBarConfiguration()
        invalid.pins = [pin("a"), pin("b"), pin("c"), pin("d")]
        XCTAssertThrowsError(try store.commit(invalid))
        XCTAssertNil(persistence.data)
        XCTAssertEqual(store.configuration, MenuBarConfiguration())
    }

    func testDecodeRejectsUnsupportedVersionAndDuplicateComponent() throws {
        var unsupported = MenuBarConfiguration(); unsupported.version = 2
        let unsupportedData = try JSONEncoder().encode(unsupported)
        XCTAssertThrowsError(try MenuBarConfiguration.decode(unsupportedData))

        var duplicate = MenuBarConfiguration()
        duplicate.pins = [pin("same"), pin("same")]
        XCTAssertThrowsError(try duplicate.validate())
    }

    func testFailedWriteKeepsPriorConfigurationAndFailedRecoveryLeavesUnavailable() throws {
        var initial = MenuBarConfiguration(); initial.pins = [pin()]
        let initialData = try JSONEncoder().encode(initial)
        let persistence = Persistence(initialData)
        let store = MenuBarConfigurationStore(persistence: persistence)
        var next = MenuBarConfiguration(); next.display = .batteryGauge
        persistence.failSave = true
        XCTAssertThrowsError(try store.commit(next))
        XCTAssertEqual(store.configuration, initial)
        XCTAssertEqual(persistence.data, initialData)

        persistence.data = Data("broken".utf8)
        XCTAssertFalse(store.reload())
        persistence.failSave = false
        persistence.ignoreSave = true
        XCTAssertThrowsError(try store.commit(next, resetting: true))
        XCTAssertTrue(store.unavailable)
        XCTAssertEqual(store.configuration, initial)
    }

    func testLayoutCapsAt280AndIgnoresIneligiblePins() {
        let resolved = (0..<4).map { index -> MenuBarResolvedPin in
            let value = pin("d\(index)")
            return MenuBarResolvedPin(pin: value, device: nil, logicalID: value.deviceID,
                                      state: index == 0 ? .hidden : .missing)
        }
        let capped = MenuBarLayout.project(resolved, budget: 10_000)
        XCTAssertLessThanOrEqual(capped.width, 280)
        XCTAssertEqual(capped.displayedIDs, Array(resolved.dropFirst()).map(\.id))
        XCTAssertFalse(capped.displayedIDs.contains(resolved[0].id))
        XCTAssertEqual(capped.displayedIDs.count + capped.overflow, 3)
        XCTAssertEqual(MenuBarLayout.project(resolved, budget: nil).displayedIDs, [])
        XCTAssertEqual(MenuBarLayout.project(resolved, budget: nil).overflow, 0)
    }
}
