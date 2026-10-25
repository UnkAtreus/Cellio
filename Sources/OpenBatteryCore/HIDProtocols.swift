import Foundation

public struct HIDReportEvidence: Equatable {
    public var inputUsageBits:[UInt32:Int]=[:]; public var outputUsageBits:[UInt32:Int]=[:]
    public var id: UInt8; public var inputBytes: Int; public var outputBytes: Int; public var pages: Set<UInt32>; public var usages: Set<UInt32>
    public init(id:UInt8,inputBytes:Int=0,outputBytes:Int=0,pages:Set<UInt32>=[],usages:Set<UInt32>=[]) { self.id=id; self.inputBytes=inputBytes; self.outputBytes=outputBytes; self.pages=pages; self.usages=usages }
}
public struct HIDDescriptor {
    public var reports: [UInt8:HIDReportEvidence]
    public init(_ data: Data) throws {
        struct Globals { var page:UInt32=0; var size=0; var count=0; var id:UInt8=0 }
        let bytes=Array(data); var i=0; var g=Globals(); var stack:[Globals]=[]; var collections:[(UInt32,UInt32)]=[]; var local:[UInt32]=[]
        var inputBits:[UInt8:Int]=[:], outputBits:[UInt8:Int]=[:]; var reportEvidence:[UInt8:HIDReportEvidence]=[:]
        while i<bytes.count {
            let prefix=bytes[i]; i+=1
            if prefix==0xfe { guard i+2<=bytes.count else { throw ParseFailure.truncated }; let n=Int(bytes[i]); i+=2; guard i+n<=bytes.count else { throw ParseFailure.truncated }; i+=n; continue }
            let n=prefix & 3 == 3 ? 4 : Int(prefix & 3); guard i+n<=bytes.count else { throw ParseFailure.truncated }
            var value:UInt32=0; for offset in 0..<n { value |= UInt32(bytes[i+offset]) << (offset*8) }; i+=n
            let type=(prefix >> 2)&3, tag=prefix >> 4
            if type==1 {
                switch tag { case 0:g.page=value; case 7:g.size=Int(value); case 8:guard value>0 && value<=255 else { throw ParseFailure.invalid("Report ID") }; g.id=UInt8(value); case 9:g.count=Int(value); case 10:stack.append(g); case 11:guard let saved=stack.popLast() else { throw ParseFailure.invalid("Descriptor stack") }; g=saved; default:break }
            } else if type==2 && tag==0 { local.append(value) }
            else if type==0 {
                if tag==10 { collections.append((g.page,local.last ?? 0)) }
                else if tag==12 { guard !collections.isEmpty else { throw ParseFailure.invalid("Descriptor collection") }; collections.removeLast() }
                else if tag==8 || tag==9 {
                    guard g.size<=65536, g.count<=65536, g.size*g.count<=1048576 else { throw ParseFailure.invalid("Descriptor report bounds") }
                    if tag==8 { inputBits[g.id,default:0] += g.size*g.count } else { outputBits[g.id,default:0] += g.size*g.count }
                    var e=reportEvidence[g.id] ?? HIDReportEvidence(id:g.id)
                    e.pages.insert(g.page); e.usages.formUnion(local.map { (g.page << 16) | ($0 & 0xffff) })
                    for (page,usage) in collections { e.pages.insert(page); e.usages.insert((page << 16) | (usage & 0xffff)) }
                    // Evidence belongs to the collection and direction of each Main item.
                    // A vendor input cannot authorize a consumer output sharing its report ID.
                    for usage in Set(collections.map { ($0.0 << 16) | ($0.1 & 0xffff) }) {
                        if tag==8 { e.inputUsageBits[usage,default:0] += g.size*g.count }
                        else { e.outputUsageBits[usage,default:0] += g.size*g.count }
                    }
                    reportEvidence[g.id]=e
                }
                local=[]
            }
        }
        guard collections.isEmpty else { throw ParseFailure.truncated }
        for id in reportEvidence.keys { reportEvidence[id]?.inputBytes=((inputBits[id] ?? 0)+7)/8 + (id==0 ? 0:1); reportEvidence[id]?.outputBytes=((outputBits[id] ?? 0)+7)/8 + (id==0 ? 0:1) }
        reports=reportEvidence
    }
    public var hidPlusReports: [UInt8:Int] {
        var result:[UInt8:Int]=[:]
        for (id,size,mask) in [(UInt8(0x10),7,1),(0x11,20,2)] {
            guard let e=reports[id], e.inputBytes==size, e.outputBytes==size else { continue }
            func proven(_ evidence:[UInt32:Int]) -> Bool {
                evidence.contains { usage,bits in
                    let official=usage==0xff000001 || usage==0xff000002
                    let modern=(usage >> 16)==0xff43 && [1,2,4].contains(Int(usage & 0xff)) && (Int((usage >> 8) & 0xff) & mask) != 0
                    return bits==(size-1)*8 && (official || modern)
                }
            }
            if proven(e.inputUsageBits) && proven(e.outputUsageBits) { result[id]=size }
        }
        return result
    }
    /// Independent direction evidence; long input never grants modern long output.
    public var legacy07Eligible: Bool {
        func proven(_ id:UInt8,_ size:Int,_ input:Bool,_ mask:Int) -> Bool {
            guard let e=reports[id], (input ? e.inputBytes:e.outputBytes)==size else { return false }
            return (input ? e.inputUsageBits:e.outputUsageBits).contains { usage,bits in
                let official=usage==0xff000001 || usage==0xff000002
                let modern=(usage >> 16)==0xff43 && [1,2,4].contains(Int(usage & 0xff)) && (Int((usage >> 8) & 0xff) & mask) != 0
                return bits==(size-1)*8 && (official || modern)
            }
        }
        return proven(0x10,7,true,1) && proven(0x10,7,false,1) && proven(0x11,20,true,2)
    }
    public var hasHeadsetReport: Bool { guard let e=reports[0x51] else { return false }; return e.inputBytes==64 && e.outputBytes==64 && e.inputUsageBits[0xffa00001]==63*8 && e.outputUsageBits[0xffa00001]==63*8 }
}

public struct HIDPlusRequest: Equatable {
    public var device:UInt8; public var feature:UInt8; public var function:UInt8; public var software:UInt8; public var parameters:[UInt8]
    public init(device:UInt8,feature:UInt8,function:UInt8,software:UInt8,parameters:[UInt8]=[]) { self.device=device; self.feature=feature; self.function=function; self.software=software; self.parameters=parameters }
    public func packet(reports:[UInt8:Int]) throws -> [UInt8] {
        guard (1...15).contains(software), function<=15 else { throw ParseFailure.invalid("Request identity") }
        let id:UInt8 = parameters.count<=3 && reports[0x10]==7 ? 0x10 : 0x11
        guard let size=reports[id], parameters.count<=size-4 else { throw ParseFailure.unsupported }
        return [id,device,feature,(function << 4)|software] + parameters + Array(repeating:0,count:size-4-parameters.count)
    }
    public func reply(_ bytes:[UInt8]) throws -> [UInt8] {
        guard bytes.count>=4 else { throw ParseFailure.truncated }
        let expected = bytes[0]==0x10 ? 7 : bytes[0]==0x11 ? 20 : 0
        guard expected>0, bytes.count==expected else { throw ParseFailure.truncated }
        guard bytes[1]==device else { throw ParseFailure.unmatched }
        if bytes[2]==0x8f { guard bytes[3]==feature,bytes[4]==(function << 4)|software else { throw ParseFailure.unmatched }; throw ParseFailure.unsupported }
        if bytes[2]==0xff { guard bytes.count>=6,bytes[3]==feature,bytes[4]==(function << 4)|software else { throw ParseFailure.unmatched }; throw ParseFailure.remoteError(bytes[5]) }
        guard bytes[2]==feature,bytes[3]==(function << 4)|software else { throw ParseFailure.unmatched }
        return Array(bytes.dropFirst(4))
    }
}
public struct UnifiedCapabilities: Equatable {
    public let levels:UInt8; public let rechargeable:Bool; public let percentage:Bool
    public init(_ payload:[UInt8]) throws { guard payload.count>=2, payload[0]&0xf0==0, payload[1]&0xfc==0 else { throw ParseFailure.invalid("Unified capabilities") }; levels=payload[0]; rechargeable=payload[1]&1 != 0; percentage=payload[1]&2 != 0 }
}
public struct BatteryReading: Equatable { public let quantity:Quantity; public let charge:ChargeState; public init(quantity:Quantity,charge:ChargeState) { self.quantity=quantity; self.charge=charge } }
public enum HIDBatteryDecoder {
    public static func unified(_ payload:[UInt8],capabilities:UnifiedCapabilities) throws -> BatteryReading {
        guard payload.count>=3 else { throw ParseFailure.truncated }
        guard let status=ChargeState.hid(payload[2]), [UInt8(1),2,4,8].contains(payload[1]), capabilities.levels & payload[1] != 0 else { throw ParseFailure.invalid("Unified battery state") }
        let quantity:Quantity
        if capabilities.percentage { guard payload[0]<=100 else { throw ParseFailure.invalid("Percent") }; quantity = .reportedPercent(Int(payload[0])) }
        else { quantity = .coarse(name:[1:"Critical",2:"Low",4:"Good",8:"Full"][payload[1]]!,level:Int(payload[1])) }
        return BatteryReading(quantity:status.isError ? .unknown : quantity,charge:status)
    }
    public static func legacy(_ payload:[UInt8],capabilities:[UInt8]) throws -> BatteryReading {
        guard payload.count>=3,capabilities.count>=2 else { throw ParseFailure.truncated }
        guard payload[0]<=100,let status=ChargeState.hid(payload[2]) else { throw ParseFailure.invalid("Legacy battery state") }
        guard payload[0]>0,status == .discharging else { return BatteryReading(quantity:.unknown,charge:status) }
        let q:Quantity = capabilities[0]>=10 && capabilities[1]&2 != 0 ? .reportedPercent(Int(payload[0])) : .coarse(name:"",level:Int(payload[0]))
        return BatteryReading(quantity:q,charge:status)
    }
    public static func safeName(_ data:[UInt8],length:Int) -> String? { guard length>0,length<=128,data.count>=length,data.prefix(length).allSatisfy({ (32...126).contains($0) }) else { return nil }; return String(bytes:data.prefix(length),encoding:.ascii) }
}

public enum HeadsetFrame {
    public static func encode(_ payload:[UInt8]) throws -> [UInt8] { guard payload.count>0,payload.count<=61 else { throw ParseFailure.invalid("Frame size") }; return [0x51,UInt8(payload.count+1),0] + payload + Array(repeating:0,count:61-payload.count) }
    public static func payload(_ bytes:[UInt8]) throws -> [UInt8] { guard bytes.count>=3,bytes[0]==0x51,bytes[1]>1,bytes[2]==0 else { throw ParseFailure.invalid("Headset frame") }; let end=Int(bytes[1])+2; guard end<=bytes.count,end<=64 else { throw ParseFailure.truncated }; return Array(bytes[3..<end]) }
    public static func discoverBridgeRequest() -> [UInt8] { try! encode([0,1,0,3]) }
    public static func bridgeDiscovery(_ bytes:[UInt8]) throws -> UInt8 {
        let p=try payload(bytes)
        if p.count>=4,p[0]==0xff,p[1]==0,p[2]==1 { throw ParseFailure.remoteError(p[3]) }
        guard p.count>=5,p[0]==0,p[1]==1 else { throw ParseFailure.unmatched }; return p[2]
    }
    public static func nestedRequest(bridge:UInt8,feature:UInt8,function:UInt8=0,parameters:[UInt8]=[]) throws -> [UInt8] {
        guard function<=15 else { throw ParseFailure.invalid("Function") }; let length=3+parameters.count
        return try encode([bridge,0x11,UInt8((length >> 8)&15),UInt8(length&255),0,feature,(function<<4)|1] + parameters)
    }
    public static func nestedResult(_ bytes:[UInt8],bridge:UInt8,feature:UInt8,function:UInt8=0) throws -> [UInt8]? {
        let p=try payload(bytes)
        if p.count>=3,p[0]==0xff,p[1]==bridge,p[2]==0x11 { guard p.count>=4 else { throw ParseFailure.truncated }; throw ParseFailure.remoteError(p[3]) }
        if p.count==2,p[0]==bridge,p[1]==0x11 { return nil }
        if p.count>=4,p[0]==bridge,p[1]==0,p[2]==0 { if p[3]==0 { throw ParseFailure.offline }; return nil }
        guard p.count>=7,p[0]==bridge,p[1]==0x10 else { throw ParseFailure.unmatched }
        guard p[2]&0xf0==0 else { throw ParseFailure.invalid("Inner length") }
        let length=(Int(p[2])<<8)|Int(p[3]); guard length>=3,length+4==p.count,p[4]==0 else { throw ParseFailure.invalid("Inner length") }
        if p[5]==0xff { guard length>=5,p.count>=9,p[6]==feature,p[7]==(function<<4)|1 else { throw ParseFailure.unmatched }; throw ParseFailure.remoteError(p[8]) }
        guard p[5]==feature,p[6]==(function<<4)|1 else { throw ParseFailure.unmatched }
        return Array(p.dropFirst(7))
    }
    public static func battery(_ results:[UInt8]) throws -> BatteryReading {
        guard let percent=results.first,percent<=100 else { throw ParseFailure.invalid("Headset percent") }
        let charge:ChargeState=results.count>=3 && [UInt8(1),2].contains(results[2]) ? .charging : .unknown
        return BatteryReading(quantity:.reportedPercent(Int(percent)),charge:charge)
    }
    public static let legacyRequest:[UInt8] = [0x51,8,0,3,0x1a,0,3,0,4,0x0a]+Array(repeating:0,count:54)
    public static func legacyBattery(_ bytes:[UInt8]) throws -> BatteryReading? {
        _ = try payload(bytes)
        if bytes[1]==3 { return nil }
        if bytes[1]==5 { if bytes.count>=7,bytes[6]==0 { throw ParseFailure.offline }; return nil }
        guard bytes.count>=13,bytes[1]==0x0b,bytes[8]==4 else { throw ParseFailure.unmatched }
        guard bytes[10]<=100 else { throw ParseFailure.invalid("Legacy headset percent") }
        return BatteryReading(quantity:.reportedPercent(Int(bytes[10])),charge:bytes[12]==2 ? .charging : .unknown)
    }
}

public protocol ReportTransport: AnyObject { var advertisedReports:[UInt8:Int] { get }; func exchange(_ output:[UInt8],timeout:TimeInterval,match:([UInt8]) throws -> [UInt8]?) throws -> [UInt8] }
public final class HIDPlusClient {
    public let transport:ReportTransport; private var software:UInt8=0
    public init(transport:ReportTransport) { self.transport=transport }
    public func request(device:UInt8,feature:UInt8,function:UInt8,parameters:[UInt8]=[]) throws -> [UInt8] {
        software=software%15+1
        let r=HIDPlusRequest(device:device,feature:feature,function:function,software:software,parameters:parameters)
        return try transport.exchange(r.packet(reports:transport.advertisedReports),timeout:0.5) { try r.reply($0) }
    }
    /// Optional metadata; caller handles failure separately from the battery read.
    public func physicalIdentity(device: UInt8) throws -> VerifiedPhysicalIdentity {
        let root=try request(device:device,feature:0,function:0,parameters:[0,3,0])
        guard root.count >= 3, root[0] != 0, root[1]&0x40 == 0, root[2] >= 1 else { throw ParseFailure.unsupported }
        // Sixteen parameters force a long request; only a complete long reply is accepted.
        let payload=try request(device:device,feature:root[0],function:0,parameters:Array(repeating:0,count:16))
        return try VerifiedPhysicalIdentity.decode(payload:payload,version:root[2],target:device)
    }
    public func probe(device:UInt8,ping:UInt8) throws {
        let p:[UInt8]
        do { p=try request(device:device,feature:0,function:1,parameters:[0,0,ping]) }
        catch ParseFailure.timeout {
            // A fresh request rotates the software ID so a late first reply cannot match.
            p=try request(device:device,feature:0,function:1,parameters:[0,0,ping])
        }
        guard p.count>=3,p[0]>=2,p[2]==ping else { throw ParseFailure.unsupported }
    }
    /// Opt-in classification of the initial root exchange only. Existing probe callers
    /// retain their original parser, retry, software-ID and validation behavior.
    public func probeLegacy07(device:UInt8,ping:UInt8,timeout:TimeInterval=0.5,onTimeout:() -> Void) throws -> HIDLegacy07Probe {
        guard (1...6).contains(device), ping != 0, timeout.isFinite, timeout>0 else { throw ParseFailure.invalid("Register07 probe identity/budget") }
        software=software%15+1
        let r=HIDPlusRequest(device:device,feature:0,function:1,software:software,parameters:[0,0,ping])
        let p:[UInt8]
        do {
            p=try transport.exchange(r.packet(reports:transport.advertisedReports),timeout:min(0.5,timeout)) { bytes in
                if bytes == [0x10,device,0x8f,0,(0x10 | r.software),1,0] { throw HIDLegacy07ProbeSignal.detected }
                return try r.reply(bytes)
            }
        } catch HIDLegacy07ProbeSignal.detected { return .legacy }
        catch ParseFailure.timeout {
            onTimeout()
            // This retry is modern-only: even an exact legacy error cannot classify it.
            p=try request(device:device,feature:0,function:1,parameters:[0,0,ping])
        }
        guard p.count>=3,p[0]>=2,p[2]==ping else { throw ParseFailure.unsupported }
        return .modern
    }
    public func feature(_ id:UInt16,device:UInt8) throws -> UInt8 { let p=try request(device:device,feature:0,function:0,parameters:[UInt8(id>>8),UInt8(id&255),0]); guard p.count>=3 else { throw ParseFailure.truncated }; return p[1]&0x40==0 ? p[0]:0 }
    public func metadata(device:UInt8) -> HIDPeripheralMetadata {
        guard let f=try? feature(5,device:device),f != 0 else { return HIDPeripheralMetadata() }
        let type=(try? request(device:device,feature:f,function:2))?.first.flatMap { $0<=7 ? $0:nil }
        var name:String?
        if let p=try? request(device:device,feature:f,function:0),let first=p.first,first>0,first<=128 {
            let length=Int(first); var data:[UInt8]=[]
            while data.count<length {
                guard let chunk=try? request(device:device,feature:f,function:1,parameters:[UInt8(data.count)]),!chunk.isEmpty else { break }
                data.append(contentsOf:chunk.prefix(length-data.count))
            }
            name=HIDBatteryDecoder.safeName(data,length:length)
        }
        return HIDPeripheralMetadata(name:name,type:type)
    }
    public func name(device:UInt8) -> String? { metadata(device:device).name }
    public func battery(device:UInt8) throws -> (BatteryReading,BatterySource) {
        let unified=try feature(0x1004,device:device)
        if unified != 0 { let caps=try UnifiedCapabilities(request(device:device,feature:unified,function:0)); let reading=try HIDBatteryDecoder.unified(request(device:device,feature:unified,function:1),capabilities:caps); return (reading,.hidUnified) }
        let legacy=try feature(0x1000,device:device); guard legacy != 0 else { throw ParseFailure.unsupported }
        let caps=try request(device:device,feature:legacy,function:1)
        return (try HIDBatteryDecoder.legacy(request(device:device,feature:legacy,function:0),capabilities:caps),.hidLegacy)
    }
}
public final class HeadsetClient {
    public let transport:ReportTransport
    public init(transport:ReportTransport) { self.transport=transport }
    public func battery() throws -> BatteryReading {
        let found=try transport.exchange(HeadsetFrame.discoverBridgeRequest(),timeout:0.5) { [try HeadsetFrame.bridgeDiscovery($0)] }
        guard let bridge=found.first,bridge != 0 else { throw ParseFailure.unsupported }
        let discovery=try transport.exchange(HeadsetFrame.nestedRequest(bridge:bridge,feature:0,parameters:[1,4]),timeout:0.5) { try HeadsetFrame.nestedResult($0,bridge:bridge,feature:0) }
        guard discovery.count>=3 else { throw ParseFailure.truncated }
        if discovery[0]==0 { let p=try transport.exchange(HeadsetFrame.legacyRequest,timeout:0.5) { bytes in if let reading=try HeadsetFrame.legacyBattery(bytes),case .reportedPercent(let value)=reading.quantity { return [UInt8(value),reading.charge == .charging ? 2:0] }; return nil }; return BatteryReading(quantity:.reportedPercent(Int(p[0])),charge:p[1]==2 ? .charging:.unknown) }
        let results=try transport.exchange(HeadsetFrame.nestedRequest(bridge:bridge,feature:discovery[0]),timeout:0.5) { try HeadsetFrame.nestedResult($0,bridge:bridge,feature:discovery[0]) }
        return try HeadsetFrame.battery(results)
    }
}

/// Report-specific unsolicited events. Responses, acknowledgements and malformed
/// frames never request another scan.
public enum HIDInputEvent {
    public static func requestsRefresh(_ frame:[UInt8]) -> Bool {
        guard let id=frame.first else { return false }
        if id==0x10 || id==0x11 {
            return frame.count==(id==0x10 ? 7:20) && frame[2]>0 && frame[2] != 0x8f && frame[2] != 0xff && frame[3]==0
        }
        if id==0x51,let p=try? HeadsetFrame.payload(frame) {
            return p.count==4 && p[0]>0 && p[0] != 0xff && p[1]==0 && p[2]==0 && p[3]<=1
        }
        return false
    }
}
public struct HIDPeripheralMetadata:Equatable {
    public var name:String?; public var type:UInt8?
    public init(name:String?=nil,type:UInt8?=nil) { self.name=name; self.type=type }
}
/// Only a real serial supports continuity across enumeration. Without one, a
/// connection-specific ID avoids merging two devices swapped on the same port.
public enum HIDDeviceIdentity {
    public static func key(vendor:Int,product:Int,transport:String,serial:String?,registryID:UInt64) -> String {
        if let serial=serial?.trimmingCharacters(in:.whitespacesAndNewlines),!serial.isEmpty,serial.contains(where: { $0 != "0" }) {
            return "hid-serial-"+SystemReportParser.opaqueIdentity("\(vendor):\(product):\(transport):\(serial)")
        }
        return "hid-connection-\(registryID)"
    }
}
/// Connection-scoped slot metadata; failed probes invalidate only that slot.
public struct HIDMetadataCache {
    private var values:[String:HIDPeripheralMetadata]=[:]
    public init() {}
    public subscript(_ slot:String) -> HIDPeripheralMetadata? {
        get { values[slot] }
        set { values[slot]=newValue }
    }
    public mutating func invalidate(channel:String) { values=values.filter { !$0.key.hasPrefix(channel+"-") } }
}

/// One HID++ wire destination and its independent application identity.
public struct HIDRoutingTarget: Equatable {
    public let wireAddress: UInt8
    public let logicalID: String
    public init(wireAddress: UInt8, logicalID: String) {
        self.wireAddress = wireAddress
        self.logicalID = logicalID
    }
}

/// Pure routing seam for descriptor-qualified HID++ channels.
public enum HIDRoutingPlan {
    public static func isDirectBluetooth(transport: String) -> Bool {
        transport == "Bluetooth Low Energy" || transport == "Bluetooth" || transport == "BluetoothLowEnergy"
    }
    /// The caller must first qualify the HID++ descriptor. Unknown transports retain
    /// the legacy peripheral plan; they do not establish a direct-device identity.
    /// `transport` is the unmodified HID transport string; `channelIdentity` is opaque.
    public static func targets(transport: String, channelIdentity: String) -> [HIDRoutingTarget] {
        if isDirectBluetooth(transport: transport) {
            return [HIDRoutingTarget(wireAddress: 255, logicalID: channelIdentity+"-1")]
        }
        return (UInt8(1)...UInt8(6)).map {
            HIDRoutingTarget(wireAddress: $0, logicalID: channelIdentity+"-\($0)")
        }
    }
}

/// Receiver deduplication consumes a key only after production descriptor
/// qualification. Ordinary interfaces cannot hide a later usable modern one.
public struct HIDReceiverInterfaceAdmission {
    private var consumed=Set<String>()
    public init() {}
    public mutating func admit(generation:String,vendor:Int,product:Int,transport:String,descriptor:HIDDescriptor) -> Bool {
        guard !generation.isEmpty, vendor==0x046d, product==0xc52b, transport=="USB",
              HIDLegacy07.eligible(vendor:vendor,product:product,transport:transport,descriptor:descriptor) || !descriptor.hidPlusReports.isEmpty else { return false }
        return consumed.insert(generation).inserted
    }
}

/// Same failure state for ordinary and opt-in modern probes. This seam does not
/// classify legacy or issue traffic; metadata invalidation remains with its owner.
public enum HIDModernProbeFailure {
    public static func connection(removed:Bool,error:Error) -> ConnectionState {
        (removed || (error as? ParseFailure) == .offline) ? .disconnected:.unavailable
    }
    public static func message(_ error:Error) -> String { "Accessory battery unavailable: \(error)" }
}
