import Foundation

/// A separate, optional v2 policy overlay. IDs are exact identities, including bounded tombstones.
public struct DeviceVisibility: Codable, Equatable {
    public var version: Int = 1
    public var hiddenIDs: [String]
    public init(hiddenIDs: [String] = []) { self.hiddenIDs = hiddenIDs.sorted() }
}

/// Stable confirmation identity. Battery samples and requested settings are deliberately absent.
public struct DeviceVisibilitySnapshot: Equatable {
    public let id: String
    public let name: String
    public let kind: PhysicalDeviceKind?
    public let members: [String]
    public let proofs: [String: String]
    public let policyRevisions: [String: UInt64]
    public let hidden: Bool
}

public enum DeviceVisibilityError: Error, LocalizedError, Equatable {
    case changed, unavailable, storage
    public var errorDescription: String? {
        switch self {
        case .changed: return "This device changed. Review it and try again."
        case .unavailable: return "Device settings are unavailable. Review storage recovery."
        case .storage: return "Device visibility could not be saved."
        }
    }
}
