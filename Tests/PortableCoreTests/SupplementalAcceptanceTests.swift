import XCTest
import Foundation
@testable import OpenBatteryCore

private final class SupplementalTransport: ReportTransport {
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

final class SupplementalAcceptanceTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_792_670_400)

    func testLocalEndpointDistinguishesLocalIPv4FromNumericDomainsAndPublicAddresses() {
        for value in ["http://10.0.0.1.example:58271", "http://192.168.1.1.example:58271", "http://127.0.0.1.example:58271", "http://8.8.8.8:58271", "http://1.1.1.1:58271"] {
            XCTAssertNil(LocalEndpoint.validate(value), "Fixture \(value) is a domain/public host, not an approved local literal")
        }
        for value in ["http://10.0.0.1:58271", "http://192.168.1.4:58271", "http://172.31.0.2:58271", "http://169.254.2.1:58271", "http://openbattery.local:58271"] {
            XCTAssertNotNil(LocalEndpoint.validate(value), "Fixture \(value) is an allowed local endpoint")
        }
        for value in ["http://10.2.3:58271", "http://10.2.3.999:58271", "http://10.2.3.4.5:58271", "http://[2001:db8::1]:58271", "http://[fdzz::1]:58271", "http://[fe80:not-ipv6]:58271", "http://[fcgarbage]:58271"] {
            XCTAssertNil(LocalEndpoint.validate(value), "Fixture \(value) is malformed or nonlocal")
        }
    }

    func testHIDDescriptorRequiresReport51InputAndOutputVendorUsageEvidence() throws {
        func descriptor(vendorInput: Bool, vendorOutput: Bool) throws -> HIDDescriptor {
            var bytes:[UInt8] = [0x05,0x0c, 0x09,0x01, 0xa1,0x01, 0x06,0xa0,0xff, 0x09,0x01, 0xa1,0x01, 0x85,0x51, 0x75,0x08, 0x95,0x3f]
            if vendorInput { bytes += [0x81,0x02] }
            if vendorOutput { bytes += [0x91,0x02] }
            bytes += [0xc0,0xc0]
            return try HIDDescriptor(Data(bytes))
        }
        XCTAssertTrue(try descriptor(vendorInput:true,vendorOutput:true).hasHeadsetReport)
        XCTAssertFalse(try descriptor(vendorInput:true,vendorOutput:false).hasHeadsetReport)
        XCTAssertFalse(try descriptor(vendorInput:false,vendorOutput:true).hasHeadsetReport)
        XCTAssertFalse(try descriptor(vendorInput:false,vendorOutput:false).hasHeadsetReport)
    }

    func testHeadsetLegacyFallbackRequiresSuccessfulNestedFeatureAbsence() throws {
        let bridge = try HeadsetFrame.encode([0,1,2,0,3])
        var legacy = Array(repeating:UInt8(0),count:64); legacy[0]=0x51; legacy[1]=0x0b; legacy[8]=4; legacy[10]=47
        let fallback = try HeadsetFrame.encode([2,0x10,0,6,0,0,1,0,0,3])
        let allowed = SupplementalTransport([bridge,fallback,legacy])
        XCTAssertEqual(try HeadsetClient(transport:allowed).battery().quantity,.reportedPercent(47))
        XCTAssertEqual(allowed.sent.count,3)

        let timeout = SupplementalTransport([bridge])
        XCTAssertThrowsError(try HeadsetClient(transport:timeout).battery())
        XCTAssertEqual(timeout.sent.count,2)
        XCTAssertFalse(timeout.sent.contains(HeadsetFrame.legacyRequest))

        let bridgeError = try HeadsetFrame.encode([0xff,0,1,7])
        let error = SupplementalTransport([bridge,bridgeError])
        XCTAssertThrowsError(try HeadsetClient(transport:error).battery())
        XCTAssertEqual(error.sent.count,2)
        XCTAssertFalse(error.sent.contains(HeadsetFrame.legacyRequest))

        let offline = try HeadsetFrame.encode([2,0,0,0])
        let offlineTransport = SupplementalTransport([bridge,offline])
        XCTAssertThrowsError(try HeadsetClient(transport:offlineTransport).battery())
        XCTAssertEqual(offlineTransport.sent.count,2)
        XCTAssertFalse(offlineTransport.sent.contains(HeadsetFrame.legacyRequest))

        let missingBridge = SupplementalTransport([])
        XCTAssertThrowsError(try HeadsetClient(transport:missingBridge).battery())
        XCTAssertEqual(missingBridge.sent.count,1)
        XCTAssertFalse(missingBridge.sent.contains(HeadsetFrame.legacyRequest))
    }

    func testWatchIntegerTimeRangeBoundariesAndExactMillisecondTimestamp() throws {
        let device=UUID(), sample=UUID()
        func body(ms:Int64, percent:String="100") -> Data {
            Data("{\"schemaVersion\":1,\"source\":\"watch-companion\",\"deviceID\":\"\(device.uuidString)\",\"sampleID\":\"\(sample.uuidString)\",\"measuredAt\":\(ms),\"batteryPercent\":\(percent),\"batteryState\":\"full\"}".utf8)
        }
        let center=Int64((now.timeIntervalSince1970*1000).rounded())
        XCTAssertEqual(try WatchSample.validate(body(ms:center-86_400_000),now:now).measuredAt,center-86_400_000)
        XCTAssertThrowsError(try WatchSample.validate(body(ms:center-86_400_001),now:now))
        XCTAssertEqual(try WatchSample.validate(body(ms:center+120_000),now:now).measuredAt,center+120_000)
        XCTAssertThrowsError(try WatchSample.validate(body(ms:center+120_001),now:now))
        let parsed=try WatchSample.validate(body(ms:center-1234),now:now)
        XCTAssertEqual(parsed.measuredAt,center-1234)
        XCTAssertEqual(parsed.date.timeIntervalSince1970,Double(center-1234)/1000,accuracy:0.000001)
        XCTAssertThrowsError(try WatchSample.validate(body(ms:center,percent:"1.5"),now:now))
        XCTAssertThrowsError(try WatchSample.validate(body(ms:center,percent:"true"),now:now))
    }

    func testWatchRetainedQuantityAndTimestampSurviveNewerChargeOnlySampleAndPersistence() throws {
        let device=UUID()
        let measured=now.addingTimeInterval(-321.456)
        let value=WatchSample(deviceID:device,measuredAt:measured,batteryPercent:63,batteryState:.unplugged)
        var receipt=WatchReceipt()
        XCTAssertTrue(try receipt.accept(value))
        let chargeOnly=WatchSample(deviceID:device,measuredAt:now.addingTimeInterval(-10),batteryPercent:nil,batteryState:.charging)
        XCTAssertTrue(try receipt.accept(chargeOnly))
        XCTAssertEqual(receipt.latest?.measuredAt,chargeOnly.measuredAt)
        XCTAssertEqual(receipt.quantitySample?.measuredAt,value.measuredAt)
        XCTAssertEqual(receipt.quantitySample?.batteryPercent,63)
        let restored=try JSONDecoder().decode(WatchReceipt.self,from:JSONEncoder().encode(receipt))
        XCTAssertEqual(restored.latest?.measuredAt,chargeOnly.measuredAt)
        XCTAssertEqual(restored.quantitySample?.measuredAt,value.measuredAt)
        XCTAssertEqual(restored.quantitySample?.batteryPercent,63)
        let observation=try XCTUnwrap(restored.quantitySample).observation(collectedAt:now)
        XCTAssertEqual(observation.measuredAt,value.date)
        XCTAssertEqual(observation.observedAt,value.date)
    }

    func testHTTPRequestEnforcesHeaderAndBodyResourceBounds() throws {
        XCTAssertThrowsError(try HTTPRequest.parse(Data(String(repeating:"x",count:8193).utf8)))
        XCTAssertThrowsError(try HTTPRequest.parse(Data("POST / HTTP/1.1\r\nContent-Length: 4097\r\n\r\n".utf8)))
        let exactBody=Data("POST / HTTP/1.1\r\nContent-Length: 4096\r\n\r\n".utf8)+Data(repeating:0x61,count:4096)
        XCTAssertNotNil(try HTTPRequest.parse(exactBody))
        XCTAssertThrowsError(try HTTPRequest.parse(exactBody+Data([0x61])))
    }
}
