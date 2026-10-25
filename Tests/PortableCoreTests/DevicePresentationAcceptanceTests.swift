import XCTest
import Foundation
@testable import OpenBatteryCore

final class DevicePresentationAcceptanceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_670_400)

    private func record(_ device: String, _ component: String = "battery", name: String = "Device",
                        source: BatterySource = .hidUnified, connection: ConnectionState = .connected,
                        quantity: Quantity = .reportedPercent(54), charge: ChargeState = .discharging,
                        observed: Date? = nil, measured: Date? = nil, sampled: Date? = nil,
                        collected: Date? = nil, error: String? = nil, retained: Bool? = nil,
                        attempt: Date? = nil) -> BatteryRecord {
        let observation = Observation(id: ComponentID(device: device, component: component), name: name,
                                      source: source, connection: connection, quantity: quantity, charge: charge,
                                      observedAt: observed, measuredAt: measured, sampleMeasuredAt: sampled,
                                      collectedAt: collected ?? now, error: error)
        var result = BatteryRecord(observation)
        result.lastAttempt = attempt ?? collected ?? now
        result.error = error
        if let retained { result.retained = retained }
        return result
    }

    func testGroupsUseStableDeviceIDsAndOrderAirPodsComponents() {
        let input = [record("z-device", "case", name: "AirPods Pro", source: .systemReport),
                     record("a-device", name: "Mouse"),
                     record("z-device", "right", name: "AirPods Pro", source: .systemReport),
                     record("b-device", name: "Mouse"),
                     record("z-device", "left", name: "AirPods Pro", source: .systemReport)]
        let groups = BatteryDevicePresentation.groups(records: input, at: now)
        XCTAssertEqual(groups.map(\.id), ["z-device", "a-device", "b-device"])
        XCTAssertEqual(groups.filter { $0.name == "Mouse" }.count, 2, "same display name with distinct stable IDs stays separate")
        let airpods = try! XCTUnwrap(groups.first { $0.id == "z-device" })
        XCTAssertEqual(airpods.components.map { $0.id.component }, ["left", "right", "case"])
        XCTAssertTrue(airpods.usesAirPodsLayout)
        XCTAssertEqual(BatteryDevicePresentation.groups(records: [], at: now).count, 0)
        XCTAssertEqual(BatteryDevicePresentation.groups(records: [input[1]], at: now).first?.components.count, 1)
    }

    func testPresentationPreservesEveryBatteryRecordField() throws {
        let observed = now.addingTimeInterval(-30), measured = now.addingTimeInterval(-40)
        let sampled = now.addingTimeInterval(-50), collected = now.addingTimeInterval(-4)
        let attempt = now.addingTimeInterval(-2)
        var original = record("preserved-id", "left", name: "Synthetic AirPods", source: .systemReport,
                              connection: .disconnected, quantity: .reportedPercent(0), charge: .unknown,
                              observed: observed, measured: measured, sampled: sampled, collected: collected,
                              error: "synthetic component error", retained: true, attempt: attempt)
        original.observation.error = "observation-level error"
        let presented = try XCTUnwrap(BatteryDevicePresentation.groups(records: [original], at: now).first?.components.first)
        XCTAssertEqual(presented.record.observation.id.device, "preserved-id")
        XCTAssertEqual(presented.record.observation.id.component, "left")
        XCTAssertEqual(presented.record.observation.name, "Synthetic AirPods")
        XCTAssertEqual(presented.record.observation.source, .systemReport)
        XCTAssertEqual(presented.record.observation.connection, .disconnected)
        XCTAssertEqual(presented.record.observation.quantity, .reportedPercent(0))
        XCTAssertEqual(presented.record.observation.charge, .unknown)
        XCTAssertEqual(presented.record.observation.error, "observation-level error")
        XCTAssertEqual(presented.record.error, "synthetic component error")
        XCTAssertTrue(presented.record.retained)
        XCTAssertEqual(presented.record.lastAttempt, attempt)
        XCTAssertEqual(presented.record.observation.observedAt, observed)
        XCTAssertEqual(presented.record.observation.measuredAt, measured)
        XCTAssertEqual(presented.record.observation.sampleMeasuredAt, sampled)
        XCTAssertEqual(presented.record.observation.collectedAt, collected)
    }

    func testZeroUnknownAbsentCoarseAndEstimatedHaveCorrectValuesAndGauges() throws {
        let values = [record("zero", quantity: .reportedPercent(0)),
                      record("unknown", quantity: .unknown),
                      record("absent", quantity: .absent),
                      record("coarse", quantity: .coarse(name: "Good", level: 4)),
                      record("estimated", quantity: .estimatedPercent(42, calibrationID: "synthetic-calibration"))]
        let components = Dictionary(uniqueKeysWithValues: BatteryDevicePresentation.groups(records: values, at: now).map { ($0.id, $0.components[0]) })
        XCTAssertEqual(components["zero"]?.value, "0%")
        XCTAssertEqual(components["zero"]?.reportedPercent, 0)
        XCTAssertEqual(components["unknown"]?.value, "Unknown")
        XCTAssertNil(components["unknown"]?.reportedPercent)
        XCTAssertEqual(components["absent"]?.value, "Not reported")
        XCTAssertNil(components["absent"]?.reportedPercent)
        XCTAssertEqual(components["coarse"]?.value, "Good (coarse)")
        XCTAssertNil(components["coarse"]?.reportedPercent)
        XCTAssertEqual(components["estimated"]?.value, "≈42% (estimated)")
        XCTAssertNil(components["estimated"]?.reportedPercent)
    }

    func testHundredPercentDoesNotInventChargingAndChargingCanLackQuantity() throws {
        let full = record("full", quantity: .reportedPercent(100), charge: .unknown)
        let noQuantityCharging = record("charging", quantity: .unknown, charge: .charging)
        let components = BatteryDevicePresentation.groups(records: [full, noQuantityCharging], at: now).flatMap(\.components)
        XCTAssertEqual(components.first { $0.id.device == "full" }?.charge, "Charge state unknown")
        XCTAssertEqual(components.first { $0.id.device == "full" }?.reportedPercent, 100)
        XCTAssertEqual(components.first { $0.id.device == "charging" }?.value, "Unknown")
        XCTAssertEqual(components.first { $0.id.device == "charging" }?.charge, "Charging")
        XCTAssertNil(components.first { $0.id.device == "charging" }?.reportedPercent)
    }

    func testSystemReportCacheAndUntimestampedConnectedValuesDoNotLookFresh() throws {
        let disconnected = record("cached", "left", name: "Synthetic AirPods", source: .systemReport,
                                  connection: .disconnected, quantity: .reportedPercent(81), collected: now,
                                  retained: true)
        let connected = record("connected", "case", name: "Synthetic AirPods", source: .systemReport,
                               connection: .connected, quantity: .reportedPercent(62), collected: now)
        let byID = Dictionary(uniqueKeysWithValues: BatteryDevicePresentation.groups(records: [disconnected, connected], at: now).map { ($0.id, $0.components[0]) })
        XCTAssertTrue(byID["cached"]!.freshness.contains("Last reported"))
        XCTAssertTrue(byID["cached"]!.freshness.contains("stale"))
        XCTAssertTrue(byID["cached"]!.freshness.contains("Measurement age unknown"))
        XCTAssertEqual(byID["connected"]!.connection, "Connected")
        XCTAssertEqual(byID["connected"]!.freshness, "Measurement age unknown")
        XCTAssertFalse(byID["connected"]!.freshness.contains("0s"))
    }

    func testDifferentComponentAgeAndErrorsAreNotFlattened() throws {
        let old = now.addingTimeInterval(-600), recent = now.addingTimeInterval(-10)
        var left = record("pods", "left", name: "Synthetic AirPods", source: .systemReport,
                          quantity: .reportedPercent(20), observed: old, measured: old)
        left.retained = true
        left.error = "synthetic left error"
        let right = record("pods", "right", name: "Synthetic AirPods", source: .systemReport,
                           quantity: .reportedPercent(90), observed: recent, measured: recent)
        let group = try XCTUnwrap(BatteryDevicePresentation.groups(records: [right, left], at: now).first)
        XCTAssertNil(group.commonFreshness)
        XCTAssertNotEqual(group.components[0].freshness, group.components[1].freshness)
        XCTAssertEqual(group.components[0].record.error, "synthetic left error")
        XCTAssertNil(group.components[1].record.error)
    }

    func testActualSystemReportParserReducerAndGroupingRetainPartialAirPodsFields() throws {
        let payload: [String: Any] = ["SPBluetoothDataType": [["device_not_connected": [["Synthetic AirPods Pro": [
            "device_address": "synthetic-address", "device_batteryLevelLeft": "0%", "device_batteryLevelCase": "76%"
        ]]]]]]
        let parsed = try SystemReportParser.parse(JSONSerialization.data(withJSONObject: payload), collectedAt: now)
        XCTAssertEqual(parsed.count, 3)
        var reducer = BatteryReducer()
        parsed.forEach { reducer.apply($0, now: now) }
        let group = try XCTUnwrap(BatteryDevicePresentation.groups(records: Array(reducer.records.values), at: now).first)
        XCTAssertTrue(group.usesAirPodsLayout)
        XCTAssertEqual(group.components.map { $0.id.component }, ["left", "right", "case"])
        XCTAssertEqual(group.components.map(\.value), ["0%", "Not reported", "76%"])
        XCTAssertEqual(group.components.map(\.reportedPercent), [0, nil, 76])
        XCTAssertTrue(group.components.allSatisfy { $0.connection == "Disconnected" && $0.freshness.contains("Measurement age unknown") })
        XCTAssertTrue(group.components.filter { $0.id.component != "right" }.allSatisfy { $0.freshness.contains("Last reported") })
    }
}
