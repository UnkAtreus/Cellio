import Foundation
import CryptoKit

public enum BatteryRouteType: String, Codable { case bluetooth, wiredUSB, wirelessReceiver, unknown
    public var label: String {
        switch self { case .bluetooth: return "Bluetooth"; case .wiredUSB: return "USB"; case .wirelessReceiver: return "Wireless 2.4 GHz"; case .unknown: return "Connection type unknown" }
    }
}
public enum PhysicalDeviceKind: String, Codable { case mouse, keyboard, trackpad, headset, earbuds, watch, unknown }
/// Collector evidence, never inferred from display names or battery source families.
public struct BatteryRouteMetadata: Codable, Equatable {
    public var type: BatteryRouteType
    public var kind: PhysicalDeviceKind
    public var topology: String
    public init(type: BatteryRouteType, kind: PhysicalDeviceKind = .unknown, topology: String) {
        self.type=type; self.kind=kind; self.topology=topology
    }
}
/// The hash contains the complete validated namespace/model/unit tuple. No raw unit identifier is persisted.
public struct VerifiedPhysicalIdentity: Codable, Equatable {
    public let key: String
    public let featureVersion: UInt8
    public let target: UInt8
    public let transportMask: UInt8
    public static func decode(payload: [UInt8], version: UInt8, target: UInt8) throws -> Self {
        guard version >= 1, payload.count == 16, target != 0,
              payload[5] == 0, payload[6] > 0, payload[6] & 0xf0 == 0,
              payload[6].nonzeroBitCount <= 3,
              payload[1...4].contains(where: { $0 != 0 }), payload[7...12].contains(where: { $0 != 0 }) else { throw ParseFailure.invalid("DeviceInformation base fields") }
        let bytes=Array("Logitech:046d:DeviceInformation:".utf8)+Array(payload[7...12])+Array(payload[1...4])
        let hash=SHA256.hash(data:Data(bytes)).map { String(format:"%02x",$0) }.joined()
        return Self(key:hash,featureVersion:version,target:target,transportMask:payload[6])
    }
    public var isValid: Bool { key.count == 64 && key.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } && featureVersion >= 1 && target != 0 && transportMask > 0 && transportMask & 0xf0 == 0 && transportMask.nonzeroBitCount <= 3 }
}
public struct SavedBatteryRoute: Codable, Equatable {
    public var id: String
    public var metadata: BatteryRouteMetadata
    public var identity: VerifiedPhysicalIdentity?
    public var identityConflict: Bool = false
    public var conflictingIdentities: [VerifiedPhysicalIdentity]?
    public init(id: String, metadata: BatteryRouteMetadata, identity: VerifiedPhysicalIdentity? = nil) { self.id=id; self.metadata=metadata; self.identity=identity }
}
public struct PhysicalDeviceGroup: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var members: [String]
    public var originalDevices: [KnownBatteryDevice]
    public var originalAlerts: [String:DeviceAlertConfiguration]
    public var sharedAlert: DeviceAlertConfiguration
    public var sharedDevice: KnownBatteryDevice
    public var settingsDiffered: Bool
}
public struct PhysicalSeparation: Codable, Equatable {
    public var first: String
    public var second: String
    public var identityKey: String?
    public init(_ a: String, _ b: String) { first=min(a,b); second=max(a,b) }
}
public struct PhysicalDeviceCatalog: Codable, Equatable {
    public var routes: [SavedBatteryRoute] = []
    public var groups: [PhysicalDeviceGroup] = []
    public var separations: [PhysicalSeparation] = []
    public init() {}
}
public struct ConnectionLinkPreview: Equatable {
    public var current: String
    public var selected: [String]
    public var members: [String]
    public var devices: [KnownBatteryDevice]
    public var alerts: [String:DeviceAlertConfiguration]
    public var sharedDevice: KnownBatteryDevice
    public var sharedAlert: DeviceAlertConfiguration
    public var settingsDiffered: Bool
    public var globalThreshold: Int
    public var automaticallyVerified: Bool = false
    public var summary: String {
        "\(members.count) connections · Monitoring \(sharedDevice.preferences.monitorBattery ? "on":"off") · Menu \(sharedDevice.preferences.showInMenu ? "on":"off") · Alerts \(sharedAlert.included ? "included":"excluded") · Threshold \(sharedAlert.usesCustomThreshold ? String(sharedAlert.customThreshold)+"%":"global default (\(globalThreshold)%)") · Menu: \(sharedDevice.selectionSummary) · Alerts: \(sharedAlert.summary)"
    }
}
public enum ConnectionGroupingError: Error, LocalizedError {
    case changed, incompatible, storage, unavailable
    public var errorDescription: String? {
        switch self { case .changed: return "Connections changed. Review your selection and try again."; case .incompatible: return "These entries have incompatible or unproved device/component mappings."; case .storage: return "Connections weren’t saved. Previous grouping and settings are still in use. Try Again."; case .unavailable: return "Connection settings or alert storage are unavailable. Review storage recovery." }
    }
}
/// Projection is independent of the reducer. The selected raw route is explicit in provenance.
public struct PhysicalBatteryProjection {
    public var records: [BatteryRecord]
    public var origins: [ComponentID:String]
    public var routeLabels: [String:String]
}
public final class PhysicalBatterySelector {
    private var selected: [ComponentID:String] = [:]
    public init() {}
    public func project(records: [BatteryRecord], devices: [KnownBatteryDevice], catalog: PhysicalDeviceCatalog, now: Date, connections: [String:ConnectionState] = [:]) -> PhysicalBatteryProjection {
        var result=PhysicalBatteryProjection(records:[],origins:[:],routeLabels:[:])
        let routes=Dictionary(uniqueKeysWithValues:catalog.routes.map { ($0.id,$0.metadata) })
        for device in devices {
            let group=catalog.groups.first { $0.id == device.id }
            let members=Set(group?.members ?? [device.id])
            // A reused route key with contradictory unit proof cannot supply a linked device.
            let quarantined=Set(catalog.routes.filter(\.identityConflict).map(\.id))
            let raw=records.filter { members.contains($0.observation.id.device) && (group == nil || !quarantined.contains($0.observation.id.device)) }
            let states=Dictionary(uniqueKeysWithValues:members.map { member in
                (member,quarantined.contains(member) ? .unavailable : connections[member] ?? raw.first(where: { $0.observation.id.device == member })?.observation.connection ?? .unknown)
            })
            let active=Set(states.filter { $0.value == .connected }.map(\.key))
            let byComponent=Dictionary(grouping:raw,by: { $0.observation.id.component })
            var chosenOrigins: [String] = []
            for component in KnownBatteryDevice.order(Array(byComponent.keys)) {
                let id=ComponentID(device:device.id,component:component)
                func quality(_ r: BatteryRecord) -> Int {
                    let o=r.observation
                    if !o.quantity.isKnown { return 0 }
                    if r.error != nil || o.error != nil || o.charge.isError { return 1 }
                    if r.retained || r.isStale(at:now) || (states[o.id.device] ?? o.connection) == .disconnected || (states[o.id.device] ?? o.connection) == .unavailable { return 2 }
                    return 3
                }
                let values=byComponent[component]!.sorted { a,b in
                    let qa=quality(a), qb=quality(b)
                    if qa != qb { return qa > qb }
                    func precision(_ q: Quantity) -> Int {
                        switch q { case .reportedPercent: return 3; case .coarse: return 2; case .estimatedPercent: return 1; default: return 0 }
                    }
                    let pa=precision(a.observation.quantity), pb=precision(b.observation.quantity)
                    if pa != pb { return pa > pb }
                    // Only comparable quantity clocks order readings. An unknown age is never refreshed by collection.
                    if let ta=LowBatteryAlertPolicy.quantityTime(a),let tb=LowBatteryAlertPolicy.quantityTime(b),ta != tb { return ta > tb }
                    let ra=a.observation.id.device, rb=b.observation.id.device
                    if (ra == selected[id]) != (rb == selected[id]) { return ra == selected[id] }
                    return ra < rb
                }
                guard var record=values.first else { continue }
                let origin=record.observation.id.device
                selected[id]=origin; chosenOrigins.append(origin); result.origins[id]=origin
                if group != nil {
                    record.observation.id.device=device.id; record.observation.name=device.name
                    if !active.contains(origin) { record.retained=true }
                }
                result.records.append(record)
            }
            let origin=chosenOrigins.first
            let label: String
            if !active.isEmpty {
                let liveOrigin=origin.flatMap { candidate -> String? in
                    guard active.contains(candidate), raw.contains(where: { $0.observation.id.device == candidate && $0.observation.quantity.isKnown && !$0.retained && !$0.isStale(at:now) }) else { return nil }
                    return candidate
                }
                let route=liveOrigin ?? active.sorted().first(where: { routes[$0]?.type == .wiredUSB }) ?? active.sorted().first!
                let current=routes[route]?.type.label ?? BatteryRouteType.unknown.label
                let fallback=origin.map { !active.contains($0) } ?? false
                label=current+(active.count > 1 ? " · \(active.count) connections":"")+(fallback ? " · Last known":"")
            } else if !states.isEmpty && states.values.allSatisfy({ $0 == .disconnected }) { label="Disconnected" }
            else if states.values.contains(.unavailable) { label="Connection unavailable" }
            else { label="Connection unknown" }
            result.routeLabels[device.id]=label
        }
        let covered=Set(devices.flatMap { device in catalog.groups.first { $0.id == device.id }?.members ?? [device.id] })
        for record in records where !covered.contains(record.observation.id.device) {
            result.records.append(record); result.origins[record.observation.id]=record.observation.id.device
        }
        return result
    }
}
