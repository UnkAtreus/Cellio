import AppKit
import Combine
import Sparkle

public struct ApplicationUpdateConfiguration: Equatable {
    public let feedURL: URL
    public let publicKey: String
    public static var localQACompiled: Bool {
        #if CELLIO_LOCAL_UPDATE_QA
        return true
        #else
        return false
        #endif
    }
    public enum ConfigurationError: LocalizedError {
        case missing, invalid(String)
        public var errorDescription: String? {
            switch self {
            case .missing: return "No application update feed and signing key were supplied at build time."
            case .invalid(let reason): return reason
            }
        }
    }
    public init(info: [String: Any], bundleIdentifier: String?) throws {
        let feed = info["SUFeedURL"] as? String
        let key = info["SUPublicEDKey"] as? String
        if feed == nil && key == nil { throw ConfigurationError.missing }
        guard let feed, let key, !feed.isEmpty, !key.isEmpty else {
            throw ConfigurationError.invalid("Both SUFeedURL and SUPublicEDKey are required.")
        }
        guard info["SUVerifyUpdateBeforeExtraction"] as? Bool == true else {
            throw ConfigurationError.invalid("Configured updates require SUVerifyUpdateBeforeExtraction=YES.")
        }
        guard let bytes = Data(base64Encoded: key), bytes.count == 32,
              bytes.base64EncodedString() == key else {
            throw ConfigurationError.invalid("SUPublicEDKey must be canonical base64 for a 32-byte Ed25519 public key.")
        }
        guard let components = URLComponents(string: feed), let url = components.url,
              let host = components.host, !host.isEmpty,
              feed.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              components.user == nil, components.password == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true else {
            throw ConfigurationError.invalid("SUFeedURL must be an absolute feed URL without credentials or a fragment.")
        }
        let qaMarker = info["CellioLocalUpdateQA"] as? Bool == true
        let qaIdentity = bundleIdentifier?.hasPrefix("org.openbattery.qa.") == true && bundleIdentifier != "org.openbattery.qa."
        if qaMarker && (!Self.localQACompiled || !qaIdentity) {
            throw ConfigurationError.invalid("Local update QA requires the compiled QA flag and a separate org.openbattery.qa.* identity.")
        }
        let scheme = components.scheme?.lowercased()
        guard scheme == "https" || (scheme == "http" && host == "127.0.0.1" && qaMarker && qaIdentity && Self.localQACompiled) else {
            throw ConfigurationError.invalid("Production update feeds require HTTPS. HTTP is restricted to explicitly built loopback QA applications.")
        }
        self.feedURL = url
        self.publicKey = key
    }
}

public struct ApplicationUpdaterState: Equatable {
    public var canCheck: Bool
    public var sessionInProgress: Bool
    public var automaticallyChecks: Bool
    public var automaticallyDownloads: Bool
    public var allowsAutomaticUpdates: Bool
    public var isSearching: Bool
    public init(canCheck: Bool = false, sessionInProgress: Bool = false, automaticallyChecks: Bool = false,
                automaticallyDownloads: Bool = false, allowsAutomaticUpdates: Bool = false, isSearching: Bool = false) {
        self.canCheck = canCheck; self.sessionInProgress = sessionInProgress
        self.automaticallyChecks = automaticallyChecks; self.automaticallyDownloads = automaticallyDownloads
        self.allowsAutomaticUpdates = allowsAutomaticUpdates
        self.isSearching = isSearching
    }
}

@MainActor public protocol ApplicationUpdaterAdapter: AnyObject {
    var state: ApplicationUpdaterState { get }
    var stateDidChange: (() -> Void)? { get set }
    func start() throws
    func checkForUpdates()
    func setAutomaticallyChecks(_ value: Bool)
    func setAutomaticallyDownloads(_ value: Bool)
}

/// Owns Sparkle's native controller, user driver and scheduler. The delegate pins
/// the validated build feed over any legacy feed preference.
@MainActor public final class SparkleUpdaterAdapter: NSObject, ApplicationUpdaterAdapter, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    public private(set) var standardController: SPUStandardUpdaterController!
    public var stateDidChange: (() -> Void)?
    private let configuration: ApplicationUpdateConfiguration
    private var observations: [NSKeyValueObservation] = []
    private var isSearching = false
    public init(configuration: ApplicationUpdateConfiguration) {
        self.configuration = configuration
        super.init()
        standardController = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        let updater = standardController.updater
        func observe<T>(_ key: KeyPath<SPUUpdater, T>) {
            observations.append(updater.observe(key, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.stateDidChange?() }
            })
        }
        observe(\.canCheckForUpdates); observe(\.sessionInProgress)
        observe(\.automaticallyChecksForUpdates); observe(\.automaticallyDownloadsUpdates)
        observe(\.allowsAutomaticUpdates)
    }
    public func feedURLString(for updater: SPUUpdater) -> String? { configuration.feedURL.absoluteString }
    private func setSearching(_ value: Bool) {
        guard isSearching != value else { return }
        isSearching = value
        stateDidChange?()
    }
    // These callbacks cover foreground and background checks. Eligibility and
    // session lifetime are deliberately not used to infer the search phase.
    public func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        setSearching(true)
    }
    public func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem,
                        updateCheck: SPUUpdateCheck) throws {
        setSearching(false)
    }
    public func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        setSearching(false)
    }
    public func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        setSearching(false)
    }
    public func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        setSearching(false)
    }
    public func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        setSearching(false)
    }
    public func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        setSearching(false)
    }
    public func standardUserDriverWillShowModalAlert() {
        // Error/no-update alerts can precede updater abort/cycle callbacks.
        setSearching(false)
    }
    public func standardUserDriverWillFinishUpdateSession() {
        setSearching(false)
    }
    public var state: ApplicationUpdaterState {
        let updater = standardController.updater
        return ApplicationUpdaterState(canCheck: updater.canCheckForUpdates, sessionInProgress: updater.sessionInProgress,
            automaticallyChecks: updater.automaticallyChecksForUpdates, automaticallyDownloads: updater.automaticallyDownloadsUpdates,
            allowsAutomaticUpdates: updater.allowsAutomaticUpdates, isSearching: isSearching)
    }
    public func start() throws { try standardController.updater.start() }
    public func checkForUpdates() { standardController.checkForUpdates(nil) }
    public func setAutomaticallyChecks(_ value: Bool) { standardController.updater.automaticallyChecksForUpdates = value }
    public func setAutomaticallyDownloads(_ value: Bool) { standardController.updater.automaticallyDownloadsUpdates = value }
}

@MainActor public final class ApplicationUpdatesController: ObservableObject {
    @Published public private(set) var state = ApplicationUpdaterState()
    @Published public private(set) var isAvailable = false
    @Published public private(set) var diagnostic: String?
    public private(set) var configuration: ApplicationUpdateConfiguration?
    public private(set) var adapter: (any ApplicationUpdaterAdapter)?
    public init(info: [String: Any] = Bundle.main.infoDictionary ?? [:], bundleIdentifier: String? = Bundle.main.bundleIdentifier,
                startingAllowed: Bool = true,
                makeAdapter: @MainActor (ApplicationUpdateConfiguration) -> any ApplicationUpdaterAdapter = { SparkleUpdaterAdapter(configuration: $0) }) {
        guard startingAllowed else { diagnostic = "Updater is inactive in preview mode."; return }
        do {
            let configuration = try ApplicationUpdateConfiguration(info: info, bundleIdentifier: bundleIdentifier)
            self.configuration = configuration
            let adapter = makeAdapter(configuration)
            self.adapter = adapter
            adapter.stateDidChange = { [weak self] in self?.refresh() }
            try adapter.start()
            isAvailable = true
            refresh()
        } catch {
            diagnostic = (error as NSError).localizedDescription
            NSLog("Application updates unavailable: %@", diagnostic ?? "Unknown configuration error")
        }
    }
    public func refresh() { if let adapter { state = adapter.state } }
    // Sparkle eligibility and Cellio's stricter duplicate-entry policy are separate.
    // Neither indicates whether an actual search is in progress.
    public var canCheckForUpdates: Bool { isAvailable && state.canCheck && !state.sessionInProgress }
    public func checkForUpdates() {
        guard canCheckForUpdates else { return }
        adapter?.checkForUpdates()
        refresh()
    }
    public func setAutomaticallyChecks(_ value: Bool) {
        guard isAvailable else { return }
        adapter?.setAutomaticallyChecks(value)
        refresh()
    }
    public func setAutomaticallyDownloads(_ value: Bool) {
        guard isAvailable, state.automaticallyChecks, state.allowsAutomaticUpdates else { return }
        adapter?.setAutomaticallyDownloads(value)
        refresh()
    }
}
