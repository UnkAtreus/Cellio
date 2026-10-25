import AppKit
import Combine
import Security
import ServiceManagement

public enum LoginRegistrationStatus: String {
    // A valid signed copy may need explicit setup before registration can be confirmed.
    case notRegistered, notFound, enabled, requiresApproval, unavailable
    public var isRegistered: Bool { self == .enabled || self == .requiresApproval }
}

/// Inject this boundary to exercise operations without changing OS registration.
@MainActor public protocol LoginServiceAdapter: AnyObject {
    var diagnostic: String? { get }
    func readStatus() -> LoginRegistrationStatus
    func register() async throws
    func unregister() async throws
    func openLoginItems()
}

@MainActor public final class MainAppLoginAdapter: LoginServiceAdapter {
    public private(set) var diagnostic: String?
    private let bundle = Bundle.main
    public init() {}
    public func readStatus() -> LoginRegistrationStatus {
        var code: SecStaticCode?
        let creation = SecStaticCodeCreateWithPath(bundle.bundleURL as CFURL, [], &code)
        guard bundle.bundleURL.pathExtension == "app", creation == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
            diagnostic = "Start at login requires a valid signed application bundle. Run the packaged Cellio.app."
            return .unavailable
        }
        diagnostic = nil
        switch SMAppService.mainApp.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound:
            diagnostic = "SMAppService.mainApp registration is unconfirmed for this valid signed application. Explicit setup is available."
            return .notFound
        @unknown default:
            diagnostic = "SMAppService.mainApp returned an unsupported status."
            return .unavailable
        }
    }
    public func register() async throws { try SMAppService.mainApp.register() }
    public func unregister() async throws { try await SMAppService.mainApp.unregister() }
    public func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor public final class LoginRegistrationController: ObservableObject {
    @Published public private(set) var status: LoginRegistrationStatus = .unavailable
    @Published public private(set) var isUpdating = false
    @Published public private(set) var operationError: NSError?
    @Published public private(set) var diagnostic: String?
    public private(set) var failedRequest: Bool?
    public let adapter: any LoginServiceAdapter
    public init(adapter: (any LoginServiceAdapter)? = nil) {
        self.adapter = adapter ?? MainAppLoginAdapter()
        refresh()
    }
    /// Passive at startup, General appearance, and app reactivation.
    public func refresh() {
        status = adapter.readStatus()
        diagnostic = adapter.diagnostic
    }
    public func setEnabled(_ enabled: Bool) {
        guard !isUpdating, status != .unavailable else { return }
        isUpdating = true
        operationError = nil
        failedRequest = nil
        Task {
            do {
                if enabled { try await adapter.register() }
                else { try await adapter.unregister() }
            } catch {
                operationError = error as NSError
                failedRequest = enabled
                NSLog("Start at login operation failed: %@", String(describing: error))
            }
            refresh()
            isUpdating = false
        }
    }
    public func retry() {
        guard let failedRequest else { return }
        refresh()
        setEnabled(failedRequest)
    }
    public func openSystemSettings() { adapter.openLoginItems() }
    public var accessibilityValue: String {
        if isUpdating { return "Updating…" }
        if status == .requiresApproval { return "On, needs approval; Cellio will not start at login until approved." }
        if status == .notFound { return "Off, not set up; login registration is unconfirmed." }
        if status == .unavailable { return "Unavailable" }
        return status == .enabled ? "On" : "Off"
    }
    public var statusText: String {
        if isUpdating { return "Updating…" }
        if status == .requiresApproval {
            let pending = "Needs approval. Allow Cellio in System Settings before it can start at login."
            return operationError == nil ? pending : pending + " Couldn’t change Start at login. Try again."
        }
        if operationError != nil {
            return "Couldn’t change Start at login. Try again."
        }
        switch status {
        case .notRegistered: return "Open Cellio in the menu bar when you log in."
        case .notFound: return "Not set up. Turn on to set up Start at login."
        case .enabled: return "Cellio will open in the menu bar when you log in."
        case .requiresApproval: return "Needs approval. Allow Cellio in System Settings before it can start at login."
        case .unavailable: return "Start at login is unavailable for this copy of Cellio. Run the packaged, signed Cellio.app."
        }
    }
}
