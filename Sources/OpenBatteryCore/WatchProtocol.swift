import Foundation
import CryptoKit
import Darwin

public enum WatchBatteryState:String,Codable { case unknown,unplugged,charging,full
    public var charge:ChargeState { switch self { case .unknown:return .unknown; case .unplugged:return .discharging; case .charging:return .charging; case .full:return .complete } }
}
public struct WatchSample:Codable,Equatable {
    public let schemaVersion:Int; public let source:String; public let deviceID:UUID; public let sampleID:UUID; public let measuredAt:Int64; public let batteryPercent:Int?; public let batteryState:WatchBatteryState
    public init(deviceID:UUID,sampleID:UUID=UUID(),measuredAt:Date,batteryPercent:Int?,batteryState:WatchBatteryState) { schemaVersion=1; source="watch-companion"; self.deviceID=deviceID; self.sampleID=sampleID; self.measuredAt=Int64((measuredAt.timeIntervalSince1970*1000).rounded(.down)); self.batteryPercent=batteryPercent; self.batteryState=batteryState }
    private init(deviceID:UUID,sampleID:UUID,epochMilliseconds:Int64,batteryPercent:Int?,batteryState:WatchBatteryState) { schemaVersion=1; source="watch-companion"; self.deviceID=deviceID; self.sampleID=sampleID; measuredAt=epochMilliseconds; self.batteryPercent=batteryPercent; self.batteryState=batteryState }
    public var date:Date { Date(timeIntervalSince1970:Double(measuredAt)/1000) }
    public static func validate(_ data:Data,now:Date) throws -> WatchSample {
        guard data.count<=4096,let o=try JSONSerialization.jsonObject(with:data) as? [String:Any],StrictJSON.integer(o["schemaVersion"])==1,o["source"] as? String == "watch-companion",let d=o["deviceID"] as? String,let device=UUID(uuidString:d),let s=o["sampleID"] as? String,let sample=UUID(uuidString:s),let ms=StrictJSON.integer(o["measuredAt"]),let stateRaw=o["batteryState"] as? String,let state=WatchBatteryState(rawValue:stateRaw) else { throw ParseFailure.invalid("Invalid Watch sample schema or types") }
        var percent:Int?=nil
        if o.keys.contains("batteryPercent") { guard let p=StrictJSON.integer(o["batteryPercent"]),(0...100).contains(p) else { throw ParseFailure.invalid("Invalid Watch battery percent") }; percent=p }
        let date=Date(timeIntervalSince1970:Double(ms)/1000), age=now.timeIntervalSince(date)
        guard age >= -120 else { throw ParseFailure.invalid("Watch clock is more than two minutes ahead") }
        guard age<=86400 else { throw ParseFailure.invalid("Watch sample is older than 24 hours") }
        return WatchSample(deviceID:device,sampleID:sample,epochMilliseconds:Int64(ms),batteryPercent:percent,batteryState:state)
    }
    public func observation(collectedAt:Date) -> Observation { Observation(id:ComponentID(device:"watch-"+deviceID.uuidString),name:"Apple Watch",source:.watchCompanion,connection:.unknown,quantity:batteryPercent.map(Quantity.reportedPercent) ?? .unknown,charge:batteryState.charge,observedAt:batteryPercent == nil ? nil:date,measuredAt:batteryPercent == nil ? nil:date,sampleMeasuredAt:date,collectedAt:collectedAt,route:.init(type:.unknown,kind:.watch,topology:"Watch companion via iPhone; accessory transport unknown")) }
    public static func percent(level:Float) -> Int? { guard level.isFinite,level>=0,level<=1 else { return nil }; return Int((level*100).rounded()) }
    public func propertyList() throws -> [String:Any] { try JSONSerialization.jsonObject(with:JSONEncoder().encode(self)) as! [String:Any] }
}
public enum WatchAuthentication {
    public static func signature(body:Data,secret:Data) -> String { Data(HMAC<SHA256>.authenticationCode(for:body,using:SymmetricKey(data:secret))).base64EncodedString() }
    public static func verify(body:Data,mac:String,secret:Data) -> Bool { guard secret.count==32,let tag=Data(base64Encoded:mac),tag.count==32 else { return false }; return HMAC<SHA256>.isValidAuthenticationCode(tag,authenticating:body,using:SymmetricKey(data:secret)) }
}
public struct WatchReceipt:Codable {
    public private(set) var boundDevice:UUID?
    public private(set) var latest:WatchSample?
    public private(set) var quantitySample:WatchSample?
    public private(set) var latestReceivedAt:Date?
    public private(set) var quantityReceivedAt:Date?
    public private(set) var seen:[UUID]=[]
    public init() {}
    public mutating func accept(_ sample:WatchSample,receivedAt:Date?=nil) throws -> Bool {
        if let bound=boundDevice,bound != sample.deviceID { throw ParseFailure.invalid("different-device") }
        if seen.contains(sample.sampleID) { return false }
        if let latest, sample.measuredAt<=latest.measuredAt { return false }
        boundDevice=sample.deviceID; latest=sample; latestReceivedAt=receivedAt ?? sample.date; if sample.batteryPercent != nil { quantitySample=sample; quantityReceivedAt=receivedAt ?? sample.date }; seen.append(sample.sampleID); if seen.count>256 { seen.removeFirst(seen.count-256) }; return true
    }
}
public struct HTTPRequest {
    public var method:String; public var path:String; public var headers:[String:String]; public var body:Data
    public static func parse(_ data:Data) throws -> HTTPRequest? {
        let delimiter=Data([13,10,13,10])
        guard let r=data.range(of:delimiter) else { if data.count>8192 { throw ParseFailure.invalid("headers-too-large") }; return nil }
        guard r.upperBound<=8192,let header=String(data:data[..<r.lowerBound],encoding:.utf8) else { throw ParseFailure.invalid("headers-too-large") }
        let lines=header.components(separatedBy:"\r\n"); let first=lines[0].split(separator:" ")
        guard first.count==3,first[2]=="HTTP/1.1" else { throw ParseFailure.invalid("HTTP request line") }
        var headers:[String:String]=[:]
        for line in lines.dropFirst() { guard let colon=line.firstIndex(of:":") else { throw ParseFailure.invalid("HTTP header") }; let key=line[..<colon].lowercased(),value=line[line.index(after:colon)...].trimmingCharacters(in:.whitespaces); guard headers[key]==nil else { throw ParseFailure.invalid("Duplicate HTTP header") }; headers[key]=value }
        guard headers["transfer-encoding"]==nil,let raw=headers["content-length"],!raw.isEmpty,raw.allSatisfy({ $0.isASCII && $0.isNumber }),let size=Int(raw),size>=0 else { throw ParseFailure.invalid("HTTP content length") }
        guard size<=4096 else { throw ParseFailure.invalid("body-too-large") }
        guard data.count>=r.upperBound+size else { return nil }
        guard data.count==r.upperBound+size else { throw ParseFailure.invalid("Extra HTTP data") }
        return HTTPRequest(method:String(first[0]),path:String(first[1]),headers:headers,body:Data(data[r.upperBound...]))
    }
    public func authenticatedSample(pairingID:UUID,secret:Data,now:Date) throws -> WatchSample {
        guard method=="POST",path=="/v1/watch-samples",headers["content-type"]?.lowercased().split(separator:";").first=="application/json" else { throw ParseFailure.invalid("HTTP route or content type") }
        guard let pairing=headers["x-openbattery-pairing"],UUID(uuidString:pairing)==pairingID,let mac=headers["x-openbattery-mac"],WatchAuthentication.verify(body:body,mac:mac,secret:secret) else { throw ParseFailure.invalid("unauthorized") }
        return try WatchSample.validate(body,now:now)
    }
}
public enum LocalEndpoint {
    public static func validate(_ value:String) -> URL? {
        guard let parts=URLComponents(string:value),parts.scheme=="http",parts.user==nil,parts.password==nil,parts.query==nil,parts.fragment==nil,(parts.path.isEmpty || parts.path=="/"),let host=parts.host,let port=parts.port,(1...65535).contains(port) else { return nil }
        let bracketed=host.hasPrefix("[") || host.hasSuffix("]")
        if bracketed && !(host.hasPrefix("[") && host.hasSuffix("]")) { return nil }
        let h=(bracketed ? String(host.dropFirst().dropLast()):host).lowercased()
        var v4=in_addr()
        let validIPv4=h.withCString { inet_pton(AF_INET,$0,&v4) } == 1
        let octets=withUnsafeBytes(of:v4) { Array($0) }
        let ipv4=validIPv4 && (octets[0]==10 || octets[0]==127 || (octets[0]==192 && octets[1]==168) || (octets[0]==172 && (16...31).contains(octets[1])) || (octets[0]==169 && octets[1]==254))
        var address=in6_addr()
        let validIPv6=h.withCString { inet_pton(AF_INET6,$0,&address) } == 1
        let bytes=withUnsafeBytes(of:address) { Array($0) }
        let ipv6=validIPv6 && ((bytes[0]&0xfe)==0xfc || (bytes[0]==0xfe && bytes[1]&0xc0==0x80) || (bytes.dropLast().allSatisfy { $0==0 } && bytes.last==1))
        let labels=h.split(separator:".",omittingEmptySubsequences:false)
        let localName=h.utf8.count<=253 && labels.count>=2 && labels.last=="local" && labels.allSatisfy { label in
            !label.isEmpty && label.utf8.count<=63 && label.first != "-" && label.last != "-" && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0==45 }
        }
        guard bracketed ? ipv6 : (ipv4 || localName) else { return nil }
        return parts.url
    }
    public static func sampleURL(_ endpoint:URL) -> URL { endpoint.appendingPathComponent("v1/watch-samples") }
}

/// Tokens fence asynchronous completions across cancellation and reconfiguration.
public struct ForwardingOwnership {
    public private(set) var current:UUID?
    public init() {}
    public mutating func begin() -> UUID? { guard current==nil else { return nil }; let token=UUID(); current=token; return token }
    public func owns(_ token:UUID) -> Bool { current==token }
    @discardableResult public mutating func finish(_ token:UUID) -> Bool { guard owns(token) else { return false }; current=nil; return true }
    public mutating func invalidate() { current=nil }
}

/// Session identity for listener work, including delivery queued onto another executor.
/// Keep each instance on its owner's serial executor. Stopping preserves history;
/// invalidation only removes permission for that session to deliver further work.
public struct WatchDeliveryOwnership {
    private var generation:UInt64=0
    public private(set) var current:UInt64?
    public init() {}
    @discardableResult public mutating func begin() -> UInt64 {
        generation += 1
        current=generation
        return generation
    }
    public func owns(_ token:UInt64) -> Bool { current==token }
    public mutating func invalidate() { current=nil }
}
