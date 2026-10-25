import XCTest
import Foundation
@testable import OpenBatteryCore

private final class ReceiverScriptTransport: ReportTransport {
    let advertisedReports: [UInt8:Int] = [0x10:7, 0x11:20]
    typealias Step = (_ request:[UInt8], _ match:([UInt8]) throws -> [UInt8]?) throws -> [UInt8]
    var steps:[Step]
    private(set) var sent:[[UInt8]]=[]
    private(set) var timeouts:[TimeInterval]=[]
    init(_ steps:[Step]) { self.steps=steps }
    func exchange(_ output:[UInt8], timeout:TimeInterval, match:([UInt8]) throws -> [UInt8]?) throws -> [UInt8] {
        sent.append(output); timeouts.append(timeout)
        guard !steps.isEmpty else { throw ParseFailure.timeout }
        return try steps.removeFirst()(output,match)
    }
    static func response(_ request:[UInt8], payload:[UInt8]=[2,0,0x5a]) -> [UInt8] {
        [request[0],request[1],request[2],request[3]] + payload + Array(repeating:0,count:request[0]==0x10 ? 0:13)
    }
    static func timeout() -> Step { { _,_ in throw ParseFailure.timeout } }
    static func matching(_ payload:[UInt8]=[2,0,0x5a]) -> Step {
        { request,match in try match(Self.response(request,payload:payload)) ?? { throw ParseFailure.timeout }() }
    }
}

final class ReceiverRetryAcceptanceTests: XCTestCase {
    func testTimeoutThenSuccessRetriesWithNewSoftwareIDAndPreservesProbeIdentity() throws {
        let t=ReceiverScriptTransport([ReceiverScriptTransport.timeout(),ReceiverScriptTransport.matching()])
        XCTAssertNoThrow(try HIDPlusClient(transport:t).probe(device:1,ping:0x5a))
        XCTAssertEqual(t.sent.count,2)
        XCTAssertEqual(t.sent.map { Array($0[1...2]) },[[1,0],[1,0]])
        XCTAssertEqual(t.sent.map { $0[3] >> 4 },[1,1])
        XCTAssertEqual(t.sent.map { $0[3] & 0x0f },[1,2])
        XCTAssertEqual(t.sent.map { Array($0[4...6]) },[[0,0,0x5a],[0,0,0x5a]])
        XCTAssertEqual(t.timeouts,[0.5,0.5])
    }

    func testTwoTimeoutsAreBoundedAndPropagateTimeout() {
        let t=ReceiverScriptTransport([ReceiverScriptTransport.timeout(),ReceiverScriptTransport.timeout()])
        XCTAssertThrowsError(try HIDPlusClient(transport:t).probe(device:2,ping:7)) { XCTAssertEqual($0 as? ParseFailure,.timeout) }
        XCTAssertEqual(t.sent.count,2)
        XCTAssertEqual(t.timeouts,[0.5,0.5])
    }

    func testImmediateSuccessUsesOneAttempt() throws {
        let t=ReceiverScriptTransport([ReceiverScriptTransport.matching([2,0,9])])
        try HIDPlusClient(transport:t).probe(device:3,ping:9)
        XCTAssertEqual(t.sent.count,1)
        XCTAssertEqual(t.timeouts,[0.5])
    }

    func testLateFirstReplyCannotMatchSecondSoftwareID() throws {
        var old:[UInt8]=[]
        let t=ReceiverScriptTransport([
            { request,_ in old=request; throw ParseFailure.timeout },
            { request,match in
                XCTAssertNotEqual(request[3]&0x0f,old[3]&0x0f)
                XCTAssertThrowsError(try match(ReceiverScriptTransport.response(old))) { XCTAssertEqual($0 as? ParseFailure,.unmatched) }
                return try match(ReceiverScriptTransport.response(request)) ?? { throw ParseFailure.timeout }()
            }
        ])
        try HIDPlusClient(transport:t).probe(device:1,ping:0x5a)
        XCTAssertEqual(t.sent.count,2)
    }

    func testNonTimeoutFailuresDoNotRetry() {
        let failures:[ParseFailure]=[.unsupported,.offline,.remoteError(4),.invalid("bad"),.truncated]
        for failure in failures {
            let t=ReceiverScriptTransport([{_,_ in throw failure}])
            XCTAssertThrowsError(try HIDPlusClient(transport:t).probe(device:1,ping:1))
            XCTAssertEqual(t.sent.count,1,"\(failure)")
        }
    }

    func testTimeoutThenNonTimeoutFailurePropagatesWithoutThirdAttempt() {
        let t=ReceiverScriptTransport([ReceiverScriptTransport.timeout(),{_,_ in throw ParseFailure.remoteError(7)}])
        XCTAssertThrowsError(try HIDPlusClient(transport:t).probe(device:1,ping:2)) { XCTAssertEqual($0 as? ParseFailure,.remoteError(7)) }
        XCTAssertEqual(t.sent.count,2)
    }

    func testBadProtocolAndPingRepliesAreRejectedWithoutRetry() {
        let badProtocol=ReceiverScriptTransport([ReceiverScriptTransport.matching([1,0,0x5a])])
        XCTAssertThrowsError(try HIDPlusClient(transport:badProtocol).probe(device:1,ping:0x5a))
        XCTAssertEqual(badProtocol.sent.count,1)
        let badPing=ReceiverScriptTransport([ReceiverScriptTransport.matching([2,0,0x59])])
        XCTAssertThrowsError(try HIDPlusClient(transport:badPing).probe(device:1,ping:0x5a))
        XCTAssertEqual(badPing.sent.count,1)
    }
}
