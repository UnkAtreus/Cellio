import AppKit
import OpenBatteryCore

private final class AlertHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// One public, nonactivating native panel. No provider, permission, or policy work.
@MainActor final class OnScreenAlertPresenter: AlertHUDPresenting {
    private struct Card {
        let id: String
        let content: AlertHUDContent
        var size: AlertHUDSize
        var position: AlertHUDPosition
        let admitted: Date
        let valid: () -> Bool
        let completion: (String?) -> Void
    }
    private let now: () -> Date
    private let screens: () -> [NSScreen]
    private let pointer: () -> NSPoint
    private let safeSession: () -> Bool
    private let reduceMotion: () -> Bool
    var previewScreen: () -> NSScreen? = { nil }
    private var pending: [Card] = []
    private var visible: Card?
    private var panel: AlertHUDPanel?
    private var lifetime: Timer?
    private var expiry: Timer?
    private var tokens: [NSObjectProtocol] = []
    private var distributedTokens: [NSObjectProtocol] = []
    private var keyMonitor: Any?
    private var suspended = false
    private var relocated = false
    private var visibleSerial: UInt64 = 0
    private enum Phase { case appearing, shown, disappearing }
    private var phase: Phase?
    private var appearanceCompleted = false
    private var transitionGeneration: UInt64 = 0
    private var position: AlertHUDPosition = .topCenter

    init(now: @escaping () -> Date = Date.init,
         screens: @escaping () -> [NSScreen] = { NSScreen.screens },
         pointer: @escaping () -> NSPoint = { NSEvent.mouseLocation },
         safeSession: @escaping () -> Bool = OnScreenAlertPresenter.currentSessionIsSafe,
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.now = now; self.screens = screens; self.pointer = pointer; self.safeSession = safeSession
        self.reduceMotion = reduceMotion
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            tokens.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspend() }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            tokens.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspended = false }
            })
        }
        tokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenChanged() }
        })
        tokens.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelAll() }
        })
        tokens.append(workspace.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reduceMotionChanged() }
        })
        tokens.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspend() }
        })
        // Distributed lifecycle notices supplement the public session dictionary;
        // no event tap, global key monitor, or permission request is installed.
        for name in ["com.apple.screenIsLocked", "com.apple.screensaver.didstart"] {
            distributedTokens.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspend() }
            })
        }
        for name in ["com.apple.screenIsUnlocked", "com.apple.screensaver.didstop"] {
            distributedTokens.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspended = false }
            })
        }
    }
    deinit {
        lifetime?.invalidate(); expiry?.invalidate()
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        for token in distributedTokens { DistributedNotificationCenter.default().removeObserver(token) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }
    nonisolated static func currentSessionIsSafe() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey as String] as? Bool == true,
              session[kCGSessionLoginDoneKey as String] as? Bool == true else { return false }
        guard session["CGSSessionScreenIsLocked"] as? Bool != true else { return false }
        let workspace = NSWorkspace.shared
        guard workspace.frontmostApplication?.bundleIdentifier != "com.apple.loginwindow" else { return false }
        return !workspace.runningApplications.contains { $0.bundleIdentifier == "com.apple.ScreenSaver.Engine" }
    }
    func show(_ content: AlertHUDContent, size: AlertHUDSize, requestID: String,
              valid: @escaping () -> Bool, completion: @escaping (String?) -> Void) {
        guard !suspended, safeSession() else { completion("The desktop is unavailable."); return }
        guard valid() else { completion("Source or alert settings changed."); return }
        revalidate()
        if visible?.content.example == true { removeVisible() }
        let card = Card(id: requestID, content: content, size: size, position: position, admitted: now(), valid: valid, completion: completion)
        if visible == nil { present(card) }
        else if pending.count < 2 {
            pending.append(card); scheduleExpiry()
        } else { completion("The on-screen alert queue is full.") }
    }
    func preview(size: AlertHUDSize, completion: @escaping (String?) -> Void) {
        guard visible == nil, pending.isEmpty else {
            completion(visible?.content.example == true ? "No HUD shown. An example is already on screen." : "A battery alert is on screen. Try Preview afterward.")
            return
        }
        present(Card(id: "example", content: AlertHUDContent(), size: size, position: position, admitted: now(), valid: { true }) { error in
            completion(error.map { "No HUD shown. \($0)" })
        })
    }
    func cancel(_ identifiers: [String]) {
        let ids = Set(identifiers)
        let removed = pending.filter { ids.contains($0.id) }
        pending.removeAll { ids.contains($0.id) }
        for card in removed { card.completion("Presentation canceled.") }
        if let visible, ids.contains(visible.id) { removeVisible() }
        advance()
    }
    func cancelAll() {
        let removed = pending; pending.removeAll()
        removeVisible(); expiry?.invalidate(); expiry = nil
        for card in removed { card.completion("Presentation canceled.") }
    }
    func updateSize(_ size: AlertHUDSize) {
        for index in pending.indices { pending[index].size = size }
    }
    func updatePosition(_ position: AlertHUDPosition) {
        self.position = position
        for index in pending.indices { pending[index].position = position }
    }
    func revalidate() {
        let current = now()
        let removed = pending.filter { current.timeIntervalSince($0.admitted) >= 20 || !$0.valid() }
        let ids = Set(removed.map(\.id))
        pending.removeAll { ids.contains($0.id) }
        for card in removed { card.completion(current.timeIntervalSince(card.admitted) >= 20 ? "Queued alert expired." : "Source or alert settings changed.") }
        if let visible, !visible.valid() { removeVisible(error: "Source or alert settings changed.") }
        if suspended || !safeSession() { cancelAll(); return }
        reduceMotionChanged()
        advance()
    }
    private func suspend() { suspended = true; cancelAll() }
    private func scheduleExpiry() {
        expiry?.invalidate(); expiry = nil
        guard let first = pending.first else { return }
        let timer = Timer(timeInterval: max(0.01, 20 - now().timeIntervalSince(first.admitted)), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.revalidate() }
        }
        expiry = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func advance() {
        guard visible == nil else { scheduleExpiry(); return }
        while visible == nil, !pending.isEmpty {
            let card = pending.removeFirst()
            if now().timeIntervalSince(card.admitted) >= 20 { card.completion("Queued alert expired.") }
            else { present(card) }
        }
        scheduleExpiry()
    }
    /// Pure geometry seam: visible-frame coordinates include negative screen origins.
    static func placement(size: AlertHUDSize, componentCount: Int = 1, position: AlertHUDPosition = .topCenter,
                          visibleFrame: NSRect, backingScaleFactor: CGFloat = 1) -> (AlertHUDSize, NSRect)? {
        let safe = visibleFrame.insetBy(dx: 20, dy: 20)
        let width = CGFloat(size.points), height = CGFloat(size.height(componentCount: componentCount))
        guard componentCount > 0, safe.width >= width, safe.height >= height else { return nil }
        let x = position.column == 0 ? safe.minX : position.column == 1 ? safe.midX - width / 2 : safe.maxX - width
        let y = position.row == 0 ? safe.maxY - height : position.row == 1 ? safe.midY - height / 2 : safe.minY
        let scale = max(1, backingScaleFactor)
        let alignedX = max(safe.minX, min((x * scale).rounded() / scale, safe.maxX - width))
        let alignedY = max(safe.minY, min((y * scale).rounded() / scale, safe.maxY - height))
        return (size, NSRect(x: alignedX, y: alignedY, width: width, height: height))
    }
    private func chosenScreen(example: Bool) -> NSScreen? {
        let available = screens()
        if example, let preferred = previewScreen(), available.contains(where: { $0 === preferred }) { return preferred }
        let location = pointer()
        return available.first { NSMouseInRect(location, $0.frame, false) } ?? available.first { $0 === NSScreen.main } ?? available.first
    }
    private func present(_ card: Card) {
        guard !suspended, safeSession() else { card.completion("The desktop is unavailable."); return }
        guard card.valid() else { card.completion("Source or alert settings changed."); return }
        guard let screen = chosenScreen(example: card.content.example),
              let (size, frame) = Self.placement(size: card.size, componentCount: card.content.components.count, position: card.position,
                                                visibleFrame: screen.visibleFrame, backingScaleFactor: screen.backingScaleFactor) else {
            card.completion("No screen can safely fit this HUD."); return
        }
        guard AlertHUDView.fits(card.content, size: size) else {
            card.completion("All component labels and percentages cannot fit this HUD."); return
        }
        let panel = AlertHUDPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false; panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true; panel.isMovable = false
        panel.animationBehavior = .none
        panel.appearance = NSApp.appearance
        panel.setAccessibilityIdentifier("cellio.alerts.hud.panel")
        panel.setAccessibilityLabel(card.content.example ? "Example. Not a device reading" : "\(card.content.deviceName). Battery low")
        visibleSerial &+= 1; let serial = visibleSerial
        panel.contentView = AlertHUDView(content: card.content, size: size) { [weak self] in self?.dismiss(serial: serial) }
        panel.setFrame(frame, display: false)
        panel.alphaValue = 0
        // orderFrontRegardless does not activate the app or make this panel key.
        panel.orderFrontRegardless()
        guard panel.isVisible, panel.isOnActiveSpace, !suspended, safeSession() else {
            panel.orderOut(nil); panel.close()
            card.completion("The HUD could not be ordered on the current desktop."); return
        }
        self.panel = panel; visible = card; relocated = false
        phase = .appearing; appearanceCompleted = false
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { Task { @MainActor in self?.dismiss(serial: serial) }; return nil }
            return event
        }
        transition(panel: panel, serial: serial)
    }
    /// The animator proxy is bounded to opacity; the panel's frame never animates.
    private func transition(panel: AlertHUDPanel, serial: UInt64) {
        transitionGeneration &+= 1
        let generation = transitionGeneration
        let appearing = phase == .appearing
        if reduceMotion() {
            finishTransition(panel: panel, serial: serial, generation: generation)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = appearing ? 0.180 : 0.150
            context.timingFunction = .init(name: appearing ? .easeOut : .easeIn)
            panel.animator().alphaValue = appearing ? 1 : 0
        } completionHandler: { [weak self, weak panel] in
            // AppKit completes window animations on the main thread. Both fences
            // are checked before touching a panel, completion, timer or queue.
            MainActor.assumeIsolated {
                guard let self, let panel else { return }
                self.finishTransition(panel: panel, serial: serial, generation: generation)
            }
        }
    }
    private func setAlphaImmediately(_ alpha: CGFloat, panel: AlertHUDPanel) {
        // AppKit's documented way to stop an in-flight animator property change.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = alpha
        }
        panel.alphaValue = alpha
    }
    private func reduceMotionChanged() {
        guard reduceMotion(), let panel, phase == .appearing || phase == .disappearing else { return }
        finishTransition(panel: panel, serial: visibleSerial, generation: transitionGeneration)
    }
    private func finishTransition(panel: AlertHUDPanel, serial: UInt64, generation: UInt64) {
        guard self.panel === panel, visibleSerial == serial, transitionGeneration == generation,
              let card = visible else { return }
        if phase == .disappearing {
            removeVisible(error: "The HUD was dismissed before it fully appeared.")
            advance()
            return
        }
        guard phase == .appearing else { return }
        guard !suspended, safeSession() else { cancelAll(); return }
        guard card.valid() else {
            removeVisible(error: "Source or alert settings changed."); advance(); return
        }
        guard panel.isVisible, panel.isOnActiveSpace,
              screens().contains(where: { $0.visibleFrame.insetBy(dx: 20, dy: 20).contains(panel.frame) }) else {
            removeVisible(error: "The HUD could not appear on the current desktop."); advance(); return
        }
        transitionGeneration &+= 1
        setAlphaImmediately(1, panel: panel)
        guard panel.alphaValue == 1 else {
            removeVisible(error: "The HUD could not reach full opacity."); advance(); return
        }
        phase = .shown; appearanceCompleted = true
        let timer = Timer(timeInterval: 6, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismiss(serial: serial) }
        }
        lifetime = timer; RunLoop.main.add(timer, forMode: .common)
        let announcement = (card.content.example ? "Example. Not a device reading. " : "\(card.content.deviceName). Battery low. ")
            + card.content.components.map { "\($0.label) \($0.percent)%" }.joined(separator: ", ")
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: announcement, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        // Only a fully opaque, still eligible card is accepted. Bookkeeping and
        // lifetime are committed before calling out, allowing synchronous cancel.
        card.completion(nil)
    }
    private func removeVisible(error: String = "Presentation canceled.") {
        let removed = visible, oldPanel = panel
        let needsFailure = !appearanceCompleted
        visibleSerial &+= 1
        transitionGeneration &+= 1
        lifetime?.invalidate(); lifetime = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        panel = nil; visible = nil; phase = nil; appearanceCompleted = false
        if let oldPanel {
            setAlphaImmediately(0, panel: oldPanel)
            oldPanel.orderOut(nil); oldPanel.close()
        }
        // Clear ownership and remove the old panel before any reentrant callback.
        if needsFailure { removed?.completion(error) }
    }
    private func dismiss(serial: UInt64) {
        guard let card = visible, let panel, serial == visibleSerial, phase != .disappearing else { return }
        guard !suspended, safeSession() else { cancelAll(); return }
        guard card.valid(), panel.isVisible, panel.isOnActiveSpace,
              screens().contains(where: { $0.visibleFrame.insetBy(dx: 20, dy: 20).contains(panel.frame) }) else {
            removeVisible(); advance(); return
        }
        lifetime?.invalidate(); lifetime = nil
        phase = .disappearing
        transition(panel: panel, serial: serial)
    }
    private func screenChanged() {
        guard let panel, let card = visible else { return }
        guard !suspended, safeSession(), panel.isOnActiveSpace else { cancelAll(); return }
        let available = screens()
        if available.contains(where: { $0.visibleFrame.insetBy(dx: 20, dy: 20).contains(panel.frame) }) { return }
        guard !relocated, safeSession() else { cancelAll(); return }
        let preferred = chosenScreen(example: card.content.example)
        let candidates = available.sorted { $0 === preferred && $1 !== preferred }
        guard let frame = candidates.lazy.compactMap({ screen in
            Self.placement(size: card.size, componentCount: card.content.components.count, position: card.position,
                           visibleFrame: screen.visibleFrame, backingScaleFactor: screen.backingScaleFactor)?.1
        }).first else { cancelAll(); return }
        relocated = true
        panel.setFrame(frame, display: true)
    }
}

/// Native text, one opaque surface, and a real 24pt accessible dismiss button.
private final class AlertHUDDismissButton: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        let mark = NSBezierPath()
        let rect = bounds.insetBy(dx: 7, dy: 7)
        mark.move(to: NSPoint(x: rect.minX, y: rect.minY))
        mark.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        mark.move(to: NSPoint(x: rect.minX, y: rect.maxY))
        mark.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        mark.lineWidth = 1.5; mark.lineCapStyle = .round
        NSColor.labelColor.setStroke(); mark.stroke()
    }
    override func accessibilityFrame() -> NSRect {
        guard let window else { return super.accessibilityFrame() }
        return window.convertToScreen(convert(bounds, to: nil))
    }
}

private final class AlertHUDView: NSView {
    private struct TextRun {
        let text: String
        let rect: NSRect
        let font: NSFont
        var alignment: NSTextAlignment = .left
        var lines = 1
        var id: String
        var ax: String?
        var decorative = false
        var truncates = false
    }
    private struct Layout {
        var text: [TextRun] = []
        var glyph = NSRect.zero
        var close = NSRect.zero
        var dot: NSRect?
        var bars: [(NSRect, Int)] = []
    }
    private let layout: Layout
    private let dismiss: () -> Void
    override var isFlipped: Bool { true }

    /// The same measured plan drives admission and drawing. Only the device name
    /// may truncate; all part labels, numbers and percent signs must fit in full.
    static func fits(_ content: AlertHUDContent, size: AlertHUDSize) -> Bool {
        makeLayout(content, size: size) != nil
    }
    private static func makeLayout(_ content: AlertHUDContent, size: AlertHUDSize) -> Layout? {
        let parts = content.components, count = parts.count
        guard count > 0, parts.allSatisfy({ (0...100).contains($0.percent) }) else { return nil }
        let width = CGFloat(size.points), height = CGFloat(size.height(componentCount: count))
        var plan = Layout()
        func text(_ value: String, _ rect: NSRect, _ font: CGFloat, _ id: String,
                  alignment: NSTextAlignment = .left, ax: String? = nil, decorative: Bool = false,
                  lines: Int = 1, name: Bool = false, digits: Bool = false) {
            let face: NSFont = digits ? .monospacedDigitSystemFont(ofSize: font, weight: .medium)
                : .systemFont(ofSize: font, weight: name ? .semibold : .regular)
            plan.text.append(TextRun(text: value, rect: rect, font: face, alignment: alignment,
                                     lines: lines, id: id, ax: ax, decorative: decorative, truncates: name))
        }
        let status = content.example ? "Example · Not a device reading" : "Battery low"
        func partID(_ part: AlertHUDComponent) -> String { "cellio.alerts.hud.component.\(part.id.component)" }
        func compactRows(top: CGFloat, rowHeight: CGFloat, inset: CGFloat) -> Bool {
            guard top + CGFloat(count) * rowHeight <= height - inset else { return false }
            for (index, part) in parts.enumerated() {
                let y = top + CGFloat(index) * rowHeight
                text(part.label, NSRect(x: inset, y: y, width: width - 2 * inset - 80, height: rowHeight), 14,
                     partID(part), ax: "\(part.label) \(part.percent)%")
                text("\(part.percent)%", NSRect(x: width - inset - 72, y: y, width: 72, height: rowHeight), 14,
                     partID(part) + ".value", alignment: .right, decorative: true, digits: true)
            }
            return true
        }
        switch size {
        case .small:
            plan.glyph = NSRect(x: 12, y: 12, width: 16, height: 16)
            plan.close = NSRect(x: width - 36, y: 12, width: 24, height: 24)
            if count == 1 {
                let part = parts[0], value = "\(part.label) \(part.percent)%"
                let font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium)
                let valueWidth = ceil((value as NSString).size(withAttributes: [.font: font]).width) + 4
                let start = plan.close.minX - 8 - valueWidth
                let nameWidth = start - 8 - 36 - (content.example ? 0 : 12)
                guard nameWidth >= 40 else { return nil }
                text(content.deviceName, NSRect(x: 36, y: 11, width: nameWidth, height: 20), 13,
                     "cellio.alerts.hud.device", name: true)
                text(value, NSRect(x: start, y: 11, width: valueWidth, height: 22), 14, partID(part), digits: true)
                if !content.example { plan.dot = NSRect(x: start - 12, y: 19, width: 6, height: 6) }
                text(status, NSRect(x: 36, y: 36, width: width - 48, height: 16), 11, "cellio.alerts.hud.kind")
            } else {
                guard count <= 3 else { return nil }
                text(content.deviceName, NSRect(x: 36, y: 9, width: plan.close.minX - 44, height: 20), 13,
                     "cellio.alerts.hud.device", name: true)
                if !content.example { plan.dot = NSRect(x: 36, y: 34, width: 6, height: 6) }
                text(status, NSRect(x: content.example ? 36 : 48, y: 29, width: width - 60, height: 16), 11, "cellio.alerts.hud.kind")
                let cell = (width - 24) / CGFloat(count)
                for (index, part) in parts.enumerated() {
                    text("\(part.label) \(part.percent)%", NSRect(x: 12 + CGFloat(index) * cell, y: 52, width: cell, height: 20),
                         14, partID(part), alignment: .center, digits: true)
                }
            }
        case .medium:
            plan.glyph = NSRect(x: 16, y: 16, width: 24, height: 24)
            plan.close = NSRect(x: width - 40, y: 16, width: 24, height: 24)
            text(content.deviceName, NSRect(x: 48, y: 14, width: plan.close.minX - 56, height: 36), 14,
                 "cellio.alerts.hud.device", lines: 2, name: true)
            if !content.example { plan.dot = NSRect(x: 48, y: 57, width: 6, height: 6) }
            text(status, NSRect(x: content.example ? 48 : 60, y: 52, width: width - (content.example ? 64 : 76), height: 16),
                 11, "cellio.alerts.hud.kind")
            if count <= 3 {
                let cell = (width - 32) / CGFloat(count)
                for (index, part) in parts.enumerated() {
                    let x = 16 + CGFloat(index) * cell
                    text("\(part.percent)%", NSRect(x: x, y: count == 1 ? 78 : 99, width: cell, height: count == 1 ? 42 : 32),
                         count == 1 ? 32 : 24, partID(part) + ".value", alignment: .center, decorative: true, digits: true)
                    text(part.label, NSRect(x: x, y: count == 1 ? 126 : 139, width: cell, height: 18), 12,
                         partID(part), alignment: .center, ax: "\(part.label) \(part.percent)%")
                }
            } else if !compactRows(top: 78, rowHeight: 22, inset: 16) { return nil }
        case .large:
            plan.glyph = NSRect(x: 20, y: 20, width: 32, height: 32)
            plan.close = NSRect(x: width - 44, y: 20, width: 24, height: 24)
            text(content.deviceName, NSRect(x: 60, y: 18, width: plan.close.minX - 68, height: 42), 16,
                 "cellio.alerts.hud.device", lines: 2, name: true)
            if !content.example { plan.dot = NSRect(x: 60, y: 68, width: 6, height: 6) }
            text(status, NSRect(x: content.example ? 60 : 72, y: 62, width: width - (content.example ? 80 : 92), height: 18),
                 12, "cellio.alerts.hud.kind")
            if count == 1 {
                let part = parts[0]
                let valueWidth: CGFloat = 156
                text(part.label, NSRect(x: 20, y: 120, width: width - 40 - valueWidth - 12, height: 22), 14,
                     partID(part), ax: "\(part.label) \(part.percent)%")
                text("\(part.percent)%", NSRect(x: width - 20 - valueWidth, y: 100, width: valueWidth, height: 60), 48,
                     partID(part) + ".value", alignment: .right, decorative: true, digits: true)
                plan.bars.append((NSRect(x: 20, y: 176, width: width - 40, height: 4), part.percent))
            } else if count <= 3 {
                let rowHeight = (height - 116) / CGFloat(count)
                for (index, part) in parts.enumerated() {
                    let y = 94 + CGFloat(index) * rowHeight
                    text(part.label, NSRect(x: 20, y: y + 5, width: width - 128, height: 22), 14,
                         partID(part), ax: "\(part.label) \(part.percent)%")
                    text("\(part.percent)%", NSRect(x: width - 100, y: y, width: 80, height: 32), 24,
                         partID(part) + ".value", alignment: .right, decorative: true, digits: true)
                    plan.bars.append((NSRect(x: 20, y: y + 35, width: width - 40, height: 4), part.percent))
                }
            } else if !compactRows(top: 94, rowHeight: 24, inset: 20) { return nil }
        }
        let bounds = NSRect(x: 0, y: 0, width: width, height: height)
        guard plan.text.allSatisfy({ run in
            guard bounds.contains(run.rect), run.rect.width > 0 else { return false }
            if run.truncates { return true }
            let measured = (run.text as NSString).size(withAttributes: [.font: run.font])
            // NSTextField's native cell has a small horizontal text inset.
            return ceil(measured.width) + 4 <= run.rect.width && ceil(measured.height) <= run.rect.height
        }) else { return nil }
        return plan
    }
    init(content: AlertHUDContent, size: AlertHUDSize, dismiss: @escaping () -> Void) {
        self.dismiss = dismiss
        // Presenter admits only a completely measured, readable layout.
        guard let layout = Self.makeLayout(content, size: size) else { preconditionFailure("Unfittable HUD") }
        self.layout = layout
        super.init(frame: NSRect(x: 0, y: 0, width: CGFloat(size.points), height: CGFloat(size.height(componentCount: content.components.count))))
        setAccessibilityElement(false)
        for run in layout.text {
            let field = NSTextField(wrappingLabelWithString: run.text)
            field.frame = run.rect; field.font = run.font; field.alignment = run.alignment
            field.textColor = .labelColor; field.maximumNumberOfLines = run.lines
            field.lineBreakMode = run.truncates ? .byTruncatingTail : .byClipping
            field.setAccessibilityElement(!run.decorative)
            field.setAccessibilityLabel(run.ax ?? run.text)
            field.setAccessibilityIdentifier(run.id)
            addSubview(field)
        }
        let symbol = content.example ? "battery.100" : DeviceSymbols.symbol(name: content.deviceName, source: content.source)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "battery.100", accessibilityDescription: nil)
        let glyph = NSImageView(image: image ?? NSImage())
        glyph.frame = layout.glyph; glyph.contentTintColor = .labelColor
        glyph.imageScaling = .scaleProportionallyUpOrDown
        glyph.setAccessibilityElement(false); addSubview(glyph)
        let button = AlertHUDDismissButton(image: NSImage(), target: self, action: #selector(clicked))
        button.frame = layout.close; button.isBordered = false; button.bezelStyle = .regularSquare
        button.setAccessibilityLabel(content.example ? "Dismiss example HUD" : "Dismiss battery alert")
        button.setAccessibilityIdentifier("cellio.alerts.hud.dismiss")
        addSubview(button)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).contains(point) else { return nil }
        if let button = subviews.first(where: { $0 is NSButton }), button.frame.contains(point) { return button }
        return self
    }
    override func mouseDown(with event: NSEvent) { dismiss() }
    @objc private func clicked() { dismiss() }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.windowBackgroundColor.withAlphaComponent(1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
        NSColor.separatorColor.setStroke()
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 11.5, yRadius: 11.5)
        outline.lineWidth = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 2 : 1
        outline.stroke()
        if let dot = layout.dot {
            NSColor.systemRed.setFill(); NSBezierPath(ovalIn: dot).fill()
        }
        for (rect, percent) in layout.bars {
            NSColor.separatorColor.setFill(); NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
            if percent > 0 {
                var fill = rect; fill.size.width *= CGFloat(percent) / 100
                NSColor.secondaryLabelColor.setFill(); NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
            }
        }
    }
}
