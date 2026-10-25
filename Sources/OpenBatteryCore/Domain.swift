import Foundation

public protocol BatteryClock { func now() -> Date }
public struct SystemBatteryClock: BatteryClock { public init() {}; public func now() -> Date { Date() } }
public enum BatterySource: String, Codable { case systemReport, hidUnified, hidLegacy, headset, watchCompanion, standardBluetooth, usbPresence }
public enum ConnectionState: String, Codable { case connected, disconnected, unavailable, unknown }
public enum ChargeState: String, Codable { case unknown, discharging, charging, finalStage, complete, slowCharging, invalidBattery, thermalError, chargingError
    public var isError: Bool { [.invalidBattery, .thermalError, .chargingError].contains(self) }
    public static func hid(_ value: UInt8) -> ChargeState? { [Self.discharging, .charging, .finalStage, .complete, .slowCharging, .invalidBattery, .thermalError, .chargingError].indices.contains(Int(value)) ? [Self.discharging, .charging, .finalStage, .complete, .slowCharging, .invalidBattery, .thermalError, .chargingError][Int(value)] : nil }
}
public enum Quantity: Equatable, Codable {
    case reportedPercent(Int)
    case coarse(name: String, level: Int?)
    case estimatedPercent(Int, calibrationID: String)
    case unknown
    case absent
    public var isKnown: Bool { switch self { case .reportedPercent, .coarse, .estimatedPercent: return true; default: return false } }
    public var display: String {
        switch self { case .reportedPercent(let p): return "\(p)%"; case .coarse(let name, let n): return "\(name.isEmpty ? n.map { "Level \($0)" } ?? "Level unknown" : name) (coarse)"; case .estimatedPercent(let p, _): return "≈\(p)% (estimated)"; case .unknown: return "Unknown"; case .absent: return "Not reported" }
    }
}
public struct ComponentID: Hashable, Codable {
    public var device: String; public var component: String
    public init(device: String, component: String = "battery") { self.device = device; self.component = component }
}
public struct Observation: Codable {
    public var id: ComponentID; public var name: String; public var source: BatterySource
    public var connection: ConnectionState; public var quantity: Quantity; public var charge: ChargeState
    public var observedAt: Date?; public var measuredAt: Date?; public var sampleMeasuredAt:Date?; public var collectedAt: Date
    public var error: String?
    public var route: BatteryRouteMetadata?
    public init(id: ComponentID, name: String, source: BatterySource, connection: ConnectionState, quantity: Quantity = .unknown, charge: ChargeState = .unknown, observedAt: Date? = nil, measuredAt: Date? = nil, sampleMeasuredAt:Date? = nil, collectedAt: Date, error: String? = nil, route: BatteryRouteMetadata? = nil) { self.id=id; self.name=name; self.source=source; self.connection=connection; self.quantity=quantity; self.charge=charge; self.observedAt=observedAt; self.measuredAt=measuredAt; self.sampleMeasuredAt=sampleMeasuredAt ?? measuredAt; self.collectedAt=collectedAt; self.error=error; self.route=route }
}
public struct BatteryRecord: Codable {
    public var observation: Observation
    public var lastAttempt: Date
    public var error: String?
    public var retained: Bool
    public init(_ observation: Observation) { self.observation=observation; lastAttempt=observation.collectedAt; error=observation.error; retained=observation.quantity.isKnown && (observation.connection == .disconnected || observation.error != nil) }
    public func isStale(at now: Date) -> Bool {
        if retained || observation.connection == .disconnected || error != nil { return true }
        switch observation.source {
        case .systemReport: return false // measurement age is explicitly unknown
        case .watchCompanion: return observation.measuredAt.map { now.timeIntervalSince($0) > 900 } ?? true
        default: return observation.observedAt.map { now.timeIntervalSince($0) > 120 } ?? true
        }
    }
    public func ageDescription(at now: Date) -> String {
        guard let time = observation.source == .systemReport ? observation.measuredAt : observation.measuredAt ?? observation.observedAt else { return "Measurement age unknown" }
        let seconds = max(0, Int(now.timeIntervalSince(time)))
        return seconds < 60 ? "\(seconds)s ago" : seconds < 3600 ? "\(seconds / 60)m ago" : "\(seconds / 3600)h ago"
    }
    public func presentation(at now: Date) -> BatteryPresentation { BatteryPresentation(value: observation.quantity.display, detail: "\(isStale(at: now) && observation.quantity.isKnown ? "Last known · stale · " : "")\(ageDescription(at: now))", connection: observation.connection.rawValue, charge: observation.charge.rawValue, error: error) }
}
public struct BatteryPresentation: Codable { public var value: String; public var detail: String; public var connection: String; public var charge: String; public var error: String? }
public struct BatteryReducer: Codable {
    public private(set) var records: [ComponentID: BatteryRecord] = [:]
    public init() {}
    /// Remove one provider without replaying observations or losing record history.
    public mutating func removeRecords(source:BatterySource) { records=records.filter { $0.value.observation.source != source } }
    /// Receiver identities are exact keys; only delimiter-separated slots belong to them.
    public mutating func disconnectReceiver(_ receiver:String,at:Date) {
        let devices=Set(records.keys.map(\.device).filter { $0==receiver || $0.hasPrefix(receiver+"-") })
        for device in devices { disconnect(device:device,at:at) }
    }
    public mutating func apply(_ next: Observation, now: Date) {
        guard (next.sampleMeasuredAt ?? next.measuredAt).map({ $0.timeIntervalSince(now) <= 120 }) ?? true else { fail(id: next.id, at: next.collectedAt, message: "Source clock is more than two minutes ahead"); return }
        guard var old = records[next.id] else { records[next.id]=BatteryRecord(next); return }
        if let nextTime=next.sampleMeasuredAt,let oldTime=old.observation.sampleMeasuredAt,nextTime<=oldTime { return }
        old.lastAttempt=next.collectedAt; old.error=next.error
        if let error = next.error { old.error=error; old.retained=old.observation.quantity.isKnown; records[next.id]=old; return }
        if next.quantity.isKnown, let nextTime=next.measuredAt ?? next.observedAt, let oldTime=old.observation.measuredAt ?? old.observation.observedAt, nextTime <= oldTime {
            records[next.id]=old; return
        }
        let preserve = !next.quantity.isKnown && old.observation.quantity.isKnown
        var merged=next
        if preserve { merged.quantity=old.observation.quantity; merged.observedAt=old.observation.observedAt; merged.measuredAt=old.observation.measuredAt }
        // Repeated untimestamped system cache is not a new sensor observation.
        if next.source == .systemReport && next.quantity == old.observation.quantity { merged.observedAt=old.observation.observedAt; merged.measuredAt=old.observation.measuredAt }
        old.observation=merged; old.retained=preserve || next.connection == .disconnected; records[next.id]=old
    }
    public mutating func fail(id: ComponentID, at: Date, message: String) { guard var record=records[id] else { return }; record.lastAttempt=at; record.error=message; record.retained=record.observation.quantity.isKnown; records[id]=record }
    public mutating func disconnect(device: String, at: Date) { for id in Array(records.keys) where id.device == device { records[id]?.observation.connection = .disconnected; records[id]?.lastAttempt=at; records[id]?.retained=true } }
}
public enum ParseFailure: Error, Equatable { case invalid(String), truncated, unmatched, remoteError(UInt8), offline, timeout, unsupported }
public enum StrictJSON {
    public static func integer(_ value: Any?) -> Int? {
        guard let n=value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), String(cString: n.objCType) != "f", String(cString: n.objCType) != "d" else { return nil }
        let d=n.doubleValue; guard d.isFinite, d.rounded() == d, d >= Double(Int.min), d < Double(Int.max) else { return nil }; return n.intValue
    }
}
import CoreFoundation
