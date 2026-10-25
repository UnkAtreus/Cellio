import XCTest
import Foundation
@testable import OpenBatteryCore

private final class RegressionTransport: ReportTransport {
    let advertisedReports:[UInt8:Int] = [0x10:7]
    let reply:[UInt8]
    init(_ reply:[UInt8]) { self.reply=reply }
    func exchange(_ output:[UInt8],timeout:TimeInterval,match:([UInt8]) throws -> [UInt8]?) throws -> [UInt8] {
        try match(reply) ?? { throw ParseFailure.timeout }()
    }
}

final class RegressionAcceptanceTests: XCTestCase {
    func testHiddenFeatureLookupIsTreatedAsAbsent() throws {
        let hidden = RegressionTransport([0x10,1,0,0x01,3,0x40,1])
        XCTAssertEqual(try HIDPlusClient(transport:hidden).feature(0x1004,device:1),0,
                       "Feature type bit 0x40 marks a hidden feature that must be skipped")
        let visible = RegressionTransport([0x10,1,0,0x01,3,0x02,1])
        XCTAssertEqual(try HIDPlusClient(transport:visible).feature(0x1004,device:1),3)
    }

    func testOnlyDocumentedReportSpecificEventsRequestRefresh() throws {
        // HID++ ordinary root/battery replies, error frames and software-zero
        // acknowledgements are not broadcasts. A recognized event uses index 0.
        XCTAssertFalse(HIDInputEvent.requestsRefresh([0x10, 1, 0, 0x01, 0, 0, 0]))
        XCTAssertFalse(HIDInputEvent.requestsRefresh([0x10, 1, 0x20, 0x01, 63, 0, 0]))
        XCTAssertFalse(HIDInputEvent.requestsRefresh([0x10, 1, 0, 0, 0, 0, 0]))
        XCTAssertTrue(HIDInputEvent.requestsRefresh([0x10, 1, 0x20, 0, 0, 0, 0]))

        let rootReply = try HeadsetFrame.encode([0, 1, 2, 0, 3])
        let ack = try HeadsetFrame.encode([2, 0x11])
        let result = try HeadsetFrame.encode([2, 0x10, 0, 6, 0, 4, 0x11, 50])
        let event = try HeadsetFrame.encode([2, 0, 0, 1])
        XCTAssertFalse(HIDInputEvent.requestsRefresh(rootReply))
        XCTAssertFalse(HIDInputEvent.requestsRefresh(ack))
        XCTAssertFalse(HIDInputEvent.requestsRefresh(result))
        XCTAssertTrue(HIDInputEvent.requestsRefresh(event))
        XCTAssertFalse(HIDInputEvent.requestsRefresh(try HeadsetFrame.encode([2, 0, 0, 2])))
    }

    func testVendorReportEvidenceIsRequiredInBothDirectionsWithinVendorCollection() throws {
        func descriptor(input: Bool, output: Bool) throws -> HIDDescriptor {
            var bytes: [UInt8] = [0x05,0x0c, 0x09,0x01, 0xa1,0x01,
                                  0x06,0xa0,0xff, 0x09,0x01, 0xa1,0x01,
                                  0x85,0x51, 0x75,0x08, 0x95,0x3f]
            if input { bytes += [0x81,0x02] }
            if output { bytes += [0x91,0x02] }
            bytes += [0xc0,0xc0]
            return try HIDDescriptor(Data(bytes))
        }
        XCTAssertTrue(try descriptor(input:true,output:true).hasHeadsetReport)
        XCTAssertFalse(try descriptor(input:true,output:false).hasHeadsetReport)
        XCTAssertFalse(try descriptor(input:false,output:true).hasHeadsetReport)
    }

    func testMetadataCacheIsIsolatedAndInvalidatedByPeripheralConnection() {
        var cache = HIDMetadataCache()
        let first = HIDPeripheralMetadata(name:"MX Master 4",type:3)
        let second = HIDPeripheralMetadata(name:"Other device",type:3)
        cache["receiver-A-1"] = first
        cache["receiver-A-2"] = second
        cache["receiver-B-1"] = second
        XCTAssertEqual(cache["receiver-A-1"], first)
        cache.invalidate(channel:"receiver-A")
        XCTAssertNil(cache["receiver-A-1"])
        XCTAssertNil(cache["receiver-A-2"])
        XCTAssertEqual(cache["receiver-B-1"], second)
    }

    func testHardwareIdentityIsStableAndSeparatesDistinctDevices() {
        let serialA = HIDDeviceIdentity.key(vendor:0x046d,product:0xc548,transport:"USB",serial:"serial-A",registryID:10)
        let serialAReenumerated = HIDDeviceIdentity.key(vendor:0x046d,product:0xc548,transport:"USB",serial:"serial-A",registryID:99)
        let serialB = HIDDeviceIdentity.key(vendor:0x046d,product:0xc548,transport:"USB",serial:"serial-B",registryID:10)
        XCTAssertEqual(serialA, serialAReenumerated)
        XCTAssertNotEqual(serialA, serialB)

        let connectionA = HIDDeviceIdentity.key(vendor:0x046d,product:0xc548,transport:"USB",serial:nil,registryID:10)
        let connectionB = HIDDeviceIdentity.key(vendor:0x046d,product:0xc548,transport:"USB",serial:nil,registryID:11)
        XCTAssertNotEqual(connectionA, connectionB)
        XCTAssertTrue(connectionA.hasPrefix("hid-connection-"))
    }

    func testStaleForwardingCompletionCannotReleaseReplacementOwner() throws {
        var ownership = ForwardingOwnership()
        let old = try XCTUnwrap(ownership.begin())
        XCTAssertTrue(ownership.owns(old))

        // Cancellation/reconfiguration invalidates first, then a new task owns delivery.
        ownership.invalidate()
        XCTAssertFalse(ownership.owns(old))
        let replacement = try XCTUnwrap(ownership.begin())
        XCTAssertTrue(ownership.owns(replacement))
        XCTAssertFalse(ownership.finish(old), "Old cleanup must not clear replacement ownership")
        XCTAssertTrue(ownership.owns(replacement), "Old delivery/cleanup must remain fenced out")
        XCTAssertTrue(ownership.finish(replacement))
        XCTAssertNil(ownership.current)
    }
}
