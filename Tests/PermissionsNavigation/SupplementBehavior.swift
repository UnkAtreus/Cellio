import Foundation
extension NativeSettingsDestination: Equatable {}

@MainActor final class SupplementScheduler: NativePermissionScheduling {
    var jobs: [(TimeInterval, @MainActor () -> Void)] = []
    func after(_ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) { jobs.append((seconds, work)) }
    func run(_ seconds: TimeInterval) { let due = jobs.filter { $0.0 <= seconds }; jobs.removeAll { $0.0 <= seconds }; due.forEach { $0.1() } }
}
@MainActor final class InjectingAdapter: NativePermissionAdapter {
    let production: NativePermissionAdapter
    var facts: [NativePermissionKind: NativePermissionFact]
    init(_ production: NativePermissionAdapter, _ facts: [NativePermissionKind: NativePermissionFact]) { self.production = production; self.facts = facts }
    func inspect(_ kind: NativePermissionKind, completion: @escaping @MainActor (NativePermissionFact?) -> Void) { completion(facts[kind]) }
    func request(_ kind: NativePermissionKind, completion: @escaping @MainActor () -> Void) { completion() }
    func openSettings(completion: @escaping @MainActor (Bool) -> Void) { production.openSettings(completion: completion) }
    func openSettings(_ destination: NativeSettingsDestination, isCurrent: @escaping @MainActor () -> Bool, completion: @escaping @MainActor (Bool) -> Void) {
        production.openSettings(destination, isCurrent: isCurrent, completion: completion)
    }
}
@MainActor var supplementCount = 0
@MainActor var supplementFailures: [String] = []
@MainActor func check(_ condition: @autoclosure () -> Bool, _ label: String) { supplementCount += 1; if !condition() { supplementFailures.append(label); print("FAIL: \(label)") } }
@MainActor func makeController(_ kind: NativePermissionKind, fact: NativePermissionFact, workspace: FakeWorkspace, scheduler: SupplementScheduler) -> (NativePermissionsController, InjectingAdapter) {
    let native: NativePermissionAdapter = MacNativePermissionAdapter(notifications: FakeNotifications(), gate: NativePermissionRequestGate(scheduler: scheduler), workspace: workspace, majorVersion: { 26 })
    let facts = Dictionary(uniqueKeysWithValues: NativePermissionKind.allCases.map { ($0, NativePermissionFact(access: .allowed, radio: .poweredOn)) })
    var overridden = facts; overridden[kind] = fact
    let injected = InjectingAdapter(native, overridden)
    let controller = NativePermissionsController(adapter: injected, gate: NativePermissionRequestGate(scheduler: scheduler), scheduler: scheduler)
    controller.refresh()
    return (controller, injected)
}
@main struct SupplementBehavior {
 @MainActor static func main() {
  let cases: [(NativePermissionKind, NativePermissionFact, String, String)] = [
   (.bluetooth, .init(access: .denied, radio: .poweredOff), "bluetoothPrivacy", "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Bluetooth"),
   (.bluetooth, .init(access: .allowed, radio: .poweredOff), "bluetoothRadio", "x-apple.systempreferences:com.apple.BluetoothSettings"),
   (.inputMonitoring, .init(access: .denied), "inputMonitoring", "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent"),
   (.notifications, .init(access: .denied), "notifications", "x-apple.systempreferences:com.apple.Notifications-Settings.extension"),
   (.notifications, .init(access: .alertsOff), "notifications", "x-apple.systempreferences:com.apple.Notifications-Settings.extension"),
   (.notifications, .init(access: .limited), "notifications", "x-apple.systempreferences:com.apple.Notifications-Settings.extension"),
   (.inputMonitoring, .init(access: .denied), "inputMonitoring", "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent")
  ]
  for (kind, fact, destName, route) in cases {
   let w = FakeWorkspace(); let s = SupplementScheduler(); let (c, _) = makeController(kind, fact: fact, workspace: w, scheduler: s)
   c.act(kind)
   check(w.targets.map(\.absoluteString) == [route] && w.genericOpens == 0, "controller \(kind) \(fact.access) opens exact \(destName) route")
   check(c.row(kind).fact == fact && c.row(kind).phase == .waiting, "opening preserves injected facts and waits \(kind) \(fact.access)")
  }
  // Unconfirmed input after an explicit attempt maps to Settings; an allow press itself only requests.
  do { let w = FakeWorkspace(); let s = SupplementScheduler(); let (c, _) = makeController(.inputMonitoring, fact: .init(access: .notDetermined), workspace: w, scheduler: s); c.act(.inputMonitoring); check(w.targets.isEmpty, "first input action requests without navigating"); s.run(50); c.refresh(); c.act(.inputMonitoring); check(w.targets.count == 1 && w.targets[0].absoluteString.contains("Privacy_ListenEvent"), "unconfirmed input after explicit attempt opens Input Monitoring") }
  // Controller ticket: production adapter's target callback remains held across timeout and all invalidation paths.
  for mode in ["timeout", "refresh", "disappear", "replacement"] {
   let w = FakeWorkspace(); let s = SupplementScheduler(); let (c, _) = makeController(.notifications, fact: .init(access: .denied), workspace: w, scheduler: s); c.act(.notifications)
   if mode == "timeout" { s.run(8) }
   if mode == "refresh" { c.refresh() }
   if mode == "disappear" { c.invalidateSettingsOpening() }
   if mode == "replacement" { c.invalidateSettingsOpening(); c.act(.notifications) }
   let before = w.genericOpens
   w.finishTarget(0, error: NSError(domain: "late target", code: 9))
   check(w.genericOpens == before, "late target error after (mode) causes zero generic dispatch")
  }
  // Newer operation reaches failure before old successful callback arrives.
  do {
   let facts = Dictionary(uniqueKeysWithValues: NativePermissionKind.allCases.map { ($0, NativePermissionFact(access: .allowed, radio: .poweredOn)) })
   let w = FakeWorkspace(); let s = SupplementScheduler(); let native: NativePermissionAdapter = MacNativePermissionAdapter(notifications: FakeNotifications(), gate: NativePermissionRequestGate(scheduler: s), workspace: w, majorVersion: { 26 })
   let injected = InjectingAdapter(native, facts.merging([.bluetooth: .init(access: .denied)]) { _, n in n })
   let c = NativePermissionsController(adapter: injected, gate: NativePermissionRequestGate(scheduler: s), scheduler: s); c.refresh(); c.act(.bluetooth); c.invalidateSettingsOpening(); c.act(.bluetooth)
   s.run(8); check(c.row(.bluetooth).openFailed && c.row(.bluetooth).phase == .idle, "newer opening reaches openFailed state")
   let factsBefore = c.row(.bluetooth).fact; w.finishTarget(0, accepted: true)
   check(c.row(.bluetooth).openFailed && c.row(.bluetooth).fact == factsBefore, "old success cannot clear newer failure or alter permission facts")
  }
  print("SUPPLEMENT_ASSERTIONS count=\(supplementCount) failed=\(supplementFailures.count)"); if !supplementFailures.isEmpty { exit(1) }
 }
}
