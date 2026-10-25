import XCTest
import Foundation
@testable import OpenBatteryCore

final class MainSystemReportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_670_400)

    private func payload(_ records: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["SPBluetoothDataType": records])
    }

    private func report(_ name: String, _ fields: [String: Any], disconnected: Bool = false) throws -> Data {
        let state = disconnected ? "device_not_connected" : "device_connected"
        return try payload([[state: [[name: fields]]]])
    }

    private func fixtureData() throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/pro-x2-system-report.json")
        return try Data(contentsOf: url)
    }

    func testApprovedNestedFixtureProducesOneMainBatteryAtOneHundred() throws {
        let observations = try SystemReportParser.parse(fixtureData(), collectedAt: now)
        XCTAssertEqual(observations.count, 1)
        let item = try XCTUnwrap(observations.first)
        XCTAssertEqual(item.id.component, "battery")
        XCTAssertEqual(item.id.device, "bluetooth-" + SystemReportParser.opaqueIdentity("02:00:00:00:00:42"))
        XCTAssertEqual(item.quantity, .reportedPercent(100))
        XCTAssertEqual(item.connection, .connected)
        XCTAssertEqual(item.source, .systemReport)
        XCTAssertNil(item.measuredAt)
        XCTAssertNil(item.observedAt)
        XCTAssertEqual(item.charge, .unknown)
    }

    func testMainAcceptsGenuineZeroAndInvalidValueIsUnknownWithError() throws {
        let zero = try SystemReportParser.parse(report("Generic audio", ["device_address": "zero", "device_batteryLevelMain": "0%"]), collectedAt: now)
        XCTAssertEqual(zero.count, 1)
        XCTAssertEqual(zero.first?.quantity, .reportedPercent(0))

        let invalid = try SystemReportParser.parse(report("Generic audio", ["device_address": "invalid", "device_batteryLevelMain": "101%"]), collectedAt: now)
        XCTAssertEqual(invalid.count, 1)
        XCTAssertEqual(invalid.first?.quantity, .unknown)
        XCTAssertNotNil(invalid.first?.error)
    }

    func testMainRequiresActualKeyAndMissingMainKeepsAirPodsFallback() throws {
        let unrelated = try SystemReportParser.parse(report("Generic audio", ["device_firmwareVersion": "1"]), collectedAt: now)
        XCTAssertTrue(unrelated.isEmpty)
        let fallback = try SystemReportParser.parse(report("AirPods Pro", ["device_address": "pods"]), collectedAt: now)
        XCTAssertEqual(fallback.map(\.id.component).sorted(), ["case", "left", "right"])
        XCTAssertTrue(fallback.allSatisfy { $0.quantity == .absent })
    }

    func testExplicitPartsTakePriorityOverMainWithoutFanout() throws {
        let data = try report("Generic audio", [
            "device_address": "parts", "device_batteryLevelMain": "88%",
            "device_batteryLevelLeft": "61%", "device_batteryLevelRight": "62%"
        ])
        let observations = try SystemReportParser.parse(data, collectedAt: now)
        XCTAssertEqual(observations.map(\.id.component).sorted(), ["case", "left", "right"])
        XCTAssertEqual(observations.first { $0.id.component == "left" }?.quantity, .reportedPercent(61))
        XCTAssertEqual(observations.first { $0.id.component == "right" }?.quantity, .reportedPercent(62))
        XCTAssertEqual(observations.first { $0.id.component == "case" }?.quantity, .absent)
    }

    func testConnectionStateAndDuplicateOpaqueIdentityPreferConnected() throws {
        let connected = ["device_address": "same", "device_batteryLevelMain": "70%"]
        let disconnected = ["device_address": "same", "device_batteryLevelMain": "69%"]
        let data = try payload([
            ["device_connected": [["Generic one": connected], ["Generic duplicate": connected]]],
            ["device_not_connected": [["Generic old": disconnected]]]
        ])
        let observations = try SystemReportParser.parse(data, collectedAt: now)
        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(observations.first?.id.device, "bluetooth-" + SystemReportParser.opaqueIdentity("same"))
        XCTAssertEqual(observations.first?.connection, .connected)
        XCTAssertEqual(observations.first?.quantity, .reportedPercent(70))

        let offline = try SystemReportParser.parse(report("Generic offline", ["device_address": "offline", "device_batteryLevelMain": "70%"], disconnected: true), collectedAt: now)
        XCTAssertEqual(offline.first?.connection, .disconnected)
    }

    func testUntimestampedMainStaysUnknownAgeAndLowAlertIneligible() throws {
        let data = try SystemReportParser.parse(report("Generic audio", ["device_address": "low", "device_batteryLevelMain": "10%"]), collectedAt: now)
        var reducer = BatteryReducer()
        data.forEach { reducer.apply($0, now: now) }
        let record = try XCTUnwrap(reducer.records.values.first)
        XCTAssertNil(record.observation.measuredAt)
        XCTAssertNil(record.observation.observedAt)
        XCTAssertEqual(record.ageDescription(at: now), "Measurement age unknown")
        XCTAssertEqual(LowBatteryAlertPolicy.ineligibility(record, monitoring: true, now: now), "Source age unknown")
    }
}
