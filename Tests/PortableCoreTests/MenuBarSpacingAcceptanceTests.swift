import XCTest
@testable import OpenBatteryCore

/// Expectations frozen from docs/SPEC-MENUBAR-SPACING.md before implementation.
final class MenuBarSpacingAcceptanceTests: XCTestCase {
    private final class Disk: MenuBarPersistence {
        var data: Data?
        var writes = 0
        var failNextSave = false
        var ignoreNextSave = false
        var failReadbackOnce = false
        private var pendingReadFailure = false
        init(_ data: Data? = nil) { self.data = data }
        func load() throws -> Data? {
            if pendingReadFailure {
                pendingReadFailure = false
                throw MenuBarStorageError.unavailable
            }
            return data
        }
        func save(_ next: Data?) throws {
            writes += 1
            if failNextSave {
                failNextSave = false
                throw MenuBarStorageError.saveFailed
            }
            if ignoreNextSave { ignoreNextSave = false }
            else { data = next }
            if failReadbackOnce {
                failReadbackOnce = false
                pendingReadFailure = true
            }
        }
    }

    private func pins(_ components: [String] = ["left", "right", "case"]) -> [MenuBarResolvedPin] {
        components.enumerated().map { index, component in
            let id = String(format: "00000000-0000-0000-0000-%012d", index + 1)
            let pin = MenuBarPin(id: id, deviceID: "pods", componentID: component,
                                sourceMembers: ["pods-route"], deviceName: "QA Pods")
            return MenuBarResolvedPin(pin: pin, device: nil, logicalID: "pods", state: .missing)
        }
    }

    private func configuration() -> MenuBarConfiguration {
        var result = MenuBarConfiguration()
        result.display = .batteryGauge
        result.separator = .line
        result.pins = pins(["case", "left", "right"]).map(\.pin)
        return result
    }

    private func document(spacing: String? = nil) throws -> Data {
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration())) as? [String: Any])
        raw.removeValue(forKey: "spacing")
        let legacy = String(decoding: try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]), as: UTF8.self)
        guard let spacing else { return Data(legacy.utf8) }
        return Data(("{\"spacing\":" + spacing + "," + legacy.dropFirst()).utf8)
    }

    func testDefaultBoundsAndEveryIntegerSpacingRoundTrip() throws {
        XCTAssertEqual(MenuBarConfiguration().spacing, 8)
        XCTAssertEqual(DefaultsMenuBarPersistence.key, "cellio.menuBar.v1")
        for spacing in 4...16 {
            var value = configuration()
            value.spacing = spacing
            try value.validate()
            let disk = Disk()
            let store = MenuBarConfigurationStore(persistence: disk)
            try store.commit(value)
            XCTAssertEqual(store.configuration, value)
            XCTAssertEqual(MenuBarConfigurationStore(persistence: disk).configuration, value)
            let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(disk.data)) as? [String: Any])
            XCTAssertEqual(Set(raw.keys), Set(["version", "display", "separator", "pins", "spacing"]))
            XCTAssertEqual(StrictJSON.integer(raw["spacing"]), spacing)
        }
        for spacing in [Int.min, -1, 0, 3, 17, Int.max] {
            var value = configuration()
            value.spacing = spacing
            let disk = Disk()
            let store = MenuBarConfigurationStore(persistence: disk)
            XCTAssertThrowsError(try value.validate(), "spacing=\(spacing)")
            XCTAssertThrowsError(try store.commit(value), "spacing=\(spacing)")
            XCTAssertEqual(disk.writes, 0)
            XCTAssertEqual(store.configuration.spacing, 8)
        }
    }

    func testLegacySchemaLoadsAllFieldsWithoutWritingOrNormalizing() throws {
        let bytes = try document()
        let expected = configuration()
        XCTAssertEqual(try MenuBarConfiguration.decode(bytes), expected)
        let disk = Disk(bytes)
        let store = MenuBarConfigurationStore(persistence: disk)
        XCTAssertFalse(store.unavailable)
        XCTAssertTrue(store.hasVerifiedLayout)
        XCTAssertEqual(store.configuration.spacing, 8)
        XCTAssertEqual(store.configuration.pins, expected.pins)
        XCTAssertEqual(store.configuration.display, .batteryGauge)
        XCTAssertEqual(store.configuration.separator, .line)
        XCTAssertTrue(store.reload())
        XCTAssertEqual(store.configuration, expected)
        XCTAssertEqual(disk.writes, 0)
        XCTAssertEqual(disk.data, bytes)
    }

    func testExtendedSchemaRejectsNonIntegerAndUnknownOrIncompleteFieldsWithoutWrites() throws {
        let invalid = ["true", "false", "null", "\"8\"", "8.5", "-1", "3", "17", "1e309", "NaN", "Infinity", "[]", "{}"]
        for literal in invalid {
            let bytes = try document(spacing: literal)
            XCTAssertThrowsError(try MenuBarConfiguration.decode(bytes), literal)
            let disk = Disk(bytes)
            let store = MenuBarConfigurationStore(persistence: disk)
            XCTAssertTrue(store.unavailable, literal)
            XCTAssertFalse(store.hasVerifiedLayout, literal)
            XCTAssertEqual(disk.writes, 0, literal)
            XCTAssertEqual(disk.data, bytes, literal)
        }
        let good = try document(spacing: "12")
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: good) as? [String: Any])
        for key in ["version", "display", "separator", "pins"] {
            var changed = raw
            changed.removeValue(forKey: key)
            XCTAssertThrowsError(try MenuBarConfiguration.decode(JSONSerialization.data(withJSONObject: changed)), key)
        }
        for legacy in [true, false] {
            var changed = raw
            if legacy { changed.removeValue(forKey: "spacing") }
            changed["itemSpacing"] = 12
            XCTAssertThrowsError(try MenuBarConfiguration.decode(JSONSerialization.data(withJSONObject: changed)))
        }
        var nested = raw
        var savedPins = try XCTUnwrap(nested["pins"] as? [[String: Any]])
        savedPins[0]["spacing"] = 12
        nested["pins"] = savedPins
        XCTAssertThrowsError(try MenuBarConfiguration.decode(JSONSerialization.data(withJSONObject: nested)))
    }

    func testSpacingSaveFailureAndMismatchedReadbackRestoreExactLegacyBytesThenRetry() throws {
        let legacy = try document()
        let disk = Disk(legacy)
        let store = MenuBarConfigurationStore(persistence: disk)
        let initial = store.configuration
        var next = initial
        next.spacing = 16
        disk.failNextSave = true
        XCTAssertThrowsError(try store.commit(next))
        XCTAssertEqual(store.configuration, initial)
        XCTAssertEqual(disk.data, legacy)
        XCTAssertFalse(store.unavailable)
        disk.ignoreNextSave = true
        XCTAssertThrowsError(try store.commit(next))
        XCTAssertEqual(store.configuration, initial)
        XCTAssertEqual(disk.data, legacy)
        XCTAssertFalse(store.unavailable)
        try store.commit(next)
        XCTAssertEqual(store.configuration, next)
        XCTAssertEqual(MenuBarConfigurationStore(persistence: disk).configuration, next)
        XCTAssertEqual(try MenuBarConfiguration.decode(XCTUnwrap(disk.data)).spacing, 16)
    }

    func testReadbackFailureRestoresSpacingAndAbsentStorageAndRecoveryDefaults() throws {
        for legacy in [false, true] {
            let original = legacy ? try document() : nil
            let disk = Disk(original)
            let store = MenuBarConfigurationStore(persistence: disk)
            let initial = store.configuration
            var next = initial
            next.spacing = 4
            disk.failReadbackOnce = true
            XCTAssertThrowsError(try store.commit(next))
            XCTAssertEqual(store.configuration, initial)
            XCTAssertEqual(store.configuration.spacing, 8)
            XCTAssertEqual(disk.data, original)
            XCTAssertEqual(disk.writes, 2)
            XCTAssertFalse(store.unavailable)
        }
        let corrupt = Disk(try document(spacing: "true"))
        let recovery = MenuBarConfigurationStore(persistence: corrupt)
        XCTAssertTrue(recovery.unavailable)
        try recovery.commit(MenuBarConfiguration(), resetting: true)
        XCTAssertFalse(recovery.unavailable)
        XCTAssertEqual(recovery.configuration, MenuBarConfiguration())
        XCTAssertEqual(try MenuBarConfiguration.decode(XCTUnwrap(corrupt.data)).spacing, 8)
    }

    func testZeroOneTwoThreePinsUseOnlyOccupiedSpansAndSelectedIntervals() {
        let resolved = pins()
        let widths = Dictionary(uniqueKeysWithValues: zip(resolved.map(\.id), [50.0, 60.0, 70.0]))
        for spacing in [4, 8, 16] {
            let empty = MenuBarLayout.project([], budget: 280, spacing: spacing, contentWidths: widths)
            XCTAssertEqual(empty.displayedIDs, [])
            XCTAssertEqual(empty.overflow, 0)
            XCTAssertEqual(empty.width, 26)
            for count in 1...3 {
                let selected = Array(resolved.prefix(count))
                let layout = MenuBarLayout.project(selected, budget: 280, spacing: spacing, contentWidths: widths)
                // Existing native image insets total4; target overhead2. No24pt anchor tail.
                let expected = [50.0, 60.0, 70.0].prefix(count).reduce(6, +) + Double(count - 1) * Double(spacing)
                XCTAssertEqual(layout.displayedIDs, selected.map(\.id))
                XCTAssertEqual(layout.overflow, 0)
                XCTAssertEqual(layout.width, expected)
            }
        }
        let caseOnly = MenuBarLayout.project(Array(resolved.suffix(1)), budget: 280, spacing: 16, contentWidths: widths)
        XCTAssertEqual(caseOnly.displayedIDs, [resolved[2].id])
        XCTAssertEqual(caseOnly.width, 76)
    }

    func testChosenGapAndOverflowFitAtExactBoundaryWithoutSqueezingOrDeletingPins() {
        let resolved = pins()
        let originalIDs = resolved.map(\.id)
        let widths = Dictionary(uniqueKeysWithValues: resolved.map { ($0.id, 70.0) })
        let allAtMinimum = MenuBarLayout.project(resolved, budget: 224, spacing: 4, contentWidths: widths)
        XCTAssertEqual(allAtMinimum.displayedIDs, originalIDs)
        XCTAssertEqual(allAtMinimum.width, 224)
        let spaced = MenuBarLayout.project(resolved, budget: 224, spacing: 16, contentWidths: widths)
        XCTAssertEqual(spaced.displayedIDs, Array(originalIDs.prefix(2)))
        XCTAssertEqual(spaced.overflow, 1)
        XCTAssertEqual(spaced.width, 188)
        let exact = MenuBarLayout.project(resolved, budget: 180, spacing: 8, contentWidths: widths)
        XCTAssertEqual(exact.displayedIDs, Array(originalIDs.prefix(2)))
        XCTAssertEqual(exact.overflow, 1)
        XCTAssertEqual(exact.width, 180)
        let below = MenuBarLayout.project(resolved, budget: 179.5, spacing: 8, contentWidths: widths)
        XCTAssertEqual(below.displayedIDs, [originalIDs[0]])
        XCTAssertEqual(below.overflow, 2)
        XCTAssertEqual(below.width, 102)
        let none = MenuBarLayout.project(resolved, budget: 101.5, spacing: 8, contentWidths: widths)
        XCTAssertEqual(none.displayedIDs, [])
        XCTAssertEqual(none.overflow, 0)
        XCTAssertEqual(none.width, 26)
        XCTAssertEqual(resolved.map(\.id), originalIDs)
    }

    func testFallbackFollowsDisplayedEligibilityAndUnsafeGeometryRatherThanSavedCount() {
        var resolved = pins()
        resolved[0].state = .hidden
        resolved[1].state = .coalesced
        let widths = Dictionary(uniqueKeysWithValues: resolved.map { ($0.id, 50.0) })
        let visible = MenuBarLayout.project(resolved, budget: 56, spacing: 8, contentWidths: widths)
        XCTAssertEqual(visible.displayedIDs, [resolved[2].id])
        XCTAssertEqual(visible.overflow, 0)
        XCTAssertEqual(visible.width, 56)
        for state in [MenuBarResolvedPin.State.missing, .review, .active] {
            resolved[2].state = state
            XCTAssertEqual(MenuBarLayout.project(resolved, budget: 56, spacing: 8, contentWidths: widths).displayedIDs, [resolved[2].id])
        }
        resolved[2].state = .hidden
        let hidden = MenuBarLayout.project(resolved, budget: 280, spacing: 16, contentWidths: widths)
        XCTAssertEqual(hidden.displayedIDs, [])
        XCTAssertEqual(hidden.width, 26)
        for budget: Double? in [nil, .nan, .infinity, -.infinity, -1, 0, 25, 55.5] {
            let fallback = MenuBarLayout.project(pins(["case"]), budget: budget, spacing: 8,
                                                 contentWidths: [pins(["case"])[0].id: 50])
            XCTAssertEqual(fallback.displayedIDs, [])
            XCTAssertEqual(fallback.overflow, 0)
            XCTAssertEqual(fallback.width, 26)
        }
    }

    func testBudgetCapAndActualReadingSpansReplaceEmptyMarkerOrGaugeReservations() {
        let resolved = pins()
        let ids = resolved.map(\.id)
        // Supplied occupied widths represent marker-free gauge, percentage and two-marker reading.
        let widths = Dictionary(uniqueKeysWithValues: zip(ids, [42.0, 52.0, 69.0]))
        let compact = MenuBarLayout.project(resolved, budget: 185, spacing: 8, contentWidths: widths)
        XCTAssertEqual(compact.displayedIDs, ids)
        XCTAssertEqual(compact.width, 185)
        let wider = Dictionary(uniqueKeysWithValues: resolved.map { ($0.id, 90.0) })
        let capped = MenuBarLayout.project(resolved, budget: 10_000, spacing: 8, contentWidths: wider)
        XCTAssertEqual(capped.displayedIDs, Array(ids.prefix(2)))
        XCTAssertEqual(capped.overflow, 1)
        XCTAssertEqual(capped.width, 220)
        XCTAssertLessThanOrEqual(capped.width, 280)
        var overwideFirst = widths
        overwideFirst[ids[0]] = 281
        let cannotSkipFirst = MenuBarLayout.project(resolved, budget: 280, spacing: 8, contentWidths: overwideFirst)
        XCTAssertEqual(cannotSkipFirst.displayedIDs, [])
        XCTAssertEqual(cannotSkipFirst.width, 26)
    }
}
