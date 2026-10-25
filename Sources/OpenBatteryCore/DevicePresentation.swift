import Foundation

/// A lossless view of a component. Presentation never rewrites its quantity or times.
public struct BatteryComponentPresentation: Identifiable {
    public let record: BatteryRecord
    public let value: String
    public let freshness: String
    public var id: ComponentID { record.observation.id }
    public var title: String {
        switch id.component {
        case "left": return "Left"
        case "right": return "Right"
        case "case": return "Case"
        case "battery": return "Battery"
        default: return id.component
        }
    }
    /// Only a reported percentage has a precise gauge. Zero is a valid empty gauge.
    public var reportedPercent: Int? {
        guard case .reportedPercent(let value) = record.observation.quantity,
              (0...100).contains(value) else { return nil }
        return value
    }
    public var connection: String {
        switch record.observation.connection {
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
        case .unavailable: return "Unavailable"
        case .unknown: return "Connection unknown"
        }
    }
    public var charge: String {
        switch record.observation.charge {
        case .unknown: return "Charge state unknown"
        case .discharging: return "Discharging"
        case .charging: return "Charging"
        case .finalStage: return "Finishing charge"
        case .complete: return "Charge complete"
        case .slowCharging: return "Slow charging"
        case .invalidBattery: return "Battery error"
        case .thermalError: return "Temperature error"
        case .chargingError: return "Charging error"
        }
    }
    public init(record: BatteryRecord, at now: Date) {
        self.record = record
        value = record.observation.quantity.display
        let age = record.ageDescription(at: now)
        if record.observation.quantity.isKnown && record.isStale(at: now) {
            let label = record.observation.source == .systemReport ? "Last reported" : "Last known"
            freshness = "\(label) · stale · \(age)"
        } else {
            freshness = age
        }
    }
}

public struct BatteryDevicePresentation: Identifiable {
    /// The existing device identity, never a display name or a component identity.
    public let id: String
    public let name: String
    public let components: [BatteryComponentPresentation]
    public var connection: String {
        let labels = Set(components.map(\.connection))
        return labels.count == 1 ? components[0].connection : "Connection varies by component"
    }
    public var commonFreshness: String? {
        let labels = Set(components.map(\.freshness))
        return labels.count == 1 ? components.first?.freshness : nil
    }
    public var usesAirPodsLayout: Bool {
        !components.isEmpty && components.allSatisfy {
            $0.record.observation.source == .systemReport && ["left", "right", "case"].contains($0.id.component)
        }
    }

    /// Deterministic device grouping and Left / Right / Case order, used by the app.
    /// All input records survive intact, including unknown and absent components.
    public static func groups(records: [BatteryRecord], at now: Date) -> [Self] {
        Dictionary(grouping: records, by: { $0.observation.id.device }).map { device, records in
            let rank = ["left": 0, "right": 1, "case": 2, "battery": 3]
            let ordered = records.sorted {
                let a = $0.observation.id.component, b = $1.observation.id.component
                return (rank[a] ?? 4, a) < (rank[b] ?? 4, b)
            }
            return Self(id: device, name: ordered[0].observation.name,
                        components: ordered.map { BatteryComponentPresentation(record: $0, at: now) })
        }.sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
    }
}

/// Menu projection joins catalog metadata with retained samples. Missing rows have no record.
public struct BatteryMenuComponentPresentation: Identifiable {
    public let id: String
    public let reading: BatteryComponentPresentation?
    public var title: String { KnownBatteryDevice.componentName(id) }
    public var value: String { reading?.value ?? "Not reported" }
}

public struct BatteryMenuDevicePresentation: Identifiable {
    public let id: String
    public let name: String
    public let source: BatterySource?
    public let components: [BatteryMenuComponentPresentation]
    public var kind: PhysicalDeviceKind? = nil
    public static func groups(records: [BatteryRecord], settings: DeviceSettingsStore, at now: Date) -> [Self] {
        let readings = BatteryDevicePresentation.groups(records: records, at: now)
        let catalog = settings.devices
        let ids = Set(readings.map(\.id)).union(catalog.map(\.id))
        return ids.compactMap { id -> Self? in
            guard settings.preferences(for: id).showInMenu else { return nil }
            let entry = catalog.first { $0.id == id }
            let reading = readings.first { $0.id == id }
            let known = Set(entry?.knownComponentIDs ?? []).union(reading?.components.map { $0.id.component } ?? [])
            let selected = KnownBatteryDevice.order(Array(known)).filter { settings.showsComponent($0, for: id) }
            return Self(id: id, name: entry?.name ?? reading?.name ?? "Accessory", source: entry?.source ?? reading?.components.first?.record.observation.source,
                        components: selected.map { component in
                            BatteryMenuComponentPresentation(id: component, reading: reading?.components.first { $0.id.component == component })
                        },kind:entry?.kind ?? reading?.components.first?.record.observation.route?.kind)
        }.sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
    }
}
