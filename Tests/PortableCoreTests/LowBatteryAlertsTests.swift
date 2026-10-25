import XCTest
@testable import OpenBatteryCore

final class LowBatteryAlertsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func record(_ device: String = "d", _ part: String = "left", value: Quantity = .reportedPercent(10),
                        at offset: TimeInterval = 0, source: BatterySource = .hidUnified,
                        connection: ConnectionState = .connected, charge: ChargeState = .unknown,
                        observed: Date? = nil, measured: Date? = nil, retained: Bool = false,
                        error: String? = nil) -> BatteryRecord {
        let t = now.addingTimeInterval(offset)
        let o = Observation(id: .init(device: device, component: part), name: device, source: source,
                            connection: connection, quantity: value, charge: charge,
                            observedAt: observed ?? t, measuredAt: measured, collectedAt: t, error: error)
        var r = BatteryRecord(o); r.retained = retained
        return r
    }
    private func device(_ id: String = "d", _ name: String = "Same", _ monitor: Bool = true) -> KnownBatteryDevice {
        .init(id: id, name: name, source: .hidUnified, preferences: .init(monitorBattery: monitor), knownComponentIDs: ["left", "right", "case"])
    }
    private func configured(_ persistence: MemoryAlertPersistence = MemoryAlertPersistence(), threshold: Int = 20) -> LowBatteryAlertPolicy {
        let p = LowBatteryAlertPolicy(persistence: persistence); var c = p.configuration
        c.enabled = true; c.threshold = threshold; XCTAssertTrue(p.configure(c)); return p
    }
    private func run(_ p: LowBatteryAlertPolicy, _ rs: [BatteryRecord], _ ds: [KnownBatteryDevice] = [KnownBatteryDevice(id: "d", name: "Same", source: .hidUnified, knownComponentIDs: ["left", "right", "case"])], authorized: Bool = true, now clock: Date? = nil) -> [AlertReservation] {
        let simulatedNow = clock ?? rs.map(\.observation.collectedAt).max() ?? now
        return p.process(records: rs, devices: ds, authorized: authorized, now: simulatedNow)
    }

    func testDefaultsBoundsAndInvalidConfiguration() {
        let p = LowBatteryAlertPolicy()
        XCTAssertFalse(p.configuration.enabled); XCTAssertEqual(p.configuration.threshold, 20)
        XCTAssertTrue(p.configuration.device("new").included)
        XCTAssertEqual(p.configuration.device("new").components.mode, .all)
        for value in 1...99 { var c = p.configuration; c.threshold = value; XCTAssertTrue(p.configure(c)) }
        var bad = p.configuration; bad.threshold = 0; XCTAssertFalse(p.configure(bad))
        bad.threshold = 100; XCTAssertFalse(p.configure(bad))
        bad.threshold = 20; var d = bad.device("x"); d.customThreshold = 100; bad.devices["x"] = d
        XCTAssertFalse(p.configure(bad))
    }

    func testMalformedVersionAndCorruptBytesFailClosedPreservingBytesUntilReset() throws {
        for bytes in [Data("{\"version\":2}".utf8), Data("garbage".utf8), Data(repeating: 0x41, count: 1_048_577)] {
            let store = MemoryAlertPersistence(data: bytes), p = LowBatteryAlertPolicy(persistence: store)
            XCTAssertTrue(p.corrupt); XCTAssertNotNil(p.issue); XCTAssertTrue(run(p, [record()]).isEmpty)
            XCTAssertEqual(store.data, bytes)
            p.retry(); XCTAssertEqual(store.data, bytes)
            p.reset(); XCTAssertFalse(p.corrupt); XCTAssertNotEqual(store.data, bytes)
        }
    }

    func testZeroIsEligibleAndRepeatedOrSameTimeDoesNotRepeat() {
        let p = configured(); let first = run(p, [record(value: .reportedPercent(0))])
        XCTAssertEqual(first.count, 1); XCTAssertEqual(first[0].components[0].percent, 0)
        XCTAssertTrue(run(p, [record(value: .reportedPercent(0))]).isEmpty)
        XCTAssertTrue(run(p, [record(value: .reportedPercent(0), at: -1)]).isEmpty)
    }

    func testUnknownCoarseEstimateRetainedErrorsAndFreshnessAreIneligible() {
        let p = configured()
        let cases: [BatteryRecord] = [
            record(value: .unknown), record(value: .absent), record(value: .coarse(name: "Low", level: 1)),
            record(value: .estimatedPercent(5, calibrationID: "x")), record(retained: true), record(error: "read"),
            record(at: 1), record(at: 0, observed: now.addingTimeInterval(1)),
            record(source: .systemReport, observed: nil),
            record(source: .headset, connection: .unknown),
            record(source: .watchCompanion, connection: .unknown, measured: now.addingTimeInterval(-901)),
            record(source: .watchCompanion, connection: .unknown, observed: now, measured: now.addingTimeInterval(-1_000))
        ]
        for sample in cases { XCTAssertTrue(run(p, [sample], now: now).isEmpty, "unexpectedly eligible: \(sample.observation)") }
    }

    func testKnownChargingSuppressesLowButFreshHighRecovers() {
        let p = configured()
        XCTAssertTrue(run(p, [record(at: -1, charge: .charging)]).isEmpty)
        XCTAssertEqual(run(p, [record(value: .reportedPercent(10))]).count, 1)
        XCTAssertTrue(run(p, [record(value: .reportedPercent(30), at: 1, charge: .charging)]).isEmpty)
        XCTAssertFalse(p.episodes.first!.latched)
        XCTAssertEqual(run(p, [record(value: .reportedPercent(10), at: 2)]).count, 1)
    }

    func testScopeSelectionMenuIndependenceAndSameNameIdentity() {
        let p = configured(); var c = p.configuration
        var first = c.device("d"); first.components = .init(mode: .selected, ids: ["right"]); c.devices["d"] = first
        XCTAssertTrue(p.configure(c))
        XCTAssertTrue(run(p, [record("d", "left")]).isEmpty)
        XCTAssertEqual(run(p, [record("d", "right")]).count, 1)
        let other = device("other", "Same")
        XCTAssertEqual(run(p, [record("other", "left")], [device(), other]).count, 1)
        XCTAssertTrue(p.configuration.device("d").components.includes("right"))
    }

    func testRecoveryWorksWhenExcludedOffUnauthorizedAndChargingThenNewLowRearms() {
        let p = configured(); XCTAssertEqual(run(p, [record()]).count, 1)
        var c = p.configuration; c.enabled = false; var d = c.device("d"); d.included = false; c.devices["d"] = d
        XCTAssertTrue(p.configure(c))
        XCTAssertTrue(run(p, [record(value: .reportedPercent(25), at: 1, charge: .charging)], authorized: false).isEmpty)
        XCTAssertFalse(p.episodes[0].latched)
        c.enabled = true; d.included = true; c.devices["d"] = d; XCTAssertTrue(p.configure(c))
        XCTAssertEqual(run(p, [record(at: 2)]).count, 1)
    }

    func testBatchCoalescesPartsAndSeparatesDevices() {
        let p = configured(); let work = run(p, [record("d", "right"), record("d", "left"), record("other", "case")], [device(), device("other", "Same")])
        XCTAssertEqual(work.count, 2)
        let same = work.first { $0.deviceID == "d" }!
        XCTAssertEqual(Set(same.components.map(\.id.component)), Set(["left", "right"]))
        XCTAssertNotEqual(work[0].requestID, work[1].requestID)
    }

    func testReservationSavedBeforeWorkAndAmbiguousRestartIsSuppressed() {
        let store = MemoryAlertPersistence(), p = configured(store)
        let work = run(p, [record()]); XCTAssertEqual(work.count, 1)
        let restored = LowBatteryAlertPolicy(persistence: MemoryAlertPersistence(data: store.data))
        XCTAssertTrue(run(restored, [record(at: 1)]).isEmpty)
        XCTAssertTrue(work[0].requestID.hasPrefix("cellio.low-battery."))
    }

    func testSaveFailureBlocksAddAndRetryDoesNotReplayOldLow() {
        final class Store: AlertPersistence { var data: Data?; var fail = false; func load() throws -> Data? { data }; func save(_ d: Data) throws { if fail { throw AlertStorageError.saveFailed }; data = d } }
        let store = Store(), p = LowBatteryAlertPolicy(persistence: store); var c = p.configuration; c.enabled = true; XCTAssertTrue(p.configure(c))
        store.fail = true; XCTAssertTrue(run(p, [record()]).isEmpty); XCTAssertNotNil(p.issue)
        store.fail = false; p.retry(); XCTAssertNil(p.issue)
        XCTAssertTrue(run(p, [record()]).isEmpty)
    }

    func testFailedAttemptRequiresNewerSampleSixtySecondsAndCapsThree() {
        let p = configured(); let first = run(p, [record()])[0]; p.complete(requestID: first.requestID, accepted: false)
        XCTAssertTrue(run(p, [record(at: 1)]).isEmpty)
        let second = run(p, [record(at: 61)])[0]; XCTAssertEqual(second.requestID, first.requestID); p.complete(requestID: second.requestID, accepted: false)
        let third = run(p, [record(at: 122)])[0]; XCTAssertEqual(third.requestID, first.requestID); p.complete(requestID: third.requestID, accepted: false)
        XCTAssertTrue(run(p, [record(at: 183)]).isEmpty)
    }

    func testWatchUsesMeasuredAtNotForwardingTimeAndUnknownConnectionIsAccepted() {
        let measured = now.addingTimeInterval(-20)
        let sample = record(source: .watchCompanion, connection: .unknown, observed: now, measured: measured)
        XCTAssertEqual(LowBatteryAlertPolicy.quantityTime(sample), measured)
        XCTAssertNil(LowBatteryAlertPolicy.ineligibility(sample, monitoring: true, now: now))
    }

    func testRecoveryBoundariesAndIndependentMasterPermissionMonitoringScopes() {
        // Each case gets its own watermark so an earlier low cannot mask its recovery.
        for setup in 0..<4 {
            let p = configured(); XCTAssertEqual(run(p, [record()]).count, 1)
            var c = p.configuration
            var d = c.device("d")
            var devices = [device()]
            var authorized = true
            switch setup {
            case 0: d.components = .init(mode: .selected, ids: ["right"]); c.devices["d"] = d
            case 1: c.enabled = false
            case 2: authorized = false
            default: break // charge-only recovery
            }
            XCTAssertTrue(p.configure(c))
            let recovered = record(value: .reportedPercent(25), at: 1, charge: setup == 3 ? .charging : .unknown)
            XCTAssertTrue(run(p, [recovered], devices, authorized: authorized).isEmpty)
            XCTAssertFalse(p.episodes[0].latched, "recovery must run outside delivery gates: case \(setup)")
        }
    }

    func testRecoveryRequiresStrictlyNewerTimestampAndThresholdPlusFiveWithCap() {
        for threshold in [20, 95] {
            let p = configured(threshold: threshold)
            XCTAssertEqual(run(p, [record()]).count, 1)
            let boundary = threshold == 95 ? 100 : threshold + 5
            XCTAssertTrue(run(p, [record(value: .reportedPercent(boundary), at: 0)]).isEmpty)
            XCTAssertTrue(p.episodes[0].latched, "same timestamp cannot recover")
            XCTAssertTrue(run(p, [record(value: .reportedPercent(boundary - 1), at: 1)]).isEmpty)
            XCTAssertTrue(p.episodes[0].latched, "below recovery boundary cannot recover")
            XCTAssertTrue(run(p, [record(value: .reportedPercent(boundary), at: 2)]).isEmpty)
            XCTAssertFalse(p.episodes[0].latched)
        }
    }

    func testFutureMeasurementCannotRecoverOrSchedule() {
        let p = configured(); XCTAssertEqual(run(p, [record()]).count, 1)
        let futureHID = record(value: .reportedPercent(40), observed: now.addingTimeInterval(10))
        XCTAssertTrue(run(p, [futureHID], now: now).isEmpty)
        XCTAssertTrue(p.episodes[0].latched)
        let futureWatch = record(value: .reportedPercent(40), source: .watchCompanion, connection: .unknown,
                                 observed: now, measured: now.addingTimeInterval(10))
        XCTAssertTrue(run(p, [futureWatch], now: now).isEmpty)
        XCTAssertTrue(p.episodes[0].latched)
    }

    func testUnchangedAndScopeConfigurationEditsDoNotRequestStorageOrAuthorize() {
        let p = configured(); XCTAssertEqual(run(p, [record()]).count, 1)
        var c = p.configuration; var d = c.device("d"); d.components = .init(mode: .selected, ids: ["left"]); c.devices["d"] = d
        XCTAssertTrue(p.configure(c)); XCTAssertTrue(run(p, [record(at: 1)]).isEmpty)
    }

    func testStrictJSONTypesAndFailedConfigurationRetainsRuntimeChoices() throws {
        for bytes in [Data("{\"version\":true}".utf8), Data("{\"version\":1,\"enabled\":\"true\"}".utf8), Data("[]".utf8)] {
            let p = LowBatteryAlertPolicy(persistence: MemoryAlertPersistence(data: bytes))
            XCTAssertTrue(p.corrupt); XCTAssertTrue(run(p, [record()]).isEmpty)
        }
        final class Store: AlertPersistence {
            var data: Data?; var fail = false
            func load() throws -> Data? { data }
            func save(_ data: Data) throws { if fail { throw AlertStorageError.saveFailed }; self.data = data }
        }
        let store = Store(), p = LowBatteryAlertPolicy(persistence: store)
        var initial = p.configuration; initial.threshold = 33; XCTAssertTrue(p.configure(initial))
        let saved = store.data
        store.fail = true
        var rejected = p.configuration; rejected.threshold = 44
        XCTAssertFalse(p.configure(rejected)); XCTAssertEqual(p.configuration.threshold, 44)
        XCTAssertEqual(store.data, saved); XCTAssertNotNil(p.issue)
        XCTAssertTrue(run(p, [record(value: .reportedPercent(40))]).isEmpty)
        store.fail = false; p.retry(); XCTAssertNil(p.issue); XCTAssertEqual(p.configuration.threshold, 44)
        XCTAssertNotEqual(store.data, saved)
    }
}
