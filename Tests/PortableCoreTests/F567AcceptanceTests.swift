import XCTest
import Foundation
@testable import OpenBatteryCore

private final class HIDErrorSequenceTransport: ReportTransport {
    let advertisedReports: [UInt8:Int] = [0x10:7]
    var frames: [[UInt8]]
    init(_ frames: [[UInt8]]) { self.frames=frames }
    func exchange(_ output:[UInt8], timeout:TimeInterval, match:([UInt8]) throws -> [UInt8]?) throws -> [UInt8] {
        while !frames.isEmpty {
            let frame=frames.removeFirst()
            do { if let result=try match(frame) { return result } }
            catch ParseFailure.unmatched { continue }
        }
        throw ParseFailure.timeout
    }
}

final class F567AcceptanceTests: XCTestCase {
    let now=Date(timeIntervalSince1970:1_792_670_400)

    func testHIDPlus1ErrorRequiresCompleteOriginalRequestIdentity() throws {
        let request=HIDPlusRequest(device:1,feature:7,function:1,software:3)
        XCTAssertThrowsError(try request.reply([0x10,1,0x8f,7,0x13,1,0])) { error in
            XCTAssertEqual(error as? ParseFailure,.unsupported,"A fully attributed HID++1 error remains unsupported")
        }
        let unrelated:[[UInt8]]=[
            [0x10,1,0x8f,7,0x23,1,0], // wrong function
            [0x10,1,0x8f,7,0x14,1,0], // wrong software ID
            [0x10,2,0x8f,7,0x24,1,0], // wrong device
            [0x10,1,0x8f,8,0x24,1,0]  // wrong feature
        ]
        for frame in unrelated {
            XCTAssertThrowsError(try request.reply(frame),"\(frame) must not be attributed to this request") { error in
                XCTAssertEqual(error as? ParseFailure,.unmatched)
            }
        }
        let transport=HIDErrorSequenceTransport([unrelated[0],[0x10,1,7,0x13,42,0,0]])
        let reply=try transport.exchange([0x10,1,7,0x13,0,0,0],timeout:0.5) { try request.reply($0) }
        XCTAssertEqual(reply.first,42,"An unrelated frame must be skipped so the valid own reply succeeds")
    }

    func testWatchSourceRemovalPreservesCompleteFailedNonWatchRecord() throws {
        let hidID=ComponentID(device:"hid-connection-12",component:"battery")
        let watchID=ComponentID(device:"watch-install",component:"battery")
        let measured=now.addingTimeInterval(-37)
        let collected=now.addingTimeInterval(-35)
        let sampleMeasured=now.addingTimeInterval(-33)
        var reducer=BatteryReducer()
        reducer.apply(Observation(id:hidID,name:"MX",source:.hidUnified,connection:.connected,
                                  quantity:.reportedPercent(61),observedAt:measured,measuredAt:measured,sampleMeasuredAt:sampleMeasured,
                                  collectedAt:collected),now:now)
        reducer.apply(Observation(id:watchID,name:"Watch",source:.watchCompanion,connection:.connected,
                                  quantity:.reportedPercent(20),observedAt:now,measuredAt:now,collectedAt:now),now:now)
        let failedAt=now.addingTimeInterval(-2)
        reducer.fail(id:hidID,at:failedAt,message:"temporary HID read failure")
        let before=try XCTUnwrap(reducer.records[hidID])
        XCTAssertTrue(before.retained)
        reducer.removeRecords(source:.watchCompanion)
        let after=try XCTUnwrap(reducer.records[hidID])
        XCTAssertNil(reducer.records[watchID])
        XCTAssertEqual(after.error,"temporary HID read failure")
        XCTAssertEqual(after.retained,before.retained)
        XCTAssertEqual(after.lastAttempt,failedAt)
        XCTAssertEqual(after.observation.quantity,.reportedPercent(61))
        XCTAssertEqual(after.observation.observedAt,measured)
        XCTAssertEqual(after.observation.measuredAt,measured)
        XCTAssertEqual(after.observation.sampleMeasuredAt,sampleMeasured)
        XCTAssertEqual(after.observation.collectedAt,collected)
        XCTAssertEqual(after.observation.connection,.connected)
    }

    func testReceiverRemovalDisconnectsOnlyExactOrDelimitedChildren() throws {
        var reducer=BatteryReducer()
        let ids=["hid-12","hid-12-1","hid-123-1"].map { ComponentID(device:$0,component:"battery") }
        for (index,id) in ids.enumerated() {
            reducer.apply(Observation(id:id,name:id.device,source:.hidUnified,connection:.connected,
                                      quantity:.reportedPercent(40+index),observedAt:now,measuredAt:now,collectedAt:now),now:now)
        }
        let removedAt=now.addingTimeInterval(1)
        reducer.disconnectReceiver("hid-12",at:removedAt)
        XCTAssertEqual(reducer.records[ids[0]]?.observation.connection,.disconnected)
        XCTAssertEqual(reducer.records[ids[1]]?.observation.connection,.disconnected)
        XCTAssertEqual(reducer.records[ids[0]]?.lastAttempt,removedAt)
        XCTAssertEqual(reducer.records[ids[1]]?.lastAttempt,removedAt)
        XCTAssertEqual(reducer.records[ids[2]]?.observation.connection,.connected,
                       "hid-12 removal must not match the colliding prefix hid-123-1")
        XCTAssertNotEqual(reducer.records[ids[2]]?.lastAttempt,removedAt)
    }
}
