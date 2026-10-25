import Foundation

/// Storage contains only the versioned device catalog/preferences, never readings or Watch data.
public protocol DeviceSettingsPersistence {
    func load() throws -> Data?
    func save(_ data: Data) throws
}

public final class MemoryDeviceSettingsPersistence: DeviceSettingsPersistence {
    public var data: Data?
    public init(data: Data? = nil) { self.data = data }
    public func load() throws -> Data? { data }
    public func save(_ data: Data) throws { self.data = data }
}

public final class DefaultsDeviceSettingsPersistence: DeviceSettingsPersistence {
    public static let key = "cellio.deviceSettings.v2"
    public static let legacyKey = "cellio.deviceSettings.v1"
    private let defaults: Foundation.UserDefaults
    public init(defaults: Foundation.UserDefaults = .standard) { self.defaults = defaults }
    public func load() throws -> Data? {
        if let value = defaults.object(forKey: Self.key) {
            guard let data = value as? Data, data.count <= 1_048_576 else { throw DeviceSettingsError.invalidData }
            // A v2 key never accepts a legacy document or falls back to v1.
            guard (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["version"] as? Int == 2 else { throw DeviceSettingsError.invalidData }
            return data
        }
        guard let value = defaults.object(forKey: Self.legacyKey) else { return nil }
        guard let data = value as? Data, data.count <= 1_048_576,
              (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["version"] as? Int == 1 else { throw DeviceSettingsError.invalidData }
        return data
    }
    public func save(_ data: Data) throws {
        let previous = defaults.object(forKey: Self.key)
        defaults.set(data, forKey: Self.key)
        guard defaults.synchronize(), defaults.data(forKey: Self.key) == data else {
            // Failed migration must not make an unverified v2 value authoritative.
            if let previous { defaults.set(previous, forKey: Self.key) }
            else { defaults.removeObject(forKey: Self.key) }
            _ = defaults.synchronize()
            throw DeviceSettingsError.saveFailed
        }
    }
}

public enum DeviceSettingsError: Error { case invalidData, saveFailed, invalidSuite }

public struct DevicePreferences: Codable, Equatable {
    public var monitorBattery: Bool
    public var showInMenu: Bool
    public init(monitorBattery: Bool = true, showInMenu: Bool = true) {
        self.monitorBattery = monitorBattery; self.showInMenu = showInMenu
    }
}

public struct ComponentSelection: Codable, Equatable {
    public enum Mode: String, Codable { case all, selected }
    public var mode: Mode
    public var ids: [String]
    public init(mode: Mode = .all, ids: [String] = []) { self.mode = mode; self.ids = ids }
    public func includes(_ id: String) -> Bool { mode == .all || ids.contains(id) }
}

public struct KnownBatteryDevice: Codable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var source: BatterySource?
    public var kind: PhysicalDeviceKind?
    public var preferences: DevicePreferences
    public var knownComponentIDs: [String]
    public var componentSelection: ComponentSelection
    public init(id: String, name: String, source: BatterySource?, preferences: DevicePreferences = .init(),
                knownComponentIDs: [String] = [], componentSelection: ComponentSelection = .init(), kind: PhysicalDeviceKind? = nil) {
        self.id = id; self.name = name; self.source = source; self.preferences = preferences
        self.knownComponentIDs = knownComponentIDs; self.componentSelection = componentSelection
        self.kind = kind
    }
    public var orderedComponentIDs: [String] { Self.order(knownComponentIDs) }
    public static func order(_ ids: [String]) -> [String] {
        let rank = ["left": 0, "right": 1, "case": 2, "battery": 3]
        return ids.sorted { (rank[$0] ?? 4, $0) < (rank[$1] ?? 4, $1) }
    }
    public static func componentName(_ id: String) -> String {
        ["left": "Left", "right": "Right", "case": "Case", "battery": "Battery"][id] ?? id
    }
    public var selectionSummary: String {
        if componentSelection.mode == .all { return "All components" }
        if Set(componentSelection.ids) == Set(knownComponentIDs) { return "All current components" }
        return Self.order(componentSelection.ids).map(Self.componentName).joined(separator: ", ")
    }
    public var providerDescription: String {
        switch source {
        case .systemReport: return "macOS system report · experimental · measurement age unknown"
        case .hidUnified, .hidLegacy: return "Logitech accessory · experimental"
        case .headset: return "Headset receiver · experimental"
        case .watchCompanion: return "Watch via iPhone · delivery may be delayed"
        case .standardBluetooth: return "Standard Bluetooth battery · host read time; sensor age unknown"
        case .usbPresence: return "USB connected · battery not reported; battery protocol unverified"
        case nil: return "Accessory provider · battery support not yet established"
        }
    }
}

/// A value captured before collection/dispatch. Missing IDs mean a new, enabled device at revision zero.
public struct DeviceCollectionContext {
    fileprivate let epoch: UInt64
    fileprivate let revisions: [String: UInt64]
    fileprivate let paused: Set<String>
    fileprivate let hidden: Set<String>
    fileprivate let archived: Set<String>
    fileprivate let blocked: Bool
    public func shouldQuery(_ device: String) -> Bool { !blocked && !paused.contains(device) && !hidden.contains(device) && !archived.contains(device) }
}

/// Original erroneous slot records, retained verbatim. The exact channel also
/// tombstones absent slots so delayed pre-repair discovery cannot recreate them.
public struct DirectBluetoothAliasArchive: Codable, Equatable {
    public let channelIdentity: String
    public let devices: [KnownBatteryDevice]
    public init(channelIdentity: String, devices: [KnownBatteryDevice]) {
        self.channelIdentity = channelIdentity; self.devices = devices
    }
}

/// Optional adapters keep AppModel compatible with minimal, unfiltered native providers.
public protocol DevicePolicyProvider { func useDeviceSettings(_ settings: DeviceSettingsStore) }
public protocol DevicePolicyBatchContext { var devicePolicyContext: DeviceCollectionContext? { get } }

/// Thread-safe shared policy used by host acceptance, HID collection and both presentations.
public final class DeviceSettingsStore {
    private struct Document: Codable {
        var version: Int
        var devices: [KnownBatteryDevice]
        // Optional keeps documents without an archive on the existing v2 shape.
        var directBluetoothAliasArchives: [DirectBluetoothAliasArchive]?
        var physicalDevices: PhysicalDeviceCatalog?
        var visibility: DeviceVisibility?
    }
    private struct LegacyDocument: Decodable {
        struct Device: Decodable { var id: String; var name: String; var source: BatterySource?; var preferences: DevicePreferences }
        var version: Int; var devices: [Device]
    }
    private let lock = NSLock()
    private let persistence: DeviceSettingsPersistence
    private var catalog: [String: KnownBatteryDevice] = [:]
    private var archives: [String: DirectBluetoothAliasArchive] = [:]
    private var archivedIDs: Set<String> = []
    private var physical = PhysicalDeviceCatalog()
    private var hiddenIDs: Set<String> = []
    private var visibilityQuarantine: Set<String> = []
    private var revisions: [String: UInt64] = [:]
    private var epoch: UInt64 = 0
    private var blocked = false
    private var error: String?
    public init(persistence: DeviceSettingsPersistence = MemoryDeviceSettingsPersistence()) {
        self.persistence = persistence
        do {
            if let data = try persistence.load() {
                guard data.count <= 1_048_576 else { throw DeviceSettingsError.invalidData }
                guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DeviceSettingsError.invalidData }
                let version = StrictJSON.integer(raw["version"])
                if let overlay = raw["visibility"] {
                    guard version == 2, let value = overlay as? [String: Any],
                          Set(value.keys) == Set(["version", "hiddenIDs"]), StrictJSON.integer(value["version"]) == 1,
                          let ids = value["hiddenIDs"] as? [String], ids.count <= 8192,
                          Set(ids).count == ids.count, ids.allSatisfy(Self.validID) else { throw DeviceSettingsError.invalidData }
                    hiddenIDs = Set(ids)
                }
                let entries: [KnownBatteryDevice]
                if version == 1 {
                    let old = try JSONDecoder().decode(LegacyDocument.self, from: data)
                    entries = old.devices.map { KnownBatteryDevice(id: $0.id, name: $0.name, source: $0.source, preferences: $0.preferences) }
                } else if version == 2 {
                    let document = try JSONDecoder().decode(Document.self, from: data)
                    entries = document.devices
                    let saved = document.directBluetoothAliasArchives ?? []
                    guard saved.count <= 1024, Set(saved.map(\.channelIdentity)).count == saved.count,
                          saved.allSatisfy(Self.validArchive) else { throw DeviceSettingsError.invalidData }
                    let excluded = Set(saved.flatMap { Self.aliasIDs(channel: $0.channelIdentity) })
                    guard entries.allSatisfy({ !excluded.contains($0.id) }) else { throw DeviceSettingsError.invalidData }
                    archives = Dictionary(uniqueKeysWithValues: saved.map { ($0.channelIdentity, $0) })
                    archivedIDs = excluded
                    physical = document.physicalDevices ?? .init()
                } else { throw DeviceSettingsError.invalidData }
                guard entries.count <= 1024, Set(entries.map(\.id)).count == entries.count,
                      entries.allSatisfy(Self.validEntry) else { throw DeviceSettingsError.invalidData }
                catalog = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
                guard Self.validPhysical(physical, catalog:catalog, archived:archivedIDs) else { throw DeviceSettingsError.invalidData }
                if version == 1 { persistLocked() } // Successfully saved v2 becomes authoritative; v1 is untouched.
            }
        } catch {
            catalog.removeAll(); archives.removeAll(); archivedIDs.removeAll(); hiddenIDs.removeAll(); visibilityQuarantine.removeAll(); physical = .init()
            blocked = true
            self.error = "Device settings could not be loaded. Battery updates are paused. Reset device settings explicitly to continue. (\(error))"
        }
    }
    private static func validID(_ id: String) -> Bool { !id.isEmpty && id.utf8.count <= 512 && !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }
    private static func validName(_ name: String) -> Bool { !name.isEmpty && name.utf8.count <= 256 && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }
    private static func validComponentID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128 && !id.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    private static func validEntry(_ entry: KnownBatteryDevice) -> Bool {
        let ids = entry.knownComponentIDs, selected = entry.componentSelection.ids
        return validID(entry.id) && validName(entry.name) && ids.count <= 64 && Set(ids).count == ids.count
            && ids.allSatisfy(validComponentID) && selected.count <= 64 && Set(selected).count == selected.count
            && selected.allSatisfy(validComponentID) && Set(selected).isSubset(of: Set(ids))
            && (entry.componentSelection.mode == .all ? selected.isEmpty : !selected.isEmpty)
    }
    private static func aliasIDs(channel: String) -> [String] { (2...6).map { channel + "-\($0)" } }
    private static func validArchive(_ archive: DirectBluetoothAliasArchive) -> Bool {
        let ids = Set(aliasIDs(channel: archive.channelIdentity))
        return validID(archive.channelIdentity) && validID(archive.channelIdentity + "-1")
            && ids.allSatisfy(validID) && archive.devices.count <= 5
            && Set(archive.devices.map(\.id)).count == archive.devices.count
            && archive.devices.allSatisfy { ids.contains($0.id) && validEntry($0) }
    }
    public var directBluetoothAliasArchives: [DirectBluetoothAliasArchive] {
        lock.lock(); defer { lock.unlock() }
        return archives.values.sorted { $0.channelIdentity < $1.channelIdentity }
    }
    public func isArchivedAlias(_ device: String) -> Bool {
        lock.lock(); defer { lock.unlock() }; return archivedIDs.contains(device)
    }
    /// Call only for a currently observed channel. Both exact transport and the
    /// bidirectional HID++ descriptor gate are checked here as well as by the host.
    /// No names, suffix stripping, transport joins or receiver-history links occur.
    @discardableResult public func archiveDirectBluetoothAliases(transport: String, channelIdentity: String, descriptor: HIDDescriptor) -> Bool {
        guard HIDRoutingPlan.isDirectBluetooth(transport: transport), !descriptor.hidPlusReports.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        let canonicalID = channelIdentity + "-1"
        let ids = Self.aliasIDs(channel: channelIdentity)
        guard !blocked, Self.validID(channelIdentity), Self.validID(canonicalID), ids.allSatisfy(Self.validID),
              !archivedIDs.contains(canonicalID) else { return false }
        if archives[channelIdentity] != nil { return true }
        let originals = ids.compactMap { catalog[$0] }
        guard archives.count < 1024 else {
            error = "Changes aren’t saved. Direct Bluetooth alias archive is full; battery updates for this channel are deferred."
            return false
        }
        var canonical = catalog[canonicalID]
        if !originals.isEmpty {
            var entry = canonical ?? KnownBatteryDevice(id: canonicalID, name: "Logitech accessory", source: nil)
            let oldPreferences = entry.preferences
            entry.preferences.monitorBattery = entry.preferences.monitorBattery && originals.allSatisfy { $0.preferences.monitorBattery }
            entry.preferences.showInMenu = entry.preferences.showInMenu && originals.allSatisfy { $0.preferences.showInMenu }
            if entry.preferences != oldPreferences { revisions[canonicalID, default: 0] &+= 1 }
            canonical = entry
        }
        if !hiddenIDs.isDisjoint(with:Set(ids)) { hiddenIDs.insert(canonicalID); revisions[canonicalID,default:0] &+= 1 }
        archives[channelIdentity] = DirectBluetoothAliasArchive(channelIdentity: channelIdentity, devices: originals)
        archivedIDs.formUnion(ids)
        for id in ids { catalog.removeValue(forKey: id) }
        if let canonical { catalog[canonicalID] = canonical }
        // A failed save retains the complete originals in memory, the exclusion
        // and conservative policy. retrySave persists this same pending document.
        persistLocked()
        return true
    }
    public var devices: [KnownBatteryDevice] {
        lock.lock(); defer { lock.unlock() }
        return visibleDevicesLocked()
    }
    public var issue: String? { lock.lock(); defer { lock.unlock() }; return error }
    public var updatesBlocked: Bool { lock.lock(); defer { lock.unlock() }; return blocked }
    public func preferences(for device: String) -> DevicePreferences {
        lock.lock(); defer { lock.unlock() }
        return archivedIDs.contains(device) ? .init(monitorBattery: false, showInMenu: false) : physical.groups.first(where: { $0.id == device })?.sharedDevice.preferences ?? effectivePreferencesLocked(device)
    }
    public func context() -> DeviceCollectionContext {
        lock.lock(); defer { lock.unlock() }
        return DeviceCollectionContext(epoch: epoch, revisions: revisions,
            paused: Set(catalog.keys.filter { !effectivePreferencesLocked($0).monitorBattery }), hidden: effectiveHiddenIDsLocked(), archived: archivedIDs, blocked: blocked)
    }
    public func accepts(_ device: String, from context: DeviceCollectionContext) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !blocked && !isHiddenLocked(device) && !archivedIDs.contains(device) && !context.blocked && context.epoch == epoch && context.shouldQuery(device)
            && effectivePreferencesLocked(device).monitorBattery
            && (context.revisions[device] ?? 0) == (revisions[device] ?? 0)
    }
    /// Discovery metadata is independent of battery payload acceptance; invalid/oversize IDs are never truncated.
    public func discover(id: String, name: String, source: BatterySource?, componentIDs: [String] = [], kind: PhysicalDeviceKind? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard !blocked, !archivedIDs.contains(id), Self.validID(id) else { return }
        let safeName = Self.validName(name) ? name : "Accessory"
        let source = source ?? catalog[id]?.source
        let kind = kind == nil || kind == .unknown ? catalog[id]?.kind : kind
        guard componentIDs.count <= 64, componentIDs.allSatisfy(Self.validComponentID) else { return }
        let ids = Set(catalog[id]?.knownComponentIDs ?? []).union(componentIDs)
        guard ids.count <= 64 else { error = "Component catalog is full; new components cannot be saved."; return }
        if let old = catalog[id], old.name == safeName, old.source == source, old.kind == kind, Set(old.knownComponentIDs) == ids { return }
        guard catalog[id] != nil || catalog.count < 1024 else {
            error = "Device catalog is full; new devices cannot be saved."; return
        }
        catalog[id] = KnownBatteryDevice(id: id, name: safeName, source: source, preferences: catalog[id]?.preferences ?? .init(), knownComponentIDs: KnownBatteryDevice.order(Array(ids)), componentSelection: catalog[id]?.componentSelection ?? .init(), kind:kind)
        if let index=physical.groups.firstIndex(where: { $0.members.contains(id) }) {
            let combined=Set(physical.groups[index].sharedDevice.knownComponentIDs).union(ids)
            if combined.count <= 64 { physical.groups[index].sharedDevice.knownComponentIDs=KnownBatteryDevice.order(Array(combined)) }
            if let kind { physical.groups[index].sharedDevice.kind=kind }
        }
        persistLocked()
    }
    public func setMonitoring(_ enabled: Bool, for device: String) {
        lock.lock(); defer { lock.unlock() }
        if updateGroupLocked(device, { $0.sharedDevice.preferences.monitorBattery = enabled }) { return }
        guard !blocked, var entry = catalog[device], entry.preferences.monitorBattery != enabled else { return }
        entry.preferences.monitorBattery = enabled; catalog[device] = entry
        revisions[device, default: 0] &+= 1
        persistLocked()
    }
    public func setMenuVisibility(_ visible: Bool, for device: String) {
        lock.lock(); defer { lock.unlock() }
        if updateGroupLocked(device, { $0.sharedDevice.preferences.showInMenu = visible }) { return }
        guard !blocked, var entry = catalog[device], entry.preferences.showInMenu != visible else { return }
        entry.preferences.showInMenu = visible; catalog[device] = entry
        persistLocked()
    }
    /// Pure menu policy: does not affect contexts, revisions, acquisition or samples.
    public func showsComponent(_ component: String, for device: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !isHiddenLocked(device), !archivedIDs.contains(device) else { return false }
        guard let entry = physical.groups.first(where: { $0.id == device })?.sharedDevice ?? physical.groups.first(where: { $0.members.contains(device) })?.sharedDevice ?? catalog[device] else { return true }
        return entry.preferences.showInMenu && entry.componentSelection.includes(component)
    }
    public func setComponentSelected(_ selected: Bool, component: String, for device: String) {
        lock.lock(); defer { lock.unlock() }
        if physical.groups.contains(where: { $0.id == device || $0.members.contains(device) }) {
            _ = updateGroupLocked(device) { group in
                guard group.sharedDevice.knownComponentIDs.contains(component) else { return }
                var ids=Set(group.sharedDevice.componentSelection.mode == .all ? group.sharedDevice.knownComponentIDs : group.sharedDevice.componentSelection.ids)
                if selected { ids.insert(component) } else { ids.remove(component) }
                if !ids.isEmpty { group.sharedDevice.componentSelection = .init(mode:.selected,ids:KnownBatteryDevice.order(Array(ids))) }
            }
            return
        }
        guard !blocked, var entry = catalog[device], entry.knownComponentIDs.contains(component) else { return }
        var ids = Set(entry.componentSelection.mode == .all ? entry.knownComponentIDs : entry.componentSelection.ids)
        if selected { ids.insert(component) } else { ids.remove(component) }
        guard !ids.isEmpty else { return }
        // Checking all current IDs intentionally does not opt into future discoveries.
        if entry.componentSelection.mode == .all && selected { return }
        entry.componentSelection = ComponentSelection(mode: .selected, ids: KnownBatteryDevice.order(Array(ids)))
        catalog[device] = entry; persistLocked()
    }
    public func includeAllComponents(for device: String) {
        lock.lock(); defer { lock.unlock() }
        if updateGroupLocked(device, { $0.sharedDevice.componentSelection = .init() }) { return }
        guard !blocked, var entry = catalog[device] else { return }
        entry.componentSelection = .init(); catalog[device] = entry; persistLocked()
    }
    /// Only explicit reset may replace an unreadable document. Old collection contexts remain invalid.
    @discardableResult public func reset() -> Bool {
        lock.lock(); defer { lock.unlock() }
        epoch &+= 1
        do {
            // Stage defaults without changing the last established policy or recovery state.
            let data = try JSONEncoder().encode(Document(version: 2, devices: [], directBluetoothAliasArchives: nil, physicalDevices: nil, visibility: nil))
            try saveVerifiedLocked(data, allowingUnreadablePrevious: true)
            catalog.removeAll(); archives.removeAll(); archivedIDs.removeAll(); hiddenIDs.removeAll(); visibilityQuarantine.removeAll(); physical = .init(); revisions.removeAll()
            blocked = false; error = nil
            return true
        } catch {
            self.error = blocked
                ? "Device settings could not be reset. Battery updates are paused. Reset device settings explicitly to try again. (\(error))"
                : "Changes aren’t saved. Device settings could not be reset; your settings are unchanged. (\(error))"
            return false
        }
    }
    public func retrySave() { lock.lock(); defer { lock.unlock() }; if !blocked { persistLocked() } }
    private func persistLocked() {
        do {
            let saved = archives.values.sorted { $0.channelIdentity < $1.channelIdentity }
            let entries = catalog.values.sorted { $0.id < $1.id }
            guard entries.count <= 1024, saved.count <= 1024 else { throw DeviceSettingsError.invalidData }
            let data = try JSONEncoder().encode(Document(version: 2, devices: entries, directBluetoothAliasArchives: saved.isEmpty ? nil : saved, physicalDevices: physical == PhysicalDeviceCatalog() ? nil : physical, visibility: visibilityLocked))
            guard data.count <= 1_048_576 else { throw DeviceSettingsError.invalidData }
            try persistence.save(data); error = nil
        } catch { self.error = "Changes aren’t saved. Device settings were not saved; choices may be lost on restart. (\(error))" }
    }
    /// Validates the QA suite without opening it. Watch storage never uses this selection.
    public static func qaSuite(arguments: [String]) throws -> String? {
        let indices = arguments.indices.filter { arguments[$0] == "--device-settings-suite" }
        guard !indices.isEmpty else { return nil }
        guard indices.count == 1, let index = indices.first, index + 1 < arguments.count else { throw DeviceSettingsError.invalidSuite }
        let suite = arguments[index + 1], prefix = "org.openbattery.qa."
        guard suite.hasPrefix(prefix), suite.utf8.count <= 128 else { throw DeviceSettingsError.invalidSuite }
        let suffix = String(suite.dropFirst(prefix.count))
        guard !suffix.isEmpty, suffix.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              suffix.utf8.first.map({ $0 != 45 && $0 != 95 }) == true else { throw DeviceSettingsError.invalidSuite }
        return suite
    }
    public static func processStore(arguments: [String]) throws -> DeviceSettingsStore {
        if let suite = try qaSuite(arguments: arguments) {
            guard let defaults = Foundation.UserDefaults(suiteName: suite) else { throw DeviceSettingsError.invalidSuite }
            return DeviceSettingsStore(persistence: DefaultsDeviceSettingsPersistence(defaults: defaults))
        }
        return DeviceSettingsStore(persistence: DefaultsDeviceSettingsPersistence())
    }
    public func readingStatus(for device: String, hasReading: Bool, age: String) -> String {
        if updatesBlocked { return hasReading ? "Settings unavailable · Last reading · \(age)" : "Settings unavailable · No reading" }
        if !preferences(for: device).monitorBattery { return hasReading ? "Monitoring off · Last reading · \(age)" : "Monitoring off · No reading" }
        return hasReading ? age : "No reading in this session"
    }
}

extension DeviceSettingsStore {
    public var physicalCatalog: PhysicalDeviceCatalog { lock.lock(); defer { lock.unlock() }; return physical }
    public var rawDevices: [KnownBatteryDevice] { lock.lock(); defer { lock.unlock() }; return catalog.values.sorted { $0.id < $1.id } }
    public var allLogicalDevices: [KnownBatteryDevice] { lock.lock(); defer { lock.unlock() }; return logicalDevicesLocked() }
    public var hiddenDevices: [KnownBatteryDevice] { lock.lock(); defer { lock.unlock() }; return logicalDevicesLocked().filter { isHiddenLocked($0.id) } }
    private func visibleDevicesLocked() -> [KnownBatteryDevice] { logicalDevicesLocked().filter { !isHiddenLocked($0.id) } }
    private func logicalDevicesLocked() -> [KnownBatteryDevice] {
        let members=Set(physical.groups.flatMap(\.members))
        return (catalog.values.filter { !members.contains($0.id) } + physical.groups.map(\.sharedDevice))
            .sorted { ($0.name.lowercased(),$0.id) < ($1.name.lowercased(),$1.id) }
    }
    private func effectivePreferencesLocked(_ route: String) -> DevicePreferences {
        physical.groups.first { $0.members.contains(route) }?.sharedDevice.preferences ?? catalog[route]?.preferences ?? .init()
    }
    public func members(of device: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return physical.groups.first { $0.id == device }?.members ?? (catalog[device] == nil ? []:[device])
    }
    public func logicalID(for route: String) -> String {
        lock.lock(); defer { lock.unlock() }; return physical.groups.first { $0.members.contains(route) }?.id ?? route
    }
    public func alertConfiguration(over base: AlertConfiguration) -> AlertConfiguration {
        lock.lock(); defer { lock.unlock() }; var result=base
        for group in physical.groups { result.devices[group.id]=group.sharedAlert }
        return result
    }
    /// Saves grouped alert edits in the same document as membership; returns the IDs it owns.
    public func saveGroupedAlerts(_ next: AlertConfiguration) throws -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        let ids=Set(physical.groups.map(\.id)), old=physical
        for i in physical.groups.indices { physical.groups[i].sharedAlert=next.device(physical.groups[i].id) }
        guard physical != old else { return ids }
        do { try savePhysicalLocked(); return ids } catch { physical=old; throw error }
    }
    private func updateGroupLocked(_ id: String, _ edit: (inout PhysicalDeviceGroup)->Void) -> Bool {
        guard let i=physical.groups.firstIndex(where: { $0.id == id }) ?? physical.groups.firstIndex(where: { $0.members.contains(id) }) else { return false }
        guard !blocked else { return true }
        let old=physical; edit(&physical.groups[i])
        guard old != physical else { return true }
        do {
            try savePhysicalLocked()
            if old.groups[i].sharedDevice.preferences.monitorBattery != physical.groups[i].sharedDevice.preferences.monitorBattery {
                for member in physical.groups[i].members { revisions[member,default:0] &+= 1 }
            }
        } catch { physical=old }
        return true
    }
    private func savePhysicalLocked() throws {
        guard !blocked, hiddenIDs.count <= 8192, hiddenIDs.allSatisfy(Self.validID), Self.validPhysical(physical,catalog:catalog,archived:archivedIDs) else { throw ConnectionGroupingError.unavailable }
        do {
            let saved=archives.values.sorted { $0.channelIdentity < $1.channelIdentity }
            let data=try JSONEncoder().encode(Document(version:2,devices:catalog.values.sorted { $0.id < $1.id },directBluetoothAliasArchives:saved.isEmpty ? nil:saved,physicalDevices:physical,visibility:visibilityLocked))
            guard data.count <= 1_048_576 else { throw DeviceSettingsError.invalidData }
            try saveVerifiedLocked(data); error=nil
        } catch {
            self.error=ConnectionGroupingError.storage.localizedDescription
            throw ConnectionGroupingError.storage
        }
    }
    private static func validAlert(_ a: DeviceAlertConfiguration) -> Bool {
        (1...99).contains(a.customThreshold) && a.components.ids.count <= 64 && Set(a.components.ids).count == a.components.ids.count && a.components.ids.allSatisfy(validComponentID) && (a.components.mode == .all ? a.components.ids.isEmpty:!a.components.ids.isEmpty)
    }
    private static func validPhysical(_ p: PhysicalDeviceCatalog, catalog: [String:KnownBatteryDevice], archived: Set<String>) -> Bool {
        guard p.routes.count <= 1024, p.groups.count <= 1024, p.separations.count <= 4096,
              Set(p.routes.map(\.id)).count == p.routes.count, Set(p.groups.map(\.id)).count == p.groups.count,
              Set(p.groups.flatMap(\.members)).count == p.groups.flatMap(\.members).count else { return false }
        return p.routes.allSatisfy { r in
            validID(r.id) && catalog[r.id] != nil && !archived.contains(r.id) && r.metadata.topology.utf8.count <= 512 && !r.metadata.topology.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) && (r.identity?.isValid ?? true) && (r.conflictingIdentities?.count ?? 0) <= 8 && (r.conflictingIdentities?.allSatisfy { $0.isValid } ?? true)
        } && p.groups.allSatisfy { g in
            validID(g.id) && validName(g.name) && !g.members.isEmpty && g.members.count <= 1024 && Set(g.members).count == g.members.count && g.members.allSatisfy { catalog[$0] != nil && !archived.contains($0) } && g.originalDevices.count <= 1024 && g.originalDevices.allSatisfy(validEntry) && g.originalAlerts.count <= 1024 && g.originalAlerts.allSatisfy { validID($0.key) && validAlert($0.value) } && validEntry(g.sharedDevice) && g.sharedDevice.id == g.id && g.sharedDevice.name == g.name && validAlert(g.sharedAlert) && (catalog[g.id] == nil || g.members.contains(g.id) || p.groups.contains { $0.id != g.id && $0.members.contains(g.id) })
        } && p.separations.allSatisfy { validID($0.first) && validID($0.second) && $0.first < $0.second && ($0.identityKey.map { $0.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } } ?? true) }
    }
    /// Positive evidence is monotonic: a contradictory identity quarantines the route instead of replacing proof.
    public func rememberRoute(_ route: SavedBatteryRoute) {
        lock.lock(); defer { lock.unlock() }
        guard !blocked, catalog[route.id] != nil, !archivedIDs.contains(route.id), route.identity?.isValid ?? true else { return }
        let old=physical, oldHidden=hiddenIDs, oldQuarantine=visibilityQuarantine
        if let i=physical.routes.firstIndex(where: { $0.id == route.id }) {
            var next=route
            let previous=physical.routes[i]
            next.identity=previous.identity ?? route.identity
            next.conflictingIdentities=previous.conflictingIdentities
            if let proof=route.identity, let established=previous.identity, proof.key != established.key {
                var conflicting=previous.conflictingIdentities ?? []
                if !conflicting.contains(where: { $0.key == proof.key }), conflicting.count < 8 { conflicting.append(proof) }
                next.conflictingIdentities=conflicting
            }
            next.identityConflict=previous.identityConflict || route.identityConflict || (previous.identity != nil && route.identity != nil && previous.identity?.key != route.identity?.key)
            // Stable proof survives an optional query failure.
            physical.routes[i]=next
        } else { physical.routes.append(route) }
        guard old != physical else { return }
        do { try inheritProvedVisibilityLocked(); try savePhysicalLocked() }
        catch {
            let visibilityChanged=hiddenIDs != oldHidden || visibilityQuarantine != oldQuarantine
            visibilityQuarantine.formUnion(hiddenIDs.subtracting(oldHidden))
            physical=old; hiddenIDs=oldHidden
            if visibilityChanged { blocked=true; self.error="Device settings could not be saved. Battery updates are paused. Reset device settings explicitly to continue." }
        }
    }
    private func previewLocked(current: String, selected: [String], alerts: AlertConfiguration, automatic: Bool = false) throws -> ConnectionLinkPreview {
        guard !blocked, error == nil, !selected.isEmpty, Set(selected).count == selected.count, !selected.contains(current) else { throw ConnectionGroupingError.unavailable }
        let visible=Dictionary(uniqueKeysWithValues:(automatic ? logicalDevicesLocked():visibleDevicesLocked()).map { ($0.id,$0) })
        let ids=[current]+selected.sorted()
        guard let anchor=visible[current], ids.allSatisfy({ visible[$0] != nil }) else { throw ConnectionGroupingError.changed }
        let devices=ids.compactMap { visible[$0] }
        let members=ids.flatMap { id in physical.groups.first { $0.id == id }?.members ?? [id] }.sorted()
        guard Set(members).count == members.count else { throw ConnectionGroupingError.changed }
        let kinds=Set(members.compactMap { id in physical.routes.first { $0.id == id }?.metadata.kind }.filter { $0 != .unknown })
        guard kinds.count <= 1,
              Set(devices.map { Set($0.knownComponentIDs) }).count == 1, !anchor.knownComponentIDs.isEmpty else { throw ConnectionGroupingError.incompatible }
        let configs=Dictionary(uniqueKeysWithValues:ids.map { ($0,alerts.device($0)) })
        func intersection(_ selections: [ComponentSelection]) -> (ComponentSelection,Bool) {
            if selections.allSatisfy({ $0.mode == .all }) { return (.init(),true) }
            let all=Set(anchor.knownComponentIDs)
            let common=selections.reduce(all) { $0.intersection($1.mode == .all ? all:Set($1.ids)) }
            return common.isEmpty ? (selections.first(where: { $0.mode == .selected }) ?? .init(),false):(.init(mode:.selected,ids:KnownBatteryDevice.order(Array(common))),true)
        }
        var shared=anchor
        shared.kind=kinds.first ?? anchor.kind
        shared.preferences.monitorBattery=devices.allSatisfy { $0.preferences.monitorBattery }
        shared.preferences.showInMenu=devices.allSatisfy { $0.preferences.showInMenu }
        let menu=intersection(devices.map(\.componentSelection)); shared.componentSelection=menu.0
        shared.preferences.showInMenu = shared.preferences.showInMenu && menu.1
        var alert=alerts.device(current)
        alert.included=ids.allSatisfy { alerts.device($0).included }
        let components=intersection(ids.map { alerts.device($0).components }); alert.components=components.0; alert.included = alert.included && components.1
        if !ids.allSatisfy({ alerts.device($0).usesCustomThreshold == alert.usesCustomThreshold && (!alert.usesCustomThreshold || alerts.device($0).customThreshold == alert.customThreshold) }) {
            alert.usesCustomThreshold=true; alert.customThreshold=ids.map { alerts.threshold(for:$0) }.min()!
        }
        return ConnectionLinkPreview(current:current,selected:selected.sorted(),members:members,devices:devices,alerts:configs,sharedDevice:shared,sharedAlert:alert,settingsDiffered:devices.contains { $0.preferences != shared.preferences || $0.componentSelection != shared.componentSelection } || configs.values.contains { $0 != alert },globalThreshold:alerts.threshold,automaticallyVerified:automatic)
    }
    public func previewLink(current: String, selected: [String], alerts: AlertConfiguration) throws -> ConnectionLinkPreview {
        lock.lock(); defer { lock.unlock() }; return try previewLocked(current:current,selected:selected,alerts:alerts)
    }
    public func commitLink(_ preview: ConnectionLinkPreview, alerts: AlertConfiguration) throws {
        lock.lock(); defer { lock.unlock() }
        guard try previewLocked(current:preview.current,selected:preview.selected,alerts:alerts,automatic:preview.automaticallyVerified) == preview, !preview.automaticallyVerified || automaticLinkCandidateLocked(alerts:alerts) == preview else { throw ConnectionGroupingError.changed }
        let old=physical, oldHidden=hiddenIDs
        let inheritsHidden=([preview.current]+preview.selected+preview.members).contains(where:isHiddenLocked)
        let ids=Set([preview.current]+preview.selected)
        let previous=physical.groups.filter { ids.contains($0.id) }
        var originals=Dictionary(uniqueKeysWithValues:preview.members.compactMap { catalog[$0] }.map { ($0.id,$0) })
        var originalAlerts=Dictionary(uniqueKeysWithValues:preview.members.map { ($0,alerts.device($0)) })
        for group in previous { for d in group.originalDevices { originals[d.id]=d }; for (id,a) in group.originalAlerts { originalAlerts[id]=a } }
        physical.groups.removeAll { ids.contains($0.id) }
        physical.groups.append(PhysicalDeviceGroup(id:preview.current,name:preview.sharedDevice.name,members:preview.members,originalDevices:originals.values.sorted { $0.id < $1.id },originalAlerts:originalAlerts,sharedAlert:preview.sharedAlert,sharedDevice:preview.sharedDevice,settingsDiffered:preview.settingsDiffered))
        physical.separations.removeAll { preview.members.contains($0.first) && preview.members.contains($0.second) }
        if inheritsHidden { hiddenIDs.formUnion(preview.members+[preview.current]) }
        do { try savePhysicalLocked(); for member in preview.members { revisions[member,default:0] &+= 1 } } catch { physical=old; hiddenIDs=oldHidden; throw error }
    }
    public func unlink(member: String, from id: String, newID: String = "physical-"+UUID().uuidString.lowercased()) throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard let i=physical.groups.firstIndex(where: { $0.id == id }), physical.groups[i].members.count > 1, physical.groups[i].members.contains(member) else { throw ConnectionGroupingError.changed }
        let old=physical, oldHidden=hiddenIDs, group=physical.groups[i]
        let inheritsHidden=isHiddenLocked(id)
        guard Self.validID(newID), catalog[newID] == nil, !physical.groups.contains(where: { $0.id == newID }) else { throw ConnectionGroupingError.changed }
        physical.groups[i].members.removeAll { $0 == member }
        var detached=group; detached.id=newID; detached.members=[member]; detached.sharedDevice=KnownBatteryDevice(id:newID,name:group.name,source:catalog[member]?.source,preferences:group.sharedDevice.preferences,knownComponentIDs:group.sharedDevice.knownComponentIDs,componentSelection:group.sharedDevice.componentSelection,kind:group.sharedDevice.kind)
        physical.groups.append(detached)
        for other in physical.groups[i].members {
            var separation=PhysicalSeparation(member,other)
            if let a=physical.routes.first(where: { $0.id == member })?.identity?.key, a == physical.routes.first(where: { $0.id == other })?.identity?.key { separation.identityKey=a }
            if !physical.separations.contains(separation) { physical.separations.append(separation) }
        }
        if inheritsHidden { hiddenIDs.formUnion(group.members+[id,newID]) }
        do { try savePhysicalLocked(); for member in group.members { revisions[member,default:0] &+= 1 }; return newID } catch { physical=old; hiddenIDs=oldHidden; throw error }
    }
    /// Returns a candidate only for full, consistent proof and compatible typed topology.
    public func automaticLinkCandidate(alerts: AlertConfiguration) -> ConnectionLinkPreview? {
        lock.lock(); defer { lock.unlock() }
        return automaticLinkCandidateLocked(alerts:alerts)
    }
    private func automaticLinkCandidateLocked(alerts: AlertConfiguration) -> ConnectionLinkPreview? {
        for routes in Dictionary(grouping:physical.routes.filter { $0.identity != nil && !$0.identityConflict },by: { $0.identity!.key }).sorted(by: { $0.key < $1.key }).map(\.value) {
            let members=Set(routes.map(\.id))
            let key=routes[0].identity!.key
            if physical.separations.contains(where: { $0.identityKey == key || (members.contains($0.first) && members.contains($0.second)) }) { continue }
            let ids=Set(members.map { route in physical.groups.first { $0.members.contains(route) }?.id ?? route }).sorted()
            guard ids.count > 1 else { continue }
            // A manual group's unknown or contradictory member prevents implicit expansion.
            let expanded=ids.flatMap { id in physical.groups.first { $0.id == id }?.members ?? [id] }
            guard expanded.allSatisfy({ id in !physical.routes.contains { $0.id == id && ($0.identityConflict || ($0.identity != nil && $0.identity?.key != key)) } }) else { continue }
            let current=ids.first(where: { id in physical.groups.contains { $0.id == id } }) ?? ids[0]
            if let preview=try? previewLocked(current:current,selected:ids.filter { $0 != current },alerts:alerts,automatic:true) { return preview }
        }
        return nil
    }
}

extension DeviceSettingsStore {
    private var visibilityLocked: DeviceVisibility? { hiddenIDs.isEmpty ? nil : DeviceVisibility(hiddenIDs:Array(hiddenIDs)) }
    private func policyIDsLocked(_ device: String) -> Set<String> {
        if let group=physical.groups.first(where: { $0.id == device || $0.members.contains(device) }) { return Set(group.members+[group.id]) }
        return [device]
    }
    private func isHiddenLocked(_ device: String) -> Bool { !hiddenIDs.union(visibilityQuarantine).isDisjoint(with:policyIDsLocked(device)) }
    private func effectiveHiddenIDsLocked() -> Set<String> {
        var ids=hiddenIDs.union(visibilityQuarantine)
        for group in physical.groups where isHiddenLocked(group.id) { ids.formUnion(group.members+[group.id]) }
        return ids
    }
    public func isHidden(_ device: String) -> Bool { lock.lock(); defer { lock.unlock() }; return isHiddenLocked(device) }
    public var hiddenPolicyIDs: Set<String> { lock.lock(); defer { lock.unlock() }; return effectiveHiddenIDsLocked() }
    public var visibility: DeviceVisibility { lock.lock(); defer { lock.unlock() }; return DeviceVisibility(hiddenIDs:Array(hiddenIDs)) }
    private func visibilitySnapshotLocked(_ device: String) throws -> DeviceVisibilitySnapshot {
        guard let entry=logicalDevicesLocked().first(where: { $0.id == device }) else { throw DeviceVisibilityError.changed }
        let members=physical.groups.first(where: { $0.id == device })?.members.sorted() ?? [device]
        let proofs=Dictionary(uniqueKeysWithValues:physical.routes.filter { members.contains($0.id) }.map { ($0.id, ($0.identity?.key ?? "") + ($0.identityConflict ? ":conflict":"")) })
        return DeviceVisibilitySnapshot(id:device,name:entry.name,kind:entry.kind,members:members,proofs:proofs,policyRevisions:Dictionary(uniqueKeysWithValues:Set(members+[device]).map { ($0,revisions[$0,default:0]) }),hidden:isHiddenLocked(device))
    }
    public func visibilitySnapshot(for device: String) throws -> DeviceVisibilitySnapshot {
        lock.lock(); defer { lock.unlock() }; return try visibilitySnapshotLocked(device)
    }
    /// Both transitions fence only affected IDs, even when a storage operation fails.
    /// Callers revoke delivery ownership before entering this durable boundary.
    public func setHidden(_ hidden: Bool, snapshot: DeviceVisibilitySnapshot) throws {
        lock.lock(); defer { lock.unlock() }
        guard !blocked else { throw DeviceVisibilityError.unavailable }
        guard try visibilitySnapshotLocked(snapshot.id) == snapshot, snapshot.hidden != hidden else { throw DeviceVisibilityError.changed }
        let ids=policyIDsLocked(snapshot.id), old=hiddenIDs, oldError=error
        for id in ids { revisions[id,default:0] &+= 1 }
        if hidden { hiddenIDs.formUnion(ids) } else { hiddenIDs.subtract(ids) }
        do {
            guard hiddenIDs.count <= 8192, hiddenIDs.allSatisfy(Self.validID) else { throw DeviceVisibilityError.storage }
            try savePhysicalLocked()
        } catch {
            hiddenIDs=old
            self.error=blocked ? "Device settings could not be verified. Battery updates are paused. Reset device settings explicitly to continue.":oldError
            throw blocked ? DeviceVisibilityError.unavailable:DeviceVisibilityError.storage
        }
    }
    private func saveVerifiedLocked(_ data: Data, allowingUnreadablePrevious: Bool = false) throws {
        let previous: Data?
        do { previous=try persistence.load() }
        catch {
            blocked=true
            // Only an explicit Reset can replace storage whose prior bytes cannot be read.
            guard allowingUnreadablePrevious else { throw DeviceVisibilityError.unavailable }
            previous=nil
        }
        // The persistence interface's throwing save is atomic (the defaults adapter verifies
        // and restores its own previous value). A successful save is independently read back.
        do { try persistence.save(data) }
        catch {
            if allowingUnreadablePrevious {
                // Do not trust a failed adapter rollback to have preserved readable storage.
                do {
                    guard try persistence.load() == previous else { throw DeviceSettingsError.saveFailed }
                } catch { blocked=true }
            }
            throw error
        }
        do {
            guard try persistence.load() == data else { throw DeviceSettingsError.saveFailed }
        } catch {
            if allowingUnreadablePrevious { blocked=true }
            if let previous {
                do {
                    try persistence.save(previous)
                    guard try persistence.load() == previous else { throw DeviceSettingsError.saveFailed }
                } catch { blocked=true }
            } else { blocked=true }
            throw DeviceSettingsError.saveFailed
        }
    }
    /// Propagate only complete positive identity evidence, respecting explicit separations.
    /// This runs before host payload acceptance, independently of alert-store availability.
    private func inheritProvedVisibilityLocked() throws {
        for routes in Dictionary(grouping:physical.routes.filter { $0.identity != nil && !$0.identityConflict },by: { $0.identity!.key }).values {
            let members=Set(routes.map(\.id)), key=routes[0].identity!.key
            guard !physical.separations.contains(where: { $0.identityKey == key || (members.contains($0.first) && members.contains($0.second)) }) else { continue }
            let expanded=members.reduce(into:Set<String>()) { $0.formUnion(policyIDsLocked($1)) }
            guard expanded.contains(where:isHiddenLocked), !physical.routes.contains(where: { expanded.contains($0.id) && ($0.identityConflict || ($0.identity != nil && $0.identity?.key != key)) }) else { continue }
            let added=expanded.subtracting(hiddenIDs)
            guard hiddenIDs.count+added.count <= 8192 else {
                // Capacity cannot expose a newly proved hidden route before persistence succeeds.
                visibilityQuarantine.formUnion(added)
                throw DeviceVisibilityError.storage
            }
            hiddenIDs.formUnion(added)
            for id in added { revisions[id,default:0] &+= 1 }
        }
    }
}
