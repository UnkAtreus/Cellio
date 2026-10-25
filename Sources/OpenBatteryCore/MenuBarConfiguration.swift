import Foundation

public enum MenuBarDisplay: String, Codable, CaseIterable { case percentage, batteryGauge }
public enum MenuBarSeparator: String, Codable, CaseIterable { case none, line }

/// Immutable creation provenance. Membership is never replaced with a guessed current device.
public struct MenuBarPin: Codable, Equatable, Identifiable {
    public let id: String
    public let deviceID: String
    public let componentID: String
    public let sourceMembers: [String]
    public let deviceName: String
    public init(id: String = UUID().uuidString.lowercased(), deviceID: String, componentID: String,
                sourceMembers: [String], deviceName: String) {
        self.id=id; self.deviceID=deviceID; self.componentID=componentID
        self.sourceMembers=sourceMembers.sorted(); self.deviceName=deviceName
    }
}
public struct MenuBarConfiguration: Codable, Equatable {
    public static let defaultSpacing = 8
    public static let spacingRange = 4...16
    public var version: Int = 1
    public var display: MenuBarDisplay = .percentage
    public var separator: MenuBarSeparator = .none
    public var spacing: Int = defaultSpacing
    public var pins: [MenuBarPin] = []
    public init() {}
    private enum CodingKeys: String, CodingKey { case version, display, separator, spacing, pins }
    public init(from decoder: Decoder) throws {
        let values=try decoder.container(keyedBy:CodingKeys.self)
        version=try values.decode(Int.self,forKey:.version)
        display=try values.decode(MenuBarDisplay.self,forKey:.display)
        separator=try values.decode(MenuBarSeparator.self,forKey:.separator)
        spacing=values.contains(.spacing) ? try values.decode(Int.self,forKey:.spacing):Self.defaultSpacing
        pins=try values.decode([MenuBarPin].self,forKey:.pins)
    }
    public static func validText(_ value: String, limit: Int = 512) -> Bool {
        !value.isEmpty && value.utf8.count <= limit && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    public func validate() throws {
        guard version == 1, Self.spacingRange.contains(spacing), pins.count <= 3,
              Set(pins.map(\.id)).count == pins.count else { throw MenuBarStorageError.invalidData }
        var pairs=Set<ComponentID>()
        for pin in pins {
            guard UUID(uuidString:pin.id) != nil, Self.validText(pin.deviceID), Self.validText(pin.componentID),
                  Self.validText(pin.deviceName), !pin.sourceMembers.isEmpty, pin.sourceMembers.count <= 1024,
                  Set(pin.sourceMembers).count == pin.sourceMembers.count, pin.sourceMembers.allSatisfy({ Self.validText($0) }),
                  pairs.insert(ComponentID(device:pin.deviceID,component:pin.componentID)).inserted else { throw MenuBarStorageError.invalidData }
        }
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 65_536,
              let raw=try JSONSerialization.jsonObject(with:data) as? [String:Any],
              [Set(["version","display","separator","pins"]),Set(["version","display","separator","spacing","pins"])].contains(Set(raw.keys)),
              StrictJSON.integer(raw["version"]) == 1,
              !raw.keys.contains("spacing") || StrictJSON.integer(raw["spacing"]).map(Self.spacingRange.contains) == true,
              let pins=raw["pins"] as? [[String:Any]], pins.count <= 3,
              pins.allSatisfy({ Set($0.keys) == Set(["id","deviceID","componentID","sourceMembers","deviceName"]) }) else { throw MenuBarStorageError.invalidData }
        let result=try JSONDecoder().decode(Self.self,from:data)
        try result.validate(); return result
    }
}
public enum MenuBarStorageError: Error { case invalidData, saveFailed, unavailable }

/// save must be atomic on throw. nil restores an originally absent key after failed readback.
public protocol MenuBarPersistence {
    func load() throws -> Data?
    func save(_ data: Data?) throws
}
public final class MemoryMenuBarPersistence: MenuBarPersistence {
    public var data: Data?
    public init(data: Data? = nil) { self.data=data }
    public func load() throws -> Data? { data }
    public func save(_ data: Data?) throws { self.data=data }
}
public final class DefaultsMenuBarPersistence: MenuBarPersistence {
    public static let key="cellio.menuBar.v1"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults) { self.defaults=defaults }
    public static func process(arguments: [String]) throws -> DefaultsMenuBarPersistence {
        if let suite=try DeviceSettingsStore.qaSuite(arguments:arguments) {
            guard let defaults=UserDefaults(suiteName:suite) else { throw DeviceSettingsError.invalidSuite }
            return .init(defaults:defaults)
        }
        return .init(defaults:.standard)
    }
    public func load() throws -> Data? {
        guard let value=defaults.object(forKey:Self.key) else { return nil }
        guard let data=value as? Data, data.count <= 65_536 else { throw MenuBarStorageError.invalidData }
        return data
    }
    public func save(_ data: Data?) throws {
        let previous=defaults.object(forKey:Self.key)
        if let data { defaults.set(data,forKey:Self.key) } else { defaults.removeObject(forKey:Self.key) }
        guard defaults.synchronize(), defaults.object(forKey:Self.key) as? Data == data else {
            if let previous { defaults.set(previous,forKey:Self.key) } else { defaults.removeObject(forKey:Self.key) }
            _=defaults.synchronize(); throw MenuBarStorageError.saveFailed
        }
    }
}

/// A separate transaction boundary: never reads or writes device/alert/appearance documents.
public final class MenuBarConfigurationStore {
    public private(set) var configuration=MenuBarConfiguration()
    public private(set) var unavailable=false
    public private(set) var hasVerifiedLayout=false
    private let persistence: MenuBarPersistence
    private var verifiedBytes: Data?
    public init(persistence: MenuBarPersistence = MemoryMenuBarPersistence()) {
        self.persistence=persistence; _=reload()
    }
    @discardableResult public func reload() -> Bool {
        do {
            let data=try persistence.load()
            let next=try data.map(MenuBarConfiguration.decode) ?? MenuBarConfiguration()
            configuration=next; verifiedBytes=data; unavailable=false; hasVerifiedLayout=true; return true
        } catch { unavailable=true; return false }
    }
    public func commit(_ next: MenuBarConfiguration, resetting: Bool = false) throws {
        guard !unavailable || resetting else { throw MenuBarStorageError.unavailable }
        try next.validate()
        let data=try JSONEncoder().encode(next)
        guard data.count <= 65_536 else { throw MenuBarStorageError.invalidData }
        // An explicit recovery Reset may replace unreadable/wrong-type storage.
        let previous: Data?
        do { previous=try persistence.load() }
        catch {
            guard resetting else { unavailable=true; throw MenuBarStorageError.unavailable }
            previous=nil
        }
        if !resetting, previous != verifiedBytes {
            unavailable=true; throw MenuBarStorageError.unavailable
        }
        try persistence.save(data)
        do {
            guard try persistence.load() == data else { throw MenuBarStorageError.saveFailed }
        } catch {
            do {
                try persistence.save(previous)
                guard try persistence.load() == previous else { throw MenuBarStorageError.saveFailed }
            } catch { unavailable=true }
            throw MenuBarStorageError.saveFailed
        }
        configuration=next; verifiedBytes=data; unavailable=false; hasVerifiedLayout=true
    }
}

public struct MenuBarResolvedPin: Identifiable {
    public enum State: Equatable { case active, hidden, review, missing, coalesced }
    public let pin: MenuBarPin
    public let device: KnownBatteryDevice?
    public let logicalID: String?
    public var state: State
    public var id: String { pin.id }
}
public enum MenuBarPinPolicy {
    public static func makePin(device: KnownBatteryDevice, component: String, settings: DeviceSettingsStore) throws -> MenuBarPin {
        guard !settings.updatesBlocked, !settings.isHidden(device.id),
              settings.devices.contains(where: { $0.id == device.id && $0.knownComponentIDs.contains(component) }) else { throw MenuBarStorageError.unavailable }
        let pin=MenuBarPin(deviceID:device.id,componentID:component,sourceMembers:settings.members(of:device.id),deviceName:device.name)
        var config=MenuBarConfiguration(); config.pins=[pin]; try config.validate(); return pin
    }
    public static func resolve(_ config: MenuBarConfiguration, settings: DeviceSettingsStore, quarantinedRoutes: Set<String> = []) -> [MenuBarResolvedPin] {
        let devices=settings.allLogicalDevices, catalog=settings.physicalCatalog
        var seen=Set<ComponentID>()
        return config.pins.map { pin in
            let current=Set(pin.sourceMembers.map { settings.logicalID(for:$0) })
            let hidden=pin.sourceMembers.contains(where:settings.isHidden)
            let conflict = !quarantinedRoutes.isDisjoint(with:pin.sourceMembers) || catalog.routes.contains { pin.sourceMembers.contains($0.id) && $0.identityConflict }
            guard current.count == 1, let id=current.first, !conflict else {
                return .init(pin:pin,device:nil,logicalID:nil,state:hidden ? .hidden:.review)
            }
            let device=devices.first { $0.id == id }
            let state: MenuBarResolvedPin.State
            if hidden || settings.isHidden(id) { state = .hidden }
            else if device == nil { state = .missing }
            else if !seen.insert(ComponentID(device:id,component:pin.componentID)).inserted { state = .coalesced }
            else { state = .active }
            return .init(pin:pin,device:device,logicalID:id,state:state)
        }
    }
    /// Build a singleton with the original quantity/times, independently of dropdown choices.
    public static func presentation(_ resolved: MenuBarResolvedPin, records: [BatteryRecord], at now: Date) -> BatteryMenuDevicePresentation {
        let id=resolved.logicalID ?? resolved.pin.deviceID
        let record=resolved.state == .active ? records.first { $0.observation.id == ComponentID(device:id,component:resolved.pin.componentID) }:nil
        return BatteryMenuDevicePresentation(id:id,name:resolved.device?.name ?? resolved.pin.deviceName,
            source:resolved.device?.source,components:[BatteryMenuComponentPresentation(id:resolved.pin.componentID,
                reading:record.map { BatteryComponentPresentation(record:$0,at:now) })],kind:resolved.device?.kind)
    }
}

public struct MenuBarLayout: Equatable {
    public let displayedIDs: [String]
    public let overflow: Int
    public let width: Double
    public static let maximumWidth: Double = 280
    public static let iconWidth: Double = 24
    public static let overflowWidth: Double = 26
    public static let gap = Double(MenuBarConfiguration.defaultSpacing)
    /// Total native image edge inset, retained once for either content or fallback.
    public static let imageInsets: Double = 4
    // Observed native target adds 2pt to item.length. width reserves that once,
    // against both the public geometry budget and the 280pt policy cap.
    public static let nativeTargetOverhead: Double = 2
    public static func discriminatorWidth(component: String) -> Double {
        // Whole-point bounds for the unchanged native 9pt font: L/R/Case.
        switch component {
        case "battery": return 0
        case "left": return 6
        case "right": return 7
        default: return 22
        }
    }
    public static func pinWidth(component: String) -> Double {
        // Conservative fallback: glyph 12 + current gap 8 + safety reserve 8
        // + maximum quantity ceiling 39 + gap 1 + two 8pt state markers.
        // Native callers supply exact occupied widths instead of this estimate.
        let label=discriminatorWidth(component:component)
        return 84 + label + (label > 0 ? 2:0)
    }
    public static func project(_ pins: [MenuBarResolvedPin], budget: Double?,
                               spacing: Int = MenuBarConfiguration.defaultSpacing,
                               contentWidths: [String:Double]? = nil) -> Self {
        let iconOnlyWidth=iconWidth+nativeTargetOverhead
        let fallback=Self(displayedIDs:[],overflow:0,width:iconOnlyWidth)
        guard MenuBarConfiguration.spacingRange.contains(spacing),
              let budget, budget.isFinite, budget >= iconOnlyWidth else { return fallback }
        let available=min(maximumWidth,budget)
        let eligible=pins.filter { $0.state != .hidden && $0.state != .coalesced }
        guard !eligible.isEmpty else { return fallback }
        let widths: [Double?]=eligible.map { pin in
            if let contentWidths { return contentWidths[pin.id] }
            return pinWidth(component:pin.pin.componentID)
        }
        guard widths.allSatisfy({ $0.map { $0.isFinite && $0 > 0 } == true }) else { return fallback }
        for count in stride(from:eligible.count,through:1,by:-1) {
            let selected=Array(eligible.prefix(count)), overflow=eligible.count-count
            let width=imageInsets+nativeTargetOverhead+widths.prefix(count).reduce(0) { $0+($1 ?? 0) }
                + Double(count-1)*Double(spacing)+(overflow > 0 ? overflowWidth:0)
            if width <= available { return .init(displayedIDs:selected.map(\.id),overflow:overflow,width:width) }
        }
        return fallback
    }
}
