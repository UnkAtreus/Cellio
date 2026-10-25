import Foundation
import AppKit
import SystemConfiguration
import Security
import OpenBatteryCore

// Inspect only this process's signing metadata; startup must not access Keychain.
enum WatchStartupSigning {
    static var permitsAutomaticResume:Bool {
        var code:SecCode?
        guard SecCodeCopySelf([], &code)==errSecSuccess,let code,
              SecCodeCheckValidity(code,[],nil)==errSecSuccess else { return false }
        var staticCode:SecStaticCode?
        guard SecCodeCopyStaticCode(code,[],&staticCode)==errSecSuccess,let staticCode else { return false }
        var information:CFDictionary?
        guard SecCodeCopySigningInformation(staticCode,SecCSFlags(rawValue:kSecCSSigningInformation),&information)==errSecSuccess,
              let information=information as? [String:Any],
              let certificates=information[kSecCodeInfoCertificates as String] as? [SecCertificate],
              !certificates.isEmpty,
              let flags=information[kSecCodeInfoFlags as String] as? NSNumber else { return false }
        return flags.uint32Value & SecCodeSignatureFlags.adhoc.rawValue==0
    }
}

struct DeviceVisibilityRequest: Equatable {
    let token=UUID()
    let snapshot: DeviceVisibilitySnapshot
    let hidden: Bool
}

@MainActor final class AppModel:ObservableObject {
    @Published var reducer=BatteryReducer()
    @Published var statuses:[String:String]=[:]
    @Published var listenerEnabled=false
    @Published var listenerStatus="Watch sharing is off."
    @Published var revealed:PairingCredentials?
    @Published var refreshing=false
    let report=SystemReportProvider(); let hid=HIDProvider(); lazy var watch=WatchListener()
    let deviceSettings:DeviceSettingsStore
    let menuBar:MenuBarController
    // Installed by the GUI host; inert native probes and CLI never create a Bluetooth manager.
    var bluetoothBattery:StandardBluetoothBatteryProviding?
    @Published var bluetoothPresentation:BluetoothBatteryPresentationState?
    @Published private(set) var settingsChange=0
    private var timer:Timer?; private var refreshTimer:Timer?
    private var previousReportDevices=Set<String>()
    private var watchDelivery=WatchDeliveryOwnership()
    private let collectionEnabled:Bool
    private let clock: BatteryClock
    private var refreshPending=false
    private let physicalSelector=PhysicalBatterySelector()
    // Also fail closed during this process if persisting a new conflict fails.
    private var identityQuarantine=Set<String>()
    var connectionAlertConfiguration: (() -> AlertConfiguration?)?
    var prepareConnectionChange: (([String],[String]) -> Bool)?
    var retryConnectionAlertStorage: (() -> Void)?
    var visibilityPolicyDidChange: (() -> Void)?
    var didCommitVisibilityChange: (() -> Void)?
    var prepareVisibilityChange: (([String], Bool) -> Bool)?
    @Published private(set) var visibilityRequest: DeviceVisibilityRequest?
    @Published private(set) var visibilityIssue: String?
    private var committingVisibility=false
    var didCommitConnectionChange: (() -> Void)?
    @Published private(set) var connectionIssue: String?
    private(set) var routeConnections: [String:ConnectionState] = [:]
    var physicalProjection: PhysicalBatteryProjection {
        var catalog=deviceSettings.physicalCatalog
        for index in catalog.routes.indices where identityQuarantine.contains(catalog.routes[index].id) { catalog.routes[index].identityConflict=true }
        return physicalSelector.project(records:rawRecords.filter { !deviceSettings.isHidden($0.observation.id.device) },devices:knownDevices,catalog:catalog,now:clock.now(),connections:routeConnections)
    }
    func resolveMenuBarPins(_ configuration: MenuBarConfiguration) -> [MenuBarResolvedPin] {
        MenuBarPinPolicy.resolve(configuration,settings:deviceSettings,quarantinedRoutes:identityQuarantine)
    }
    var rawRecords: [BatteryRecord] { reducer.records.values.filter { !deviceSettings.isArchivedAlias($0.observation.id.device) }.sorted { ($0.observation.id.device,$0.observation.id.component) < ($1.observation.id.device,$1.observation.id.component) } }
    func connectionLabel(for device: String) -> String { physicalProjection.routeLabels[device] ?? "Connection unknown" }
    func connectionSummary(for device: String, at now: Date) -> String {
        let projection=physicalProjection
        let records=projection.records.filter { $0.observation.id.device == device }
        var label=projection.routeLabels[device] ?? "Connection unknown"
        if records.contains(where: { $0.observation.quantity.isKnown && ($0.retained || $0.isStale(at:now)) }), !label.contains("Last known") { label += " · Last known" }
        let ages=records.filter { $0.observation.quantity.isKnown }.map { record -> String in
            let origin=projection.origins[record.observation.id]
            let type=deviceSettings.physicalCatalog.routes.first { $0.id == origin }?.metadata.type.label ?? BatteryRouteType.unknown.label
            let from=record.retained || record.isStale(at:now) ? "From \(type) · ":""
            return from+record.ageDescription(at:now)
        }
        return label+"\n"+(ages.isEmpty ? "No reading":Array(Set(ages)).sorted().joined(separator:" · "))
    }
    func previewConnections(current: String, selected: [String]) throws -> ConnectionLinkPreview {
        guard let config=connectionAlertConfiguration?() else { throw ConnectionGroupingError.unavailable }
        return try deviceSettings.previewLink(current:current,selected:selected,alerts:config)
    }
    @discardableResult func linkConnections(_ preview: ConnectionLinkPreview) -> Bool {
        guard !committingVisibility, visibilityRequest == nil || preview.automaticallyVerified else { return false }
        do {
            guard let config=connectionAlertConfiguration?(), let prepare=prepareConnectionChange else { throw ConnectionGroupingError.unavailable }
            // Samples do not invalidate confirmation; changed membership/settings do.
            if preview.automaticallyVerified {
                // Proved grouping includes hidden participants; manual candidates deliberately exclude them.
                guard deviceSettings.automaticLinkCandidate(alerts:config) == preview else { throw ConnectionGroupingError.changed }
            } else {
                guard try deviceSettings.previewLink(current:preview.current,selected:preview.selected,alerts:config) == preview else { throw ConnectionGroupingError.changed }
            }
            guard prepare(preview.members+[preview.current]+preview.selected,preview.members+[preview.current]) else { throw ConnectionGroupingError.unavailable }
            try deviceSettings.commitLink(preview,alerts:config)
            didCommitConnectionChange?()
            connectionIssue=nil; settingsChange &+= 1; return true
        } catch { connectionIssue=error.localizedDescription; settingsChange &+= 1; return false }
    }
    @discardableResult func unlinkConnection(member: String, from device: String) -> Bool {
        guard visibilityRequest == nil, !committingVisibility else { return false }
        do {
            let members=deviceSettings.members(of:device)
            let detached="physical-"+UUID().uuidString.lowercased()
            guard members.count > 1, members.contains(member), let prepare=prepareConnectionChange,
                  prepare(members+[device],members+[device,detached]) else { throw ConnectionGroupingError.unavailable }
            _ = try deviceSettings.unlink(member:member,from:device,newID:detached)
            didCommitConnectionChange?()
            connectionIssue=nil; settingsChange &+= 1; return true
        } catch { connectionIssue=error.localizedDescription; settingsChange &+= 1; return false }
    }
    func reconcileVerifiedConnections() {
        guard let configuration=connectionAlertConfiguration?() else { return }
        while let preview=deviceSettings.automaticLinkCandidate(alerts:deviceSettings.alertConfiguration(over:configuration)) {
            if !linkConnections(preview) { break }
        }
    }
    init(start:Bool=true,settings:DeviceSettingsStore?=nil,clock:BatteryClock=SystemBatteryClock(),menuBarPersistence:MenuBarPersistence?=nil) {
        self.clock=clock
        collectionEnabled=start
        let store:DeviceSettingsStore
        if let settings { store=settings }
        else if start {
            do { store=try DeviceSettingsStore.processStore(arguments:CommandLine.arguments) }
            catch { store=DeviceSettingsStore(persistence:MemoryDeviceSettingsPersistence(data:Data())) }
        } else { store=DeviceSettingsStore() }
        deviceSettings=store
        if let menuBarPersistence { menuBar=MenuBarController(persistence:menuBarPersistence) }
        else if start && settings == nil {
            do { menuBar=MenuBarController(persistence:try DefaultsMenuBarPersistence.process(arguments:CommandLine.arguments)) }
            catch { menuBar=MenuBarController(persistence:MemoryMenuBarPersistence(data:Data())) }
        } else { menuBar=MenuBarController() }
        ((hid as Any) as? DevicePolicyProvider)?.useDeviceSettings(store)
        hid.completion={ [weak self] batch in
            let context=((batch as Any) as? DevicePolicyBatchContext)?.devicePolicyContext ?? store.context()
            Task { @MainActor in self?.receive(batch,context:context) }
        }
        if start {
            let context=store.context()
            for item in watch.history { accept(item.sample.observation(collectedAt:item.receivedAt),context:context,now:clock.now()) }
            hid.start(); refresh()
            timer=Timer.scheduledTimer(withTimeInterval:60,repeats:true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
            // Watch setup is deferred. Keep saved sharing preferences and history,
            // but never resume the listener or access pairing Keychain at launch.
        }
    }
    var sortedRecords:[BatteryRecord] { physicalProjection.records }
    var menuRecords:[BatteryRecord] { sortedRecords.filter { deviceSettings.showsComponent($0.observation.id.component,for:$0.observation.id.device) } }
    var knownDevices:[KnownBatteryDevice] { deviceSettings.devices }
    private func accept(_ observation:Observation,context:DeviceCollectionContext,now:Date) {
        deviceSettings.discover(id:observation.id.device,name:observation.name,source:observation.source,componentIDs:[observation.id.component],kind:observation.route?.kind)
        if let route=observation.route { deviceSettings.rememberRoute(SavedBatteryRoute(id:observation.id.device,metadata:route)) }
        visibilityPolicyDidChange?()
        guard deviceSettings.accepts(observation.id.device,from:context) else { return }
        guard !isIdentityQuarantined(observation.id.device) else {
            routeConnections[observation.id.device] = .unavailable
            reducer.disconnect(device:observation.id.device,at:now)
            for id in Array(reducer.records.keys) where id.device == observation.id.device { reducer.fail(id:id,at:now,message:"Physical identity conflict; route readings quarantined") }
            return
        }
        routeConnections[observation.id.device]=observation.connection
        if observation.connection == .disconnected { reducer.disconnect(device:observation.id.device,at:now) }
        reducer.apply(observation,now:now)
    }
    func receive(_ batch:ProviderBatch,context:DeviceCollectionContext?=nil) {
        let context=context ?? ((batch as Any) as? DevicePolicyBatchContext)?.devicePolicyContext ?? deviceSettings.context()
        let now=clock.now()
        // Establish identity conflicts before any new quantity can enter the reducer/projection.
        for observation in batch.observations {
            deviceSettings.discover(id:observation.id.device,name:observation.name,source:observation.source,componentIDs:[observation.id.component],kind:observation.route?.kind)
        }
        for route in batch.routes {
            let old=deviceSettings.physicalCatalog.routes.first { $0.id == route.id }
            if route.identityConflict || old?.identityConflict == true || (route.identity != nil && old?.identity != nil && route.identity?.key != old?.identity?.key) { identityQuarantine.insert(route.id) }
            deviceSettings.rememberRoute(route)
        }
        visibilityPolicyDidChange?()
        reconcileVerifiedConnections()
        for (key,value) in batch.status {
            if key.hasPrefix("removed:") {
                let receiver=String(key.dropFirst(8))
                guard !deviceSettings.isArchivedAlias(receiver) else { continue }
                let devices=Set((reducer.records.keys.map(\.device)+deviceSettings.rawDevices.map(\.id)).filter { $0==receiver || $0.hasPrefix(receiver+"-") })
                for device in devices where deviceSettings.accepts(device,from:context) { routeConnections[device] = .disconnected; reducer.disconnect(device:device,at:now) }
            } else { statuses[key]=value }
        }
        for observation in batch.observations { accept(observation,context:context,now:now) }
        for (device,message) in batch.failures {
            guard !deviceSettings.isArchivedAlias(device) else { continue }
            let reportScope = device == "systemReport" || device == "accessory-power"
            for record in reducer.records.values where reportScope
                ? record.observation.source == .systemReport && record.observation.id.device.hasPrefix("accessory-power-") == (device == "accessory-power")
                : record.observation.id.device==device || record.observation.id.device.hasPrefix(device+"-") {
                if deviceSettings.accepts(record.observation.id.device,from:context) { reducer.fail(id:record.observation.id,at:now,message:message) }
            }
        }
        for scope in ["systemReport","accessory-power"] {
            // Original callers historically use status-without-failure for success.
            // Preserve that meaning only for the original report partition. The
            // new source requires explicit success, including a successful empty stream.
            let succeeded = batch.successfulSources.contains(scope) || (scope == "systemReport" && batch.status[scope] != nil)
            guard succeeded, batch.failures[scope] == nil else { continue }
            let accessory = scope == "accessory-power"
            func inScope(_ id:String) -> Bool { id.hasPrefix("accessory-power-") == accessory }
            let devices=Set(batch.observations.filter { $0.source == .systemReport && inScope($0.id.device) }.map { $0.id.device })
            let retained=Set(rawRecords.filter { $0.observation.source == .systemReport && inScope($0.observation.id.device) }.map { $0.observation.id.device })
            // Metadata survives restart even when production does not persist readings.
            let known=Set(deviceSettings.rawDevices.filter { $0.source == .systemReport && inScope($0.id) }.map(\.id))
            let previous=Set(previousReportDevices.filter(inScope))
            for device in previous.union(retained).union(known).subtracting(devices) where deviceSettings.accepts(device,from:context) {
                routeConnections[device] = isIdentityQuarantined(device) ? .unavailable:.disconnected
                reducer.disconnect(device:device,at:now)
            }
            previousReportDevices.subtract(previous)
            previousReportDevices.formUnion(devices)
        }
        for (id,state) in batch.connections where deviceSettings.accepts(id,from:context) { routeConnections[id]=isIdentityQuarantined(id) ? .unavailable:state }
        reconcileVerifiedConnections()
        settingsChange &+= 1
    }
    private func isIdentityQuarantined(_ id: String) -> Bool {
        identityQuarantine.contains(id) || deviceSettings.physicalCatalog.routes.contains { $0.id == id && $0.identityConflict }
    }
    @discardableResult func beginVisibilityChange(for device: String, hidden: Bool, expected: DeviceVisibilitySnapshot? = nil) -> DeviceVisibilityRequest? {
        guard visibilityRequest == nil, !committingVisibility, !deviceSettings.updatesBlocked else { return nil }
        do {
            let snapshot=try deviceSettings.visibilitySnapshot(for:device)
            if let expected, expected != snapshot { throw DeviceVisibilityError.changed }
            guard snapshot.hidden != hidden else { return nil }
            let request=DeviceVisibilityRequest(snapshot:snapshot,hidden:hidden)
            visibilityIssue=nil; visibilityRequest=request
            return request
        } catch { visibilityIssue=error.localizedDescription; return nil }
    }
    func cancelVisibilityChange(_ request: DeviceVisibilityRequest? = nil) {
        guard !committingVisibility, request == nil || visibilityRequest == request else { return }
        visibilityRequest=nil
    }
    @discardableResult func commitVisibilityChange(_ request: DeviceVisibilityRequest) -> Bool {
        guard !committingVisibility, visibilityRequest == request else { return false }
        committingVisibility=true
        defer { committingVisibility=false; visibilityRequest=nil; settingsChange &+= 1 }
        do {
            guard !deviceSettings.updatesBlocked else { throw DeviceVisibilityError.unavailable }
            guard try deviceSettings.visibilitySnapshot(for:request.snapshot.id) == request.snapshot else { throw DeviceVisibilityError.changed }
            let ids=request.snapshot.members+[request.snapshot.id]
            guard prepareVisibilityChange?(ids,!request.hidden) ?? true else { throw DeviceVisibilityError.storage }
            try deviceSettings.setHidden(request.hidden,snapshot:request.snapshot)
            didCommitVisibilityChange?()
            visibilityIssue=nil
            if !request.hidden, deviceSettings.preferences(for:request.snapshot.id).monitorBattery, collectionEnabled { refresh() }
            return true
        } catch {
            if let error=error as? DeviceVisibilityError, error == .changed { visibilityIssue=error.localizedDescription }
            else { visibilityIssue=request.hidden ? "Couldn’t hide this device. Your settings are unchanged.":"Couldn’t restore. Try again." }
            return false
        }
    }
    func connectionPreferencesDidChange() { settingsChange &+= 1 }
    func setMonitoring(_ enabled:Bool,for device:String) {
        guard visibilityRequest == nil, !committingVisibility else { return }
        if deviceSettings.preferences(for:device).monitorBattery != enabled {
            let members=deviceSettings.members(of:device)
            _ = prepareConnectionChange?(members+[device],members+[device])
        }
        deviceSettings.setMonitoring(enabled,for:device); settingsChange &+= 1
        if enabled && collectionEnabled { refresh() }
    }
    func setMenuVisibility(_ visible:Bool,for device:String) {
        guard visibilityRequest == nil, !committingVisibility else { return }
        deviceSettings.setMenuVisibility(visible,for:device); settingsChange &+= 1
    }
    func setComponentSelected(_ selected:Bool,component:String,for device:String) {
        guard visibilityRequest == nil, !committingVisibility else { return }
        deviceSettings.setComponentSelected(selected,component:component,for:device); settingsChange &+= 1
    }
    func includeAllComponents(for device:String) {
        guard visibilityRequest == nil, !committingVisibility else { return }
        deviceSettings.includeAllComponents(for:device); settingsChange &+= 1
    }
    func resetDeviceSettings() {
        guard visibilityRequest == nil, !committingVisibility else { return }
        guard deviceSettings.reset() else { settingsChange &+= 1; return }
        for record in rawRecords { let o=record.observation; deviceSettings.discover(id:o.id.device,name:o.name,source:o.source,componentIDs:[o.id.component]) }
        settingsChange &+= 1
        if collectionEnabled { refresh() }
    }
    func retryDeviceSettingsSave() { deviceSettings.retrySave(); settingsChange &+= 1 }
    @discardableResult func retryConnectionStorageSave() -> Bool {
        deviceSettings.retrySave()
        retryConnectionAlertStorage?()
        // Alert recovery includes its baseline save. Check both stores afterwards.
        let recovered = !deviceSettings.updatesBlocked && deviceSettings.issue == nil && connectionAlertConfiguration?() != nil
        connectionIssue = recovered ? nil : (deviceSettings.issue != nil && !deviceSettings.updatesBlocked ? ConnectionGroupingError.storage.localizedDescription : ConnectionGroupingError.unavailable.localizedDescription)
        settingsChange &+= 1
        return recovered
    }
    func refresh() {
        bluetoothBattery?.refresh()
        // Resume during an old collection must request a subsequent ordinary collection.
        if refreshing { refreshPending=true; hid.requestRefresh(); return }
        let context=deviceSettings.context()
        refreshing=true
        report.collect { [weak self] batch in Task { @MainActor in
            guard let self else { return }
            self.receive(batch,context:context); self.refreshing=false
            if self.refreshPending { self.refreshPending=false; self.refresh() }
        } }
        hid.requestRefresh()
    }
    func toggleListener(_ enabled:Bool) {
        // Invalidate before stopping: a Task already queued on the main actor can
        // otherwise restore revoked history, even after an immediate re-enable.
        watchDelivery.invalidate()
        watch.stop()
        listenerEnabled=enabled; UserDefaults.standard.set(enabled,forKey:"watchListenerEnabled"); revealed=nil
        guard enabled else { listenerStatus="Watch sharing is off."; return }
        let generation=watchDelivery.begin()
        let settings=deviceSettings
        listenerStatus="Starting Watch listener…"
        watch.start(onSample:{ [weak self] sample in
            let receivedAt=Date()
            let context=settings.context()
            Task { @MainActor in
                guard let self,self.listenerEnabled,self.watchDelivery.owns(generation) else { return }
                self.accept(sample.observation(collectedAt:receivedAt),context:context,now:Date())
                self.reconcileVerifiedConnections()
                self.settingsChange &+= 1
            }
        },onStatus:{ [weak self] status in
            Task { @MainActor in
                guard let self,self.listenerEnabled,self.watchDelivery.owns(generation) else { return }
                self.listenerStatus=status
            }
        })
    }
    func reveal() {
        guard listenerEnabled else { revealed=nil; return }
        do { revealed=try watch.pairing() } catch { revealed=nil; listenerStatus="Pairing unavailable: \(error)" }
    }
    func revoke() { toggleListener(false); watch.revoke(); revealed=nil; reducer.removeRecords(source:.watchCompanion); listenerStatus="Pairing revoked. Listener stopped." }
    func copyPairing() { guard listenerEnabled,let revealed else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString("Pairing ID: \(revealed.id.uuidString)\nSecret: \(revealed.secret.base64EncodedString())",forType:.string) }
    var endpoint:String {
        guard listenerEnabled else { return "Unavailable — enable sharing" }
        guard let host=SCDynamicStoreCopyLocalHostName(nil) as String?, !host.isEmpty else { return "Hostname unavailable — use your Mac’s local IP and port 58271" }
        return "http://\(host).local:58271"
    }
}
