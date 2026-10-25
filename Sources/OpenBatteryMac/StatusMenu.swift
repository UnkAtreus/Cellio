import AppKit
import Combine
import OpenBatteryCore

/// Native menu tracking owns scrolling, dismissal and action-key navigation.
/// Each read-only group has an explicit fitting frame, including the empty state.
/// There is no ScrollView or externally sized window in the status-item path.
@MainActor final class StatusMenuController:NSObject,NSMenuDelegate,NSMenuItemValidation {
    private let model:AppModel
    private let appearance:AppearancePreferencesController
    private let showDetails:()->Void
    private let updates:ApplicationUpdatesController
    private var updateObservation:AnyCancellable?
    private var updateItems:[NSMenuItem]=[]
    private let statusItem=NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
    private let menu=NSMenu(title:"Cellio")
    private var readingItems:[String:NSMenuItem]=[:]
    private var observation:AnyCancellable?
    private var ageTimer:Timer?
    private var pinTimer:Timer?
    private var pinObservation:AnyCancellable?
    private var appearanceObservation:AnyCancellable?
    private var geometryObservations:[AnyCancellable]=[]
    private let pinRenderer=MenuBarStatusRenderer()
    private var tracking=false
    private var updatePending=false
    private let statusHelp=MenuStatusHoverController()

    init(model:AppModel,appearance:AppearancePreferencesController?=nil,updates:ApplicationUpdatesController?=nil,showDetails:@escaping ()->Void) {
        self.model=model
        self.updates=updates ?? ApplicationUpdatesController(startingAllowed:false)
        self.appearance=appearance ?? AppearancePreferencesController()
        self.showDetails=showDetails
        super.init()
        self.appearance.configure(menu:menu)
        menu.autoenablesItems=false
        menu.minimumWidth=324
        menu.delegate=self
        addActions(to:menu)
        statusItem.menu=menu
        if let button=statusItem.button {
            let image=NSImage(systemSymbolName:"battery.75percent",accessibilityDescription:"Cellio")
            image?.isTemplate=true
            button.image=image
            button.toolTip="Cellio — Accessory battery readings"
            button.setAccessibilityLabel("Cellio")
            button.setAccessibilityHelp("Open Cellio accessory battery readings, details and settings")
        }
        observation=model.objectWillChange.sink { [weak self] _ in
            self?.scheduleUpdate()
        }
        updateReadings()
        pinObservation=model.menuBar.objectWillChange.sink { [weak self] _ in self?.scheduleUpdate() }
        appearanceObservation=self.appearance.objectWillChange.sink { [weak self] _ in self?.scheduleUpdate() }
        for name in [NSApplication.didChangeScreenParametersNotification,NSWindow.didMoveNotification,NSWindow.didResizeNotification,NSWindow.didChangeScreenNotification] {
            geometryObservations.append(NotificationCenter.default.publisher(for:name).sink { [weak self] note in
                guard let self else { return }
                if name == NSApplication.didChangeScreenParametersNotification || (note.object as? NSWindow) === self.statusItem.button?.window { self.scheduleUpdate() }
            })
        }
        let timer=Timer(timeInterval:15,repeats:true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePins() }
        }
        pinTimer=timer
        RunLoop.main.add(timer,forMode:.common)
        RunLoop.main.add(timer,forMode:.eventTracking)
        scheduleUpdate() // Own native geometry can become available after status-item creation.
        updateObservation=self.updates.objectWillChange.sink { [weak self] _ in
            RunLoop.main.perform(inModes:[.default,.eventTracking]) { [weak self] in
                MainActor.assumeIsolated { self?.updateCheckItems() }
            }
        }
    }

    func menuNeedsUpdate(_ menu:NSMenu) { updateReadings() }

    func menuWillOpen(_ menu:NSMenu) {
        appearance.configure(menu:menu)
        updatePins()
        tracking=true
        updateReadings()
        statusHelp.start { [weak self] in
            self?.readingItems.values.compactMap { $0.view as? CompactDeviceMenuView } ?? []
        }
        let timer=Timer(timeInterval:15,repeats:true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateReadings() }
        }
        ageTimer=timer
        RunLoop.main.add(timer,forMode:.common)
        RunLoop.main.add(timer,forMode:.eventTracking)
    }

    func menuDidClose(_ menu:NSMenu) {
        tracking=false
        statusHelp.stop()
        ageTimer?.invalidate()
        ageTimer=nil
        updatePins()
    }

    private func scheduleUpdate() {
        // Published changes arrive before mutation. Coalesce and read afterwards,
        // including inside AppKit's native menu tracking run loop.
        guard !updatePending else { return }
        updatePending=true
        RunLoop.main.perform(inModes:[.default,.eventTracking]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updatePending=false
                self.updatePins()
                if self.tracking { self.updateReadings() }
            }
        }
    }

    private func updatePins() {
        pinRenderer.update(button:statusItem.button,item:statusItem,model:model,tracking:tracking,at:Date(),
                           budget:MenuBarGeometryPolicy.budget(button:statusItem.button))
    }

    deinit {
        ageTimer?.invalidate(); pinTimer?.invalidate()
        observation?.cancel(); pinObservation?.cancel(); appearanceObservation?.cancel(); updateObservation?.cancel()
        geometryObservations.forEach { $0.cancel() }
        MainActor.assumeIsolated {
            statusHelp.stop()
            statusItem.menu=nil
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    private func updateReadings() {
        let now=Date()
        let devices=BatteryMenuDevicePresentation.groups(records:model.sortedRecords,settings:model.deviceSettings,at:now)
        let count=devices.count
        var groups:[(id:String,title:String,content:MenuReadingContent)]=[]
        var header=[MenuReadingLine("Cellio",value:"\(count) \(count == 1 ? "device" : "devices")",emphasized:true)]
        if model.refreshing { header.append(MenuReadingLine("Collecting reports…",secondary:true)) }
        if model.deviceSettings.issue != nil { header.append(MenuReadingLine("Device settings error · See Details & Settings",secondary:true)) }
        groups.append(("header","Cellio",.lines(header)))
        if count == 0 {
            let allHidden = model.knownDevices.isEmpty && !model.deviceSettings.hiddenDevices.isEmpty
            let hidden = allHidden || !model.knownDevices.isEmpty || !model.sortedRecords.isEmpty
            let title = allHidden ? "All devices are hidden" : hidden ? "No devices shown" : "No battery readings yet"
            groups.append(("empty",title,.lines([
                MenuReadingLine(title),
                MenuReadingLine(allHidden ? "Restore a device from Hidden Devices." : hidden ? "Manage visibility in Details & Settings." : "Connect an accessory, then Refresh.",secondary:true)
            ])))
        }
        for device in devices {
            let baseStatus=MenuDeviceStatus.evaluate(device,
                monitoring:model.deviceSettings.preferences(for:device.id).monitorBattery,
                updatesBlocked:model.deviceSettings.updatesBlocked,at:now)
            let routeSummary=model.connectionSummary(for:device.id,at:now)
            let qualifier=baseStatus.tone == .error || !model.deviceSettings.preferences(for:device.id).monitorBattery ? " · \(baseStatus.label)":""
            let lines=routeSummary.components(separatedBy:"\n")
            let summary=(lines.first ?? "Connection unknown")+qualifier+"\n"+(lines.dropFirst().first ?? "No reading")
            let status=MenuDeviceStatus(tone:baseStatus.tone,label:baseStatus.label,help:baseStatus.help+"\n"+routeSummary,summary:summary)
            groups.append(("device:"+device.id,device.name,.device(device,status)))
        }
        // Only the receiver formatter's address list identifies failed slots.
        // Discovery/retained records prove recipients; failed probes do not.
        let records=model.sortedRecords
        let catalog=model.deviceSettings.allLogicalDevices + model.deviceSettings.rawDevices
        let provenIDs=Set(catalog.map(\.id)).union(records.map { $0.observation.id.device })
        func attributed(_ key:String,id:String,source:BatterySource?)->Bool {
            key == id || (1...6).contains { id == key+"-\($0)" }
                || (key == "systemReport" && source == .systemReport)
                || (key == "HID" && [.hidUnified,.hidLegacy,.headset].contains(source))
        }
        func hasError(_ record:BatteryRecord)->Bool {
            record.error != nil || record.observation.error != nil || record.observation.charge.isError
        }
        func failedSlotIDs(_ key:String,status:String)->Set<String>? {
            // Match the production summary, never a display name or an arbitrary
            // device-ID prefix. Both zero-success and healthy-sibling summaries
            // carry the same bounded address list (Providers.swift 190–205).
            guard let summary=status.range(of:#": (?:[0-6] accessory battery channel\(s\)|accessory battery unavailable) \(address [1-6]: "#,
                                           options:.regularExpression) else { return nil }
            let details=String(status[summary.lowerBound...])
            guard let pattern=try? NSRegularExpression(pattern:#"(?:\(address |; address )([1-6]): "#) else { return nil }
            let text=details as NSString
            return Set(pattern.matches(in:details,range:NSRange(location:0,length:text.length)).map {
                key+"-"+text.substring(with:$0.range(at:1))
            })
        }
        if model.statuses.contains(where: { key,status in
            if let slots=failedSlotIDs(key,status:status) {
                return devices.contains { device in
                    guard slots.contains(device.id), provenIDs.contains(device.id) else { return false }
                    // Selected errors already have a status token; errors on
                    // hidden components stay hidden. Evaluate each recipient so
                    // neither can swallow another slot's catalog-only failure.
                    return !records.contains { $0.observation.id.device == device.id && hasError($0) }
                }
            }
            let failed=["unavailable","denied","no compatible","failed","error"].contains { status.localizedCaseInsensitiveContains($0) }
            guard failed else { return false }
            let visible=devices.filter { attributed(key,id:$0.id,source:$0.source) }
            if visible.isEmpty {
                // Hidden devices must not reappear as a generic warning.
                return !catalog.contains { attributed(key,id:$0.id,source:$0.source) }
            }
            let errors=records.filter {
                attributed(key,id:$0.observation.id.device,source:$0.observation.source) && hasError($0)
            }
            // Unassigned manager/channel failures retain shared behavior. Check
            // missing records independently of errors belonging to hidden rows.
            return errors.isEmpty || visible.contains { device in
                !records.contains { $0.observation.id.device == device.id }
            }
        }) {
            groups.append(("unavailable","Readings unavailable",.lines([
                MenuReadingLine("Readings unavailable · See Details & Settings",secondary:true)
            ])))
        }

        // Preserve native utility items (and their keyboard selection) while
        // reconciling actual stable device identities, never display names.
        let keys=Set(groups.map(\.id))
        for (key,item) in readingItems where !keys.contains(key) {
            if let view=item.view as? CompactDeviceMenuView { statusHelp.dismiss(view: view) }
            menu.removeItem(item)
        }
        readingItems=readingItems.filter { keys.contains($0.key) }
        for (index,group) in groups.enumerated() {
            let item=readingItems[group.id] ?? NSMenuItem()
            if item.menu == nil { menu.insertItem(item,at:index) }
            else if menu.index(of:item) != index {
                menu.removeItem(item)
                menu.insertItem(item,at:index)
            }
            item.title=group.title
            switch group.content {
            case .lines(let lines):
                item.isEnabled=false
                if let view=item.view as? MenuReadingView { view.update(lines:lines) }
                else { item.view=MenuReadingView(lines:lines) }
            case .device(let device,let status):
                item.toolTip=nil
                // Freeze the summary and copy payload from the start of dwell.
                // Selection/source replacement invalidates even a visible target.
                if let view=item.view as? CompactDeviceMenuView, statusHelp.isPresenting(view: view) {
                    if view.matchesSelection(device) { break }
                    statusHelp.dismiss(view: view)
                }
                item.isEnabled=status.tone == .caution || status.tone == .error
                if let view=item.view as? CompactDeviceMenuView { view.update(device:device,status:status) }
                else { item.view=CompactDeviceMenuView(device:device,status:status) }
                if let view=item.view as? CompactDeviceMenuView {
                    view.didCopyStatus = { [weak self, weak view] in
                        if let view { self?.statusHelp.dismiss(view: view) }
                    }
                }
            }
            readingItems[group.id]=item
        }
    }

    private func action(_ title:String,_ selector:Selector,key:String="")->NSMenuItem {
        let item=NSMenuItem(title:title,action:selector,keyEquivalent:key)
        item.target=self
        return item
    }

    private func addActions(to menu:NSMenu) {
        menu.addItem(.separator())
        menu.addItem(action("Refresh",#selector(refresh),key:"r"))
        menu.addItem(action("Details & Settings…",#selector(details),key:","))
        menu.addItem(.separator())
        menu.addItem(action("About Cellio",#selector(about)))
        let check=action("Check for Updates…",#selector(checkForUpdates))
        updateItems.append(check)
        menu.addItem(check)
        updateCheckItems()
        menu.addItem(action("Quit Cellio",#selector(quit),key:"q"))
    }

    func applicationMenu()->NSMenu {
        let result=NSMenu(title:"Cellio")
        appearance.configure(menu:result)
        addActions(to:result)
        result.insertItem(withTitle:"Close Window",action:#selector(NSWindow.performClose(_:)),keyEquivalent:"w",at:result.numberOfItems-1)
        return result
    }

    @objc private func refresh() { model.refresh() }
    private func updateCheckItems() {
        for item in updateItems { item.isEnabled=updates.canCheckForUpdates }
    }
    func validateMenuItem(_ menuItem:NSMenuItem)->Bool {
        menuItem.action == #selector(checkForUpdates) ? updates.canCheckForUpdates:true
    }
    @objc private func checkForUpdates() { updates.checkForUpdates() }
    @objc private func details() { showDetails() }
    @objc private func about() {
        appearance.showStandardAbout()
    }
    @objc private func quit() { statusHelp.stop(); NSApp.terminate(nil) }
}

/// A real NSButton supplies native AXPress, keyboard activation and focus rings.
/// Neither construction nor hover calls the injected plain-text writer.
@MainActor final class MenuStatusButton:NSButton {
    let deviceID:String
    let snapshot:MenuDeviceStatus
    private let copyText:@MainActor (String)->Void

    init(deviceID:String,deviceName:String,status:MenuDeviceStatus,copyText:@escaping @MainActor (String)->Void) {
        self.deviceID=deviceID
        snapshot=status
        self.copyText=copyText
        super.init(frame:NSRect(x:0,y:0,width:24,height:24))
        title=""
        setButtonType(.momentaryPushIn)
        bezelStyle = .regularSquare
        isBordered=false
        focusRingType = .exterior
        target=self
        action=#selector(copyStatusDetails(_:))
        toolTip=nil
        setAccessibilityIdentifier("cellio.status.copy."+deviceID)
        setAccessibilityLabel("Copy status details for \(deviceName)")
        setAccessibilityValue(status.summary)
        setAccessibilityHelp(status.summary + ". Copies full status details to the clipboard.")
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is unsupported") }

    override func draw(_ dirtyRect:NSRect) {
        super.draw(dirtyRect)
        (snapshot.tone == .error ? NSColor.systemRed:NSColor.systemOrange).setFill()
        NSBezierPath(ovalIn:NSRect(x:bounds.midX-3,y:bounds.midY-3,width:6,height:6)).fill()
    }
    override var focusRingMaskBounds:NSRect { bounds.insetBy(dx:1,dy:1) }
    override func drawFocusRingMask() { NSBezierPath(roundedRect:focusRingMaskBounds,xRadius:4,yRadius:4).fill() }

    @objc private func copyStatusDetails(_ sender:Any?) {
        // A detached/recycled indicator cannot copy another device's snapshot.
        guard snapshot.tone == .caution || snapshot.tone == .error,
              let owner=superview as? CompactDeviceMenuView,
              owner.window != nil, owner.enclosingMenuItem?.menu != nil,
              owner.deviceID == deviceID, owner.statusIndicator === self,
              owner.status == snapshot else { return }
        copyText(snapshot.help)
        owner.didCopyStatus?()
    }

    static func copyToPasteboard(_ text:String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text,forType:.string)
    }
}

/// Draw the read-only 6pt visual independently of its transparent hover region.
@MainActor private final class MenuStatusDot:NSView {
    private let color:NSColor

    init(color:NSColor) {
        self.color=color
        super.init(frame:NSRect(x:0,y:0,width:24,height:24))
        setAccessibilityRole(.image)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is unsupported") }

    override func draw(_ dirtyRect:NSRect) {
        color.setFill()
        NSBezierPath(ovalIn:NSRect(x:bounds.midX-3,y:bounds.midY-3,width:6,height:6)).fill()
    }
}

@MainActor private final class MenuStatusHelpPanel:NSPanel {
    override var canBecomeKey:Bool { false }
    override var canBecomeMain:Bool { false }
}

/// One menu-scoped, nonactivating native fallback. Screen hit testing and a timer
/// work in NSMenu's tracking run loop without a global monitor or key focus.
@MainActor private final class MenuStatusHoverController {
    private var timer:Timer?
    private var escapeMonitor:Any?
    private var panel:MenuStatusHelpPanel?
    private weak var candidate:CompactDeviceMenuView?
    private weak var anchor:NSView?
    private weak var suppressedAnchor:NSView?
    private weak var candidateWindow:NSWindow?
    private var candidateRect:NSRect?
    private var candidateScreenFrame:NSRect?
    private var enteredAt=Date.distantPast
    private var shown=false

    func start(views:@escaping ()->[CompactDeviceMenuView]) {
        stop()
        let timer=Timer(timeInterval:0.08,repeats:true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll(views()) }
        }
        self.timer=timer
        RunLoop.main.add(timer,forMode:.common)
        RunLoop.main.add(timer,forMode:.eventTracking)
        escapeMonitor=NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.scrollWheel,.mouseMoved,.leftMouseDragged,.leftMouseDown]) { [weak self] event in
            if event.type == .scrollWheel || (event.type == .keyDown && event.keyCode == 53) {
                self?.dismiss(suppress:true)
            } else if event.type != .keyDown { self?.poll(views()) }
            return event // Preserve native Escape/menu handling.
        }
    }

    func stop() {
        timer?.invalidate()
        timer=nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor=nil
        dismiss()
        suppressedAnchor=nil
    }

    func isPresenting(view:CompactDeviceMenuView)->Bool { candidate === view }
    func dismiss(view:CompactDeviceMenuView) { if candidate === view { dismiss(suppress:true) } }

    private func dismiss(suppress:Bool=false) {
        if suppress { suppressedAnchor=anchor }
        panel?.orderOut(nil)
        panel?.close()
        panel=nil
        candidate=nil
        anchor=nil
        candidateWindow=nil
        candidateRect=nil
        candidateScreenFrame=nil
        shown=false
    }

    private func screenRect(_ view:NSView)->NSRect? {
        guard let window=view.window, window.isVisible, !view.isHiddenOrHasHiddenAncestor,
              !view.visibleRect.isEmpty else { return nil }
        return window.convertToScreen(view.convert(view.visibleRect,to:nil))
    }

    private func poll(_ views:[CompactDeviceMenuView]) {
        let mouse=NSEvent.mouseLocation
        guard let view=views.first(where:{ view in
            guard let indicator=view.statusIndicator, let rect=screenRect(indicator) else { return false }
            return rect.contains(mouse)
        }), let indicator=view.statusIndicator, let rect=screenRect(indicator) else {
            dismiss(); suppressedAnchor=nil; return
        }
        if suppressedAnchor === indicator { return }
        suppressedAnchor=nil
        if candidate !== view || anchor !== indicator {
            dismiss()
            candidate=view
            anchor=indicator
            candidateWindow=indicator.window
            candidateRect=rect
            candidateScreenFrame=indicator.window?.screen?.frame
            enteredAt=Date()
        } else if candidateWindow !== indicator.window || candidateRect != rect
                    || candidateScreenFrame != indicator.window?.screen?.frame {
            dismiss(suppress:true)
            return
        }
        if shown {
            if let panel, panel.isVisible, panel.isOnActiveSpace,
               panel.occlusionState.contains(.visible) {
                panel.appearance=indicator.effectiveAppearance
                return
            }
            // A failed/lost presentation must allow another attempt this dwell.
            panel?.close()
            panel=nil
            shown=false
        }
        guard !shown, Date().timeIntervalSince(enteredAt) >= 0.55,
              let rect=screenRect(indicator) else { return }
        show(text:view.status.summary,anchor:rect,view:indicator)
    }

    private func show(text:String,anchor:NSRect,view:NSView) {
        guard let menuWindow=view.window, let screen=menuWindow.screen else { return }
        let visible=screen.visibleFrame.insetBy(dx:8,dy:8)
        let width=min(280,visible.width)
        let label=NSTextField(wrappingLabelWithString:text)
        label.font=NSFont.systemFont(ofSize:11)
        label.textColor = .labelColor
        label.maximumNumberOfLines=0
        label.cell?.usesSingleLineMode=false
        label.lineBreakMode = .byWordWrapping
        label.preferredMaxLayoutWidth=width-20
        label.toolTip=nil
        // Drop the lower-priority qualifier if unusually long elapsed units
        // would wrap past two lines. Never truncate or scroll the primary reason.
        label.stringValue="Status\nReading"
        let twoLineHeight=ceil(label.intrinsicContentSize.height)
        label.stringValue=text
        if ceil(label.intrinsicContentSize.height) > twoLineHeight {
            label.stringValue=String(text.split(separator:"\n",maxSplits:1).first ?? "")
        }
        let height=ceil(label.intrinsicContentSize.height)+16
        label.frame=NSRect(x:10,y:8,width:width-20,height:height-16)
        let panel=MenuStatusHelpPanel(contentRect:NSRect(x:0,y:0,width:width,height:height),
                                    styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.isReleasedWhenClosed=false
        panel.appearance=view.effectiveAppearance
        panel.backgroundColor = .windowBackgroundColor
        panel.hasShadow=true
        panel.isFloatingPanel=true
        panel.becomesKeyOnlyIfNeeded=true
        panel.hidesOnDeactivate=false
        panel.collectionBehavior=[.moveToActiveSpace,.transient]
        panel.ignoresMouseEvents=true
        panel.level=NSWindow.Level(rawValue:NSWindow.Level.popUpMenu.rawValue+1)
        panel.contentView?.addSubview(label)
        panel.setAccessibilityLabel(label.stringValue)
        // Place beside the menu when possible, then clamp to the current screen.
        let menuFrame=menuWindow.frame
        let proposedX=menuFrame.maxX+6
        let x=proposedX+width <= visible.maxX ? proposedX:menuFrame.minX-width-6
        panel.setFrameOrigin(NSPoint(x:max(visible.minX,min(x,visible.maxX-width)),
                                     y:max(visible.minY,min(anchor.maxY-height,visible.maxY-height))))
        self.panel=panel
        panel.orderFrontRegardless() // Never makeKey/orderFront or activate NSApp.
        panel.order(.above,relativeTo:menuWindow.windowNumber)
        // This is bookkeeping, not proof of readable on-screen help. Keep failed
        // ordering retryable; native host/guest acceptance requires a capture.
        shown=panel.isVisible && panel.isOnActiveSpace
        if !shown {
            panel.close()
            self.panel=nil
        }
    }
}

private enum MenuReadingContent {
    case lines([MenuReadingLine])
    case device(BatteryMenuDevicePresentation,MenuDeviceStatus)
}

private struct MenuReadingLine {
    let text:String
    var value:String?=nil
    var symbol:String?=nil
    var secondary=false
    var emphasized=false
    var indented=false

    init(_ text:String,value:String?=nil,symbol:String?=nil,secondary:Bool=false,emphasized:Bool=false,indented:Bool=false) {
        self.text=text; self.value=value; self.symbol=symbol
        self.secondary=secondary; self.emphasized=emphasized; self.indented=indented
    }
}

/// AppKit explicitly sizes native menu items from their view frames, and adjusts
/// an open menu when those frames change (NSMenuItem.view's documented contract).
@MainActor private final class MenuReadingView:NSView {
    override var isFlipped:Bool { true }

    init(lines:[MenuReadingLine]) {
        super.init(frame:NSRect(x:0,y:0,width:324,height:1))
        update(lines:lines)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is unsupported") }

    func update(lines:[MenuReadingLine]) {
        subviews.forEach { $0.removeFromSuperview() }
        var y:CGFloat=5
        for line in lines {
            let font=NSFont.systemFont(ofSize:line.secondary ? 11:13,weight:line.emphasized ? .semibold:.regular)
            let x:CGFloat=(line.indented || line.symbol != nil) ? 30:10
            let right:CGFloat=314
            var valueWidth:CGFloat=0
            if let value=line.value {
                valueWidth=min(145,max(65,ceil((value as NSString).size(withAttributes:[.font:font]).width)+2))
            }
            let textWidth=right-x-(line.value == nil ? 0:valueWidth+8)
            let text=line.secondary ? NSTextField(wrappingLabelWithString:line.text):NSTextField(labelWithString:line.text)
            text.font=font
            text.textColor=line.secondary ? .secondaryLabelColor:.labelColor
            if line.secondary {
                text.maximumNumberOfLines=0
                text.cell?.usesSingleLineMode=false
                text.lineBreakMode = .byWordWrapping
                text.preferredMaxLayoutWidth=textWidth
            } else { text.lineBreakMode = .byTruncatingTail }
            // Measure the configured native field, including its cell insets and
            // wrapping strategy. NSString's bounds can undercount painted lines.
            let height:CGFloat=line.secondary ? max(15,ceil(text.intrinsicContentSize.height)):18
            text.frame=NSRect(x:x,y:y,width:textWidth,height:height)
            text.setAccessibilityLabel(line.text)
            text.toolTip=line.text
            addSubview(text)
            if let value=line.value {
                let quantity=NSTextField(labelWithString:value)
                quantity.font=NSFont.monospacedDigitSystemFont(ofSize:13,weight:.regular)
                quantity.alignment = .right
                quantity.lineBreakMode = .byTruncatingTail
                quantity.frame=NSRect(x:right-valueWidth,y:y,width:valueWidth,height:height)
                quantity.setAccessibilityLabel(value)
                quantity.toolTip=value
                addSubview(quantity)
            }
            if let symbol=line.symbol {
                let image=NSImageView(frame:NSRect(x:10,y:y+1,width:14,height:14))
                image.image=NSImage(systemSymbolName:symbol,accessibilityDescription:nil)
                image.contentTintColor = .secondaryLabelColor
                image.setAccessibilityElement(false)
                addSubview(image)
            }
            y += height+2
        }
        setFrameSize(NSSize(width:324,height:y+3))
    }
}

/// Native quantities and a status indicator in a menu-owned, explicitly sized group.
@MainActor final class CompactDeviceMenuView:NSView {
    override var isFlipped:Bool { true }
    private let width:CGFloat=324
    private let inset:CGFloat=10
    private let copyText:@MainActor (String)->Void
    private(set) var deviceID=""
    private(set) var status:MenuDeviceStatus!
    private(set) var statusIndicator:NSView?
    var didCopyStatus:(()->Void)?
    private var selectedComponents:[String]=[]
    private var selectedSources:[BatterySource?]=[]

    func matchesSelection(_ device:BatteryMenuDevicePresentation)->Bool {
        deviceID == device.id && selectedComponents == device.components.map(\.id)
            && selectedSources == device.components.map { $0.reading?.record.observation.source }
    }

    // Inert injection lets isolated native harnesses exercise the real button
    // action without touching a user's pasteboard. Production writes on action only.
    init(device:BatteryMenuDevicePresentation,status:MenuDeviceStatus,
         copyText:@escaping @MainActor (String)->Void=MenuStatusButton.copyToPasteboard) {
        self.copyText=copyText
        super.init(frame:NSRect(x:0,y:0,width:324,height:28))
        update(device:device,status:status)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is unsupported") }

    func update(device:BatteryMenuDevicePresentation,status:MenuDeviceStatus) {
        deviceID=device.id
        selectedComponents=device.components.map(\.id)
        selectedSources=device.components.map { $0.reading?.record.observation.source }
        self.status=status
        subviews.forEach { $0.removeFromSuperview() }
        toolTip=nil
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(device.name)
        setAccessibilityValue(status.summary)
        setAccessibilityHelp(status.summary)

        func field(_ text:String,x:CGFloat,y:CGFloat,width:CGFloat,font:NSFont,
                   secondary:Bool=false,label:String?=nil,value:String?=nil)->NSTextField {
            let field=NSTextField(labelWithString:text)
            field.font=font
            field.textColor=secondary ? .secondaryLabelColor:.labelColor
            field.lineBreakMode = .byTruncatingTail
            field.frame=NSRect(x:x,y:y,width:max(1,width),height:18)
            field.toolTip=nil
            field.setAccessibilityLabel(label ?? text)
            if let value { field.setAccessibilityValue(value) }
            field.setAccessibilityHelp(status.summary)
            addSubview(field)
            return field
        }
        let nameFont=NSFont.systemFont(ofSize:13)
        let secondaryFont=NSFont.systemFont(ofSize:11)
        let quantityFont=NSFont.monospacedDigitSystemFont(ofSize:13,weight:.regular)
        func textWidth(_ text:String,_ font:NSFont)->CGFloat {
            ceil((text as NSString).size(withAttributes:[.font:font]).width)+4
        }
        func compactValue(_ component:BatteryMenuComponentPresentation)->String {
            guard let quantity=component.reading?.record.observation.quantity else { return "Not reported" }
            switch quantity {
            case .estimatedPercent(let value,_): return "≈\(value)% est."
            case .coarse(let name,let level): return "Coarse: \(name.isEmpty ? level.map { "Level \($0)" } ?? "Unknown" : name)"
            default: return component.value
            }
        }
        func quantityLabel(_ component:BatteryMenuComponentPresentation)->String {
            "\(device.name), \(component.id == "battery" ? "Battery" : component.title+" battery")"
        }
        // The projection includes selected missing identities and excludes hidden parts.
        let components=device.components
        let batterySingleton=components.count == 1 && components[0].id == "battery"
        let partSingleton=components.count == 1 && !batterySingleton
        let available=width-2*inset
        let part=partSingleton ? components.first:nil
        let partLabelWidth=part.map { textWidth($0.title,secondaryFont) } ?? 0
        let partValueWidth=part.map { textWidth(compactValue($0),quantityFont) } ?? 0
        // Reserve name, explicit part, status target and the complete quantity.
        let inlinePart=partSingleton && partLabelWidth+partValueWidth+6+24+10+36 <= width-inset-30
        let single=batterySingleton || inlinePart
        var right=width-inset
        if single,let component=components.first {
            let value=compactValue(component)
            let valueWidth=batterySingleton ? min(148,textWidth(value,quantityFont)):partValueWidth
            let quantity=field(value,x:right-valueWidth,y:5,width:valueWidth,font:quantityFont,
                label:quantityLabel(component),value:component.value)
            quantity.alignment = .right
            right -= valueWidth+8
        }
        let indicator:NSView
        if status.tone == .caution || status.tone == .error {
            indicator=MenuStatusButton(deviceID:device.id,deviceName:device.name,status:status,copyText:copyText)
        } else {
            let dot=MenuStatusDot(color:status.tone == .current ? .systemGreen:.tertiaryLabelColor)
            dot.setAccessibilityElement(true)
            dot.setAccessibilityLabel("\(device.name), \(status.summary)")
            dot.setAccessibilityValue(status.summary)
            dot.setAccessibilityHelp(status.summary)
            dot.setAccessibilityIdentifier("cellio.status.indicator."+device.id)
            indicator=dot
        }
        // Keep the 6pt visual centered within the native 24pt action target.
        indicator.frame=NSRect(x:right-15,y:2,width:24,height:24)
        indicator.toolTip=nil
        statusIndicator=indicator
        addSubview(indicator)
        right -= batterySingleton ? 12:16
        if inlinePart,let part {
            _=field(part.title,x:right-partLabelWidth,y:5,width:partLabelWidth,font:secondaryFont,secondary:true)
            right -= partLabelWidth+6
        }
        _=field(device.name,x:30,y:5,width:right-30,font:nameFont)
        let image=NSImageView(frame:NSRect(x:inset,y:6,width:14,height:14))
        image.image=NSImage(systemSymbolName:DeviceSymbols.symbol(name:device.name,source:device.source,kind:device.kind),accessibilityDescription:nil)
        image.contentTintColor = .secondaryLabelColor
        image.setAccessibilityElement(false)
        addSubview(image)

        var height:CGFloat=28
        if !single && !components.isEmpty {
            // Ordinary two/three-part selections use the whole balanced strip.
            // Long quantities retain their precision in compact labeled rows.
            let cellWidth=(available-CGFloat(components.count-1)*12)/CGFloat(components.count)
            let balanced=components.allSatisfy {
                textWidth($0.title,secondaryFont)+6+textWidth(compactValue($0),quantityFont) <= cellWidth
            }
            var rows:[[BatteryMenuComponentPresentation]]=[]
            if balanced { rows=[components] }
            else {
                var row:[BatteryMenuComponentPresentation]=[]
                var needed:CGFloat=0
                for component in components {
                    let size=textWidth(component.title,secondaryFont)+6+textWidth(compactValue(component),quantityFont)
                    // Equal cells must fit every label/value, not just their sum.
                    let next=row+[component]
                    let nextWidth=(available-CGFloat(next.count-1)*12)/CGFloat(next.count)
                    if !row.isEmpty && max(needed,size)>nextWidth {
                        rows.append(row); row=[]; needed=0
                    }
                    row.append(component); needed=max(needed,size)
                }
                if !row.isEmpty { rows.append(row) }
            }
            var y:CGFloat=26
            for row in rows {
                let cellWidth=(available-CGFloat(row.count-1)*12)/CGFloat(row.count)
                var rowHeight:CGFloat=18
                for (column,component) in row.enumerated() {
                    let x=inset+CGFloat(column)*(cellWidth+12)
                    let value=compactValue(component)
                    let labelWidth=min(textWidth(component.title,secondaryFont),cellWidth*0.45)
                    let valueWidth=cellWidth-labelWidth-6
                    _=field(component.title,x:x,y:y,width:labelWidth,font:secondaryFont,secondary:true)
                    let quantity=field(value,x:x+labelWidth+6,y:y,width:valueWidth,font:quantityFont,
                        label:quantityLabel(component),value:component.value)
                    quantity.alignment = .right
                    if textWidth(value,quantityFont)>valueWidth {
                        quantity.maximumNumberOfLines=0
                        quantity.cell?.usesSingleLineMode=false
                        quantity.lineBreakMode = .byCharWrapping
                        quantity.preferredMaxLayoutWidth=valueWidth
                        let h=max(18,ceil(quantity.intrinsicContentSize.height))
                        quantity.setFrameSize(NSSize(width:valueWidth,height:h))
                        rowHeight=max(rowHeight,h)
                    }
                }
                y += rowHeight+4
            }
            height=y+2
        }
        setFrameSize(NSSize(width:width,height:height))
        addSubview(indicator,positioned:.above,relativeTo:nil)
        // The menu-scoped panel is the sole hover owner, including over labels.
        toolTip=nil
        removeAllToolTips()
        subviews.forEach { $0.toolTip=nil; $0.removeAllToolTips() }
    }
}
