import AppKit
import SwiftUI
import OpenBatteryCore

/// Native anchored chooser; its content never participates in Settings sizing.
struct HUDPositionButton: NSViewRepresentable {
    let position: AlertHUDPosition
    let choose: (AlertHUDPosition) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: position.title, target: context.coordinator, action: #selector(Coordinator.open(_:)))
        button.bezelStyle = .rounded; button.controlSize = .small
        button.setAccessibilityIdentifier("cellio.alerts.hud.position")
        context.coordinator.opener = button
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self
        button.title = position.title
        button.setAccessibilityLabel("HUD position")
        button.setAccessibilityValue(position.title)
        button.toolTip = "HUD position: \(position.title)"
        context.coordinator.refreshSelection()
    }
    static func dismantleNSView(_ view: NSButton, coordinator: Coordinator) {
        coordinator.popover?.delegate = nil
        coordinator.popover?.close()
    }
    @MainActor final class Coordinator: NSObject, NSPopoverDelegate {
        var parent: HUDPositionButton
        weak var opener: NSButton?
        var popover: NSPopover?
        private var targets: [HUDPositionTarget] = []
        init(_ parent: HUDPositionButton) { self.parent = parent }
        @objc func open(_ sender: NSButton) {
            if popover?.isShown == true { popover?.performClose(nil); return }
            let chooser = NSPopover()
            chooser.behavior = .transient; chooser.animates = false; chooser.delegate = self
            let controller = NSViewController()
            controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 124, height: 124))
            controller.view.setAccessibilityLabel("HUD position")
            targets = AlertHUDPosition.allCases.enumerated().map { index, position in
                let button = HUDPositionTarget(title: "", target: self, action: #selector(commit(_:)))
                button.tag = index; button.bezelStyle = .regularSquare; button.setButtonType(.toggle)
                button.frame = NSRect(x: CGFloat(10 + position.column * 36), y: CGFloat(10 + (2 - position.row) * 36), width: 32, height: 32)
                button.imagePosition = .imageOnly
                button.toolTip = position.title; button.setAccessibilityLabel(position.title)
                button.setAccessibilityIdentifier("cellio.alerts.hud.position.\(position.rawValue)")
                button.handleKey = { [weak self] event in self?.handleKey(event, index: index) ?? false }
                controller.view.addSubview(button)
                return button
            }
            for index in targets.indices { targets[index].nextKeyView = targets[(index + 1) % targets.count] }
            refreshSelection()
            chooser.contentViewController = controller; chooser.contentSize = NSSize(width: 124, height: 124)
            popover = chooser
            chooser.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
            DispatchQueue.main.async { [weak self, weak chooser] in
                guard let self, chooser?.isShown == true,
                      let index = AlertHUDPosition.allCases.firstIndex(of: self.parent.position) else { return }
                chooser?.contentViewController?.view.window?.makeFirstResponder(self.targets[index])
            }
        }
        func refreshSelection() {
            for (index, button) in targets.enumerated() {
                let position = AlertHUDPosition.allCases[index], selected = position == parent.position
                button.state = selected ? .on : .off
                button.setAccessibilityValue(selected ? "Selected" : "Not selected")
                button.setAccessibilitySelected(selected)
                let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
                    NSColor.black.setStroke(); NSColor.black.setFill()
                    let screen = NSBezierPath(roundedRect: NSRect(x: 2, y: 6, width: 20, height: 15), xRadius: 2, yRadius: 2)
                    screen.lineWidth = selected ? 2 : 1; screen.stroke()
                    NSBezierPath(rect: NSRect(x: CGFloat(4 + position.column * 7), y: CGFloat(16 - position.row * 4), width: 3, height: 3)).fill()
                    if selected {
                        let check = NSBezierPath()
                        check.move(to: NSPoint(x: 15, y: 3)); check.line(to: NSPoint(x: 18, y: 0.5)); check.line(to: NSPoint(x: 23, y: 5))
                        check.lineWidth = 1.5; check.stroke()
                    }
                    return true
                }
                image.isTemplate = true; button.image = image
            }
        }
        @objc private func commit(_ sender: NSButton) {
            guard AlertHUDPosition.allCases.indices.contains(sender.tag) else { return }
            parent.choose(AlertHUDPosition.allCases[sender.tag])
            popover?.performClose(nil)
        }
        private func handleKey(_ event: NSEvent, index: Int) -> Bool {
            switch event.keyCode {
            case 53: popover?.performClose(nil)
            case 36, 49, 76: targets[index].performClick(nil)
            case 123, 124, 125, 126:
                let row = index / 3, column = index % 3
                let nextRow = max(0, min(2, row + (event.keyCode == 125 ? 1 : event.keyCode == 126 ? -1 : 0)))
                let nextColumn = max(0, min(2, column + (event.keyCode == 124 ? 1 : event.keyCode == 123 ? -1 : 0)))
                targets[index].window?.makeFirstResponder(targets[nextRow * 3 + nextColumn])
            default: return false
            }
            return true
        }
        func popoverDidClose(_ notification: Notification) {
            popover = nil; targets.removeAll()
            if let opener { opener.window?.makeFirstResponder(opener) }
        }
    }
}

private final class HUDPositionTarget: NSButton {
    var handleKey: ((NSEvent) -> Bool)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if handleKey?(event) != true { super.keyDown(with: event) }
    }
}

/// Retained by the application, including while closed. Reopening uses the same
/// model, window and navigation state; ordinary launch never constructs a window.
@MainActor final class ManagementWindowController:NSWindowController,NSWindowDelegate {
    private let appearance:AppearancePreferencesController
    private let notificationRoute=AlertSettingsRoute()
    init(model:AppModel,appearance:AppearancePreferencesController?=nil,alerts:AlertCoordinator?=nil,login:LoginRegistrationController?=nil,updates:ApplicationUpdatesController?=nil) {
        let appearance=appearance ?? AppearancePreferencesController()
        self.appearance=appearance
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:800,height:560),
                            styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],
                            backing:.buffered,defer:false)
        window.title="Cellio Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent=true
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed=false
        window.minSize=NSSize(width:720,height:500)
        window.setFrame(NSRect(x:0,y:0,width:800,height:560),display:false)
        let host=NSHostingView(rootView:BatteryPanel(model:model,appearance:appearance,alerts:alerts,notificationRoute:notificationRoute,login:login,updates:updates))
        host.sizingOptions=[] // Window geometry belongs only to AppKit and explicit user resizing.
        window.contentView=host
        window.center()
        super.init(window:window)
        window.delegate=self
    }

    required init?(coder:NSCoder) { fatalError("init(coder:) is unsupported") }

    func present() {
        NSApp.setActivationPolicy(.regular)
        appearance.reapplyBranding()
        showWindow(nil)
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
    }

    func presentDevice(_ id:String) {
        present()
        notificationRoute.open(id)
    }

    func presentNotifications() {
        present()
        notificationRoute.openNotifications()
    }

    func windowWillClose(_ notification:Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

enum MenuAppearance {
    static func override(arguments:[String])->AppAppearanceChoice? {
        let flag=arguments.contains("--appearance") ? "--appearance" : "--preview-appearance"
        guard let index=arguments.firstIndex(of:flag),
              flag == "--appearance" || arguments.contains("--preview-window") else { return nil }
        guard index+1 < arguments.count, ["light","dark"].contains(arguments[index+1]) else {
            fputs("Usage: cellio --appearance light|dark\n",stderr)
            exit(2)
        }
        return AppAppearanceChoice(rawValue:arguments[index+1])
    }
    // Preserve the process-only native QA entry point without preference access.
    static func apply(arguments:[String]) {
        if let choice=override(arguments:arguments) { NSApplication.shared.appearance=choice.native }
    }
}

@MainActor final class AppDelegate:NSObject,NSApplicationDelegate {
    private let appearance:AppearancePreferencesController
    private var model:AppModel?
    private var statusMenu:StatusMenuController?
    private var managementWindow:ManagementWindowController?
    private var alerts:AlertCoordinator?
    private var notificationBoundary:MacAlertNotificationBoundary?
    private var hudPresenter:OnScreenAlertPresenter?
    private var launchReady=false
    private var pendingDeviceRoutes:[String]=[]
    private var pendingNotificationsRoute=false
    private var login:LoginRegistrationController?
    private var updates:ApplicationUpdatesController?

    init(appearance:AppearancePreferencesController?=nil) {
        self.appearance=appearance ?? AppearancePreferencesController()
        super.init()
    }

    func applicationWillFinishLaunching(_ notification:Notification) {
        // Install and retain the weak UN delegate before launch finishes.
        guard !CommandLine.arguments.contains("--preview-window"),notificationBoundary == nil else { return }
        let boundary=MacAlertNotificationBoundary(center:.current())
        notificationBoundary=boundary
        boundary.route={ [weak self] id in self?.showDevice(id) }
        boundary.routeNotifications={ [weak self] in self?.showNotifications() }
    }

    func applicationDidFinishLaunching(_ notification:Notification) {
        guard self.model == nil else { return }
        let model=AppModel()
        model.installStandardBluetoothBatteryProvider()
        self.model=model
        let login=LoginRegistrationController()
        let updates=ApplicationUpdatesController(startingAllowed: !CommandLine.arguments.contains("--preview-window"))
        self.login=login
        self.updates=updates
        // Preview/native probes stay memory-only; live center exists only in ordinary GUI launch.
        if let boundary=notificationBoundary {
            let policy:LowBatteryAlertPolicy
            do { policy=LowBatteryAlertPolicy(persistence:try DefaultsAlertPersistence.process(arguments:CommandLine.arguments)) }
            catch { policy=LowBatteryAlertPolicy(persistence:MemoryAlertPersistence(data:Data())) }
            let presentation:AlertPresentationStore
            do { presentation=AlertPresentationStore(persistence:try DefaultsAlertPersistence.process(arguments:CommandLine.arguments,key:"cellio.alertPresentation.v1")) }
            catch { presentation=AlertPresentationStore(persistence:MemoryAlertPersistence(data:Data())) }
            let hud=OnScreenAlertPresenter()
            hud.previewScreen={ [weak self] in self?.managementWindow?.window?.screen }
            hudPresenter=hud
            let alerts=AlertCoordinator(model:model,policy:policy,boundary:boundary,presentationStore:presentation,hud:hud)
            self.alerts=alerts
        }
        let statusMenu=StatusMenuController(model:model,appearance:appearance,updates:updates,showDetails:{ [weak self] in self?.showDetails() })
        self.statusMenu=statusMenu
        // Standard responder actions remain available for selectable diagnostics
        // and explicitly revealed pairing credentials in Settings.
        let mainMenu=NSMenu()
        let appItem=NSMenuItem()
        appItem.submenu=statusMenu.applicationMenu()
        mainMenu.addItem(appItem)
        let editItem=NSMenuItem()
        let edit=NSMenu(title:"Edit")
        edit.addItem(withTitle:"Cut",action:#selector(NSText.cut(_:)),keyEquivalent:"x")
        edit.addItem(withTitle:"Copy",action:#selector(NSText.copy(_:)),keyEquivalent:"c")
        edit.addItem(withTitle:"Paste",action:#selector(NSText.paste(_:)),keyEquivalent:"v")
        edit.addItem(withTitle:"Select All",action:#selector(NSText.selectAll(_:)),keyEquivalent:"a")
        editItem.submenu=edit
        mainMenu.addItem(editItem)
        NSApp.mainMenu=mainMenu
        appearance.configure(menu:mainMenu)
        launchReady=true
        let routes=pendingDeviceRoutes
        pendingDeviceRoutes.removeAll()
        for id in routes { showDevice(id) }
        if pendingNotificationsRoute { pendingNotificationsRoute=false; showNotifications() }
        if CommandLine.arguments.contains("--preview-window") { showDetails() }
    }

    func applicationDidBecomeActive(_ notification:Notification) {
        login?.refresh()
        updates?.refresh()
        model?.bluetoothBattery?.refresh()
    }

    private func showDetails() {
        guard let model else { return }
        if managementWindow == nil { managementWindow=ManagementWindowController(model:model,appearance:appearance,alerts:alerts,login:login,updates:updates) }
        managementWindow?.present()
    }

    private func showDevice(_ id:String) {
        guard launchReady else { pendingDeviceRoutes.append(id); return }
        guard let model else { return }
        if managementWindow == nil { managementWindow=ManagementWindowController(model:model,appearance:appearance,alerts:alerts,login:login,updates:updates) }
        managementWindow?.presentDevice(id)
    }

    private func showNotifications() {
        guard launchReady else { pendingNotificationsRoute=true; return }
        guard let model else { return }
        if managementWindow == nil { managementWindow=ManagementWindowController(model:model,appearance:appearance,alerts:alerts,login:login,updates:updates) }
        managementWindow?.presentNotifications()
    }

    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool {
        showDetails()
        return false
    }

    func applicationWillTerminate(_ notification:Notification) {
        model?.bluetoothBattery?.stop()
        alerts?.stop()
        model?.report.cancel()
        model?.hid.stop(waitUntilStopped:2)
        model?.watch.stop()
    }
}

/// One native scrolling owner with a permanently reserved legacy scroller gutter.
/// The column never tracks the user's overlay/always scrollbar preference.
struct SettingsScrollPane<Content:View>:NSViewRepresentable {
    let page:String
    @ViewBuilder var content:Content
    func makeNSView(context:Context)->RetainedSettingsScrollView {
        let view=RetainedSettingsScrollView()
        view.hasVerticalScroller=true
        view.hasHorizontalScroller=false
        view.autohidesScrollers=false
        view.scrollerStyle = .legacy
        view.drawsBackground=false
        view.contentView.drawsBackground=false
        view.setAccessibilityIdentifier("cellio.settings.scroll")
        return view
    }
    func updateNSView(_ view:RetainedSettingsScrollView,context:Context) {
        view.update(page:page,content:AnyView(content))
    }
}

private final class SettingsScrollDocument:NSView {
    override var isFlipped:Bool { true }
}

final class RetainedSettingsScrollView:NSScrollView {
    private let document=SettingsScrollDocument()
    private let host=NSHostingView(rootView:AnyView(EmptyView()))
    private var content=AnyView(EmptyView())
    private var page=""
    private var offsets:[String:NSPoint]=[:]
    private var layingOut=false
    private var pendingOffset:NSPoint?
    private var dirty=true
    private var lastWidth:CGFloat=0
    private var lastViewportHeight:CGFloat=0
    override init(frame:NSRect) {
        super.init(frame:frame)
        // The SwiftUI column owns top spacing, including the titlebar region.
        automaticallyAdjustsContentInsets=false
        contentInsets=NSEdgeInsets()
        // Keep the host at its natural height and at the document's top. Only
        // the flipped document expands to fill a short page's viewport.
        host.sizingOptions = [.intrinsicContentSize]
        document.addSubview(host)
        documentView=document
        host.setAccessibilityIdentifier("cellio.settings.column")
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is unsupported") }
    func update(page:String,content:AnyView) {
        if self.page != page {
            offsets[self.page]=contentView.bounds.origin
            self.page=page
            pendingOffset=offsets[page] ?? .zero
        }
        self.content=content
        dirty=true
        resizeDocument()
    }
    override func layout() {
        super.layout()
        resizeDocument()
    }
    func revealConnectionFeedback(_ anchor:NSView) {
        guard anchor.isDescendant(of:host) else { return }
        // Local SwiftUI feedback may have changed height since the last model update.
        resizeDocument(force:true)
        host.layoutSubtreeIfNeeded()
        let rect=document.convert(anchor.bounds,from:anchor).insetBy(dx:0,dy:-8)
        document.scrollToVisible(rect)
    }
    private func resizeDocument(force:Bool=false) {
        guard !layingOut else { return }
        layingOut=true
        defer { layingOut=false }
        let width=max(1,contentSize.width)
        let viewportHeight=contentSize.height
        guard force || dirty || width != lastWidth || viewportHeight != lastViewportHeight else { return }
        if dirty || width != lastWidth {
            host.rootView=AnyView(content.frame(width:width,alignment:.topLeading)
                .fixedSize(horizontal:false,vertical:true))
        }
        dirty=false; lastWidth=width; lastViewportHeight=viewportHeight
        // Measure only width-constrained content: viewport/document height never
        // feeds back into fitting height, including after a height-only resize.
        let contentHeight=ceil(host.fittingSize.height)
        let height=max(viewportHeight,contentHeight)
        let point=pendingOffset ?? contentView.bounds.origin
        host.frame=NSRect(x:0,y:0,width:width,height:contentHeight)
        document.setFrameSize(NSSize(width:width,height:height))
        contentView.scroll(to:NSPoint(x:0,y:max(0,min(point.y,height-viewportHeight))))
        reflectScrolledClipView(contentView)
        pendingOffset=nil
    }
}
