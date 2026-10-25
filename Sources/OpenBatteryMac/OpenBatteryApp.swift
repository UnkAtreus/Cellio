import SwiftUI
import AppKit
import OpenBatteryCore

@main @MainActor struct OpenBatteryApp {
    static func main() {
        // Snapshot must dispatch before NSApplication, AppModel or appearance setup.
        if CommandLine.arguments.contains("--snapshot") { SnapshotRunner.run(); return }
        do { _ = try DeviceSettingsStore.qaSuite(arguments:CommandLine.arguments) }
        catch { fputs("Usage: cellio --device-settings-suite org.openbattery.qa.<suffix> (letters, digits, hyphen or underscore; start with a letter or digit)\n",stderr); exit(2) }
        let app=NSApplication.shared
        let appearance:AppearancePreferencesController
        do {
            appearance=AppearancePreferencesController(
                persistence:try DefaultsAppearancePreferencesPersistence.process(arguments:CommandLine.arguments),
                appearanceOverride:MenuAppearance.override(arguments:CommandLine.arguments))
        } catch { fputs("Unable to open visual preference suite.\n",stderr); exit(2) }
        appearance.apply(to:app)
        app.setActivationPolicy(.accessory)
        let delegate=AppDelegate(appearance:appearance)
        app.delegate=delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

private enum SettingsSection:String,CaseIterable,Identifiable {
    case general,devices,permissions,notifications,about
    var id:String { rawValue }
    var title:String {
        switch self {
        case .general:return "General"
        case .devices:return "Devices"
        case .permissions:return "Permissions"
        case .notifications:return "Notifications"
        case .about:return "About"
        }
    }
    var symbol:String {
        switch self {
        case .general:return "gearshape"
        case .devices:return "desktopcomputer"
        case .permissions:return "hand.raised"
        case .notifications:return "bell"
        case .about:return "info.circle"
        }
    }
}

private struct HiddenDeviceRow: Identifiable {
    let device: KnownBatteryDevice
    let snapshot: DeviceVisibilitySnapshot
    let savedTransport: String
    var id: String { device.id }
}
private enum HiddenDeviceRowState { case hidden, restoring, restored, failed }

private struct SettingsSidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private enum SettingsSurface {
    static let canvas = NSColor(name:nil) { appearance in
        appearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua
            ? .windowBackgroundColor : NSColor(srgbRed:242/255,green:242/255,blue:244/255,alpha:1)
    }
    static let sidebar = NSColor(name:nil) { appearance in
        appearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua
            ? .windowBackgroundColor : NSColor(srgbRed:231/255,green:231/255,blue:233/255,alpha:1)
    }
}

@MainActor struct BatteryPanel:View {
    @ObservedObject var model:AppModel
    @ObservedObject var appearance:AppearancePreferencesController
    @ObservedObject var alerts:AlertCoordinator
    @ObservedObject var permissions:NativePermissionsController
    @ObservedObject var notificationRoute:AlertSettingsRoute
    @ObservedObject var login:LoginRegistrationController
    @ObservedObject var updates:ApplicationUpdatesController
    init(model:AppModel,appearance:AppearancePreferencesController?=nil,alerts:AlertCoordinator?=nil,notificationRoute:AlertSettingsRoute?=nil,login:LoginRegistrationController?=nil,updates:ApplicationUpdatesController?=nil,permissions:NativePermissionsController?=nil) {
        self.model=model
        self.login=login ?? LoginRegistrationController()
        self.updates=updates ?? ApplicationUpdatesController(startingAllowed:false)
        let alerts=alerts ?? AlertCoordinator(model:model)
        self.alerts=alerts
        if let permissions { self.permissions=permissions }
        else {
            let adapter=MacNativePermissionAdapter(notifications:alerts.permissionBoundary,gate:.shared)
            let controller=NativePermissionsController(adapter:adapter,gate:.shared)
            adapter.changed={ [weak controller] in controller?.refresh() }
            adapter.notificationAccessDidChange={ [weak alerts] in alerts?.refreshPermission() }
            self.permissions=controller
        }
        self.notificationRoute=notificationRoute ?? AlertSettingsRoute()
        self.appearance=appearance ?? AppearancePreferencesController()
    }
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var permissionOrigin:SettingsSection?
    @State private var permissionTarget:NativePermissionKind?
    @State private var permissionKeyboardEntry=false
    @State private var permissionEntryID=UUID()
    @StateObject private var permissionFocus=PermissionFocusTransfer()
    @State private var selectedSection=SettingsSection.devices
    @State private var selectedDeviceID:String?
    @State private var deviceSubpage="main"
    @State private var aboutSubpage="main"
    @State private var generalSubpage="main"
    @State private var restoreMenuBarFocus=false
    @State private var alertDeviceID:String?
    @State private var alertComponents=false
    @State private var confirmAlertReset=false
    @State private var handledNotificationRoute=0
    @State private var recovery=false
    @FocusState private var keyboardFocus:String?
    @AccessibilityFocusState(for:.voiceOver) private var accessibilityFocus:String?
    @State private var returnFocus:[String:String]=[:]
    @State private var now=Date()
    @State private var confirmSettingsReset=false
    @State private var hiddenPage=false
    @State private var hiddenPageGeneration=UUID()
    @State private var hiddenRows:[HiddenDeviceRow]=[]
    @State private var hiddenRowErrors:[String:String]=[:]
    @State private var hiddenRowStates:[String:HiddenDeviceRowState]=[:]
    @State private var confirmHide=false
    @State private var hideRequest:DeviceVisibilityRequest?
    @State private var hideUsesFocus=false
    @State private var hideFailureID:String?


    private var readings:[BatteryDevicePresentation] {
        BatteryDevicePresentation.groups(records:model.sortedRecords,at:now)
    }
    private func reading(for id:String)->BatteryDevicePresentation? { readings.first { $0.id == id } }
    private var pageID:String {
        if recovery { return "recovery" }
        switch selectedSection {
        case .general:return generalSubpage == "menubar" ? "general.menubar":"general"
        case .devices:if hiddenPage { return "devices.hidden" }; return selectedDeviceID.map { "device.\($0).\(deviceSubpage)" } ?? "devices"
        case .permissions:return "permissions"
        case .notifications:return alertDeviceID.map { "alerts.\($0).\(alertComponents ? "components":"main")" } ?? "notifications"
        case .about:return "about.\(aboutSubpage)"
        }
    }
    private var isKeyboardActivation:Bool {
        // Capture the native activation event before any asynchronous focus work.
        guard let event=NSApp.currentEvent else { return false }
        return event.type == .keyDown || event.type == .keyUp
    }
    private func focusHeading() {
        keyboardFocus=nil
        accessibilityFocus=nil
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        let destination=pageID
        DispatchQueue.main.async {
            guard pageID == destination,NSWorkspace.shared.isVoiceOverEnabled else { return }
            accessibilityFocus="heading.\(destination)"
        }
    }
    private func enter(_ destination:String,from control:String,action:()->Void) {
        returnFocus[destination]=isKeyboardActivation ? control:nil
        action(); focusHeading()
    }
    private func back(from page:String,action:()->Void) {
        let control=isKeyboardActivation ? returnFocus[page]:nil
        action()
        guard let control else { focusHeading(); return }
        keyboardFocus=nil
        accessibilityFocus=nil
        let destination=pageID
        DispatchQueue.main.async {
            guard pageID == destination else { return }
            keyboardFocus=control
            if NSWorkspace.shared.isVoiceOverEnabled { accessibilityFocus=control }
        }
    }
    private var hasUnavailableReadings:Bool {
        model.sortedRecords.contains {
            $0.error != nil || $0.observation.error != nil || $0.observation.connection == .unavailable || $0.observation.charge.isError
        } || model.statuses.values.contains { message in
            ["unavailable","denied","no compatible","failed","error"].contains { message.localizedCaseInsensitiveContains($0) }
        }
    }
    private var sidebar:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Cellio").font(.system(size:20,weight:.semibold))
                .frame(height:28,alignment:.leading).padding(.leading,10)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment:.leading,spacing:4) {
            ForEach(SettingsSection.allCases) { section in
                Button {
                    permissionFocus.cancel()
                    selectedSection=section
                    permissionOrigin=nil; permissionTarget=nil; permissionEntryID=UUID()
                    recovery=false
                    focusHeading()
                } label:{
                    HStack(spacing:9) {
                        Image(systemName:section.symbol).font(.system(size:15)).frame(width:22)
                            .accessibilityHidden(true)
                        Text(section.title).font(.system(size:13))
                        Spacer(minLength:0)
                    }.padding(.horizontal,10).frame(height:34)
                        .foregroundStyle(selectedSection == section ? Color(nsColor:controlActiveState == .inactive ? .unemphasizedSelectedTextColor:.alternateSelectedControlTextColor):Color(nsColor:.labelColor))
                        .contentShape(Rectangle())
                        .background(selectedSection == section ? Color(nsColor:controlActiveState == .inactive ? .unemphasizedSelectedContentBackgroundColor:.selectedContentBackgroundColor):.clear,in:RoundedRectangle(cornerRadius:6))
                }.buttonStyle(.plain)
                    .accessibilityLabel(section.title)
                    .accessibilityAddTraits(selectedSection == section ? .isSelected:[])
                    .accessibilityIdentifier("cellio.sidebar.\(section.rawValue)")
            }
            }
            Spacer(minLength:0)
        }.padding(.horizontal,10).padding(.top,56)
            .frame(width:200).frame(maxHeight:.infinity)
            .background {
                if reduceTransparency { Color(nsColor:SettingsSurface.sidebar) }
                else { SettingsSidebarMaterial() }
            }
            .accessibilityElement(children:.contain)
            .accessibilityLabel("Settings sections")
            .accessibilityIdentifier("cellio.settings.sidebar")
    }
    var body:some View {
        HStack(spacing:0) {
            sidebar
            Divider()
            SettingsScrollPane(page:pageID) {
                VStack(alignment:.leading,spacing:8) {
                    if recovery { recoveryPage } else {
                    switch selectedSection {
                    case .general:
                        if generalSubpage == "menubar" {
                            backButton("General") { restoreMenuBarFocus=isKeyboardActivation; back(from:"general.menubar") { generalSubpage="main" } }
                            pageHeading("Menu Bar")
                            MenuBarSettingsContent(model:model,controller:model.menuBar)
                        } else {
                            heading(.general)
                            GeneralSettingsContent(login:login,updates:updates,openMenuBar: {
                                restoreMenuBarFocus=false
                                enter("general.menubar",from:"cellio.general.menubar") { generalSubpage="menubar" }
                            },focusMenuBarOnAppear:restoreMenuBarFocus)
                        }
                    case .devices:
                        if hiddenPage { hiddenDevicesPage } else if let id=selectedDeviceID { devicePage(id) } else { devicesOverview }
                    case .permissions:
                        PermissionsSettingsContent(permissions:permissions,origin:permissionOrigin?.title,target:permissionTarget,keyboardEntry:permissionKeyboardEntry,back: {
                            let restore=isKeyboardActivation || NSWorkspace.shared.isVoiceOverEnabled
                            let control=returnFocus["permissions"]
                            let destination=permissionOrigin ?? .devices
                            keyboardFocus=nil; accessibilityFocus=nil
                            if restore,let control { permissionFocus.begin(route:destination.rawValue,target:control) }
                            else { permissionFocus.cancel() }
                            selectedSection=destination
                        },focusTransfer:permissionFocus,focusTicket:permissionEntryID).id(permissionEntryID)
                    case .notifications:
                        notificationsContent
                    case .about:
                        if aboutSubpage == "diagnostics" { diagnosticsPage } else { aboutContent }
                    }
                    }
                }.padding(.horizontal,18).padding(.top,64).padding(.bottom,18)
                    .frame(maxWidth:.infinity,alignment:.leading)
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
                .background(Color(nsColor:SettingsSurface.canvas))
                .accessibilityElement(children:.contain)
                .accessibilityLabel("\(selectedSection.title) content")
                .accessibilityIdentifier("cellio.content.\(selectedSection.rawValue)")
        }.frame(maxWidth:.infinity,maxHeight:.infinity)
        // One window-top origin: extend both columns through the native titlebar.
        .ignoresSafeArea(.container,edges:.top)
        .alert("Reset device settings?",isPresented:$confirmSettingsReset) {
            Button("Reset device settings",role:.destructive) { model.resetDeviceSettings() }; Button("Cancel",role:.cancel) {}
        } message:{ Text("Resets this store’s monitoring, menu choices, component choices, hidden-device choices and known-device/component catalog. Existing readings remain. Watch pairing and history are separate.") }
        .alert("Reset alert storage?",isPresented:$confirmAlertReset) {
            Button("Reset alert storage",role:.destructive) { alerts.resetStorage() }; Button("Cancel",role:.cancel) {}
        } message:{ Text("Returns alerts to off and removes only alert configuration and episode bookkeeping. Resetting can allow a previously alerted low to alert again after a new eligible measurement.") }
        .alert(hideRequest.map { "Hide “\($0.snapshot.name)”?" } ?? "Hide Device?",isPresented:$confirmHide) {
            Button("Hide") { commitHide() }
            Button("Cancel",role:.cancel) { cancelHide() }
        } message: {
            Text(hideConfirmationBody)
        }
        .onChange(of:confirmHide) { presented in if !presented { cancelHide() } }
        .onChange(of:pageID) { destination in
            permissionFocus.keepOnly(route:destination)
            model.cancelVisibilityChange(); hideRequest=nil; confirmHide=false
            if destination != "general.menubar" { model.menuBar.leavePage() }
            if destination != "devices.hidden", hiddenPage { hiddenPage=false; hiddenRows=[]; hiddenRowStates=[:]; hiddenRowErrors=[:] }
        }
        .onDisappear { permissionFocus.cancel(); model.cancelVisibilityChange(); hideRequest=nil; confirmHide=false }
        .onAppear { applyNotificationRoute(); permissions.refresh() }
        .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) { _ in permissions.refresh() }
        .onChange(of:notificationRoute.revision) { _ in applyNotificationRoute() }
        // Retain the existing display clock; it never changes source timestamps or collects data.
        .onReceive(Timer.publish(every:15,on:.main,in:.common).autoconnect()) { now=$0 }
    }
    private func openPermissions(_ kind:NativePermissionKind,from origin:SettingsSection,control:String) {
        permissionOrigin=origin; permissionTarget=kind
        permissionKeyboardEntry=isKeyboardActivation; permissionEntryID=UUID()
        keyboardFocus=nil; accessibilityFocus=nil
        if permissionKeyboardEntry || NSWorkspace.shared.isVoiceOverEnabled {
            permissionFocus.begin(ticket:permissionEntryID,route:"permissions")
        } else { permissionFocus.cancel() }
        selectedSection = .permissions; recovery=false
        returnFocus["permissions"]=control
    }
    private func applyNotificationRoute() {
        guard handledNotificationRoute != notificationRoute.revision,let destination=notificationRoute.destination else { return }
        handledNotificationRoute=notificationRoute.revision
        permissionFocus.cancel()
        switch destination {
        case .device(let id): selectedSection = .devices; selectedDeviceID=id; deviceSubpage="main"
        case .notifications: selectedSection = .notifications; alertDeviceID=nil; alertComponents=false
        }
        recovery=false; hiddenPage=false
        focusHeading()
    }
    private func pageHeading(_ title:String)->some View {
        Text(title).font(.headline).lineLimit(1).truncationMode(.tail).help(title)
            .accessibilityLabel(title).accessibilityAddTraits(.isHeader)
            .accessibilityFocused($accessibilityFocus,equals:"heading.\(pageID)")
            .accessibilityIdentifier("cellio.content.\(pageID == "about.main" ? "about":pageID).title")
    }
    private func heading(_ section:SettingsSection)->some View { pageHeading(section.title) }
    private var refreshAction:some View {
        HStack {
            Button("Refresh battery reports") { model.refresh() }.accessibilityIdentifier("cellio.refresh")
            ProgressView().controlSize(.small).opacity(model.refreshing ? 1:0)
                .accessibilityHidden(!model.refreshing).accessibilityLabel("Collecting battery reports")
        }.frame(height:24)
    }
    private func navigationRow(_ title:String,value:String="",id:String,enabled:Bool=true,help:String="",action:@escaping ()->Void)->some View {
        Button(action:action) {
            HStack(spacing:8) {
                Text(title).lineLimit(1)
                Spacer(minLength:8)
                Text(value).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Image(systemName:"chevron.right").font(.caption2).accessibilityHidden(true)
            }.padding(.horizontal,12).frame(height:44).frame(maxWidth:.infinity).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!enabled).help(help)
            .accessibilityLabel(title).accessibilityValue(value).accessibilityIdentifier(id)
            .focused($keyboardFocus,equals:id).accessibilityFocused($accessibilityFocus,equals:id)
    }
    private func backButton(_ title:String,id:String="cellio.subpage.back",action:@escaping ()->Void)->some View {
        Button(action:action) { Label("Back to \(title)",systemImage:"chevron.left") }
            .buttonStyle(.borderless).accessibilityIdentifier(id).frame(height:24)
    }
    private var devicesOverview:some View {
        Group {
            HStack(alignment:.top) { heading(.devices); Spacer(minLength:8); settingsIssue }.frame(height:24,alignment:.top)
            if model.knownDevices.isEmpty {
                Text(model.deviceSettings.hiddenDevices.isEmpty ? "No devices yet. Connect an accessory, then Refresh to collect available reports.":"All devices are hidden. Restore a device from Hidden Devices.")
                    .foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    .accessibilityIdentifier("cellio.devices.empty")
            } else {
                SettingsGroup {
                    ForEach(Array(model.knownDevices.enumerated()),id:\.element.id) { index,device in
                        if index > 0 { Divider().padding(.leading,52) }
                        Button {
                            deviceSubpage="main"
                            enter("device.\(device.id).main",from:"cellio.device.manage.\(device.id)") { selectedDeviceID=device.id }
                        } label:{
                            overviewRow(device)
                                // Group the label only; keep the native Button's role and press action.
                                .accessibilityElement(children:.ignore)
                        }.buttonStyle(.plain)
                            .accessibilityLabel("Manage device \(device.name)")
                            .accessibilityValue("\(availability(for:device)), \(batteryDescription(reading(for:device.id)))")
                            .accessibilityIdentifier("cellio.device.manage.\(device.id)")
                            .focused($keyboardFocus,equals:"cellio.device.manage.\(device.id)")
                            .accessibilityFocused($accessibilityFocus,equals:"cellio.device.manage.\(device.id)")
                    }
                }
            }
            SettingsGroup {
                navigationRow("Hidden Devices",value:String(model.deviceSettings.hiddenDevices.count),id:"cellio.devices.hidden") {
                    openHiddenDevices()
                }
            }
            HStack(spacing:8) {
                refreshAction
                Spacer(minLength:0)
                BluetoothKeyboardConnection(openPermissions: {
                    openPermissions(.bluetooth,from:.devices,control:"cellio.bluetooth.connectKeyboard")
                },focusTransfer:permissionFocus)
            }
            BluetoothKeyboardAssistance(model:model)
            if hasUnavailableReadings {
                Label("Some readings are unavailable; retained values may be shown.",systemImage:"exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
        }
    }
    private var hideConfirmationBody:String {
        let count=hideRequest?.snapshot.members.count ?? 1
        return "This device will disappear from Devices, the menu and Notifications. Battery monitoring and alerts will pause. Its readings and settings will be kept. Restore it in Devices → Hidden Devices." + (count > 1 ? " All \(count) linked connections will be hidden together.":"")
    }
    private func focusControl(_ id:String,enabled:Bool) {
        guard enabled else { return }
        keyboardFocus=nil; accessibilityFocus=nil
        let destination=pageID
        DispatchQueue.main.async {
            guard destination == pageID else { return }
            keyboardFocus=id
            if NSWorkspace.shared.isVoiceOverEnabled { accessibilityFocus=id }
        }
    }
    private func beginHide(_ id:String) {
        hideUsesFocus=isKeyboardActivation || NSWorkspace.shared.isVoiceOverEnabled || NSApp.currentEvent == nil
        guard let request=model.beginVisibilityChange(for:id,hidden:true) else { return }
        hideRequest=request; confirmHide=true
    }
    private func cancelHide() {
        guard let request=hideRequest else { return }
        model.cancelVisibilityChange(request); hideRequest=nil
        focusControl("cellio.device.hide.\(request.snapshot.id)",enabled:hideUsesFocus)
    }
    private func commitHide() {
        guard let request=hideRequest else { return }
        let useFocus=hideUsesFocus
        let success=model.commitVisibilityChange(request)
        hideRequest=nil
        if success {
            hideFailureID=nil; selectedDeviceID=nil; deviceSubpage="main"
            focusControl("cellio.devices.hidden",enabled:useFocus)
        } else {
            hideFailureID=request.snapshot.id
            focusControl("cellio.device.hide.\(request.snapshot.id)",enabled:useFocus)
        }
    }
    private func openHiddenDevices() {
        hiddenPageGeneration=UUID()
        hiddenRows=model.deviceSettings.hiddenDevices.compactMap { device in
            guard let snapshot=try? model.deviceSettings.visibilitySnapshot(for:device.id) else { return nil }
            let transport=model.deviceSettings.physicalCatalog.routes.first { snapshot.members.contains($0.id) }?.metadata.type.label ?? "Connection type unknown"
            return HiddenDeviceRow(device:device,snapshot:snapshot,savedTransport:transport)
        }
        hiddenRowStates=[:]; hiddenRowErrors=[:]
        enter("devices.hidden",from:"cellio.devices.hidden") { hiddenPage=true }
    }
    private var hiddenDevicesPage:some View {
        Group {
            HStack {
                backButton("Devices",id:"cellio.hidden.back") { back(from:"devices.hidden") { hiddenPage=false } }
                Spacer(minLength:8); settingsIssue
            }.frame(height:24)
            pageHeading("Hidden Devices")
            Text("Hidden devices are paused. Restoring uses their saved settings.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if hiddenRows.isEmpty {
                Text("No hidden devices.").foregroundStyle(.secondary).accessibilityIdentifier("cellio.hidden.empty")
            } else {
                SettingsGroup {
                    ForEach(Array(hiddenRows.enumerated()),id:\.element.id) { index,row in
                        if index > 0 { Divider().padding(.leading,52) }
                        hiddenDeviceRow(row)
                    }
                }
            }
        }
    }
    private func hiddenDeviceRow(_ row:HiddenDeviceRow)->some View {
        let state=hiddenRowStates[row.id] ?? .hidden
        let status:String
        let title:String
        switch state {
        case .hidden: status=row.snapshot.members.count > 1 ? "Hidden · \(row.snapshot.members.count) saved connections":"Hidden · \(row.savedTransport)"; title="Restore"
        case .restoring: status=row.snapshot.members.count > 1 ? "Hidden · \(row.snapshot.members.count) saved connections":"Hidden · \(row.savedTransport)"; title="Restoring…"
        case .restored: status="Restored"; title="Restored"
        case .failed: status=hiddenRowErrors[row.id] ?? "Couldn’t restore. Try again."; title="Try Again"
        }
        return HStack(spacing:12) {
            Image(systemName:deviceSymbol(row.device)).font(.system(size:28))
                .foregroundStyle(.secondary).frame(width:28).accessibilityHidden(true)
            VStack(alignment:.leading,spacing:4) {
                Text(row.device.name).font(.body.weight(.medium)).lineLimit(1).truncationMode(.tail).help(row.device.name)
                    .accessibilityLabel(row.device.name)
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2).frame(height:30,alignment:.topLeading)
                    .accessibilityIdentifier("cellio.hidden.status.\(row.id)")
            }.frame(maxWidth:.infinity,alignment:.leading)
            Button(title) { restoreHiddenDevice(row) }
                .frame(width:108).disabled(state == .restoring || state == .restored || model.deviceSettings.updatesBlocked || model.visibilityRequest != nil)
                .accessibilityLabel("\(state == .failed ? "Try restoring":"Restore") \(row.device.name), \(status)")
                .accessibilityIdentifier("cellio.hidden.restore.\(row.id)")
                .focused($keyboardFocus,equals:"cellio.hidden.restore.\(row.id)")
                .accessibilityFocused($accessibilityFocus,equals:"cellio.hidden.restore.\(row.id)")
        }.padding(.horizontal,12).frame(height:72).frame(maxWidth:.infinity,alignment:.leading)
    }
    private func restoreHiddenDevice(_ row:HiddenDeviceRow) {
        let state=hiddenRowStates[row.id] ?? .hidden
        guard state == .hidden || state == .failed else { return }
        let useFocus=isKeyboardActivation || NSWorkspace.shared.isVoiceOverEnabled || NSApp.currentEvent == nil
        let pageGeneration=hiddenPageGeneration
        guard let request=model.beginVisibilityChange(for:row.id,hidden:false,expected:state == .hidden ? row.snapshot:nil) else {
            if let issue=model.visibilityIssue { hiddenRowErrors[row.id]=issue; hiddenRowStates[row.id] = .failed }
            focusControl("cellio.hidden.restore.\(row.id)",enabled:useFocus)
            return
        }
        hiddenRowStates[row.id] = .restoring
        Task { @MainActor in
            // Let the native disabled pending state render; navigation revokes this request.
            await Task.yield()
            guard pageGeneration == hiddenPageGeneration, hiddenPage, selectedSection == .devices, !recovery, model.visibilityRequest == request else {
                model.cancelVisibilityChange(request)
                if pageGeneration == hiddenPageGeneration, hiddenRowStates[row.id] == .restoring, model.visibilityRequest == nil { hiddenRowStates[row.id] = .hidden }
                return
            }
            if model.commitVisibilityChange(request) { hiddenRowStates[row.id] = .restored }
            else {
                hiddenRowStates[row.id] = .failed
                hiddenRowErrors[row.id]=model.visibilityIssue
                focusControl("cellio.hidden.restore.\(row.id)",enabled:useFocus)
            }
        }
    }
    private func overviewRow(_ device:KnownBatteryDevice)->some View {
        let value=reading(for:device.id)
        return HStack(spacing:12) {
            Image(systemName:deviceSymbol(device)).font(.system(size:28))
                .foregroundStyle(.secondary).frame(width:28).accessibilityHidden(true)
            VStack(alignment:.leading,spacing:4) {
                Text(device.name).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1).truncationMode(.tail).help(device.name)
                Text(availability(for:device)).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).frame(height:30,alignment:.topLeading)
            }.frame(maxWidth:.infinity,alignment:.leading)
            BatteryValues(reading:value,knownComponentIDs:device.orderedComponentIDs)
            Image(systemName:"chevron.right").font(.system(size:10,weight:.semibold))
                .foregroundStyle(.tertiary).accessibilityHidden(true)
        }.padding(.horizontal,12).frame(height:72)
            .frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
    }
    @ViewBuilder private var settingsIssue:some View {
        if model.deviceSettings.issue != nil {
            Button {
                enter("recovery",from:"cellio.devices.settingsIssue") { recovery=true }
            } label:{
                Label(model.deviceSettings.updatesBlocked ? "Settings unavailable · Review and reset…":"Changes aren’t saved · Review and retry…",systemImage:"exclamationmark.triangle")
                    .font(.caption).lineLimit(1).frame(maxWidth:.infinity,alignment:.leading)
            }.buttonStyle(.borderless).frame(height:24).accessibilityIdentifier("cellio.devices.settingsIssue")
                .focused($keyboardFocus,equals:"cellio.devices.settingsIssue")
                .accessibilityFocused($accessibilityFocus,equals:"cellio.devices.settingsIssue")
        }
    }
    private var recoveryPage:some View {
        Group {
            backButton("Settings") { back(from:"recovery") { recovery=false } }
            pageHeading("Device settings recovery")
            Text(model.deviceSettings.issue ?? "Device settings are saved.").textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
            if !model.deviceSettings.updatesBlocked {
                Button("Retry saving device settings") { model.retryDeviceSettingsSave() }.accessibilityIdentifier("cellio.settings.retry")
            }
            Button("Reset device settings…",role:.destructive) { confirmSettingsReset=true }.accessibilityIdentifier("cellio.settings.reset")
        }
    }
    @ViewBuilder private func devicePage(_ id:String)->some View {
        if deviceSubpage != "main" {
            deviceSubpageContent(id)
        } else {
            HStack {
                backButton("Devices",id:"cellio.device.back") { back(from:"device.\(id).main") { selectedDeviceID=nil } }
                Spacer(minLength:8)
                settingsIssue
            }.frame(height:24)
            if let device=model.knownDevices.first(where:{ $0.id == id }) {
                let value=reading(for:id)
                HStack(spacing:12) {
                    Image(systemName:deviceSymbol(device)).font(.system(size:28))
                        .foregroundStyle(.secondary).frame(width:28).accessibilityHidden(true)
                    VStack(alignment:.leading,spacing:4) {
                        pageHeading(device.name)
                        Text(availability(for:device)).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2).frame(height:30,alignment:.topLeading)
                    }.frame(maxWidth:.infinity,alignment:.leading)
                    BatteryValues(reading:value,knownComponentIDs:device.orderedComponentIDs,showCharge:true,paused:isPaused(id))
                }.frame(height:64)
                SettingsGroup {
                    SettingsSwitchRow(title:"Monitor battery",name:"Monitor battery for \(device.name), \(id)",id:"cellio.device.monitor.\(id)",isOn:Binding(get:{model.deviceSettings.preferences(for:id).monitorBattery},set:{model.setMonitoring($0,for:id)}))
                    Divider().padding(.leading,12)
                    SettingsSwitchRow(title:"Show in menu",name:"Show \(device.name) in menu, \(id)",id:"cellio.device.menu.\(id)",isOn:Binding(get:{model.deviceSettings.preferences(for:id).showInMenu},set:{model.setMenuVisibility($0,for:id)}))
                        .help("Show this device in Cellio’s dropdown. Menu bar pins, monitoring and alerts are separate.")
                    if device.knownComponentIDs.count > 1 {
                        Divider().padding(.leading,12)
                        navigationRow("Menu components",value:device.selectionSummary,id:"cellio.device.components.\(id)") {
                            enter("device.\(id).components",from:"cellio.device.components.\(id)") { deviceSubpage="components" }
                        }
                    }
                    Divider().padding(.leading,12)
                    navigationRow("Connections",value:String(model.deviceSettings.members(of:id).count),id:"cellio.device.connections.\(id)") {
                        enter("device.\(id).connections",from:"cellio.device.connections.\(id)") { deviceSubpage="connections" }
                    }
                }.disabled(model.deviceSettings.updatesBlocked)
                Text("Pausing retains readings and their age. Menu visibility is independent; shared discovery and Watch sharing may continue.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2).frame(height:32,alignment:.topLeading)
                Button("Connection details…") {
                    enter("device.\(id).details",from:"cellio.device.details.\(id)") { deviceSubpage="details" }
                }.frame(height:24).accessibilityIdentifier("cellio.device.details.\(id)")
                    .focused($keyboardFocus,equals:"cellio.device.details.\(id)")
                    .accessibilityFocused($accessibilityFocus,equals:"cellio.device.details.\(id)")
                HStack(spacing:8) {
                    Button(hideFailureID == id ? "Try Again":"Hide Device…") { beginHide(id) }
                        .frame(width:108).disabled(model.deviceSettings.updatesBlocked || model.visibilityRequest != nil)
                        .accessibilityLabel(hideFailureID == id ? "Try hiding \(device.name) again":"Hide Device \(device.name)")
                        .accessibilityIdentifier("cellio.device.hide.\(id)")
                        .focused($keyboardFocus,equals:"cellio.device.hide.\(id)")
                        .accessibilityFocused($accessibilityFocus,equals:"cellio.device.hide.\(id)")
                    Text(hideFailureID == id ? (model.visibilityIssue ?? ""):"")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .frame(maxWidth:.infinity,minHeight:32,alignment:.leading)
                        .accessibilityIdentifier("cellio.device.hide.issue.\(id)")
                }.frame(height:44)
            } else { missingDevice }
        }
    }
    private var missingDevice:some View {
        Text("Device no longer available").font(.headline).accessibilityIdentifier("cellio.device.missing")
    }
    @ViewBuilder private func deviceSubpageContent(_ id:String)->some View {
        let device=model.knownDevices.first { $0.id == id }
        backButton(deviceSubpage == "link" ? "Connections":device?.name ?? "device") { back(from:"device.\(id).\(deviceSubpage)") { deviceSubpage = deviceSubpage == "link" ? "connections":"main" } }
        if let device {
            if deviceSubpage == "connections" || deviceSubpage == "link" {
                ConnectionsSettings(model:model,deviceID:id,selecting:Binding(get:{ deviceSubpage == "link" },set:{ deviceSubpage = $0 ? "link":"connections" })) {
                    enter("device.\(id).details",from:"cellio.device.connections.\(id)") { deviceSubpage="details" }
                }
            } else {
            pageHeading(deviceSubpage == "components" ? "Menu components":"Connection details")
            if deviceSubpage == "components" {
                componentSelection(device)
            } else {
                deviceFacts(device,reading:reading(for:id))
                refreshAction
                Text("Refresh collects available reports; it does not guarantee a new battery measurement.").font(.caption).foregroundStyle(.secondary)
            }
            }
        } else { missingDevice }
    }
    private func componentSelection(_ device:KnownBatteryDevice)->some View {
        let selected=device.orderedComponentIDs.filter { device.componentSelection.includes($0) }
        return VStack(alignment:.leading,spacing:12) {
            Text(device.preferences.showInMenu ? device.selectionSummary:"Not shown in menu; these choices are kept")
                .foregroundStyle(.secondary).frame(height:32,alignment:.leading)
            SettingsGroup {
                ForEach(device.orderedComponentIDs,id:\.self) { component in
                    let final=selected.count == 1 && selected.contains(component)
                    Toggle(KnownBatteryDevice.componentName(component),isOn:Binding(
                        get:{device.componentSelection.includes(component)},
                        set:{model.setComponentSelected($0,component:component,for:device.id)}))
                        .toggleStyle(.checkbox).disabled(final || model.deviceSettings.updatesBlocked)
                        .padding(.horizontal,12).frame(height:44).frame(maxWidth:.infinity,alignment:.leading)
                        .accessibilityLabel("\(KnownBatteryDevice.componentName(component)) for \(device.name), \(device.id)")
                        .accessibilityIdentifier("cellio.device.component.\(device.id).\(component)")
                        .help(final ? "Keep one dropdown component selected. To remove this device from the dropdown, turn off Show in menu. Menu bar pins are separate.":"Choose whether this component appears in Cellio’s dropdown. Menu bar pins are separate.")
                }
            }
            Text("Keep one dropdown component selected. To remove this device from the dropdown, turn off Show in menu. Menu bar pins are separate.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            Button("Include all components") { model.includeAllComponents(for:device.id) }
                .disabled(model.deviceSettings.updatesBlocked).accessibilityIdentifier("cellio.device.includeAll.\(device.id)")
            Text("Includes every current and newly discovered component. Selecting all current checkboxes keeps your custom selection for future discoveries.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }
    }
    private func isPaused(_ id:String)->Bool {
        model.deviceSettings.updatesBlocked || !model.deviceSettings.preferences(for:id).monitorBattery
    }
    private func availability(for device:KnownBatteryDevice)->String {
        guard let value=reading(for:device.id) else {
            return isPaused(device.id) ? model.deviceSettings.readingStatus(for:device.id,hasReading:false,age:""):model.connectionLabel(for:device.id)+" · No reading"
        }
        let known=value.components.contains { $0.record.observation.quantity.isKnown }
        if isPaused(device.id) { return model.deviceSettings.readingStatus(for:device.id,hasReading:known,age:"").trimmingCharacters(in:CharacterSet(charactersIn:" ·")) }
        var parts=[model.connectionLabel(for:device.id)]
        if !known { parts.append("No reading") }
        if value.components.contains(where:{ $0.record.isStale(at:now) }) { parts.append("Last known · stale") }
        if value.components.contains(where:{ $0.freshness.localizedCaseInsensitiveContains("unknown") }) { parts.append("Source age unknown") }
        if value.components.contains(where:{ $0.record.error != nil || $0.record.observation.error != nil }) { parts.append("⚠ Reading unavailable") }
        let charges=Set(value.components.filter { $0.record.observation.charge.isError || [.charging,.finalStage,.complete,.slowCharging].contains($0.record.observation.charge) }.map(\.charge)).sorted()
        return (parts+charges).joined(separator:" · ")
    }
    private func measurementDate(_ component:BatteryComponentPresentation)->Date {
        let observation=component.record.observation
        return (observation.source == .systemReport ? observation.measuredAt:observation.measuredAt ?? observation.observedAt) ?? .distantPast
    }
    private func batteryDescription(_ reading:BatteryDevicePresentation?)->String {
        guard let reading else { return "No reading" }
        return reading.components.map { "\($0.title): \($0.value)" }.joined(separator:", ")
    }
    private func deviceFacts(_ device:KnownBatteryDevice,reading:BatteryDevicePresentation?)->some View {
        VStack(alignment:.leading,spacing:10) {
            Text("Device ID: \(device.id)")
            Text(device.providerDescription)
            ForEach(model.deviceSettings.members(of:device.id),id:\.self) { routeID in
                let route=model.deviceSettings.physicalCatalog.routes.first { $0.id == routeID }
                Text("Route ID: \(routeID) · \(route?.metadata.type.label ?? BatteryRouteType.unknown.label)").fontWeight(.medium)
                Text(route?.metadata.topology ?? "Topology unproved")
                Text("Physical proof: \(route?.identity?.key ?? "None") · feature version \(route?.identity.map { String($0.featureVersion) } ?? "unknown") · target \(route?.identity.map { String($0.target) } ?? "unknown") · transport mask \(route?.identity.map { String($0.transportMask) } ?? "unknown") · conflict: \(route?.identityConflict == true ? "yes":"no")")
                ForEach(route?.conflictingIdentities ?? [],id:\.key) { conflicting in
                    Text("Conflicting proof: \(conflicting.key) · version \(conflicting.featureVersion) · target \(conflicting.target)")
                }
                if let original=model.deviceSettings.physicalCatalog.groups.first(where: { $0.id == device.id })?.originalDevices.first(where: { $0.id == routeID }) {
                    Text("Pre-link monitoring: \(original.preferences.monitorBattery ? "on":"off") · menu: \(original.preferences.showInMenu ? "on":"off") · menu components: \(original.selectionSummary)")
                }
                if let originalAlert=model.deviceSettings.physicalCatalog.groups.first(where: { $0.id == device.id })?.originalAlerts[routeID] {
                    Text("Pre-link alerts: \(originalAlert.included ? "included":"excluded") · threshold: \(originalAlert.usesCustomThreshold ? String(originalAlert.customThreshold)+"%":"global default") · alert components: \(originalAlert.summary)")
                }
                ForEach(model.rawRecords.filter { $0.observation.id.device == routeID }.map { BatteryComponentPresentation(record:$0,at:now) }) { raw in
                    componentFacts(raw)
                }
            }
            Text("Known components: \(device.orderedComponentIDs.joined(separator:", "))")
            if let reading {
                ForEach(device.orderedComponentIDs.filter { id in !reading.components.contains { $0.id.component == id } },id:\.self) { id in
                    Text("\(KnownBatteryDevice.componentName(id)): Not reported · Component ID: \(id)")
                }
                ForEach(reading.components) { component in componentFacts(component) }
            } else { Text("No reading in this session.") }
        }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            .fixedSize(horizontal:false,vertical:true).frame(maxWidth:.infinity,alignment:.leading)
    }
    private func componentFacts(_ component:BatteryComponentPresentation)->some View {
        VStack(alignment:.leading,spacing:4) {
            Text("\(component.title): \(component.value)").fontWeight(.medium)
            Text("\(isPaused(component.id.device) ? "Last state: ":"")\(component.connection) · \(component.charge)")
            Text(model.deviceSettings.readingStatus(for:component.id.device,hasReading:component.record.observation.quantity.isKnown,age:component.freshness))
            quantityFacts(component.record.observation.quantity)
            Text("Component: \(component.id.component) · Source: \(component.record.observation.source.rawValue)")
            if case .estimatedPercent(_,let calibration)=component.record.observation.quantity {
                Text("Estimate calibration: \(calibration)")
            }
            if case .coarse(_,let level)=component.record.observation.quantity {
                Text("Coarse level: \(level.map(String.init) ?? "unknown")")
            }
            timestamp("Quantity observed",component.record.observation.observedAt)
            timestamp("Source measured",component.record.observation.measuredAt)
            timestamp("Sample measured",component.record.observation.sampleMeasuredAt)
            timestamp("Report collected",component.record.observation.collectedAt)
            timestamp("Last attempt",component.record.lastAttempt)
            Text("Retained reading: \(component.record.retained ? "Yes":"No")")
            Text("Reading error: \(component.record.error ?? "None")")
            Text("Source error: \(component.record.observation.error ?? "None")")
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    @ViewBuilder private func quantityFacts(_ quantity:Quantity)->some View {
        switch quantity {
        case .reportedPercent(let percent):Text("Quantity: reported percentage · \(percent)% · device-reported precision")
        case .estimatedPercent(let percent,let calibration):Text("Quantity: estimate · \(percent)% · calibration: \(calibration)")
        case .coarse(let name,let level):Text("Quantity: coarse · name: \(name) · level: \(level.map(String.init) ?? "unknown") · no precise percentage")
        case .unknown:Text("Quantity: Unknown · no reported percentage")
        case .absent:Text("Quantity: Not reported · component absent in report")
        }
    }
    private func timestamp(_ label:String,_ date:Date?)->some View {
        Text("\(label): \(date.map { $0.ISO8601Format(.init(includingFractionalSeconds:true)) } ?? "Unknown")")
    }
    private var aboutContent:some View {
        Group {
            heading(.about)
            HStack(spacing:12) {
                Image(nsImage:appearance.selectedLogoImage)
                    .resizable().renderingMode(.original).scaledToFit().frame(width:48,height:48)
                    .clipShape(RoundedRectangle(cornerRadius:10,style:.continuous)).accessibilityHidden(true)
                VStack(alignment:.leading,spacing:4) {
                    Text(Bundle.main.object(forInfoDictionaryKey:"CFBundleDisplayName") as? String ?? "Cellio").font(.headline)
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "1.0") (\(Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "1"))")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Text("An original native accessory battery viewer.").font(.callout)
            SettingsGroup {
                visualPreferenceRow("Appearance",options:AppAppearanceChoice.allCases.map(\.title),
                                    selection:appearance.appearance.title,id:"cellio.about.appearance") { title in
                    if let choice=AppAppearanceChoice(rawValue:title.lowercased()) { appearance.selectAppearance(choice) }
                }
                Divider().padding(.horizontal,12)
                visualPreferenceRow("Logo",options:AppLogoChoice.allCases.map(\.title),
                                    selection:appearance.logo.title,id:"cellio.about.logo") { title in
                    if let choice=AppLogoChoice(rawValue:title.lowercased()) { appearance.selectLogo(choice) }
                }
            }
            Text("Logo applies to Cellio and its running Dock icon. Finder keeps the Dark icon.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if let override=appearance.appearanceOverride {
                Text("QA appearance override: \(override.title). Saved Appearance is unchanged by the override.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    .accessibilityIdentifier("cellio.about.appearanceOverride")
            }
            if let issue=appearance.issue {
                Text(issue).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    .accessibilityIdentifier("cellio.about.appearanceIssue")
                if appearance.hasUnsavedChanges {
                    Button("Retry") { appearance.retrySave() }.accessibilityIdentifier("cellio.about.appearanceRetry")
                }
            }
            SettingsGroup {
                navigationRow("Diagnostics…",id:"cellio.about.diagnostics") {
                    enter("about.diagnostics",from:"cellio.about.diagnostics") { aboutSubpage="diagnostics" }
                }
            }
        }
    }
    private func visualPreferenceRow(_ title:String,options:[String],selection:String,id:String,
                                     choose:@escaping (String)->Void)->some View {
        HStack(spacing:12) {
            Text(title).frame(maxWidth:.infinity,alignment:.leading)
            AppearancePopup(title:title,options:options,selection:selection,identifier:id,
                            configureMenu:appearance.configure(menu:),choose:choose).frame(width:140,height:26)
        }.padding(.horizontal,12).frame(height:44).frame(maxWidth:.infinity)
            .accessibilityElement(children:.contain)
    }
    private var diagnosticsPage:some View {
        Group {
            backButton("About") { back(from:"about.diagnostics") { aboutSubpage="main" } }
            pageHeading("Diagnostics")
            diagnostics
        }
    }
    private var diagnostics:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("AirPods and Logitech providers are experimental. Hardware support depends on the model, transport and available interfaces; a build does not verify physical hardware.")
            Text("Apple Watch requires paired iPhone forwarding. Background delivery is not guaranteed.")
            refreshAction
            Text("Refresh collects available reports; it does not guarantee a new battery measurement. If access is denied, check Input Monitoring in System Settings.")
            ForEach(model.statuses.keys.sorted(),id:\.self) { key in
                Text("\(key): \(model.statuses[key] ?? "")")
            }
            Text("Connection details").fontWeight(.medium)
            if model.knownDevices.isEmpty && readings.isEmpty { Text("No known devices or readings.") }
            ForEach(model.knownDevices) { device in
                Text(device.name).fontWeight(.medium)
                deviceFacts(device,reading:reading(for:device.id))
            }
            // A blocked catalog can coexist with retained records. Keep those diagnostics available.
            ForEach(readings.filter { reading in !model.knownDevices.contains { $0.id == reading.id } }) { reading in
                Text(reading.name).fontWeight(.medium)
                Text("Device ID: \(reading.id) · Not in the saved catalog")
                ForEach(reading.components) { component in componentFacts(component) }
            }
        }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            .fixedSize(horizontal:false,vertical:true).frame(maxWidth:.infinity,alignment:.leading)
    }
}

private func deviceSymbol(_ device:KnownBatteryDevice)->String {
    DeviceSymbols.symbol(name:device.name,source:device.source,kind:device.kind)
}

/// All quantities come directly from the lossless presentation helper: no combined
/// AirPods percentage, invented precision, or replacement of unknown with zero.
private struct BatteryValues:View {
    let reading:BatteryDevicePresentation?
    var knownComponentIDs:[String]=[]
    var showCharge=false
    var paused=false
    private var ids:[String] {
        KnownBatteryDevice.order(Array(Set(knownComponentIDs).union(reading?.components.map { $0.id.component } ?? [])))
    }
    var body:some View {
        HStack(alignment:.top,spacing:10) {
            ForEach(Array(ids.prefix(3)),id:\.self) { id in
                let component=reading?.components.first { $0.id.component == id }
                VStack(alignment:.trailing,spacing:3) {
                    if ids.count > 1 || id != "battery" {
                        Text(KnownBatteryDevice.componentName(id)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(component?.value ?? "Not reported").font(.body.weight(.medium)).monospacedDigit().lineLimit(1)
                    if showCharge,let component,component.record.observation.charge != .unknown,component.record.observation.charge != .discharging {
                        Text("\(paused ? "Last: ":"")\(component.charge)").font(.caption).lineLimit(1)
                            .foregroundStyle(component.record.observation.charge.isError ? Color(nsColor:.systemRed):.secondary)
                    }
                }.accessibilityElement(children:.ignore)
                    .accessibilityLabel("\(KnownBatteryDevice.componentName(id)), \(component?.value ?? "Not reported"), \(component?.charge ?? "Charge state unknown"), \(component?.connection ?? "Connection unknown"), \(component?.freshness ?? "No reading"), \(component?.record.error ?? component?.record.observation.error ?? "No error")")
            }
            if ids.count > 3 { Text("+\(ids.count-3)").font(.caption).help("See Connection details for every component.") }
            if ids.isEmpty { Text("No reading").font(.callout).foregroundStyle(.secondary) }
        }
    }
}

struct SettingsGroup<Content:View>:View {
    @ViewBuilder var content:Content
    private var fill:NSColor {
        NSColor(name:nil) { appearance in
            var color=NSColor.controlBackgroundColor
            appearance.performAsCurrentDrawingAppearance {
                if appearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua {
                    color=(NSColor.windowBackgroundColor.blended(withFraction:0.06,of:.labelColor) ?? .controlBackgroundColor).withAlphaComponent(1)
                } else {
                    color=NSColor(srgbRed:250/255,green:250/255,blue:251/255,alpha:1)
                }
            }
            return color
        }
    }
    var body:some View {
        VStack(spacing:0) { content }
            .frame(maxWidth:.infinity,alignment:.leading)
            .background(Color(nsColor:fill),in:RoundedRectangle(cornerRadius:9))
            .overlay {
                RoundedRectangle(cornerRadius:9).strokeBorder(Color(nsColor:.separatorColor),lineWidth:0.5)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
    }
}

/// Explicit leading label and trailing native switch share a fixed 44pt grid.
private struct SettingsSwitchRow:View {
    let title:String
    let name:String
    let id:String
    @Binding var isOn:Bool
    var body:some View {
        HStack(spacing:12) {
            Text(title).frame(maxWidth:.infinity,alignment:.leading)
            Toggle(title,isOn:$isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
                .fixedSize().accessibilityLabel(name).accessibilityIdentifier(id)
        }.padding(.horizontal,12).frame(height:44).frame(maxWidth:.infinity)
            .accessibilityElement(children:.contain)
    }
}

extension BatteryPanel {
    @ViewBuilder private var notificationsContent:some View {
        if let id=alertDeviceID,let device=model.knownDevices.first(where:{ $0.id == id }) {
            if alertComponents { alertComponentPage(device) } else { alertDevicePage(device) }
        } else {
            pageHeading("Notifications")
            SettingsGroup {
                visualPreferenceRow("Alert style",options:AlertStyle.allCases.map(\.title),selection:alerts.presentation.style.title,id:"cellio.alerts.style") { title in
                    if let style=AlertStyle.allCases.first(where:{ $0.title == title }) { alerts.selectPresentation(style:style) }
                }
                Divider().padding(.leading,12)
                if alerts.usesHUD {
                    HStack(spacing:8) {
                        Text("HUD layout").frame(maxWidth:.infinity,alignment:.leading)
                        AppearancePopup(title:"HUD layout",options:AlertHUDSize.allCases.map(\.title),selection:alerts.presentation.size.title,
                                        identifier:"cellio.alerts.hud.size",configureMenu:appearance.configure(menu:)) { title in
                            if let size=AlertHUDSize.allCases.first(where:{ $0.title == title }) { alerts.selectPresentation(size:size) }
                        }.frame(width:110,height:26)
                        HUDPositionButton(position:alerts.presentation.position) { alerts.selectPresentation(position:$0) }
                            .frame(width:140,height:26)
                    }.padding(.horizontal,12).frame(height:44).frame(maxWidth:.infinity)
                        .accessibilityElement(children:.contain)
                }
                Divider().padding(.leading,12)
                notificationStatusRow
                Divider().padding(.leading,12)
                SettingsSwitchRow(title:"Low battery alerts",name:"Low battery alerts",id:"cellio.alerts.enabled",isOn:Binding(
                    get:{alerts.configuration.enabled},set:{ enabled in alerts.edit({ $0.enabled=enabled },explicitEnable:enabled) }))
                    .disabled(alerts.policy.corrupt)
                Divider().padding(.leading,12)
                AlertThresholdRow(title:"Default threshold",identifier:"cellio.alerts.threshold",value:alerts.configuration.threshold,enabled:!alerts.policy.corrupt) { n in alerts.edit { $0.threshold=n } }
                    .disabled(alerts.policy.corrupt)
            }.onAppear { alerts.refreshPermission() }
            Text("Menu visibility doesn't change alerts. Each device defaults to All components, including newly discovered parts.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            alertPermissionContent
            if let issue=alerts.presentationIssue {
                Text(issue).font(.caption).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                    .accessibilityIdentifier("cellio.alerts.presentation.issue")
                HStack {
                    Button("Retry reading") { alerts.retryPresentationStorage() }
                        .accessibilityIdentifier("cellio.alerts.presentation.retry")
                    Button("Save displayed choice") { alerts.selectPresentation() }
                        .accessibilityIdentifier("cellio.alerts.presentation.save")
                }.frame(height:44)
            }
            if let issue=alerts.issue {
                Text(issue).font(.caption).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                HStack {
                    Button(alerts.policy.corrupt ? "Retry reading":"Retry saving") { alerts.retryStorage() }.accessibilityIdentifier("cellio.alerts.retry")
                    Button("Reset alert storage…",role:.destructive) { confirmAlertReset=true }.accessibilityIdentifier("cellio.alerts.reset")
                }.frame(height:44)
            }
            if model.knownDevices.isEmpty {
                Text(model.deviceSettings.hiddenDevices.isEmpty ? "Known devices will appear here after ordinary discovery.":"All devices are hidden. Restore them in Devices → Hidden Devices.").foregroundStyle(.secondary)
            } else {
                Text("Devices").font(.subheadline).accessibilityAddTraits(.isHeader)
                SettingsGroup {
                    ForEach(Array(model.knownDevices.enumerated()),id:\.element.id) { index,device in
                        if index > 0 { Divider().padding(.leading,12) }
                        let config=alerts.configuration.device(device.id)
                        navigationRow(device.name,value:config.included ? config.summary:"Excluded",id:"cellio.alerts.device.\(device.id)") {
                            enter("alerts.\(device.id).main",from:"cellio.alerts.device.\(device.id)") { alertDeviceID=device.id; alertComponents=false }
                        }
                    }
                }
            }
        }
    }
    private var notificationStatusRow:some View {
        ZStack {
            HStack(spacing:8) {
                Text("macOS permission").lineLimit(1)
                Spacer(minLength:8)
                Text(permissions.row(.notifications).status(for:.notifications))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Image(systemName:"chevron.right").font(.caption2)
            }.padding(.horizontal,12).frame(height:44).frame(maxWidth:.infinity)
                .accessibilityHidden(true)
            PermissionNativeButton(title:"",id:"cellio.alerts.permission",focusTransfer:permissionFocus,
                label:"macOS permission",value:permissions.row(.notifications).status(for:.notifications),overlay:true) {
                openPermissions(.notifications,from:.notifications,control:"cellio.alerts.permission")
            }
        }.frame(height:44).onAppear { permissions.refresh() }
    }
    private var notificationPreviewStatus:String? {
        // Keep the read-only coordinator's feedback aligned with the contextual retry title.
        alerts.previewStatus?.replacingOccurrences(of:"Use Check notification settings, then retry Preview.",with:"Open Permissions to check access, then retry Preview.")
    }
    @ViewBuilder private var alertPermissionContent:some View {
        if !alerts.configuration.enabled { Text("Alerts are off. Your device choices are kept.").font(.caption).foregroundStyle(.secondary) }
        Text(alerts.usesHUD ? "Shown by Cellio. macOS notification permission isn't required." : alerts.permission.description)
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        HStack(spacing:8) {
            Button("Preview notification") { alerts.previewNotification() }
                .disabled(alerts.previewInFlight || alerts.permissionActionInFlight || alerts.presentationIssue != nil)
                .accessibilityLabel("Preview notification")
                .accessibilityIdentifier("cellio.alerts.preview")
                .accessibilityValue(notificationPreviewStatus ?? "Ready")
                .help(alerts.usesHUD ? "Shows one example HUD using the saved layout and position, even when low battery alerts are off." : "Sends one example notification through macOS, even when low battery alerts are off.")
        }.frame(height:44)
        Text(!alerts.usesHUD && alerts.permissionCheckIssue != nil ? "Couldn't check notification settings. Open Permissions to check access." : (notificationPreviewStatus ?? (alerts.usesHUD ? "Show one example HUD. Low battery alerts can stay off." : "Send one example through macOS. Low battery alerts can stay off.")))
            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            .frame(maxWidth:.infinity,alignment:.leading).frame(height:32,alignment:.topLeading)
            .accessibilityIdentifier("cellio.alerts.previewStatus")
        if !alerts.usesHUD,let error=alerts.permissionCheckIssue { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal:false,vertical:true) }
        if let error=alerts.previewIssue { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal:false,vertical:true) }
        if let error=alerts.deliveryIssue { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true) }
        if let status=alerts.attemptStatus { Text(status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) }
        if alerts.schedulingAccepted {
            Text(alerts.usesHUD ? "Cellio ordered the HUD on screen. This does not confirm that it was seen or read." : "macOS accepted scheduling. This does not confirm presentation or that an alert was read.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }
    }
    private func editAlertDevice(_ id:String,_ change:(inout DeviceAlertConfiguration)->Void) {
        alerts.edit { config in var device=config.device(id); change(&device); config.devices[id]=device }
    }
    private func effectiveAlertState(_ device:KnownBatteryDevice)->String {
        if alerts.presentationIssue != nil { return "Alerts paused · presentation preferences unavailable" }
        if alerts.policy.corrupt || alerts.issue != nil { return "Alerts blocked by alert storage" }
        if !alerts.configuration.enabled { return "Global alerts are off" }
        if !alerts.configuration.device(device.id).included { return "Device excluded from alerts" }
        if !alerts.usesHUD && !alerts.permission.allowsDelivery { return "Alerts paused · \(alerts.permission.description)" }
        return alerts.eligibility(device:device)
    }
    @ViewBuilder private func alertDevicePage(_ device:KnownBatteryDevice)->some View {
        let config=alerts.configuration.device(device.id)
        backButton("Notifications") { back(from:"alerts.\(device.id).main") { alertDeviceID=nil } }
        pageHeading(device.name)
        SettingsGroup {
            SettingsSwitchRow(title:"Include this device",name:"Include \(device.name) in alerts, \(device.id)",id:"cellio.alerts.include.\(device.id)",isOn:Binding(get:{config.included},set:{ n in editAlertDevice(device.id) { $0.included=n } }))
            Divider().padding(.leading,12)
            HStack {
                Text("Threshold").frame(maxWidth:.infinity,alignment:.leading)
                Picker("Threshold",selection:Binding(get:{config.usesCustomThreshold},set:{ n in editAlertDevice(device.id) { $0.usesCustomThreshold=n } })) {
                    Text("Use default").tag(false); Text("Custom").tag(true)
                }.labelsHidden().fixedSize().accessibilityLabel("Threshold for \(device.name)").accessibilityIdentifier("cellio.alerts.thresholdMode.\(device.id)")
            }.padding(.horizontal,12).frame(height:44)
            Divider().padding(.leading,12)
            AlertThresholdRow(title:config.usesCustomThreshold ? "Custom threshold":"Default threshold",identifier:"cellio.alerts.custom.\(device.id)",value:config.usesCustomThreshold ? config.customThreshold:alerts.configuration.threshold,enabled:config.usesCustomThreshold && !alerts.policy.corrupt) { n in editAlertDevice(device.id) { $0.customThreshold=n } }
            Divider().padding(.leading,12)
            navigationRow("Alert components",value:config.summary,id:"cellio.alerts.components.\(device.id)") {
                enter("alerts.\(device.id).components",from:"cellio.alerts.components.\(device.id)") { alertComponents=true }
            }
        }.disabled(alerts.policy.corrupt)
        Text("Menu visibility doesn't change alerts. \(config.summary).")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        Text(effectiveAlertState(device)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            .accessibilityIdentifier("cellio.alerts.eligibility.\(device.id)")
        if let issue=alerts.issue {
            Text(issue).font(.caption).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true)
            Button("Back to Notifications for recovery") { alertDeviceID=nil; focusHeading() }.frame(height:44)
        }
    }
    private func alertComponentPage(_ device:KnownBatteryDevice)->some View {
        let config=alerts.configuration.device(device.id)
        let ids=KnownBatteryDevice.order(Array(Set(device.knownComponentIDs).union(config.components.ids)))
        let selected=ids.filter { config.components.includes($0) }
        return Group {
            backButton(device.name) { back(from:"alerts.\(device.id).components") { alertComponents=false } }
            pageHeading("Alert components")
            Text(config.summary).font(.caption).foregroundStyle(.secondary)
            SettingsGroup {
                HStack {
                    Text("Components").frame(maxWidth:.infinity,alignment:.leading)
                    Picker("Components",selection:Binding(get:{config.components.mode},set:{ mode in
                        editAlertDevice(device.id) { d in
                            d.components = mode == .all ? .init():ComponentSelection(mode:.selected,ids:ids)
                        }
                    })) {
                        Text("All components").tag(ComponentSelection.Mode.all)
                        Text("Selected components").tag(ComponentSelection.Mode.selected)
                    }.labelsHidden().fixedSize().disabled(ids.isEmpty)
                        .accessibilityLabel("Alert component scope for \(device.name)")
                        .accessibilityIdentifier("cellio.alerts.componentScope.\(device.id)")
                }.padding(.horizontal,12).frame(height:44).disabled(alerts.policy.corrupt)
                ForEach(Array(ids.enumerated()),id:\.element) { index,component in
                    Divider().padding(.leading,12)
                    let final=selected.count == 1 && selected.contains(component)
                    SettingsSwitchRow(title:KnownBatteryDevice.componentName(component),name:"Alert for \(KnownBatteryDevice.componentName(component)), \(device.name), \(device.id)",id:"cellio.alerts.component.\(device.id).\(component)",isOn:Binding(get:{config.components.includes(component)},set:{ on in
                        editAlertDevice(device.id) { d in
                            var next=Set(d.components.mode == .all ? ids:d.components.ids)
                            if on { next.insert(component) } else { next.remove(component) }
                            if !next.isEmpty { d.components=ComponentSelection(mode:.selected,ids:KnownBatteryDevice.order(Array(next))) }
                        }
                    })).disabled(final || alerts.policy.corrupt)
                }
            }
            Text("All components includes current and future parts. A custom selection keeps remembered parts even when absent. Keep one selected; turn off Include this device to silence it. Menu visibility doesn't change alerts.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }
    }
}
