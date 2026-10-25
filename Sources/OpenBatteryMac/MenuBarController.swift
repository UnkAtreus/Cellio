import Foundation
import Combine
import OpenBatteryCore

/// Settings transactions and selection share one owner. Navigation/cancel/new edits revoke Retry.
@MainActor final class MenuBarController: ObservableObject {
    let store: MenuBarConfigurationStore
    @Published private(set) var revision=0
    @Published private(set) var issue: String?
    @Published private(set) var selection: String?
    @Published private(set) var adding=false
    @Published private(set) var addDevice=""
    @Published private(set) var addComponent=""
    @Published var availableLayout=MenuBarLayout.project([],budget:nil)
    private struct Attempt {
        let token: UUID
        let next: MenuBarConfiguration
        let selection: String?
        let adding: Bool
        let reset: Bool
        let addedPin: MenuBarPin?
    }
    private var pending: Attempt?
    private var generation=UUID()
    var configuration: MenuBarConfiguration { store.configuration }
    var unavailable: Bool { store.unavailable }
    var canRetry: Bool { pending?.token == generation }
    init(persistence: MenuBarPersistence = MemoryMenuBarPersistence()) { store=MenuBarConfigurationStore(persistence:persistence) }
    func revokePending() { generation=UUID(); pending=nil; issue=nil }
    func leavePage() { revokePending(); adding=false; addDevice=""; addComponent="" }
    func select(_ id: String?) { revokePending(); selection=id }
    func beginAdd() { revokePending(); guard !unavailable, configuration.pins.count < 3 else { return }; addDevice=""; addComponent=""; adding=true }
    func cancelAdd() { revokePending(); adding=false; addDevice=""; addComponent="" }
    func chooseDevice(_ id: String, settings: DeviceSettingsStore) {
        revokePending(); addDevice=id; addComponent=""
        if let device=settings.devices.first(where: { $0.id == id }), device.knownComponentIDs.count == 1 { addComponent=device.knownComponentIDs[0] }
    }
    func chooseComponent(_ id: String) { revokePending(); addComponent=id }
    func isPinned(device: KnownBatteryDevice, component: String, settings: DeviceSettingsStore) -> Bool {
        MenuBarPinPolicy.resolve(configuration,settings:settings).contains {
            $0.pin.componentID == component && ($0.logicalID == device.id || $0.pin.deviceID == device.id)
        }
    }
    func canAdd(settings: DeviceSettingsStore) -> Bool {
        guard adding, !unavailable, !settings.updatesBlocked, configuration.pins.count < 3,
              let device=settings.devices.first(where: { $0.id == addDevice }), device.knownComponentIDs.contains(addComponent) else { return false }
        return !isPinned(device:device,component:addComponent,settings:settings)
    }
    func add(settings: DeviceSettingsStore) {
        revokePending()
        guard canAdd(settings:settings), let device=settings.devices.first(where: { $0.id == addDevice }),
              let pin=try? MenuBarPinPolicy.makePin(device:device,component:addComponent,settings:settings) else { return }
        var next=configuration; next.pins.append(pin)
        apply(next,selection:pin.id,adding:true,addedPin:pin)
    }
    func remove() {
        revokePending(); guard let selection else { return }
        var next=configuration; next.pins.removeAll { $0.id == selection }
        apply(next,selection:nil)
    }
    func canMove(_ offset: Int) -> Bool {
        guard let index=configuration.pins.firstIndex(where: { $0.id == selection }) else { return false }
        return configuration.pins.indices.contains(index+offset)
    }
    func move(_ offset: Int) {
        revokePending(); guard canMove(offset), let index=configuration.pins.firstIndex(where: { $0.id == selection }) else { return }
        var next=configuration; next.pins.swapAt(index,index+offset); apply(next,selection:selection)
    }
    func setDisplay(_ value: MenuBarDisplay) { revokePending(); var next=configuration; next.display=value; apply(next,selection:selection) }
    func setSeparator(_ value: MenuBarSeparator) { revokePending(); var next=configuration; next.separator=value; apply(next,selection:selection) }
    func reload() { revokePending(); _=store.reload(); revision &+= 1 }
    func reset() { revokePending(); guard unavailable else { return }; apply(MenuBarConfiguration(),selection:nil,reset:true) }
    func retry(settings: DeviceSettingsStore) {
        guard let attempt=pending, attempt.token == generation else { return }
        if let pin=attempt.addedPin {
            guard adding, addDevice == pin.deviceID, addComponent == pin.componentID,
                  let device=settings.devices.first(where: { $0.id == pin.deviceID }),
                  let current=try? MenuBarPinPolicy.makePin(device:device,component:pin.componentID,settings:settings),
                  current.sourceMembers == pin.sourceMembers else { revokePending(); return }
        }
        perform(attempt)
    }
    private func apply(_ next: MenuBarConfiguration, selection: String?, adding: Bool = false, reset: Bool = false, addedPin: MenuBarPin? = nil) {
        let attempt=Attempt(token:generation,next:next,selection:selection,adding:adding,reset:reset,addedPin:addedPin)
        perform(attempt)
    }
    private func perform(_ attempt: Attempt) {
        guard attempt.token == generation else { return }
        do {
            try store.commit(attempt.next,resetting:attempt.reset)
            selection=attempt.selection
            if attempt.adding { adding=false; addDevice=""; addComponent="" }
            pending=nil; issue=nil; revision &+= 1
        } catch {
            pending=attempt
            issue="Couldn’t save menu bar changes. Your previous layout is still in use."
            revision &+= 1
        }
    }
}

/// Pure presentation of one exact component. No acquisition, notifications, or timestamp mutation.
struct MenuBarPinContent {
    let resolved: MenuBarResolvedPin
    let device: BatteryMenuDevicePresentation
    let status: MenuDeviceStatus
    let quantity: Quantity
    let text: String
    let gauge: Int?
    let approximate: Bool
    let markers: [String]
    let help: String
    init(_ resolved: MenuBarResolvedPin, records: [BatteryRecord], settings: DeviceSettingsStore, at now: Date) {
        self.resolved=resolved
        let device=MenuBarPinPolicy.presentation(resolved,records:records,at:now)
        self.device=device
        let status=MenuDeviceStatus.evaluate(device,monitoring:settings.preferences(for:device.id).monitorBattery,updatesBlocked:settings.updatesBlocked,at:now)
        self.status=status
        let record=device.components.first?.reading?.record
        let quantity=record?.observation.quantity ?? .absent
        self.quantity=quantity
        switch quantity {
        case .reportedPercent(let value): text="\(value)%"; gauge=(0...100).contains(value) ? value:nil; approximate=false
        case .estimatedPercent(let value,_): text="≈\(value)%"; gauge=(0...100).contains(value) ? value:nil; approximate=true
        case .coarse(let name,_): text=name.isEmpty ? "Level":name; gauge=nil; approximate=false
        case .unknown, .absent: text="—"; gauge=nil; approximate=false
        }
        let paused = !settings.preferences(for:device.id).monitorBattery || settings.updatesBlocked
        let error=record.map { $0.error != nil || $0.observation.error != nil || $0.observation.charge.isError } ?? false
        var markers: [String]=[]
        if error { markers.append("exclamationmark.triangle") }
        if paused { markers.append("pause.fill") }
        else if status.label == "Last known" { markers.append("clock") }
        if markers.count < 2, let charge=record?.observation.charge {
            if [.charging,.finalStage,.slowCharging].contains(charge) { markers.append("bolt.fill") }
            else if charge == .complete { markers.append("checkmark") }
        }
        self.markers=Array(markers.prefix(2))
        let identity=device.name+", "+KnownBatteryDevice.componentName(resolved.pin.componentID)
        let context: String
        switch resolved.state {
        case .hidden: context="Hidden device · Pin kept"
        case .review: context="Review device"
        case .coalesced: context="Same battery reading · Earlier pin displayed"
        default: context=status.summary.replacingOccurrences(of:"\n",with:" · ")
        }
        var details=context.components(separatedBy:" · ")
        if let reading=device.components.first?.reading {
            // Reuse the existing concise status, adding each connection/charge fact once.
            if !details.contains(reading.connection) { details.append(reading.connection) }
            let charge=reading.record.observation.charge
            if charge != .unknown, !details.contains(where: { $0.lowercased().hasSuffix(reading.charge.lowercased()) }) {
                details.append(reading.charge)
            }
            // Error/blocked summaries can omit age. Preserve the original authoritative
            // source clock here too, without repeating an age already in the summary.
            if quantity.isKnown, !details.contains(where: { $0.hasPrefix("Reading ") || $0.hasPrefix("Oldest reading ") }) {
                let observation=reading.record.observation
                let date=[BatterySource.systemReport,.watchCompanion].contains(observation.source) ? observation.measuredAt:observation.observedAt
                if let date, now.timeIntervalSince(date).isFinite, now.timeIntervalSince(date) >= 0 {
                    let seconds=now.timeIntervalSince(date)
                    let elapsed: String
                    if seconds < 60 { elapsed="under 1m" }
                    else if seconds < 3600 { elapsed="\(Int(seconds/60))m" }
                    else if seconds < 86400 { elapsed="\(Int(seconds/3600))h" }
                    else { elapsed=String(format:"%.0f",locale:Locale(identifier:"en_US_POSIX"),floor(seconds/86400))+"d" }
                    details.append("Reading \(elapsed) ago")
                } else { details.append("Reading age unknown") }
            }
        }
        help=identity+": "+quantity.display+" · "+details.joined(separator:" · ")
    }
    var discriminator: String {
        switch resolved.pin.componentID {
        case "battery": return ""
        case "left": return "L"
        case "right": return "R"
        case "case": return "Case"
        default: return String(KnownBatteryDevice.componentName(resolved.pin.componentID).prefix(2))
        }
    }
}
