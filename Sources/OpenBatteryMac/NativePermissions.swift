import Foundation
import Combine

// This seam has no AppModel, defaults, device, presentation, or consent side effects.
enum NativePermissionKind: String, CaseIterable, Identifiable {
    case bluetooth, inputMonitoring, notifications
    var id: String { rawValue }
    var title: String {
        switch self { case .bluetooth: return "Bluetooth"; case .inputMonitoring: return "Input Monitoring"; case .notifications: return "Notifications" }
    }
    var purpose: String {
        switch self {
        case .bluetooth: return "Read compatible connected Bluetooth batteries."
        case .inputMonitoring: return "Read battery reports from supported accessories."
        case .notifications: return "Show macOS low-battery notifications."
        }
    }
}
enum NativeAccess: Equatable { case notDetermined, denied, restricted, allowed, alertsOff, limited, unavailable }
enum NativeBluetoothRadio: Equatable { case poweredOn, poweredOff, starting, resetting, unavailable }
struct NativePermissionFact: Equatable {
    var access: NativeAccess
    var radio: NativeBluetoothRadio? = nil
}
enum NativePermissionPhase { case idle, checking, waiting }
enum NativePermissionAction { case allow, settings, check }
enum NativeSettingsDestination {
    case inputMonitoring, notifications, bluetoothPrivacy, bluetoothRadio

    init(kind: NativePermissionKind, fact: NativePermissionFact) {
        switch kind {
        case .inputMonitoring: self = .inputMonitoring
        case .notifications: self = .notifications
        case .bluetooth: self = fact.access == .allowed && fact.radio == .poweredOff ? .bluetoothRadio : .bluetoothPrivacy
        }
    }
    var manualInstructions: String {
        switch self {
        case .inputMonitoring: return "Allow this copy of Cellio in System Settings → Privacy & Security → Input Monitoring."
        case .notifications: return "In System Settings → Notifications, select Cellio and review its notifications."
        case .bluetoothPrivacy: return "Allow Cellio in System Settings → Privacy & Security → Bluetooth."
        case .bluetoothRadio: return "Turn on Bluetooth in System Settings → Bluetooth."
        }
    }
}
struct NativePermissionRow {
    var fact = NativePermissionFact(access: .unavailable)
    var phase = NativePermissionPhase.idle
    var pendingAction: NativePermissionAction?
    var attempted = false
    var openFailed = false
    func status(for kind: NativePermissionKind) -> String {
        switch phase { case .checking: return "Checking…"; case .waiting: return "Waiting…"; case .idle: break }
        switch fact.access {
        case .notDetermined: return kind == .inputMonitoring ? "Not determined" : "Not allowed"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .allowed: return "Allowed"
        case .alertsOff: return "Alerts off"
        case .limited: return "Limited"
        case .unavailable: return "Unavailable"
        }
    }
    var action: NativePermissionAction? {
        if phase != .idle, let pendingAction { return pendingAction }
        switch fact.access {
        case .notDetermined: return attempted ? .settings : .allow
        case .denied, .alertsOff, .limited: return .settings
        case .unavailable: return .check
        case .restricted: return nil
        case .allowed: return fact.radio == .poweredOff ? .settings : nil
        }
    }
    func actionTitle(for kind: NativePermissionKind) -> String? {
        guard let action else { return nil }
        switch action {
        case .settings: return "Open System Settings…"
        case .check: return "Check again"
        case .allow:
            switch kind { case .bluetooth: return "Allow Bluetooth"; case .inputMonitoring: return "Allow access…"; case .notifications: return "Allow notifications" }
        }
    }
    func help(for kind: NativePermissionKind) -> String {
        if openFailed { return "Couldn't confirm Settings opened. Open it from the Apple menu. " + NativeSettingsDestination(kind: kind, fact: fact).manualInstructions }
        if fact.access == .unavailable { return "Couldn't check access. Try again." }
        switch kind {
        case .bluetooth:
            switch fact.access {
            case .notDetermined where !attempted: return "Ask macOS to allow Bluetooth access, even before a compatible device is connected."
            case .notDetermined, .denied: return "Allow Cellio in System Settings → Privacy & Security → Bluetooth."
            case .restricted: return "Bluetooth access is restricted on this Mac."
            case .allowed:
                switch fact.radio {
                case .poweredOff: return "Bluetooth is off. Turn it on in System Settings → Bluetooth."
                case .starting, .resetting: return "Waiting for Bluetooth…"
                case .unavailable: return "Bluetooth availability is unavailable. Access is allowed."
                default: return ""
                }
            default: return ""
            }
        case .inputMonitoring:
            if fact.access == .denied || (fact.access == .notDetermined && attempted) { return "Allow this copy of Cellio in System Settings → Privacy & Security → Input Monitoring." }
            return ""
        case .notifications:
            switch fact.access {
            case .notDetermined where !attempted: return "Ask macOS to allow notifications. Alert style and low-battery alerts stay unchanged."
            case .notDetermined, .denied, .alertsOff, .limited: return NativeSettingsDestination.notifications.manualInstructions
            case .allowed: return "Focus and macOS settings may delay or hide notifications."
            default: return ""
            }
        }
    }
}

@MainActor protocol NativePermissionAdapter: AnyObject {
    // A nil result is an inspection failure/unsupported result, never denial.
    func inspect(_ kind: NativePermissionKind, completion: @escaping @MainActor (NativePermissionFact?) -> Void)
    func request(_ kind: NativePermissionKind, completion: @escaping @MainActor () -> Void)
    func openSettings(completion: @escaping @MainActor (Bool) -> Void)
    // True means an accepted opening operation, never confirmed category visibility.
    func openSettings(_ destination: NativeSettingsDestination, isCurrent: @escaping @MainActor () -> Bool,
                      completion: @escaping @MainActor (Bool) -> Void)
}
extension NativePermissionAdapter {
    func openSettings(_ destination: NativeSettingsDestination, isCurrent: @escaping @MainActor () -> Bool,
                      completion: @escaping @MainActor (Bool) -> Void) {
        guard isCurrent() else { return }
        openSettings(completion: completion)
    }
}
@MainActor protocol NativePermissionScheduling {
    func after(_ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void)
}
struct NativePermissionScheduler: NativePermissionScheduling {
    func after(_ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { work() }
    }
}

/// Shared by all consent entry points, including notification enable and Preview.
/// A timed-out OS request is quarantined until its real callback drains. The UI
/// recovers, but another click cannot create a second unresolved native request.
@MainActor final class NativePermissionRequestGate: ObservableObject {
    static let shared = NativePermissionRequestGate()
    @Published private(set) var owner: NativePermissionKind?
    private var token: UUID?
    private var uncertain: [NativePermissionKind: UUID] = [:]
    let scheduler: NativePermissionScheduling
    init(scheduler: NativePermissionScheduling? = nil) { self.scheduler = scheduler ?? NativePermissionScheduler() }
    var busy: Bool { owner != nil || !uncertain.isEmpty }
    func confirmed(_ kind: NativePermissionKind, access: NativeAccess) {
        guard access != .notDetermined, access != .unavailable, uncertain.removeValue(forKey: kind) != nil else { return }
        objectWillChange.send()
    }
    func perform<Value>(_ kind: NativePermissionKind, fallback: Value,
                        start: (@escaping @MainActor (Value) -> Void) -> Void,
                        completion: @escaping @MainActor (Value) -> Void) {
        guard !busy else { completion(fallback); return }
        let ticket = UUID(); token = ticket; owner = kind
        scheduler.after(45) { [weak self] in
            guard let self, self.token == ticket else { return }
            self.uncertain[kind] = ticket; self.token = nil; self.owner = nil
            completion(fallback)
        }
        start { [weak self] value in
            guard let self else { return }
            guard self.token == ticket else {
                if self.uncertain[kind] == ticket { self.uncertain.removeValue(forKey: kind); self.objectWillChange.send() }
                return
            }
            self.token = nil; self.owner = nil
            completion(value)
        }
    }
}

@MainActor final class NativePermissionsController: ObservableObject {
    @Published private(set) var rows = Dictionary(uniqueKeysWithValues: NativePermissionKind.allCases.map { ($0, NativePermissionRow()) })
    let gate: NativePermissionRequestGate
    private let adapter: NativePermissionAdapter
    private let scheduler: NativePermissionScheduling
    private var serial: [NativePermissionKind: UUID] = [:]
    private var requestTicket: UUID?
    private var inspection: UUID?
    private var refreshQueued = false
    private var settingsTicket: UUID?
    private var gateChanges: AnyCancellable?
    init(adapter: NativePermissionAdapter, gate: NativePermissionRequestGate,
         scheduler: NativePermissionScheduling? = nil) {
        self.adapter = adapter; self.gate = gate; self.scheduler = scheduler ?? gate.scheduler
        gateChanges = gate.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
    func row(_ kind: NativePermissionKind) -> NativePermissionRow {
        var value = rows[kind]!
        if value.phase == .idle, gate.owner == kind {
            value.pendingAction = value.action
            value.phase = .waiting
        }
        return value
    }
    func canAct(_ kind: NativePermissionKind) -> Bool {
        let row = row(kind)
        // Settings and recovery checks remain usable after an unresolved OS request.
        return inspection == nil && settingsTicket == nil && row.phase == .idle && (row.action != .allow || (!gate.busy && requestTicket == nil))
    }
    func invalidateSettingsOpening() {
        settingsTicket = nil
        for kind in NativePermissionKind.allCases where rows[kind]?.pendingAction == .settings {
            rows[kind]?.phase = .idle; rows[kind]?.pendingAction = nil
        }
    }
    /// Passive, serialized, coalesced. No request is dispatched by this chain.
    func refresh() {
        guard inspection == nil else { refreshQueued = true; return }
        settingsTicket = nil
        let ticket = UUID(); inspection = ticket
        for kind in NativePermissionKind.allCases { serial[kind] = UUID(); rows[kind]?.phase = .checking; rows[kind]?.pendingAction = nil }
        inspectNext(NativePermissionKind.allCases[...], ticket: ticket)
    }
    private func inspectNext(_ remaining: ArraySlice<NativePermissionKind>, ticket: UUID) {
        guard inspection == ticket else { return }
        guard let kind = remaining.first else {
            inspection = nil
            if refreshQueued { refreshQueued = false; refresh() }
            return
        }
        let check = UUID(); serial[kind] = check
        let finish: @MainActor (NativePermissionFact?) -> Void = { [weak self] fact in
            guard let self, self.inspection == ticket, self.serial[kind] == check else { return }
            self.serial[kind] = UUID()
            // The opening error belongs to this confirmed fact and Settings
            // action. A repeated check of the same fact keeps it readable.
            // Failed/unsupported inspections and changed facts replace its guidance.
            if fact == nil || fact?.access == .unavailable || fact != self.rows[kind]?.fact {
                self.rows[kind]?.openFailed = false
            }
            self.rows[kind]?.fact = fact ?? .init(access: .unavailable)
            if let fact { self.gate.confirmed(kind, access: fact.access) }
            self.rows[kind]?.phase = .idle; self.rows[kind]?.pendingAction = nil
            self.inspectNext(remaining.dropFirst(), ticket: ticket)
        }
        scheduler.after(8) { finish(nil) }
        adapter.inspect(kind, completion: finish)
    }
    func act(_ kind: NativePermissionKind) {
        guard canAct(kind), let action = row(kind).action else { return }
        rows[kind]?.pendingAction = action
        switch action {
        case .check: refresh()
        case .settings:
            let destination = NativeSettingsDestination(kind: kind, fact: row(kind).fact)
            let ticket = UUID(); settingsTicket = ticket; rows[kind]?.phase = .waiting
            let finish: @MainActor (Bool) -> Void = { [weak self] opened in
                guard let self, self.settingsTicket == ticket else { return }
                self.settingsTicket = nil; self.rows[kind]?.phase = .idle; self.rows[kind]?.pendingAction = nil; self.rows[kind]?.openFailed = !opened
            }
            scheduler.after(8) { finish(false) }
            adapter.openSettings(destination, isCurrent: { [weak self] in self?.settingsTicket == ticket }, completion: finish)
        case .allow:
            let ticket = UUID(); serial[kind] = ticket; requestTicket = ticket
            rows[kind]?.attempted = true; rows[kind]?.phase = .waiting; rows[kind]?.openFailed = false
            // Adapter owns the shared gate so legacy notification requests use it too.
            let finish: @MainActor () -> Void = { [weak self] in
                guard let self, self.requestTicket == ticket else { return }
                self.requestTicket = nil
                self.objectWillChange.send()
                guard self.serial[kind] == ticket else { self.refresh(); return }
                self.serial[kind] = UUID(); self.rows[kind]?.phase = .idle; self.rows[kind]?.pendingAction = nil
                self.refresh() // Callback success itself is never a grant.
            }
            scheduler.after(50, finish)
            adapter.request(kind, completion: finish)
        }
    }
}
