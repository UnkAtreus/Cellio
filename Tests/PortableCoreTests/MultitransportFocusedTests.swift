import XCTest
import Foundation
@testable import OpenBatteryCore

private final class IdentityWire: ReportTransport {
    let advertisedReports: [UInt8:Int] = [0x10:7, 0x11:20]
    var version: UInt8 = 8
    var payload: [UInt8] = [2, 1,2,3,4, 0,2, 10,11,12,13,14,15, 0,0,0]
    var corrupt: (([UInt8]) -> [UInt8])?
    var packets: [[UInt8]] = []
    func exchange(_ output: [UInt8], timeout: TimeInterval, match: ([UInt8]) throws -> [UInt8]?) throws -> [UInt8] {
        packets.append(output)
        let root = output[2] == 0
        var reply = root ? [UInt8(0x10),output[1],0,output[3],7,0,version] : [0x11,output[1],7,output[3]] + payload
        if !root, let corrupt { reply = corrupt(reply) }
        return try match(reply) ?? { throw ParseFailure.timeout }()
    }
}

final class MultitransportFocusedTests: XCTestCase {
    private func seeded(_ ids: [String] = ["a","b","c"], components: [String] = ["battery"]) -> DeviceSettingsStore {
        let s = DeviceSettingsStore()
        for id in ids {
            s.discover(id:id,name:"Identical accessory",source:.hidUnified,componentIDs:components)
            s.rememberRoute(.init(id:id,metadata:.init(type:id == "a" ? .bluetooth:.wirelessReceiver,kind:.mouse,topology:"SYNTHETIC TEST ROUTE")))
        }
        return s
    }
    private func proof(_ unit: UInt8 = 1) throws -> VerifiedPhysicalIdentity {
        var wire = IdentityWire().payload; wire[1] = unit
        return try VerifiedPhysicalIdentity.decode(payload:wire,version:8,target:255)
    }
    func testVerifiedV8UsesActualSerializedMatcherAndFullModelAndUnit() throws {
        let bt=IdentityWire(), receiver=IdentityWire()
        let a=try HIDPlusClient(transport:bt).physicalIdentity(device:255)
        let b=try HIDPlusClient(transport:receiver).physicalIdentity(device:1)
        XCTAssertEqual(a.key,b.key); XCTAssertEqual(a.featureVersion,8)
        XCTAssertEqual(bt.packets.map { $0[1] },[255,255])
        XCTAssertEqual(receiver.packets.map { $0[1] },[1,1])
        XCTAssertEqual(bt.packets.last?.count,20)
        for index in 7...12 {
            let other=IdentityWire(); other.payload[index] ^= 0x80
            XCTAssertNotEqual(try HIDPlusClient(transport:other).physicalIdentity(device:255).key,a.key,"every model byte participates")
        }
        for index in 1...4 {
            let other=IdentityWire(); other.payload[index] ^= 0x80
            XCTAssertNotEqual(try HIDPlusClient(transport:other).physicalIdentity(device:255).key,a.key,"every unit byte participates")
        }
    }
    func testIdentityRejectsInvalidBaseFieldsIncludingZeroAndTransportMasks() throws {
        let good=IdentityWire().payload
        var invalid=[[UInt8]]()
        invalid.append(Array(good.dropLast()))
        var p=good; p[5]=1; invalid.append(p)
        for mask: UInt8 in [0, 0x10, 0x80, 0x0f, 0xff] { p=good; p[6]=mask; invalid.append(p) }
        p=good; for i in 1...4 { p[i]=0 }; invalid.append(p)
        p=good; for i in 7...12 { p[i]=0 }; invalid.append(p)
        for bad in invalid { XCTAssertThrowsError(try VerifiedPhysicalIdentity.decode(payload:bad,version:8,target:255)) }
        XCTAssertThrowsError(try VerifiedPhysicalIdentity.decode(payload:good,version:0,target:255))
        XCTAssertThrowsError(try VerifiedPhysicalIdentity.decode(payload:good,version:8,target:0))
        for mask: UInt8 in [1,2,4,8,3,7] { p=good; p[6]=mask; XCTAssertTrue(try VerifiedPhysicalIdentity.decode(payload:p,version:8,target:255).isValid) }
    }
    func testIdentityFramingRejectsShortForeignLateAndErrorFrames() {
        let corruptions: [([UInt8])->[UInt8]] = [
            { Array($0.prefix(7)) },
            { var p=$0; p[1]=2; return p },
            { var p=$0; p[2]=8; return p },
            { var p=$0; p[3] ^= 1; return p },
            { var p=$0; p[2]=0xff; p[3]=7; p[4]=2; p[5]=1; return p }
        ]
        for corrupt in corruptions { let wire=IdentityWire(); wire.corrupt=corrupt; XCTAssertThrowsError(try HIDPlusClient(transport:wire).physicalIdentity(device:255)) }
        let v0=IdentityWire(); v0.version=0
        XCTAssertThrowsError(try HIDPlusClient(transport:v0).physicalIdentity(device:255))
        XCTAssertEqual(v0.packets.count,1)
    }
    func testSameNamesDoNotJoinAndConflictingProofIsRetainedDiagnostically() throws {
        let s=seeded(); XCTAssertNil(s.automaticLinkCandidate(alerts:.init()))
        let a=try proof(), b=try proof(9)
        s.rememberRoute(.init(id:"a",metadata:s.physicalCatalog.routes[0].metadata,identity:a))
        s.rememberRoute(.init(id:"b",metadata:.init(type:.wirelessReceiver,kind:.mouse,topology:"fixture"),identity:b))
        XCTAssertNil(s.automaticLinkCandidate(alerts:.init()))
        s.rememberRoute(.init(id:"a",metadata:.init(type:.bluetooth,kind:.mouse,topology:"fixture"),identity:b))
        let route=try XCTUnwrap(s.physicalCatalog.routes.first { $0.id == "a" })
        XCTAssertTrue(route.identityConflict); XCTAssertEqual(route.identity,a)
        XCTAssertNil(s.automaticLinkCandidate(alerts:.init()))
    }
    func testManualThreeMemberLinkExpandsWholeGroupsAndRetainsOriginals() throws {
        let s=seeded(["a","b","c","d"])
        try s.commitLink(s.previewLink(current:"b",selected:["c","d"],alerts:.init()),alerts:.init())
        let preview=try s.previewLink(current:"a",selected:["b"],alerts:.init())
        XCTAssertEqual(preview.members,["a","b","c","d"])
        XCTAssertThrowsError(try s.previewLink(current:"a",selected:["c"],alerts:.init()),"hidden member cannot be selected separately")
        try s.commitLink(preview,alerts:.init())
        XCTAssertEqual(s.devices.map(\.id),["a"])
        XCTAssertEqual(s.physicalCatalog.groups.first?.originalDevices.count,4)
        XCTAssertEqual(s.rawDevices.count,4)
    }
    func testPreviewIsReadOnlyAndChangedPreferencesRejectCommit() throws {
        let memory=MemoryDeviceSettingsPersistence(); let s=DeviceSettingsStore(persistence:memory)
        for id in ["a","b","c"] { s.discover(id:id,name:"Same",source:.hidUnified,componentIDs:["battery"]) }
        let bytes=memory.data, catalog=s.physicalCatalog
        let preview=try s.previewLink(current:"a",selected:["b","c"],alerts:.init())
        XCTAssertEqual(memory.data,bytes); XCTAssertEqual(s.physicalCatalog,catalog)
        s.setMenuVisibility(false,for:"b")
        XCTAssertThrowsError(try s.commitLink(preview,alerts:.init()))
        XCTAssertTrue(s.physicalCatalog.groups.isEmpty); XCTAssertFalse(s.preferences(for:"b").showInMenu)
    }
    func testOffWinsIndependentlyAndLowerThresholdAndComponentIntersection() throws {
        let s=seeded(components:["left","right","case"])
        s.setMonitoring(false,for:"b"); s.setMenuVisibility(false,for:"c")
        s.setComponentSelected(false,component:"right",for:"a")
        s.setComponentSelected(false,component:"left",for:"b")
        var config=AlertConfiguration(); config.threshold=35
        var b=DeviceAlertConfiguration(); b.usesCustomThreshold=true; b.customThreshold=12; b.included=false
        b.components = .init(mode:.selected,ids:["case","right"]); config.devices["b"]=b
        var a=DeviceAlertConfiguration(); a.components = .init(mode:.selected,ids:["case","left"]); config.devices["a"]=a
        let p=try s.previewLink(current:"a",selected:["b","c"],alerts:config)
        XCTAssertFalse(p.sharedDevice.preferences.monitorBattery); XCTAssertFalse(p.sharedDevice.preferences.showInMenu)
        XCTAssertFalse(p.sharedAlert.included); XCTAssertEqual(p.sharedAlert.customThreshold,12); XCTAssertTrue(p.sharedAlert.usesCustomThreshold)
        XCTAssertEqual(p.sharedDevice.componentSelection.ids,["case"]); XCTAssertEqual(p.sharedAlert.components.ids,["case"])
        try s.commitLink(p,alerts:config)
        XCTAssertEqual(s.physicalCatalog.groups.first?.originalDevices.first { $0.id == "a" }?.preferences.monitorBattery,true)
        XCTAssertEqual(s.alertConfiguration(over:config).threshold,35)
    }
    func testDisjointComponentSelectionsDisableMastersWithoutBroadening() throws {
        let s=seeded(["a","b"],components:["left","right","case"])
        s.setComponentSelected(false,component:"right",for:"a"); s.setComponentSelected(false,component:"case",for:"a")
        s.setComponentSelected(false,component:"left",for:"b"); s.setComponentSelected(false,component:"case",for:"b")
        var config=AlertConfiguration(), a=DeviceAlertConfiguration(), b=DeviceAlertConfiguration()
        a.components = .init(mode:.selected,ids:["left"]); b.components = .init(mode:.selected,ids:["right"])
        config.devices=["a":a,"b":b]
        let p=try s.previewLink(current:"a",selected:["b"],alerts:config)
        XCTAssertFalse(p.sharedDevice.preferences.showInMenu); XCTAssertFalse(p.sharedAlert.included)
        XCTAssertEqual(p.sharedDevice.componentSelection.mode,.selected); XCTAssertEqual(p.sharedAlert.components.mode,.selected)
        XCTAssertEqual(p.sharedAlert.components.ids,["left"])
    }
    func testUnlinkOriginalCanonicalRouteKeepsRemainingIdentityAndSharedOffPolicies() throws {
        let s=seeded(); s.setMonitoring(false,for:"b"); s.setMenuVisibility(false,for:"c")
        var config=AlertConfiguration(), excluded=DeviceAlertConfiguration(); excluded.included=false; config.devices["b"]=excluded
        try s.commitLink(s.previewLink(current:"a",selected:["b","c"],alerts:config),alerts:config)
        XCTAssertEqual(try s.unlink(member:"a",from:"a",newID:"detached"),"detached")
        XCTAssertEqual(s.members(of:"a"),["b","c"]); XCTAssertEqual(s.members(of:"detached"),["a"])
        XCTAssertEqual(s.logicalID(for:"a"),"detached"); XCTAssertEqual(s.logicalID(for:"b"),"a")
        for id in ["a","detached"] { XCTAssertFalse(s.preferences(for:id).monitorBattery); XCTAssertFalse(s.preferences(for:id).showInMenu); XCTAssertFalse(s.alertConfiguration(over:config).device(id).included) }
        XCTAssertEqual(s.physicalCatalog.separations.count,2)
        XCTAssertEqual(s.physicalCatalog.groups.first { $0.id == "detached" }?.originalDevices.first { $0.id == "a" }?.preferences.monitorBattery,true)
    }
    func testVerifiedSeparationSurvivesReloadAndExplicitRelinkReversesIt() throws {
        let memory=MemoryDeviceSettingsPersistence(); var s=DeviceSettingsStore(persistence:memory)
        for id in ["a","b","c"] { s.discover(id:id,name:"Same",source:.hidUnified,componentIDs:["battery"]); s.rememberRoute(.init(id:id,metadata:.init(type:.bluetooth,kind:.mouse,topology:"fixture"),identity:try proof())) }
        try s.commitLink(try XCTUnwrap(s.automaticLinkCandidate(alerts:.init())),alerts:.init())
        _ = try s.unlink(member:"a",from:"a",newID:"detached")
        let saved=memory.data; s=DeviceSettingsStore(persistence:memory)
        XCTAssertEqual(memory.data,saved); XCTAssertNil(s.automaticLinkCandidate(alerts:.init()))
        XCTAssertEqual(s.members(of:"a"),["b","c"])
        try s.commitLink(s.previewLink(current:"a",selected:["detached"],alerts:s.alertConfiguration(over:.init())),alerts:s.alertConfiguration(over:.init()))
        XCTAssertTrue(s.physicalCatalog.separations.isEmpty); XCTAssertEqual(s.members(of:"a"),["a","b","c"])
    }
    func testLegacyDocumentsPreserveOriginalBytesAndExistingMigrationContract() throws {
        final class LegacyKeys: DeviceSettingsPersistence {
            let legacy: Data
            var current: Data?
            init(_ data: Data) { legacy=data }
            func load() throws -> Data? { current ?? legacy }
            func save(_ data: Data) throws { current=data }
        }
        let bytes=Data(#"{"version":1,"devices":[{"id":"old","name":"Legacy","source":"hidUnified","preferences":{"monitorBattery":false,"showInMenu":false}}]}"#.utf8)
        let legacy=LegacyKeys(bytes)
        let sameBoundary=DeviceSettingsStore(persistence:legacy)
        XCTAssertFalse(sameBoundary.updatesBlocked); XCTAssertFalse(sameBoundary.preferences(for:"old").monitorBattery)
        XCTAssertEqual(legacy.legacy,bytes,"v1 key remains unchanged while a separate v2 key is written")
        let v2=try XCTUnwrap(legacy.current)
        XCTAssertEqual((try JSONSerialization.jsonObject(with:v2) as? [String:Any])?["version"] as? Int,2)
        let memory=MemoryDeviceSettingsPersistence(data:v2)
        let reread=DeviceSettingsStore(persistence:memory)
        XCTAssertFalse(reread.updatesBlocked); XCTAssertFalse(reread.preferences(for:"old").monitorBattery)
        _ = reread.devices; _ = reread.physicalCatalog
        XCTAssertEqual(memory.data,v2,"an unchanged v2 catalog needs no rewrite or physical extension")
    }
    func testCorruptCatalogFailsClosedWithoutOverwritingProtectedBytes() {
        let data=Data("{\"version\":2,\"devices\":[],\"physicalDevices\":{\"routes\":[],\"groups\":[{}],\"separations\":[]}}".utf8)
        let memory=MemoryDeviceSettingsPersistence(data:data), s=DeviceSettingsStore(persistence:memory)
        XCTAssertTrue(s.updatesBlocked); XCTAssertNotNil(s.issue)
        XCTAssertFalse(s.context().shouldQuery("new")); s.discover(id:"new",name:"Same",source:.hidUnified)
        XCTAssertEqual(memory.data,data); XCTAssertThrowsError(try s.previewLink(current:"a",selected:["b"],alerts:.init()))
    }
}
