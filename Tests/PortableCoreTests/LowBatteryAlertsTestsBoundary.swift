import XCTest
@testable import OpenBatteryCore

/// Independent boundary cases only; all storage is in memory and every negative gets a new policy.
final class LowBatteryAlertsTestsBoundary: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var checks = 0
    private func check(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        checks += 1; XCTAssertTrue(condition(), message, file: file, line: line)
    }
    override func tearDown() { print("BOUNDARY_CHECKS \(name): \(checks)"); super.tearDown() }
    private var device: KnownBatteryDevice { .init(id: "d", name: "Device", source: .hidUnified, knownComponentIDs: ["left", "right", "case"]) }
    private func record(_ percent: Int = 10, time: TimeInterval = 0, source: BatterySource = .hidUnified) -> BatteryRecord {
        let t = now.addingTimeInterval(time)
        return BatteryRecord(Observation(id: .init(device: "d", component: "left"), name: "Device", source: source,
            connection: source == .watchCompanion ? .unknown : .connected, quantity: .reportedPercent(percent),
            observedAt: t, measuredAt: source == .watchCompanion ? t : nil, collectedAt: now))
    }
    private func enabled(_ store: AlertPersistence = MemoryAlertPersistence(), threshold: Int = 20) -> LowBatteryAlertPolicy {
        let p = LowBatteryAlertPolicy(persistence: store); var c = p.configuration; c.enabled = true; c.threshold = threshold
        check(p.configure(c), "setup config"); return p
    }
    private func run(_ p: LowBatteryAlertPolicy, _ r: BatteryRecord, at clock: Date? = nil, monitoring: Bool = true) -> [AlertReservation] {
        p.process(records: [r], devices: [device], authorized: true, now: clock ?? now, monitoringAllowed: monitoring)
    }

    func testIsolatedInvalidHighCannotRecoverLatchedEpisode() {
        let cases: [(String, BatterySource, (inout BatteryRecord) -> Void, Bool)] = [
            ("paused", .hidUnified, { _ in }, false),
            ("retained", .hidUnified, { $0.retained = true }, true),
            ("record error", .hidUnified, { $0.error = "read" }, true),
            ("observation error", .hidUnified, { $0.observation.error = "read" }, true),
            ("invalid battery", .hidUnified, { $0.observation.charge = .invalidBattery }, true),
            ("thermal", .hidUnified, { $0.observation.charge = .thermalError }, true),
            ("charging error", .hidUnified, { $0.observation.charge = .chargingError }, true),
            ("disconnected", .hidUnified, { $0.observation.connection = .disconnected }, true),
            ("unknown HID connection", .hidUnified, { $0.observation.connection = .unknown }, true),
            ("unknown", .hidUnified, { $0.observation.quantity = .unknown }, true),
            ("absent", .hidUnified, { $0.observation.quantity = .absent }, true),
            ("estimated", .hidUnified, { $0.observation.quantity = .estimatedPercent(80, calibrationID: "x") }, true),
            ("coarse", .hidUnified, { $0.observation.quantity = .coarse(name: "high", level: 3) }, true),
            ("out of range high", .hidUnified, { $0.observation.quantity = .reportedPercent(101) }, true),
            ("out of range negative", .hidUnified, { $0.observation.quantity = .reportedPercent(-1) }, true),
            ("missing HID observed", .hidUnified, { $0.observation.observedAt = nil }, true),
            ("missing Watch measured", .watchCompanion, { $0.observation.measuredAt = nil }, true),
            ("missing system measured", .systemReport, { $0.observation.measuredAt = nil }, true),
            ("future HID", .hidUnified, { $0.observation.observedAt = $0.observation.collectedAt.addingTimeInterval(1) }, true),
            ("future Watch", .watchCompanion, { $0.observation.measuredAt = $0.observation.collectedAt.addingTimeInterval(1) }, true),
            ("stale HID", .hidUnified, { $0.observation.observedAt = $0.observation.collectedAt.addingTimeInterval(-999) }, true),
            ("stale Watch", .watchCompanion, { $0.observation.measuredAt = $0.observation.collectedAt.addingTimeInterval(-999) }, true),
            ("same quantity time", .hidUnified, { $0.observation.observedAt = $0.observation.collectedAt.addingTimeInterval(-1000) }, true),
            ("older quantity time", .hidUnified, { $0.observation.observedAt = $0.observation.collectedAt.addingTimeInterval(-1001) }, true)
        ]
        for (label, source, mutate, monitoring) in cases {
            let p = enabled()
            var low = record(time: -1000, source: source)
            if source == .systemReport { low.observation.measuredAt = now.addingTimeInterval(-1000) }
            check(run(p, low, at: now.addingTimeInterval(-1000)).count == 1, label + " seed low")
            let owned = p.episodes[0].requestID
            var high = record(80, time: -1, source: source); mutate(&high)
            check(run(p, high, monitoring: monitoring).isEmpty, label + " no send")
            check(p.episodes[0].latched && p.episodes[0].requestID == owned, label + " cannot recover")
            var valid = record(80, source: source)
            if source == .systemReport { valid.observation.measuredAt = now }
            check(run(p, valid).isEmpty && !p.episodes[0].latched, label + " valid high control recovers")
        }
    }

    func testThreshold99RecoveryCapsAt100() {
        let p = enabled(threshold: 99)
        check(run(p, record(98, time: -2)).count == 1, "99 threshold low")
        check(run(p, record(99, time: -1)).isEmpty && p.episodes[0].latched, "99 cannot recover threshold99")
        check(run(p, record(100)).isEmpty && !p.episodes[0].latched, "100 recovers capped boundary")
    }

    func testAuthoritativeTimesIgnoreWrongSourceFields() {
        for source in [BatterySource.hidUnified, .hidLegacy, .headset] {
            let p = enabled(); var r = record(source: source)
            r.observation.measuredAt = now.addingTimeInterval(9999)
            r.observation.sampleMeasuredAt = now.addingTimeInterval(9999)
            check(LowBatteryAlertPolicy.quantityTime(r) == now, "HID/headset observedAt is authoritative")
            check(run(p, r).count == 1, "future nonauthoritative fields cannot invalidate HID/headset")
        }
        let p = enabled(); var watch = record(time: -901, source: .watchCompanion)
        watch.observation.observedAt = now; watch.observation.sampleMeasuredAt = now
        check(run(p, watch).isEmpty, "fresh forwarding cannot refresh old Watch quantity")
        watch.observation.measuredAt = now
        check(run(p, watch).count == 1, "new Watch measuredAt qualifies")
    }

    private final class Store: AlertPersistence {
        var data: Data?; var saves = 0
        init(_ bytes: Data?) { data = bytes }
        func load() throws -> Data? { data }
        func save(_ data: Data) throws { saves += 1; self.data = data }
    }
    private func replaced(_ object: Any, _ path: ArraySlice<String>, _ value: Any) -> Any {
        guard let key = path.first else { return value }
        if var a = object as? [Any], let i = Int(key) { a[i] = replaced(a[i], path.dropFirst(), value); return a }
        var d = object as! [String: Any]; d[key] = replaced(d[key] ?? NSNull(), path.dropFirst(), value); return d
    }
    func testStrictDocumentMatrixPreservesBytesWithoutAutosave() throws {
        let baseStore = MemoryAlertPersistence(), seed = enabled(baseStore)
        var config = seed.configuration; config.devices["d"] = DeviceAlertConfiguration(); check(seed.configure(config), "device fixture")
        check(run(seed, record()).count == 1, "episode fixture")
        let valid = try JSONSerialization.jsonObject(with: XCTUnwrap(baseStore.data))
        var cases: [(String, Data)] = []
        func add(_ path: String, _ values: [Any]) throws {
            for value in values {
                let object = replaced(valid, path.split(separator: "/").map(String.init)[...], value)
                cases.append((path + "=" + String(describing: value), try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])))
            }
        }
        try add("version", [true, "1", 1.5, 0, 2, NSNull()])
        try add("configuration/threshold", [true, "20", 20.5, 0, 100, NSNull()])
        try add("configuration/enabled", [1, "true", NSNull()])
        try add("configuration/devices", [[], "devices", NSNull()])
        try add("configuration/devices/d/customThreshold", [true, "20", 20.5, 0, 100, NSNull()])
        try add("configuration/devices/d/included", [1, "true", NSNull()])
        try add("configuration/devices/d/usesCustomThreshold", [0, "false", NSNull()])
        try add("configuration/devices/d/components/mode", ["unknown", true, NSNull()])
        try add("configuration/devices/d/components/ids", [["left"], [1], "left", NSNull()]) // all-mode cannot carry ids
        try add("episodes/0/attempts", [true, "1", 1.5, -1, 4, NSNull()])
        try add("episodes/0/latched", [1, "true", NSNull()])
        try add("episodes/0/attemptState", ["sent", 1, NSNull()])
        try add("episodes/0/requestID", ["foreign", "cellio.low-battery.bad", 1, NSNull()])
        try add("episodes/0/watermark", ["today", true, NSNull()])
        try add("episodes/0/attemptedAt", ["today", true, NSNull()])
        try add("episodes/0/id/device", ["", "bad\nID", String(repeating: "d", count: 513), 1])
        try add("episodes/0/id/component", ["", "bad\nID", String(repeating: "c", count: 129), 1])
        try add("episodes", ["episodes", NSNull()])
        var missing = valid as! [String: Any]; missing.removeValue(forKey: "version")
        cases.append(("missing version", try JSONSerialization.data(withJSONObject: missing)))
        for text in ["[]", "null", "garbage"] { cases.append((text, Data(text.utf8))) }
        let bytes = try XCTUnwrap(baseStore.data)
        var atLimit = bytes; atLimit.append(Data(repeating: 0x20, count: 1_048_576 - bytes.count))
        let accepted = Store(atLimit), loaded = LowBatteryAlertPolicy(persistence: accepted)
        check(!loaded.corrupt && accepted.saves == 0, "exact byte limit accepts valid document without autosave")
        var oversized = atLimit; oversized.append(0x20); cases.append(("one byte over limit", oversized))
        for (label, bytes) in cases {
            let store = Store(bytes), p = LowBatteryAlertPolicy(persistence: store)
            check(p.corrupt && p.issue != nil, label + " rejected")
            check(run(p, record()).isEmpty, label + " delivery fails closed")
            var c = p.configuration; c.enabled = true
            check(!p.configure(c), label + " edits blocked")
            p.baseline([record()], now: now); p.retry()
            check(store.data == bytes && store.saves == 0, label + " original bytes preserved/no autosave")
        }
        print("BOUNDARY_DOCUMENT_CASES \(cases.count) rejected, 1 exact-size valid")
    }
}
