import Foundation
import Combine
import AppKit
import UserNotifications
import OpenBatteryCore

// Defaults constructors are inert. Only ordinary GUI launch selects a process store.
final class DefaultsAlertPersistence: AlertPersistence {
    static let key = "cellio.lowBatteryAlerts.v1"
    private let defaults: UserDefaults
    private let storageKey: String
    init(defaults: UserDefaults, key: String = DefaultsAlertPersistence.key) { self.defaults = defaults; storageKey = key }
    func load() throws -> Data? {
        guard let value = defaults.object(forKey: storageKey) else { return nil }
        guard let data = value as? Data, data.count <= 1_048_576 else { throw AlertStorageError.invalidDocument }
        return data
    }
    func save(_ data: Data) throws {
        let old = defaults.object(forKey: storageKey)
        defaults.set(data, forKey: storageKey)
        guard defaults.synchronize(), defaults.data(forKey: storageKey) == data else {
            if let old { defaults.set(old, forKey: storageKey) } else { defaults.removeObject(forKey: storageKey) }
            _ = defaults.synchronize()
            throw AlertStorageError.saveFailed
        }
    }
    static func process(arguments: [String], key: String = DefaultsAlertPersistence.key) throws -> DefaultsAlertPersistence {
        let suite = try DeviceSettingsStore.qaSuite(arguments: arguments)
        if let suite {
            guard let defaults = UserDefaults(suiteName: suite) else { throw DeviceSettingsError.invalidSuite }
            return DefaultsAlertPersistence(defaults: defaults, key: key)
        }
        return DefaultsAlertPersistence(defaults: .standard, key: key)
    }
}

enum AlertPermission: Equatable {
    case unknown, notDetermined, denied, alertsDisabled, limited, authorized, unavailable(String)
    var allowsDelivery: Bool { self == .authorized }
    var description: String {
        switch self {
        case .unknown: return "Checking macOS notification settings…"
        case .notDetermined: return "Notifications haven’t been allowed."
        case .denied: return "Notifications are disabled in macOS."
        case .alertsDisabled: return "macOS authorization is allowed, but native alerts are disabled."
        case .limited: return "macOS notification access is limited. Review Notifications in System Settings."
        case .authorized: return "macOS allows alerts. Focus and notification settings may delay or hide them."
        case .unavailable(let error): return "Notification settings unavailable: \(error)"
        }
    }
}
@MainActor protocol AlertNotificationBoundary: AnyObject {
    func inspect(_ completion: @escaping @MainActor (AlertPermission) -> Void)
    func requestAuthorization(_ completion: @escaping @MainActor (AlertPermission) -> Void)
    func add(_ reservation: AlertReservation, completion: @escaping @MainActor (String?) -> Void)
    func cancel(_ identifiers: [String])
    func addPreview(completion: @escaping @MainActor (String?) -> Void)
    func cancelPreview()
}
// Existing injected boundaries remain inert for previews unless explicitly implemented.
extension AlertNotificationBoundary {
    func addPreview(completion: @escaping @MainActor (String?) -> Void) { completion("No preview notification service is connected.") }
    func cancelPreview() {}
}
enum AlertNotificationPreview {
    static let identifier = "cellio.notification.preview"
    static let payloadKey = "cellio.notification.kind"
    static let payloadKind = "preview"
    static let title = "Cellio notification preview"
    static let body = "Example only. Actual low-battery alerts show the device and reported battery level."
}
@MainActor final class InertAlertNotificationBoundary: AlertNotificationBoundary {
    func inspect(_ completion: @escaping @MainActor (AlertPermission) -> Void) { completion(.notDetermined) }
    func requestAuthorization(_ completion: @escaping @MainActor (AlertPermission) -> Void) { completion(.notDetermined) }
    func add(_ reservation: AlertReservation, completion: @escaping @MainActor (String?) -> Void) { completion("No notification service is connected.") }
    func cancel(_ identifiers: [String]) {}
}

/// Constructed only after snapshot dispatch, from ordinary GUI launch.
@MainActor final class MacAlertNotificationBoundary: NSObject, AlertNotificationBoundary, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter
    var route: ((String) -> Void)?
    var routeNotifications: (() -> Void)?
    private let permissionGate: NativePermissionRequestGate
    private var inspectionToken: UUID?
    private var inspectionCallbacks: [@MainActor (AlertPermission) -> Void] = []
    init(center: UNUserNotificationCenter, permissionGate: NativePermissionRequestGate? = nil) {
        self.permissionGate = permissionGate ?? .shared
        self.center = center
        super.init()
        center.delegate = self
    }
    private static func permission(_ settings: UNNotificationSettings) -> AlertPermission {
        switch settings.authorizationStatus {
        case .authorized:
            switch settings.alertSetting {
            case .enabled: return .authorized
            case .disabled: return .alertsDisabled
            default: return .unavailable("Native alerts are not supported.")
            }
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .provisional, .ephemeral: return .limited
        default: return .unavailable("Ordinary alert authorization is required.")
        }
    }
    func inspect(_ completion: @escaping @MainActor (AlertPermission) -> Void) {
        inspectionCallbacks.append(completion)
        guard inspectionToken == nil else { return }
        let token = UUID(); inspectionToken = token
        let finish: @MainActor (AlertPermission) -> Void = { [weak self] result in
            guard let self, self.inspectionToken == token else { return }
            self.inspectionToken = nil
            let callbacks = self.inspectionCallbacks; self.inspectionCallbacks = []
            for callback in callbacks { callback(result) }
        }
        permissionGate.scheduler.after(8) { finish(.unavailable("Inspection timed out.")) }
        center.getNotificationSettings { settings in
            Task { @MainActor in finish(Self.permission(settings)) }
        }
    }
    func requestAuthorization(_ completion: @escaping @MainActor (AlertPermission) -> Void) {
        permissionGate.perform(.notifications, fallback: .unavailable("Authorization is pending or could not be confirmed. Review System Settings."), start: { done in
            self.inspect { [weak self] checked in
                guard let self else { done(.unavailable("Notification service unavailable.")); return }
                guard checked == .notDetermined else { done(checked); return }
                self.center.requestAuthorization(options: [.alert]) { [weak self] _, error in
                    Task { @MainActor in
                        if let error { done(.unavailable(error.localizedDescription)) }
                        else if let self { self.inspect(done) }
                        else { done(.unavailable("Notification service unavailable.")) }
                    }
                }
            }
        }, completion: completion)
    }
    func add(_ reservation: AlertReservation, completion: @escaping @MainActor (String?) -> Void) {
        let content = UNMutableNotificationContent()
        content.title = reservation.title
        content.body = reservation.body
        content.userInfo = ["cellio.alert.device": reservation.deviceID]
        // No sound, badge, category, or escalated interruption level.
        center.add(UNNotificationRequest(identifier: reservation.requestID, content: content, trigger: nil)) { error in
            Task { @MainActor in completion(error?.localizedDescription) }
        }
    }
    func cancel(_ identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers.filter { $0.hasPrefix("cellio.low-battery.") })
    }
    func addPreview(completion: @escaping @MainActor (String?) -> Void) {
        let content = UNMutableNotificationContent()
        content.title = AlertNotificationPreview.title
        content.body = AlertNotificationPreview.body
        content.userInfo = [AlertNotificationPreview.payloadKey: AlertNotificationPreview.payloadKind]
        center.add(UNNotificationRequest(identifier: AlertNotificationPreview.identifier, content: content, trigger: nil)) { error in
            Task { @MainActor in completion(error?.localizedDescription) }
        }
    }
    func cancelPreview() {
        center.removePendingNotificationRequests(withIdentifiers: [AlertNotificationPreview.identifier])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let request = response.notification.request
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           request.identifier == AlertNotificationPreview.identifier,
           request.content.userInfo[AlertNotificationPreview.payloadKey] as? String == AlertNotificationPreview.payloadKind {
            Task { @MainActor [weak self] in self?.routeNotifications?() }
        } else if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           request.identifier.hasPrefix("cellio.low-battery."),
           let id = request.content.userInfo["cellio.alert.device"] as? String,
           !id.isEmpty, id.utf8.count <= 512 {
            Task { @MainActor [weak self] in self?.route?(id) }
        }
        completionHandler()
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}

/// An injected model snapshot also permits compiling/probing this coordinator with an inert model.
struct AlertModelSnapshot {
    var records: [BatteryRecord]
    var devices: [KnownBatteryDevice]
    var monitoringBlocked: Bool
    init(records: [BatteryRecord] = [], devices: [KnownBatteryDevice] = [], monitoringBlocked: Bool = false) {
        self.records = records; self.devices = devices; self.monitoringBlocked = monitoringBlocked
    }
}
@MainActor protocol AlertHUDPresenting: AnyObject {
    func show(_ content: AlertHUDContent, size: AlertHUDSize, requestID: String,
              valid: @escaping () -> Bool, completion: @escaping (String?) -> Void)
    func preview(size: AlertHUDSize, completion: @escaping (String?) -> Void)
    func cancel(_ identifiers: [String])
    func cancelAll()
    func revalidate()
    func updateSize(_ size: AlertHUDSize)
    func updatePosition(_ position: AlertHUDPosition)
}
extension AlertHUDPresenting {
    // Existing injected presenters need not implement position-aware visuals.
    func updatePosition(_ position: AlertHUDPosition) {}
}
@MainActor final class AlertCoordinator: ObservableObject {
    let policy: LowBatteryAlertPolicy
    private let boundary: AlertNotificationBoundary
    private let clock: BatteryClock
    private let snapshot: () -> AlertModelSnapshot
    private let presentationStore: AlertPresentationStore
    private let hud: AlertHUDPresenting?
    @Published private(set) var presentation = AlertPresentationChoice()
    @Published private(set) var presentationIssue: String?
    @Published private(set) var permission = AlertPermission.unknown
    @Published private(set) var revision = 0
    @Published private(set) var deliveryIssue: String?
    @Published private(set) var schedulingAccepted = false
    @Published private(set) var previewInFlight = false
    @Published private(set) var previewStatus: String?
    @Published private(set) var previewIssue: String?
    @Published private(set) var permissionChecking = false
    @Published private(set) var permissionActionInFlight = false
    @Published private(set) var permissionCheckIssue: String?
    private var permissionActionSerial: UInt64 = 0
    private var permissionRefreshPending = false
    private var userCheckPending = false
    private enum PreviewPhase { case inspecting, authorizing, adding }
    private var previewPhase: PreviewPhase?
    private var previewSerial: UInt64 = 0
    private var ownsPreview = false
    private var generation: UInt64 = 0
    private var inspection: UInt64 = 0
    private var stopped = false
    private var queued = false
    private var monitoring: [String: Bool] = [:]
    private var subscriptions = Set<AnyCancellable>()
    private weak var connectionModel: AppModel?
    private var connectionCatalog = PhysicalDeviceCatalog()
    private var connectionOrigins: [ComponentID:String] = [:]
    private var hiddenPolicyIDs=Set<String>()
    private var deviceDeliveryGeneration: [String:UInt64] = [:]
    /// Shared by native notification and HUD delivery; no second episode engine.
    @discardableResult func prepareConnections(sources: [String], targets: [String]) -> Bool {
        let affected=Set(sources+targets)
        for id in affected { deviceDeliveryGeneration[id,default:0] &+= 1 }
        let pending=policy.episodes.filter { affected.contains($0.id.device) }.compactMap(\.requestID)
        boundary.cancel(pending); hud?.cancel(pending)
        let records=(connectionModel?.rawRecords ?? [])+snapshot().records
        let saved=policy.migrateConnections(sources:sources,targets:targets,records:records,now:clock.now())
        revision &+= 1
        return saved
    }
    @discardableResult func prepareVisibility(ids: [String], restoring: Bool) -> Bool {
        guard !stopped else { return false }
        let affected=Set(ids)
        for id in affected { deviceDeliveryGeneration[id,default:0] &+= 1 }
        let pending=policy.episodes.filter { affected.contains($0.id.device) }.compactMap(\.requestID)
        boundary.cancel(pending); hud?.cancel(pending)
        let saved=policy.transitionVisibility(ids:ids,records:(connectionModel?.rawRecords ?? [])+snapshot().records,restoring:restoring,now:clock.now())
        revision &+= 1
        return saved
    }
    private func synchronizeVisibility() {
        guard let model=connectionModel else { return }
        let next=model.deviceSettings.hiddenPolicyIDs
        let hidden=next.subtracting(hiddenPolicyIDs), restored=hiddenPolicyIDs.subtracting(next)
        hiddenPolicyIDs=next
        if !hidden.isEmpty { _ = prepareVisibility(ids:Array(hidden),restoring:false) }
        if !restored.isEmpty { _ = prepareVisibility(ids:Array(restored),restoring:true) }
    }
    private func synchronizeConnections() {
        guard let model=connectionModel else { return }
        let catalog=model.deviceSettings.physicalCatalog
        let origins=model.physicalProjection.origins
        let previousMembership=Dictionary(uniqueKeysWithValues:connectionCatalog.groups.map { ($0.id,$0.members) })
        let membership=Dictionary(uniqueKeysWithValues:catalog.groups.map { ($0.id,$0.members) })
        if membership != previousMembership || origins != connectionOrigins {
            let changed=Set(origins.keys.filter { connectionOrigins[$0] != nil && origins[$0] != connectionOrigins[$0] }.map(\.device))
            let groups=catalog.groups.filter { changed.contains($0.id) || previousMembership[$0.id] != $0.members }
            let ungrouped=changed.filter { id in !catalog.groups.contains { $0.id == id } }
            for group in groups { _ = prepareConnections(sources:group.members+[group.id],targets:group.members+[group.id]) }
            for id in ungrouped { _ = prepareConnections(sources:[id],targets:[id]) }
            connectionCatalog=catalog; connectionOrigins=origins
        }
    }
    init(policy: LowBatteryAlertPolicy = LowBatteryAlertPolicy(), boundary: AlertNotificationBoundary? = nil,
         clock: BatteryClock = SystemBatteryClock(), snapshot: @escaping () -> AlertModelSnapshot = { .init() },
         presentationStore: AlertPresentationStore = AlertPresentationStore(), hud: AlertHUDPresenting? = nil) {
        self.policy = policy; self.boundary = boundary ?? InertAlertNotificationBoundary(); self.clock = clock; self.snapshot = snapshot
        self.presentationStore = presentationStore; self.hud = hud
        presentation = presentationStore.choice; presentationIssue = presentationStore.issue
        hud?.updatePosition(presentation.position)
        let initial = snapshot()
        monitoring = Dictionary(uniqueKeysWithValues: initial.devices.map { ($0.id, $0.preferences.monitorBattery && !initial.monitoringBlocked) })
        policy.baseline(initial.records, now: clock.now())
        refreshPermission()
    }
    convenience init(model: AppModel, policy: LowBatteryAlertPolicy = LowBatteryAlertPolicy(), boundary: AlertNotificationBoundary? = nil,
                     clock: BatteryClock = SystemBatteryClock(), presentationStore: AlertPresentationStore = AlertPresentationStore(), hud: AlertHUDPresenting? = nil) {
        self.init(policy: policy, boundary: boundary, clock:clock, snapshot: { [weak model] in
            guard let model else { return .init() }
            return .init(records: model.sortedRecords, devices: model.knownDevices, monitoringBlocked: model.deviceSettings.updatesBlocked || model.deviceSettings.issue != nil)
        }, presentationStore: presentationStore, hud: hud)
        connectionModel=model
        model.connectionAlertConfiguration = { [weak self] in
            guard let self, !self.stopped, !self.policy.corrupt, self.policy.issue == nil else { return nil }
            return self.configuration
        }
        model.prepareConnectionChange = { [weak self] sources, targets in self?.prepareConnections(sources:sources,targets:targets) ?? false }
        model.prepareVisibilityChange = { [weak self] ids, restoring in self?.prepareVisibility(ids:ids,restoring:restoring) ?? false }
        model.visibilityPolicyDidChange = { [weak self] in self?.synchronizeVisibility() }
        model.didCommitVisibilityChange = { [weak self, weak model] in
            guard let self, let model else { return }
            self.hiddenPolicyIDs=model.deviceSettings.hiddenPolicyIDs
        }
        model.didCommitConnectionChange = { [weak self, weak model] in
            guard let self, let model else { return }
            self.hiddenPolicyIDs=model.deviceSettings.hiddenPolicyIDs
            self.connectionCatalog=model.deviceSettings.physicalCatalog
            self.connectionOrigins=model.physicalProjection.origins
        }
        model.retryConnectionAlertStorage = { [weak self] in self?.retryStorage() }
        synchronizeVisibility()
        model.reconcileVerifiedConnections()
        synchronizeConnections()
        // @Published emits before mutation: read the model on the next actor turn.
        model.$reducer.sink { [weak self] _ in self?.enqueueLatestBatch() }.store(in: &subscriptions)
        model.$settingsChange.sink { [weak self] _ in self?.enqueueLatestBatch() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification).sink { [weak self] _ in
            Task { @MainActor in self?.refreshPermission() }
        }.store(in: &subscriptions)
    }
    var permissionBoundary: AlertNotificationBoundary { boundary }
    var configuration: AlertConfiguration { connectionModel?.deviceSettings.alertConfiguration(over:policy.configuration) ?? policy.configuration }
    var issue: String? { policy.issue }
    var usesHUD: Bool { presentation.style == .hud }
    func selectPresentation(style: AlertStyle? = nil, size: AlertHUDSize? = nil, position: AlertHUDPosition? = nil) {
        var next = presentation
        if let style { next.style = style }; if let size { next.size = size }
        if let position { next.position = position }
        let old = presentation
        guard presentationStore.save(next) else {
            presentationIssue = presentationStore.issue
            invalidatePresentation()
            return
        }
        presentation = next; presentationIssue = nil
        if old.size != next.size { hud?.updateSize(next.size) }
        if old.position != next.position { hud?.updatePosition(next.position) }
        if old.style != next.style {
            invalidatePresentation()
            policy.baseline(snapshot().records, now: clock.now())
            refreshPermission()
        }
    }
    func retryPresentationStorage() {
        let old = presentation
        presentationStore.reload()
        presentationIssue = presentationStore.issue
        guard presentationIssue == nil else { invalidatePresentation(); return }
        presentation = presentationStore.choice
        hud?.updateSize(presentation.size)
        hud?.updatePosition(presentation.position)
        // A repaired read also needs new evidence before delivery resumes.
        invalidatePresentation()
        policy.baseline(snapshot().records, now: clock.now())
        if old.style != presentation.style || !usesHUD { refreshPermission() }
    }
    private func invalidatePresentation() {
        generation &+= 1; inspection &+= 1; previewSerial &+= 1; permissionActionSerial &+= 1
        boundary.cancel(policy.ownedRequestIDs)
        if ownsPreview { boundary.cancelPreview(); ownsPreview = false }
        hud?.cancelAll()
        previewPhase = nil; previewInFlight = false
        previewStatus = nil; previewIssue = nil
        permissionChecking = false; permissionActionInFlight = false
        permissionRefreshPending = false; userCheckPending = false
        deliveryIssue = nil; schedulingAccepted = false
    }
    func enqueueLatestBatch() {
        guard !queued, !stopped else { return }; queued = true
        Task { @MainActor [weak self] in
            guard let self else { return }; self.queued = false
            self.processLatestAcceptedBatch()
        }
    }
    func processLatestAcceptedBatch() {
        guard !stopped else { return }
        synchronizeVisibility()
        synchronizeConnections()
        let state = snapshot()
        for d in state.devices {
            let on = d.preferences.monitorBattery && !state.monitoringBlocked
            if let previous = monitoring[d.id], previous != on {
                deviceDeliveryGeneration[d.id,default:0] &+= 1
                policy.baseline(state.records.filter { $0.observation.id.device == d.id }, now: clock.now())
                if !on {
                    let ids = policy.episodes.filter { $0.id.device == d.id }.compactMap(\.requestID)
                    boundary.cancel(ids); hud?.cancel(ids)
                }
            }
            monitoring[d.id] = on
        }
        let work = policy.process(records: state.records, devices: state.devices,
                                  authorized: presentationIssue == nil && (usesHUD || permission.allowsDelivery), now: clock.now(), monitoringAllowed: !state.monitoringBlocked, configurationOverride:configuration)
        if let model=connectionModel {
            for group in model.deviceSettings.physicalCatalog.groups { policy.mirrorConnectionEpisodes(from:group.id,to:group.members) }
        }
        guard policy.issue == nil else { revision &+= 1; return }
        hud?.revalidate()
        revision &+= 1
        let token = generation
        for reservation in work {
            guard !stopped, token == generation else { break }
            let deviceToken=deviceDeliveryGeneration[reservation.deviceID,default:0]
            let reservationUsesHUD = usesHUD
            let completion: @MainActor (String?) -> Void = { [weak self] error in
                guard let self else { return }
                // A canceled HUD cannot confirm visibility. Native add results still
                // complete durable booking before stale-request cleanup below.
                if reservationUsesHUD && (self.stopped || token != self.generation || deviceToken != self.deviceDeliveryGeneration[reservation.deviceID,default:0]) {
                    self.hud?.cancel([reservation.requestID])
                    return
                }
                self.policy.complete(requestID: reservation.requestID, accepted: error == nil)
                if self.stopped || token != self.generation || deviceToken != self.deviceDeliveryGeneration[reservation.deviceID,default:0] {
                    self.boundary.cancel([reservation.requestID])
                } else {
                    if let error { self.deliveryIssue = "\(reservationUsesHUD ? "HUD not shown" : "macOS did not accept scheduling"): \(error). Retry requires a new eligible low reading, at least 60 seconds apart, up to 3 attempts per episode." }
                    self.schedulingAccepted = error == nil
                }
                self.revision &+= 1
            }
            if reservationUsesHUD {
                guard let hud else { completion("No on-screen presenter is connected."); continue }
                let evidence = state.records.filter { record in reservation.components.contains { $0.id == record.observation.id } }
                let source = state.devices.first { $0.id == reservation.deviceID }?.source
                let content = AlertHUDContent(reservation: reservation, source: state.devices.first { $0.id == reservation.deviceID }?.source)
                hud.show(content, size: presentation.size, requestID: reservation.requestID, valid: { [weak self] in
                    guard let self, !self.stopped, self.usesHUD, self.presentationIssue == nil,
                          token == self.generation, deviceToken == self.deviceDeliveryGeneration[reservation.deviceID,default:0], self.policy.issue == nil, self.configuration.enabled else { return false }
                    let latest = self.snapshot()
                    guard !latest.monitoringBlocked,
                          let device = latest.devices.first(where: { $0.id == reservation.deviceID }), device.preferences.monitorBattery,
                          device.source == source, self.configuration.device(device.id).included else { return false }
                    return reservation.components.allSatisfy { part in
                        guard self.configuration.device(device.id).components.includes(part.id.component),
                              let original = evidence.first(where: { $0.observation.id == part.id }),
                              let current = latest.records.first(where: { $0.observation.id == part.id }),
                              current.observation.source == original.observation.source,
                              LowBatteryAlertPolicy.quantityTime(current) == LowBatteryAlertPolicy.quantityTime(original),
                              current.observation.quantity == .reportedPercent(part.percent),
                              part.percent <= self.configuration.threshold(for: device.id),
                              LowBatteryAlertPolicy.ineligibility(current, monitoring: true, now: self.clock.now()) == nil else { return false }
                        return true
                    }
                }, completion: completion)
            } else { boundary.add(reservation, completion: completion) }
        }
    }
    func refreshPermission(userInitiated: Bool = false) {
        guard !stopped else { return }
        guard !usesHUD else { return }
        // Activation can arrive before the OS consent callback. It must not
        // invalidate an explicit chain's inspection ticket or permission baseline.
        guard !previewInFlight, !permissionActionInFlight else {
            permissionRefreshPending = true
            userCheckPending = userCheckPending || userInitiated
            return
        }
        permissionChecking = true
        if userInitiated { permissionCheckIssue = nil }
        inspection &+= 1; let ticket = inspection
        boundary.inspect { [weak self] result in
            guard let self, !self.stopped, ticket == self.inspection else { return }
            self.acceptPermission(result)
            self.permissionChecking = false
            if userInitiated, case .unavailable(let error) = result {
                self.permissionCheckIssue = "Couldn't check notification settings: \(error)"
            }
        }
    }
    private func refreshDeferredPermission() {
        guard !stopped, permissionRefreshPending else { return }
        let userInitiated = userCheckPending
        permissionRefreshPending = false; userCheckPending = false
        refreshPermission(userInitiated: userInitiated)
    }
    private func acceptPermission(_ result: AlertPermission) {
        guard !usesHUD else { return }
        if permission != result {
            generation &+= 1
            policy.baseline(snapshot().records, now: clock.now())
            if !result.allowsDelivery { boundary.cancel(policy.ownedRequestIDs) }
        }
        permission = result; revision &+= 1
    }
    /// Only explicit enable or Allow reaches the request boundary.
    func allowNotifications() {
        guard !stopped, !usesHUD, presentationIssue == nil else { return }
        guard !previewInFlight, !permissionActionInFlight else { return }
        permissionActionInFlight = true; permissionChecking = true
        permissionActionSerial &+= 1; let action = permissionActionSerial
        let token = generation
        inspection &+= 1; let ticket = inspection
        boundary.inspect { [weak self] result in
            guard let self, !self.stopped, action == self.permissionActionSerial else { return }
            guard token == self.generation, ticket == self.inspection else { self.finishPermissionAction(refreshDeferred: false); return }
            if result == .notDetermined {
                self.boundary.requestAuthorization { [weak self] permission in
                    guard let self, !self.stopped, action == self.permissionActionSerial else { return }
                    guard token == self.generation, ticket == self.inspection else { self.finishPermissionAction(refreshDeferred: false); return }
                    self.acceptPermission(permission)
                    self.finishPermissionAction()
                }
            } else { self.acceptPermission(result); self.finishPermissionAction() }
        }
    }
    private func finishPermissionAction(refreshDeferred: Bool = true) {
        permissionActionInFlight = false; permissionChecking = false
        if refreshDeferred { refreshDeferredPermission() }
        else {
            // Invalidated operations only clean up; queued checks must not
            // resurrect permission state after a genuine configuration change.
            permissionRefreshPending = false; userCheckPending = false
        }
    }
    /// Only the explicit native Preview action enters this chain, even with alerts off.
    func previewNotification() {
        guard !stopped, !previewInFlight, !permissionActionInFlight else { return }
        guard presentationIssue == nil else { previewStatus = "Preview paused. Save or retry presentation preferences."; return }
        if usesHUD {
            previewSerial &+= 1; let serial = previewSerial
            previewInFlight = true; previewIssue = nil; previewStatus = "Preparing preview…"
            guard let hud else { previewInFlight = false; previewStatus = "No HUD shown. No on-screen presenter is connected."; return }
            hud.preview(size: presentation.size) { [weak self] error in
                guard let self, !self.stopped, serial == self.previewSerial else { return }
                self.previewInFlight = false; self.previewIssue = error
                self.previewStatus = error ?? "Example HUD shown. It closes automatically."
            }
            return
        }
        previewSerial &+= 1; let serial = previewSerial
        inspection &+= 1; let ticket = inspection
        let token = generation
        previewPhase = .inspecting; previewInFlight = true; permissionChecking = true
        previewIssue = nil; permissionCheckIssue = nil; previewStatus = "Preparing preview…"
        boundary.inspect { [weak self] result in
            guard let self, self.previewCanContinue(serial, phase: .inspecting, generation: token, inspection: ticket) else { return }
            if result == .notDetermined {
                self.previewPhase = .authorizing
                self.previewStatus = "Waiting for macOS authorization…"
                self.boundary.requestAuthorization { [weak self] result in
                    guard let self, self.previewCanContinue(serial, phase: .authorizing, generation: token, inspection: ticket) else { return }
                    self.deliverPreview(result, serial: serial, inspection: ticket)
                }
            } else { self.deliverPreview(result, serial: serial, inspection: ticket) }
        }
    }
    private func previewCanContinue(_ serial: UInt64, phase: PreviewPhase, generation token: UInt64, inspection ticket: UInt64) -> Bool {
        guard !stopped, previewInFlight, serial == previewSerial, previewPhase == phase else { return false }
        guard token == generation, ticket == inspection else {
            finishPreview("Preview canceled because settings changed. Try again.")
            return false
        }
        return true
    }
    private func deliverPreview(_ result: AlertPermission, serial: UInt64, inspection ticket: UInt64) {
        // Use the existing permission baseline gate; never process or reserve a real alert.
        previewPhase = .adding
        let expectedGeneration = permission == result ? generation:generation &+ 1
        acceptPermission(result)
        guard previewCanContinue(serial, phase: .adding, generation: expectedGeneration, inspection: ticket) else { return }
        permissionChecking = false
        guard result.allowsDelivery else {
            switch result {
            case .denied, .alertsDisabled, .limited, .notDetermined:
                finishPreview("Preview not sent. Allow notifications in System Settings, then try again.")
            case .unknown, .unavailable:
                if case .unavailable(let error) = result { previewIssue = error }
                finishPreview("Couldn't check notification settings. Use Check again, then retry Preview.")
            case .authorized: break
            }
            return
        }
        previewStatus = "Sending example notification…"
        ownsPreview = true
        boundary.addPreview { [weak self] error in
            guard let self else { return }
            if self.stopped { self.boundary.cancelPreview(); return }
            if let error { self.previewIssue = error }
            guard self.previewCanContinue(serial, phase: .adding, generation: expectedGeneration, inspection: ticket) else { return }
            if error != nil { self.finishPreview("macOS couldn't accept the preview. Try again.") }
            else { self.finishPreview("macOS accepted the preview request. Check Notification Center; Focus or alert settings may hide the banner.") }
        }
    }
    private func finishPreview(_ status: String) {
        previewPhase = nil; previewInFlight = false; permissionChecking = false; previewStatus = status
        refreshDeferredPermission()
    }
    func edit(_ change: (inout AlertConfiguration) -> Void, explicitEnable: Bool = false) {
        var next = configuration; change(&next)
        guard next != configuration else { return }
        let old = configuration
        inspection &+= 1
        if next.enabled != old.enabled || next.threshold != old.threshold {
            generation &+= 1; boundary.cancel(policy.ownedRequestIDs); hud?.cancelAll()
        } else {
            let affected=Set(next.devices.keys).union(old.devices.keys).filter { next.device($0) != old.device($0) }
            for id in affected { deviceDeliveryGeneration[id,default:0] &+= 1 }
            let requests=policy.episodes.filter { affected.contains($0.id.device) }.compactMap(\.requestID)
            boundary.cancel(requests); hud?.cancel(requests)
        }
        if let model=connectionModel {
            do {
                let grouped=try model.deviceSettings.saveGroupedAlerts(next)
                var base=next
                // Group preferences live only in the atomic catalog document.
                for id in grouped {
                    if let old=policy.configuration.devices[id] { base.devices[id]=old } else { base.devices.removeValue(forKey:id) }
                }
                if base != policy.configuration { _ = policy.configure(base) }
                model.connectionPreferencesDidChange()
            } catch { deliveryIssue=error.localizedDescription; revision &+= 1; return }
        } else { _ = policy.configure(next) }
        let globallyChanged=next.enabled != old.enabled || next.threshold != old.threshold
        let affected=Set(next.devices.keys).union(old.devices.keys).filter { next.device($0) != old.device($0) }
        policy.baseline(snapshot().records.filter { globallyChanged || affected.contains($0.observation.id.device) }, now: clock.now())
        if !configuration.enabled { boundary.cancel(policy.ownedRequestIDs) }
        else {
            let disabled = Set(next.devices.keys.filter { !next.device($0).included && old.device($0).included })
            boundary.cancel(policy.episodes.filter { disabled.contains($0.id.device) }.compactMap(\.requestID))
        }
        revision &+= 1
        hud?.revalidate()
        if explicitEnable && configuration.enabled && !old.enabled { allowNotifications() }
        else { refreshPermission() }
    }
    func retryStorage() { generation &+= 1; policy.retry(); policy.baseline(snapshot().records, now: clock.now()); revision &+= 1; refreshPermission() }
    func resetStorage() {
        generation &+= 1; inspection &+= 1; boundary.cancel(policy.ownedRequestIDs)
        hud?.cancelAll()
        policy.reset(); policy.baseline(snapshot().records, now: clock.now())
        deliveryIssue = nil; schedulingAccepted = false; revision &+= 1; refreshPermission()
    }
    func stop() {
        stopped = true; generation &+= 1; inspection &+= 1; subscriptions.removeAll()
        previewSerial &+= 1; previewPhase = nil; previewInFlight = false
        permissionChecking = false; permissionActionInFlight = false
        permissionRefreshPending = false; userCheckPending = false
        if ownsPreview { boundary.cancelPreview() }
        hud?.cancelAll()
    }
    var attemptStatus: String? {
        if policy.episodes.contains(where: { $0.attemptState == .failed }) {
            return "An alert could not be scheduled. A newer eligible low reading may retry the same request, at least 60 seconds apart, up to 3 attempts per episode."
        }
        if policy.episodes.contains(where: { $0.attemptState == .reserved }) {
            return "An alert scheduling attempt is pending or its result is unknown. It stays reserved across restart to avoid a duplicate; an uncertain attempt is not retried."
        }
        return nil
    }
    func eligibility(device: KnownBatteryDevice) -> String {
        let state = snapshot()
        guard !state.monitoringBlocked else { return "Device monitoring settings unavailable" }
        guard device.preferences.monitorBattery else { return "Monitoring paused" }
        let records = state.records.filter { $0.observation.id.device == device.id && configuration.device(device.id).components.includes($0.observation.id.component) }
        guard !records.isEmpty else { return "No reported reading in this session" }
        let reasons = records.compactMap { LowBatteryAlertPolicy.ineligibility($0, monitoring: true, now: clock.now()) }
        if reasons.count < records.count { return "Eligible source · alerts require a new low measurement" }
        return Array(Set(reasons)).sorted().joined(separator: " · ")
    }
}
