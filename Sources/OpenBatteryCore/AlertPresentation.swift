import Foundation

public enum AlertStyle: String, Codable, CaseIterable {
    case system, hud
    public var title: String { self == .system ? "macOS notification" : "On-screen HUD" }
}
public enum AlertHUDSize: String, Codable, CaseIterable {
    case small, medium, large
    public var title: String { rawValue.capitalized }
    /// Full backed-card width. Layouts deliberately have different proportions.
    public var points: Int { switch self { case .small: return 360; case .medium: return 304; case .large: return 384 } }
    public func height(componentCount: Int) -> Int {
        switch self {
        case .small: return componentCount == 1 ? 64 : 84
        case .medium: return componentCount == 1 ? 160 : 184
        case .large: return componentCount == 1 ? 216 : 256
        }
    }
}
public enum AlertHUDPosition: String, Codable, CaseIterable {
    case topLeft, topCenter, topRight, leftCenter, center, rightCenter, bottomLeft, bottomCenter, bottomRight
    public var title: String {
        switch self {
        case .topLeft: return "Top left"
        case .topCenter: return "Top center"
        case .topRight: return "Top right"
        case .leftCenter: return "Left center"
        case .center: return "Center"
        case .rightCenter: return "Right center"
        case .bottomLeft: return "Bottom left"
        case .bottomCenter: return "Bottom center"
        case .bottomRight: return "Bottom right"
        }
    }
    public var row: Int { (Self.allCases.firstIndex(of: self) ?? 1) / 3 }
    public var column: Int { (Self.allCases.firstIndex(of: self) ?? 1) % 3 }
}
public struct AlertPresentationChoice: Equatable {
    public var style: AlertStyle = .system
    public var size: AlertHUDSize = .medium
    public var position: AlertHUDPosition = .topCenter
    public init() {}
}

/// Separate bounded preferences; neither readings nor episode data belong here.
public final class AlertPresentationStore {
    private let persistence: AlertPersistence
    public private(set) var choice = AlertPresentationChoice()
    public private(set) var issue: String?
    public init(persistence: AlertPersistence = MemoryAlertPersistence()) {
        self.persistence = persistence
        reload()
    }
    public func reload() {
        do {
            var next = AlertPresentationChoice()
            if let data = try persistence.load() {
                guard data.count <= 256,
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (Set(object.keys) == ["style", "size"] || Set(object.keys) == ["style", "size", "position"]),
                      let style = object["style"] as? String, let size = object["size"] as? String,
                      let s = AlertStyle(rawValue: style), let z = AlertHUDSize(rawValue: size) else {
                    throw AlertStorageError.invalidDocument
                }
                next.style = s; next.size = z
                if object.keys.contains("position") {
                    guard let value = object["position"] as? String,
                          let position = AlertHUDPosition(rawValue: value) else { throw AlertStorageError.invalidDocument }
                    next.position = position
                }
                // Legacy two-key records are read losslessly. Only an explicit
                // save writes the complete record, through the same atomic store.
            }
            choice = next; issue = nil
        } catch { issue = "Presentation paused: preferences could not be read. Retry reading or explicitly save an Alert style, HUD layout and position. (\(error))" }
    }
    @discardableResult public func save(_ next: AlertPresentationChoice) -> Bool {
        do {
            let data = try JSONSerialization.data(withJSONObject: ["style": next.style.rawValue, "size": next.size.rawValue, "position": next.position.rawValue], options: [.sortedKeys])
            try persistence.save(data)
            choice = next; issue = nil
            return true
        } catch {
            issue = "Presentation paused: choice was not saved. The last committed choice is retained. Retry saving your choice. (\(error))"
            return false
        }
    }
}

public struct AlertHUDComponent {
    public let id: ComponentID
    public let percent: Int
    public var label: String { KnownBatteryDevice.componentName(id.component) }
    public init(id: ComponentID, percent: Int) { self.id = id; self.percent = percent }
}
public struct AlertHUDContent {
    public let deviceName: String
    public let source: BatterySource?
    public let components: [AlertHUDComponent]
    public let example: Bool
    public init(reservation: AlertReservation, source: BatterySource?) {
        deviceName = reservation.title; self.source = source; example = false
        components = reservation.components.map { AlertHUDComponent(id: $0.id, percent: $0.percent) }
    }
    public init() {
        deviceName = "Example"; source = nil; example = true
        components = [AlertHUDComponent(id: ComponentID(device: "example"), percent: 20)]
    }
}
