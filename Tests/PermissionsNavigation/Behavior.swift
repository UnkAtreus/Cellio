import Foundation

extension NativeSettingsDestination: Equatable {}

@MainActor final class TestScheduler: NativePermissionScheduling {
    var jobs: [(TimeInterval, @MainActor () -> Void)] = []
    func after(_ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) { jobs.append((seconds, work)) }
    func run(_ seconds: TimeInterval) { let due = jobs.filter { $0.0 <= seconds }; jobs.removeAll { $0.0 <= seconds }; due.forEach { $0.1() } }
}

@MainActor final class ControllerAdapter: NativePermissionAdapter {
    var facts: [NativePermissionKind: NativePermissionFact] = [:]
    var held: [NativePermissionKind: (@MainActor (NativePermissionFact?) -> Void)] = [:]
    var legacyCalls = 0
    var destinations: [NativeSettingsDestination] = []
    var completions: [@MainActor (Bool) -> Void] = []
    var currentChecks: [@MainActor () -> Bool] = []
    func inspect(_ kind: NativePermissionKind, completion: @escaping @MainActor (NativePermissionFact?) -> Void) {
        if let fact = facts[kind] { completion(fact) } else { held[kind] = completion }
    }
    func request(_ kind: NativePermissionKind, completion: @escaping @MainActor () -> Void) { completion() }
    func openSettings(completion: @escaping @MainActor (Bool) -> Void) { legacyCalls += 1; completion(true) }
    func openSettings(_ destination: NativeSettingsDestination, isCurrent: @escaping @MainActor () -> Bool, completion: @escaping @MainActor (Bool) -> Void) {
        destinations.append(destination); currentChecks.append(isCurrent); completions.append(completion)
    }
}

@MainActor final class LegacyOnlyAdapter: NativePermissionAdapter {
    var legacyCalls = 0
    func inspect(_ kind: NativePermissionKind, completion: @escaping @MainActor (NativePermissionFact?) -> Void) { completion(nil) }
    func request(_ kind: NativePermissionKind, completion: @escaping @MainActor () -> Void) { completion() }
    func openSettings(completion: @escaping @MainActor (Bool) -> Void) { legacyCalls += 1; completion(true) }
}

@MainActor final class FakeNotifications: AlertNotificationBoundary {
    func inspect(_ completion: @escaping @MainActor (AlertNotificationState) -> Void) { completion(.unknown) }
    func requestAuthorization(completion: @escaping @MainActor (Bool) -> Void) { completion(false) }
}

@MainActor final class FakeWorkspace: NativeSettingsWorkspace {
    var app: URL? = URL(fileURLWithPath: "/Applications/System Settings.app")
    var targets: [URL] = []
    var genericOpens = 0
    var targetCallbacks: [@MainActor (Bool, Error?) -> Void] = []
    var genericCallbacks: [@MainActor (Bool) -> Void] = []
    var targetAccepted = true
    var targetError: Error?
    var genericAccepted = true
    func settingsApplicationURL() -> URL? { app }
    func openTarget(_ url: URL, application: URL, completion: @escaping @MainActor (Bool, Error?) -> Void) {
        targets.append(url); targetCallbacks.append(completion)
    }
    func openApplication(_ url: URL, completion: @escaping @MainActor (Bool) -> Void) {
        genericOpens += 1; genericCallbacks.append(completion)
    }
    func finishTarget(_ index: Int = 0, accepted: Bool? = nil, error: Error? = nil) { targetCallbacks[index](accepted ?? targetAccepted, error) }
    func finishGeneric(_ index: Int = 0, accepted: Bool? = nil) { genericCallbacks[index](accepted ?? genericAccepted) }
}

@MainActor var count = 0
@MainActor var failures: [String] = []
@MainActor func expect(_ ok: @autoclosure () -> Bool, _ name: String) { count += 1; if !ok() { failures.append(name); print("FAIL: \(name)") } }
@MainActor func controller(_ fact: NativePermissionFact, kind: NativePermissionKind = .bluetooth) -> (NativePermissionsController, ControllerAdapter, TestScheduler) {
    let a = ControllerAdapter(); a.facts[kind] = fact
    for k in NativePermissionKind.allCases where k != kind { a.facts[k] = .init(access: .allowed, radio: .poweredOn) }
    let s = TestScheduler(); let c = NativePermissionsController(adapter: a, gate: NativePermissionRequestGate(scheduler: s), scheduler: s)
    c.refresh(); return (c, a, s)
}

@main struct NavigationBehavior {
    @MainActor static func main() {
        // Four current-fact mappings, including access/radio separation and all notification states.
        expect(NativeSettingsDestination(kind: .inputMonitoring, fact: .init(access: .denied)) == .inputMonitoring, "denied input maps to Input Monitoring")
        expect(NativeSettingsDestination(kind: .notifications, fact: .init(access: .denied)) == .notifications, "denied notifications maps to Notifications")
        expect(NativeSettingsDestination(kind: .notifications, fact: .init(access: .alertsOff)) == .notifications, "alertsOff maps to Notifications")
        expect(NativeSettingsDestination(kind: .notifications, fact: .init(access: .limited)) == .notifications, "limited maps to Notifications")
        expect(NativeSettingsDestination(kind: .bluetooth, fact: .init(access: .allowed, radio: .poweredOff)) == .bluetoothRadio, "allowed plus radio off maps to Bluetooth radio")
        expect(NativeSettingsDestination(kind: .bluetooth, fact: .init(access: .denied, radio: .poweredOff)) == .bluetoothPrivacy, "denied plus radio off maps to Bluetooth privacy")
        expect(NativeSettingsDestination(kind: .bluetooth, fact: .init(access: .notDetermined)) == .bluetoothPrivacy, "unconfirmed Bluetooth maps to privacy")
        expect(NativeSettingsDestination.notifications.manualInstructions.contains("select Cellio"), "Notifications instructions identify Cellio")

        // Controller chooses current fact, dispatches through protocol existential, and preserves the legacy bridge.
        do {
            let (c, a, _) = controller(.init(access: .allowed, radio: .poweredOff)); c.act(.bluetooth)
            expect(a.destinations.count == 1 && a.destinations[0] == .bluetoothRadio, "controller sends mapped destination through adapter existential")
            expect(!c.canAct(.bluetooth) && c.row(.bluetooth).phase == .waiting, "one opening operation is pending")
            c.act(.bluetooth); expect(a.destinations.count == 1, "repeated activation is coalesced")
            a.completions[0](true); expect(!c.row(.bluetooth).openFailed, "accepted opening is not failure")
        }
        do {
            let a = LegacyOnlyAdapter(); let old: NativePermissionAdapter = a
            old.openSettings(.notifications, isCurrent: { true }, completion: { _ in })
            expect(a.legacyCalls == 1, "legacy-only adapter remains compatible via default bridge")
        }

        let routes: [(NativeSettingsDestination, String)] = [
            (.inputMonitoring, "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent"),
            (.notifications, "x-apple.systempreferences:com.apple.Notifications-Settings.extension"),
            (.bluetoothPrivacy, "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Bluetooth"),
            (.bluetoothRadio, "x-apple.systempreferences:com.apple.BluetoothSettings")]
        // Actual production Mac adapter dispatch with injectable OS and workspace only.
        for major in [26, 27] {
            for (destination, expected) in routes {
                let w = FakeWorkspace(); let m = MacNativePermissionAdapter(notifications: FakeNotifications(), gate: NativePermissionRequestGate(), workspace: w, majorVersion: { major })
                let adapter: NativePermissionAdapter = m
                adapter.openSettings(destination, isCurrent: { true }, completion: { _ in })
                expect(w.targets.map(\.absoluteString) == [expected] && w.genericOpens == 0, "OS \(major) exact target route \(destination)")
            }
        }
        for major in [13, 25, 28, 99] {
            let w = FakeWorkspace(); let m = MacNativePermissionAdapter(notifications: FakeNotifications(), gate: NativePermissionRequestGate(), workspace: w, majorVersion: { major })
            let adapter: NativePermissionAdapter = m
            adapter.openSettings(.notifications, isCurrent: { true }, completion: { _ in })
            expect(w.targets.isEmpty && w.genericOpens == 1, "OS \(major) uses generic launch")
        }
        do {
            let w = FakeWorkspace(); let m = MacNativePermissionAdapter(notifications: FakeNotifications(), gate: NativePermissionRequestGate(), workspace: w, majorVersion: { 26 })
            let adapter: NativePermissionAdapter = m
            var results: [Bool] = []; adapter.openSettings(.inputMonitoring, isCurrent: { true }) { results.append($0) }
            w.finishTarget(accepted: true); expect(w.genericOpens == 0 && results == [true], "accepted target has no fallback")
        }
        do {
            let w = FakeWorkspace(); let m = MacNativePermissionAdapter(notifications: FakeNotifications(), gate: NativePermissionRequestGate(), workspace: w, majorVersion: { 27 })
            let adapter: NativePermissionAdapter = m
            var results: [Bool] = []; adapter.openSettings(.notifications, isCurrent: { true }) { results.append($0) }
            w.finishTarget(error: NSError(domain: "test", code: 1)); expect(w.genericOpens == 1, "explicit target error gets one generic fallback")
            w.finishGeneric(accepted: false); expect(results == [false], "generic failure returns false")
            w.finishTarget(error: NSError(domain: "duplicate", code: 2)); expect(w.genericOpens == 1, "duplicate target callback cannot repeat fallback")
        }
        do {
            let w = FakeWorkspace(); w.app = nil; let m = MacNativePermissionAdapter(notifications: FakeNotifications(), gate: NativePermissionRequestGate(), workspace: w, majorVersion: { 26 })
            let adapter: NativePermissionAdapter = m
            var result: [Bool] = []; adapter.openSettings(.notifications, isCurrent: { true }) { result.append($0) }
            expect(w.targets.isEmpty && w.genericOpens == 0 && result == [false], "missing Settings app resolves failure without dispatch")
        }
        do {
            let w = FakeWorkspace(); let m = MacNativePermissionAdapter(notifications: FakeNotifications(), gate: NativePermissionRequestGate(), workspace: w, majorVersion: { 26 })
            let adapter: NativePermissionAdapter = m
            var live = true; adapter.openSettings(.notifications, isCurrent: { live }, completion: { _ in }); live = false
            w.finishTarget(error: NSError(domain: "late", code: 1)); expect(w.genericOpens == 0, "invalidated late target error cannot launch generic fallback")
        }
        do {
            let w = FakeWorkspace(); let m = MacNativePermissionAdapter(notifications: FakeNotifications(), gate: NativePermissionRequestGate(), workspace: w, majorVersion: { 26 })
            let adapter: NativePermissionAdapter = m
            var result: [Bool] = []; adapter.openSettings(.notifications, isCurrent: { true }) { result.append($0) }
            w.finishTarget(accepted: false); expect(result == [false] && w.genericOpens == 0, "target without explicit error reports rejection without fallback")
        }

        // Controller timeout and invalidation semantics: exactly one existing 8s timeout and manual retry.
        do {
            let (c, a, s) = controller(.init(access: .denied))
            let priorTimeoutCount = s.jobs.filter { $0.0 == 8 }.count
            c.act(.bluetooth); c.act(.bluetooth)
            let timeoutCount = s.jobs.filter { $0.0 == 8 }.count
            expect(timeoutCount == priorTimeoutCount + 1, "activation adds exactly one existing 8 second opening timeout")
            s.run(8); expect(a.destinations.count == 1 && c.row(.bluetooth).openFailed && c.canAct(.bluetooth), "timeout fails visibly and restores retry")
            c.act(.bluetooth); expect(a.destinations.count == 2, "retry is user initiated")
        }
        for invalidate in ["refresh", "explicit", "replacement"] {
            let (c, a, _) = controller(.init(access: .denied)); c.act(.bluetooth)
            if invalidate == "refresh" { c.refresh() }
            if invalidate == "explicit" { c.invalidateSettingsOpening() }
            if invalidate == "replacement" { c.invalidateSettingsOpening(); c.act(.bluetooth) }
            let before = a.destinations.count
            a.completions[0](false)
            expect(a.destinations.count == before && !c.row(.bluetooth).openFailed, "\(invalidate) invalidation ignores late old completion")
        }
        do {
            let (c, a, _) = controller(.init(access: .denied)); c.act(.bluetooth); c.invalidateSettingsOpening()
            a.facts[.inputMonitoring] = .init(access: .denied); c.refresh(); c.act(.inputMonitoring)
            a.completions[0](true)
            expect(c.row(.inputMonitoring).phase == .waiting && !c.row(.inputMonitoring).openFailed, "late success cannot overwrite newer feedback")
            expect(c.row(.inputMonitoring).fact == .init(access: .denied), "navigation leaves permission facts unchanged")
        }
        do {
            let (c, a, _) = controller(.init(access: .denied)); c.act(.bluetooth); a.completions[0](false)
            expect(c.row(.bluetooth).openFailed && c.row(.bluetooth).help(for: .bluetooth).contains("Apple menu") && c.row(.bluetooth).help(for: .bluetooth).contains("Privacy & Security → Bluetooth"), "failure keeps conservative and contextual manual help")
            expect(c.row(.bluetooth).help(for: .bluetooth).contains("Allow Cellio"), "Bluetooth manual help identifies Cellio")
        }
        do {
            let (c, _, _) = controller(.init(access: .denied), kind: .notifications)
            expect(c.row(.notifications).help(for: .notifications).contains("select Cellio"), "notification manual help tells owner to select Cellio")
        }

        print("NAVIGATION_ASSERTIONS count=\(count) failed=\(failures.count)")
        if !failures.isEmpty { exit(1) }
    }
}
