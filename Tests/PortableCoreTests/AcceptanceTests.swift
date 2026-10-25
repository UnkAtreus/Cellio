import XCTest
import Foundation
@testable import OpenBatteryCore

private final class FixtureTransport: ReportTransport {
    let advertisedReports: [UInt8:Int] = [:]
    var responses: [[UInt8]]
    private(set) var sent: [[UInt8]] = []
    init(_ responses: [[UInt8]]) { self.responses = responses }
    func exchange(_ output:[UInt8], timeout:TimeInterval, match:([UInt8]) throws -> [UInt8]?) throws -> [UInt8] {
        sent.append(output)
        guard !responses.isEmpty else { throw ParseFailure.timeout }
        return try match(responses.removeFirst()) ?? { throw ParseFailure.timeout }()
    }
}

final class AcceptanceTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_792_670_400) // 2026-10-22 12:00:00 UTC
    func airpods(_ props: [String: Any], disconnected: Bool = false) throws -> [Observation] {
        let entry: [String: Any] = ["AirPods Pro": props]
        let controller: [String: Any] = [disconnected ? "device_not_connected" : "device_connected": [entry]]
        return try SystemReportParser.parse(JSONSerialization.data(withJSONObject: ["SPBluetoothDataType": [controller]]), collectedAt: now)
    }

    func testAirPodsComponentsAreIndependentAndPreserveRealZero() throws {
        let values = try airpods(["device_address":"synthetic", "device_batteryLevelLeft":"0%", "device_batteryLevelCase":"76%"])
        XCTAssertEqual(values.count, 3)
        XCTAssertEqual(values.first { $0.id.component == "left" }?.quantity, .reportedPercent(0))
        XCTAssertEqual(values.first { $0.id.component == "right" }?.quantity, .absent)
        XCTAssertEqual(values.first { $0.id.component == "case" }?.quantity, .reportedPercent(76))
        XCTAssertNil(values.first { $0.id.component == "left" }?.measuredAt)
        XCTAssertEqual(values.first { $0.id.component == "left" }?.observedAt, now)
    }

    func testAirPodsRejectInvalidScalarsAndTrimOnlyIntegerPercent() throws {
        let values = try airpods(["device_batteryLevelLeft":"101%", "device_batteryLevelRight":" 42% ", "device_batteryLevelCase":"4.5%"])
        XCTAssertEqual(values.first { $0.id.component == "left" }?.quantity, .unknown)
        XCTAssertEqual(values.first { $0.id.component == "right" }?.quantity, .reportedPercent(42))
        XCTAssertEqual(values.first { $0.id.component == "case" }?.quantity, .unknown)
        XCTAssertEqual(SystemReportParser.percent(NSNumber(value: true)), nil)
    }

    func testSystemReportOmitsUnrelatedAndRetainsDisconnectedCachedValues() throws {
        let emptyData = try JSONSerialization.data(withJSONObject:["SPBluetoothDataType":[["device_connected":[["Keyboard":["device_firmwareVersion":"x"]]]]]])
        let empty = try SystemReportParser.parse(emptyData, collectedAt:now)
        XCTAssertTrue(empty.isEmpty)
        let cached = try airpods(["device_address":"synthetic", "device_batteryLevelLeft":"81%"], disconnected: true)
        let left = try XCTUnwrap(cached.first { $0.id.component == "left" })
        XCTAssertEqual(left.connection, .disconnected)
        XCTAssertEqual(left.quantity, .reportedPercent(81))
        XCTAssertNil(left.measuredAt)
        XCTAssertEqual(BatteryRecord(left).ageDescription(at: now), "Measurement age unknown")
    }

    func testReducerFailureDisconnectAndChargeOnlyDoNotRefreshQuantity() throws {
        let id = ComponentID(device: "mx-A")
        let oldTime = now.addingTimeInterval(-600)
        var reducer = BatteryReducer()
        reducer.apply(Observation(id:id, name:"MX", source:.hidUnified, connection:.connected, quantity:.reportedPercent(36), observedAt:oldTime, measuredAt:oldTime, collectedAt:oldTime), now:now)
        reducer.fail(id:id, at:now, message:"timeout")
        XCTAssertEqual(reducer.records[id]?.observation.observedAt, oldTime)
        XCTAssertEqual(reducer.records[id]?.lastAttempt, now)
        XCTAssertEqual(reducer.records[id]?.presentation(at:now).value, "36%")
        reducer.apply(Observation(id:id, name:"MX", source:.hidUnified, connection:.connected, quantity:.unknown, charge:.charging, collectedAt:now), now:now)
        XCTAssertEqual(reducer.records[id]?.observation.quantity, .reportedPercent(36))
        XCTAssertEqual(reducer.records[id]?.observation.observedAt, oldTime)
        XCTAssertEqual(reducer.records[id]?.observation.charge, .charging)
        reducer.disconnect(device:"mx-A", at:now)
        XCTAssertEqual(reducer.records[id]?.observation.connection, .disconnected)
        XCTAssertEqual(reducer.records[id]?.observation.observedAt, oldTime)
    }

    func testReducerRejectsFutureMeasurementAndDoesNotInventSystemReportAge() throws {
        let id = ComponentID(device:"airpods-A", component:"case")
        var reducer = BatteryReducer()
        let observation = Observation(id:id, name:"AirPods", source:.systemReport, connection:.connected, quantity:.reportedPercent(100), observedAt:now, collectedAt:now)
        reducer.apply(observation, now:now)
        XCTAssertEqual(reducer.records[id]?.presentation(at:now).detail, "Measurement age unknown")
        let future = Observation(id:id, name:"AirPods", source:.watchCompanion, connection:.connected, quantity:.reportedPercent(1), measuredAt:now.addingTimeInterval(121), collectedAt:now)
        reducer.apply(future, now:now)
        XCTAssertEqual(reducer.records[id]?.error, "Source clock is more than two minutes ahead")
        XCTAssertEqual(reducer.records[id]?.observation.quantity, .reportedPercent(100))
    }

    func testUnifiedCapabilitiesDistinguishPercentFromCoarseAndZeroIsValid() throws {
        let pct = try UnifiedCapabilities([4, 3])
        XCTAssertEqual(try HIDBatteryDecoder.unified([0,4,1], capabilities:pct).quantity, .reportedPercent(0))
        XCTAssertEqual(try HIDBatteryDecoder.unified([63,4,1], capabilities:pct).quantity, .reportedPercent(63))
        let coarse = try UnifiedCapabilities([8,1])
        let reading = try HIDBatteryDecoder.unified([0,8,0], capabilities:coarse)
        XCTAssertEqual(reading.quantity, .coarse(name:"Full", level:8))
        XCTAssertTrue(reading.quantity.display.contains("coarse"))
        XCTAssertEqual(reading.charge, .discharging)
    }

    func testUnifiedShortCoreAndInvalidStatusDoNotCreateSuccess() throws {
        let caps = try UnifiedCapabilities([15,3])
        XCTAssertEqual(try HIDBatteryDecoder.unified([50,4,7], capabilities:caps).charge, .chargingError)
        XCTAssertThrowsError(try HIDBatteryDecoder.unified([50,4,8], capabilities:caps))
        XCTAssertThrowsError(try HIDBatteryDecoder.unified([101,4,0], capabilities:caps))
        XCTAssertThrowsError(try HIDBatteryDecoder.unified([50,4], capabilities:caps))
        let noLevels = try UnifiedCapabilities([0,0])
        XCTAssertThrowsError(try HIDBatteryDecoder.unified([0,1,0], capabilities:noLevels))
    }

    func testLegacyUnknownChargingPlaceholderAndPrecision() throws {
        let capabilities = [UInt8(10), 2]
        XCTAssertEqual(try HIDBatteryDecoder.legacy([0,1,0], capabilities:capabilities).quantity, .unknown)
        XCTAssertEqual(try HIDBatteryDecoder.legacy([47,1,1], capabilities:capabilities).quantity, .unknown)
        let gauge = try HIDBatteryDecoder.legacy([47,1,0], capabilities:capabilities)
        XCTAssertEqual(gauge.quantity, .reportedPercent(47))
        let coarse = try HIDBatteryDecoder.legacy([47,1,0], capabilities:[5,0])
        XCTAssertEqual(coarse.quantity, .coarse(name:"", level:47))
        XCTAssertTrue(coarse.quantity.display.contains("coarse"))
    }

    func testHIDReplyRequiresFullRequestIdentityAndRejectsErrors() throws {
        let req = HIDPlusRequest(device:1, feature:7, function:1, software:3)
        XCTAssertEqual(try req.reply([0x10,1,7,0x13,42,0,0]).first, 42)
        for frame: [UInt8] in [[0x10,2,7,0x13,42,0,0], [0x10,1,7,0x12,42,0,0], [0x10,1,7,0x10,42,0,0]] {
            XCTAssertThrowsError(try req.reply(frame))
        }
        XCTAssertThrowsError(try req.reply([0x10,1,0xff,7,0x13,8,0]))
        XCTAssertThrowsError(try req.reply([0x10,1,7,0x13,42]))
    }

    func testCenturionFrameBoundsNestedIdentityAndLegacyGatePrimitives() throws {
        let good = try HeadsetFrame.encode([1,2,3])
        XCTAssertEqual(try HeadsetFrame.payload(good), [1,2,3])
        XCTAssertThrowsError(try HeadsetFrame.payload([0x51,2,1,0]))
        XCTAssertThrowsError(try HeadsetFrame.payload([0x51,62,0,1]))
        XCTAssertThrowsError(try HeadsetFrame.payload([0x50,2,0,1]))
        XCTAssertNil(try HeadsetFrame.nestedResult(HeadsetFrame.encode([2,0x11]) , bridge:2, feature:4))
        XCTAssertEqual(try HeadsetFrame.battery([0,0,1]).quantity, .reportedPercent(0))
        XCTAssertEqual(try HeadsetFrame.battery([50]).charge, .unknown)
        var ack=Array(repeating:UInt8(0),count:64); ack[0]=0x51; ack[1]=3
        XCTAssertNil(try HeadsetFrame.legacyBattery(ack))
        var legacy=Array(repeating:UInt8(0),count:64); legacy[0]=0x51; legacy[1]=0x0b; legacy[8]=4; legacy[10]=0; legacy[12]=2
        XCTAssertEqual(try HeadsetFrame.legacyBattery(legacy)?.quantity, .reportedPercent(0))
    }

    func testCenturionNestedErrorIdentityAndLengthAreValidated() throws {
        let matchedError = try HeadsetFrame.encode([2,0x10,0,5,0,0xff,4,1,9])
        XCTAssertThrowsError(try HeadsetFrame.nestedResult(matchedError,bridge:2,feature:4)) { error in
            XCTAssertEqual(error as? ParseFailure, .remoteError(9))
        }
        let wrongFeature = try HeadsetFrame.encode([2,0x10,0,5,0,0xff,3,1,9])
        XCTAssertThrowsError(try HeadsetFrame.nestedResult(wrongFeature,bridge:2,feature:4)) { error in
            XCTAssertEqual(error as? ParseFailure, .unmatched)
        }
        let wrongLength = try HeadsetFrame.encode([2,0x10,0,4,0,4,1,0,50])
        XCTAssertThrowsError(try HeadsetFrame.nestedResult(wrongLength,bridge:2,feature:4))
    }

    func testHeadsetClientOnlyFallsBackAfterSuccessfulNestedFeatureAbsence() throws {
        let bridge = try HeadsetFrame.encode([0,1,2,0,3])
        let missingBatteryFeature = try HeadsetFrame.encode([2,0x10,0,6,0,0,1,0,0,3])
        var legacy=Array(repeating:UInt8(0),count:64); legacy[0]=0x51; legacy[1]=0x0b; legacy[8]=4; legacy[10]=0; legacy[12]=2
        let allowed=FixtureTransport([bridge,missingBatteryFeature,legacy])
        let reading=try HeadsetClient(transport:allowed).battery()
        XCTAssertEqual(reading.quantity,.reportedPercent(0))
        XCTAssertEqual(reading.charge,.charging)
        XCTAssertEqual(allowed.sent.count,3)
        XCTAssertEqual(allowed.sent[2],HeadsetFrame.legacyRequest)

        let timedOut=FixtureTransport([bridge])
        XCTAssertThrowsError(try HeadsetClient(transport:timedOut).battery())
        XCTAssertEqual(timedOut.sent.count,2)
        XCTAssertFalse(timedOut.sent.contains(HeadsetFrame.legacyRequest))
    }

    func testWatchStrictJSONAuthenticationExactBytesAndZero() throws {
        let secret = Data(repeating:0x5a, count:32), device=UUID(), sample=UUID()
        let body=Data("{\"schemaVersion\":1,\"source\":\"watch-companion\",\"deviceID\":\"\(device.uuidString)\",\"sampleID\":\"\(sample.uuidString)\",\"measuredAt\":1792670400000,\"batteryPercent\":0,\"batteryState\":\"unplugged\"}".utf8)
        let mac=WatchAuthentication.signature(body:body,secret:secret)
        XCTAssertTrue(WatchAuthentication.verify(body:body,mac:mac,secret:secret))
        XCTAssertFalse(WatchAuthentication.verify(body:Data(body.dropLast()),mac:mac,secret:secret))
        let parsed=try WatchSample.validate(body,now:now)
        XCTAssertEqual(parsed.batteryPercent,0)
        let bodyText=String(decoding:body,as:UTF8.self)
        let fractional=Data(bodyText.replacingOccurrences(of:"\"batteryPercent\":0", with:"\"batteryPercent\":0.5").utf8)
        XCTAssertThrowsError(try WatchSample.validate(fractional,now:now))
        let boolean=Data(bodyText.replacingOccurrences(of:"\"batteryPercent\":0", with:"\"batteryPercent\":true").utf8)
        XCTAssertThrowsError(try WatchSample.validate(boolean,now:now))
    }

    func testWatchReceiptDedupOrderBindingAndDurableCodableRoundTrip() throws {
        let device=UUID(), other=UUID()
        func sample(_ id:UUID, _ at:Date, _ percent:Int?) -> WatchSample { WatchSample(deviceID:device,sampleID:id,measuredAt:at,batteryPercent:percent,batteryState:.unknown) }
        let first=sample(UUID(),now.addingTimeInterval(-60),50)
        var receipt=WatchReceipt()
        XCTAssertTrue(try receipt.accept(first))
        let encoded=try JSONEncoder().encode(receipt)
        receipt=try JSONDecoder().decode(WatchReceipt.self,from:encoded)
        XCTAssertFalse(try receipt.accept(first))
        XCTAssertFalse(try receipt.accept(sample(UUID(),now.addingTimeInterval(-60),20)))
        XCTAssertEqual(receipt.latest?.sampleID, first.sampleID)
        XCTAssertEqual(receipt.quantitySample?.batteryPercent, 50)
        XCTAssertThrowsError(try receipt.accept(WatchSample(deviceID:other,measuredAt:now,batteryPercent:5,batteryState:.charging)))
    }

    func testHTTPExactBodyAuthenticationAndLocalEndpointPolicy() throws {
        let secret=Data(repeating:7,count:32), pairing=UUID(), device=UUID()
        let body=Data("{\"schemaVersion\":1,\"source\":\"watch-companion\",\"deviceID\":\"\(device.uuidString)\",\"sampleID\":\"\(UUID().uuidString)\",\"measuredAt\":1792670400000,\"batteryState\":\"unknown\"}".utf8)
        let mac=WatchAuthentication.signature(body:body,secret:secret)
        let request=Data("POST /v1/watch-samples HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nX-OpenBattery-Pairing: \(pairing.uuidString)\r\nX-OpenBattery-MAC: \(mac)\r\n\r\n".utf8)+body
        let parsed=try XCTUnwrap(HTTPRequest.parse(request))
        XCTAssertNil(try parsed.authenticatedSample(pairingID:pairing,secret:secret,now:now).batteryPercent)
        XCTAssertThrowsError(try parsed.authenticatedSample(pairingID:UUID(),secret:secret,now:now))
        XCTAssertNil(LocalEndpoint.validate("http://example.com:58271"))
        XCTAssertNotNil(LocalEndpoint.validate("http://127.0.0.1:58271"))
        XCTAssertNotNil(LocalEndpoint.validate("http://openbattery.local:58271"))
        XCTAssertThrowsError(try HTTPRequest.parse(Data("POST / HTTP/1.1\r\nContent-Length: 4097\r\n\r\n".utf8)))
    }

    func testReportedCoarseAndEstimatedPresentationRemainDistinct() {
        XCTAssertEqual(Quantity.reportedPercent(100).display, "100%")
        XCTAssertEqual(Quantity.coarse(name:"Low",level:2).display, "Low (coarse)")
        XCTAssertEqual(Quantity.estimatedPercent(47,calibrationID:"approved-fixture").display, "≈47% (estimated)")
        XCTAssertEqual(WatchSample.percent(level:0),0)
        XCTAssertEqual(WatchSample.percent(level:1),100)
        XCTAssertNil(WatchSample.percent(level:-0.1))
        XCTAssertNil(WatchSample.percent(level:.nan))
    }
}
