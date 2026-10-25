import XCTest
import Foundation
@testable import OpenBatteryCore

final class ConnectionIdentityAcceptanceTests: XCTestCase {
    let boot="12345678-ABCD-4321-ABCD-123456789012"
    func testSameBootAndRegistryStableWithoutPerInstanceState() throws {
        let expected="usb-presence-60ed400293781da3c0e9bc30aa9c5e8b7c2af1d6fb8ce9dcd9cc3ecd41153fd4"
        let first=try XCTUnwrap(USBKeyboardPresenceIdentity.connectionKey(bootSessionID:boot,registryEntryID:42))
        // Independent repeated evaluations model collector reconstruction; no process/hardware proof.
        XCTAssertEqual(first, USBKeyboardPresenceIdentity.connectionKey(bootSessionID:boot.lowercased(),registryEntryID:42))
        XCTAssertEqual(first, USBKeyboardPresenceIdentity.connectionKey(bootSessionID:boot,registryEntryID:42))
        XCTAssertEqual(first, expected)
    }
    func testOtherBootOrRegistryDistinctAndMissingEvidenceUnknown() {
        let first=USBKeyboardPresenceIdentity.connectionKey(bootSessionID:boot,registryEntryID:42)
        XCTAssertNotEqual(first, USBKeyboardPresenceIdentity.connectionKey(bootSessionID:"12345678-ABCD-4321-ABCD-123456789013",registryEntryID:42))
        XCTAssertNotEqual(first, USBKeyboardPresenceIdentity.connectionKey(bootSessionID:boot,registryEntryID:43))
        for invalid in [nil,"","not-a-uuid"," \(boot) "] as [String?] {
            XCTAssertNil(USBKeyboardPresenceIdentity.connectionKey(bootSessionID:invalid,registryEntryID:42))
        }
        XCTAssertNil(USBKeyboardPresenceIdentity.connectionKey(bootSessionID:boot,registryEntryID:0))
    }
    func testNarrowQualificationRejectsAuxiliaryDifferentKeyboardAndIncompleteMetadata() {
        func q(_ v:Int?=0x36b0,_ p:Int?=0x3050,_ t:String?="USB",_ page:Int?=1,_ usage:Int?=6)->Bool {
            USBKeyboardPresenceIdentity.qualifies(vendor:v,product:p,transport:t,usagePage:page,usage:usage)
        }
        XCTAssertTrue(q())
        XCTAssertFalse(q(0x36b0,0x3050,"USB",0xff60,0x61))
        XCTAssertFalse(q(0x36b0,0x3050,"USB",1,2))
        XCTAssertFalse(q(0x1ea7,0x0907))
        XCTAssertFalse(q(0x36b0,0x3051)); XCTAssertFalse(q(0x36b0,0x3050,"Bluetooth"))
        XCTAssertFalse(q(nil)); XCTAssertFalse(q(0x36b0,nil)); XCTAssertFalse(q(0x36b0,0x3050,nil))
        XCTAssertFalse(q(0x36b0,0x3050,"USB",nil)); XCTAssertFalse(q(0x36b0,0x3050,"USB",1,nil))
    }
    func testGenericMainRequiresOpaqueAddressWhileInheritedPartFallbackRemains() throws {
        func parse(_ entries:[[String:Any]]) throws -> [Observation] {
            try SystemReportParser.parse(JSONSerialization.data(withJSONObject:["SPBluetoothDataType":[["device_connected":entries]]]),collectedAt:Date(timeIntervalSince1970:1792670400))
        }
        for invalid in [nil,NSNull(),42,""," \n\t"] as [Any?] {
            var props:[String:Any] = ["device_batteryLevelMain":"100%","device_minorType":"Headset"]
            props["device_address"]=invalid
            XCTAssertTrue(try parse([["Same headset":props],["Same headset":props]]).isEmpty)
        }
        let valid=try parse([["Same headset":["device_address":"opaque-a","device_batteryLevelMain":"100%"]],["Same headset":["device_address":"opaque-b","device_batteryLevelMain":"100%"]]])
        XCTAssertEqual(Set(valid.map(\.id.device)).count,2)
        let parts=try parse([["AirPods Pro":[:]], ["Other parts":["device_batteryLevelLeft":"0%"]]])
        XCTAssertEqual(parts.count,6)
        XCTAssertTrue(parts.contains { $0.id.device == "bluetooth-"+SystemReportParser.opaqueIdentity("Other parts") && $0.quantity == .reportedPercent(0) })
        XCTAssertEqual(parts.filter { $0.name == "AirPods Pro" }.map(\.id.component).sorted(),["case","left","right"])
    }
}
