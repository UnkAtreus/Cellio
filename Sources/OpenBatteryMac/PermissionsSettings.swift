import SwiftUI
import AppKit

@MainActor struct PermissionsSettingsContent: View {
    @ObservedObject var permissions: NativePermissionsController
    var origin: String?
    var target: NativePermissionKind?
    var keyboardEntry: Bool
    var back: () -> Void
    @ObservedObject var focusTransfer: PermissionFocusTransfer
    var focusTicket: UUID
    @AccessibilityFocusState(for: .voiceOver) private var voiceFocus: String?
    @State private var mounted = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let origin {
                HStack {
                    PermissionNativeButton(title: "Back to \(origin)", id: "cellio.permissions.back",
                        focusTransfer: focusTransfer, borderless: true, symbol: "chevron.left", action: back)
                        .fixedSize().frame(height: 24)
                    Spacer(minLength: 0)
                }.frame(height: 24)
            }
            Text("Permissions").font(.headline).accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("cellio.content.permissions.title")
            Text("Review macOS access for Cellio.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SettingsGroup {
                ForEach(NativePermissionKind.allCases) { kind in
                    if kind != .bluetooth { Divider().padding(.leading, 12) }
                    permissionRow(kind)
                }
            }
        }
        .onAppear {
            permissions.refresh()
            mounted = true
            focusDestination()
        }
        .onChange(of: destinationFocusID) { _ in focusDestination() }
        .onDisappear { mounted = false; permissions.invalidateSettingsOpening(); focusTransfer.cancel(ticket: focusTicket) }
    }
    private var destinationFocusID: String? {
        guard mounted, let target, origin != nil,
              NativePermissionKind.allCases.allSatisfy({ permissions.rows[$0]?.phase == .idle }) else { return nil }
        return permissions.row(target).action != nil && permissions.canAct(target)
            ? "cellio.permissions.\(target.rawValue).action" : "cellio.permissions.back"
    }
    private func focusDestination() {
        guard let id = destinationFocusID, focusTransfer.isPending(focusTicket) else { return }
        if NSWorkspace.shared.isVoiceOverEnabled, let target { voiceFocus = "row.\(target.rawValue)" }
        if keyboardEntry { focusTransfer.select(id, ticket: focusTicket) }
        else { focusTransfer.cancel(ticket: focusTicket) }
    }
    private func permissionRow(_ kind: NativePermissionKind) -> some View {
        let row = permissions.row(kind)
        let id = "cellio.permissions.\(kind.rawValue)"
        let status = presentationStatus(row, kind: kind)
        let help = "\(kind.purpose) \(status) \(row.help(for: kind))"
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(kind.title).font(.system(size: 13, weight: .medium))
                Text(subtitle(kind, row: row)).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(height: 28, alignment: .topLeading)
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                if let title = row.actionTitle(for: kind) {
                    PermissionNativeButton(title: row.phase == .idle ? title : status, id: "\(id).action",
                        focusTransfer: focusTransfer, enabled: permissions.canAct(kind), small: true,
                        label: actionLabel(kind, row: row, title: title), value: status) { permissions.act(kind) }
                        .frame(width: 156, height: 24)
                        .help(help)
                } else {
                    if row.phase == .idle && row.fact.access == .allowed {
                        Image(systemName: "checkmark").foregroundStyle(.green).accessibilityHidden(true)
                    }
                    Text(status).font(.system(size: 11))
                        .foregroundStyle(Color.primary)
                        .accessibilityLabel("\(kind.title) access: \(status)")
                        .accessibilityIdentifier("\(id).status")
                }
            }.frame(width: 170, height: 24, alignment: .trailing)
        }.padding(.horizontal, 12).frame(height: 64)
            .accessibilityElement(children: .contain)
            .accessibilityHint(help)
            .help(help)
            .accessibilityFocused($voiceFocus, equals: "row.\(kind.rawValue)")
    }
    private func presentationStatus(_ row: NativePermissionRow, kind: NativePermissionKind) -> String {
        if row.phase == .waiting && row.action == .settings { return "Opening…" }
        return row.status(for: kind)
    }
    private func subtitle(_ kind: NativePermissionKind, row: NativePermissionRow) -> String {
        if row.openFailed { return "Couldn't confirm Settings opened. Open it from the Apple menu." }
        if row.fact.access == .unavailable { return "Couldn't check access. Try again." }
        if row.fact.access == .denied || (row.fact.access == .notDetermined && row.attempted) {
            let prefix = row.fact.access == .denied ? "Denied." : "Not confirmed."
            switch kind {
            case .bluetooth: return "\(prefix) Privacy & Security → Bluetooth."
            case .inputMonitoring: return "\(prefix) Privacy & Security → Input Monitoring."
            case .notifications: return "\(prefix) System Settings → Notifications."
            }
        }
        switch kind {
        case .bluetooth:
            if row.fact.access == .restricted { return "Bluetooth access is restricted on this Mac." }
            if row.fact.access == .allowed {
                switch row.fact.radio {
                case .poweredOff: return "Allowed. Turn on Bluetooth in System Settings."
                case .starting, .resetting: return "Waiting for Bluetooth…"
                case .unavailable: return "Bluetooth availability couldn't be checked."
                default: break
                }
            }
            return "Read compatible Bluetooth batteries."
        case .inputMonitoring: return "Read supported accessory batteries."
        case .notifications:
            if row.fact.access == .alertsOff { return "Alerts off. System Settings → Notifications." }
            if row.fact.access == .limited { return "Limited access. System Settings → Notifications." }
            return "Show macOS low-battery alerts."
        }
    }
    private func actionLabel(_ kind: NativePermissionKind, row: NativePermissionRow, title: String) -> String {
        switch row.action {
        case .allow: return kind == .inputMonitoring ? "Allow Input Monitoring access" : title
        case .settings: return "Open System Settings for \(kind.title)"
        case .check: return "Check \(kind.title) access again"
        case nil: return title
        }
    }
}

/// One navigation intent, consumed only by its mounted native destination.
/// Later input, route changes and unmounting invalidate it before a slow check
/// can move focus. No consent callback creates another focus intent.
@MainActor final class PermissionFocusTransfer: ObservableObject {
    @Published private(set) var target: String?
    private var ticket: UUID?
    private var route = ""
    private var inputMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private weak var entryWindow: NSWindow?
    private weak var entryResponder: NSResponder?

    func begin(ticket: UUID = UUID(), route: String, target: String? = nil) {
        cancel()
        self.ticket = ticket; self.route = route
        entryWindow = NSApp.keyWindow; entryResponder = entryWindow?.firstResponder
        self.target = target
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
            self?.cancel()
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
            object: entryWindow, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            }
    }
    func isPending(_ ticket: UUID) -> Bool { self.ticket == ticket }
    func select(_ id: String, ticket: UUID) {
        guard self.ticket == ticket, target == nil else { return }
        target = id
    }
    func cancel(ticket: UUID? = nil) {
        if let ticket, ticket != self.ticket { return }
        self.ticket = nil
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor); self.inputMonitor = nil }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver); self.resignObserver = nil }
    }
    func keepOnly(route: String) { if self.route != route { cancel() } }
    func apply(to button: PermissionResponderButton, id: String) {
        guard ticket != nil, target == id,
              let window = button.window, window === entryWindow, window.isKeyWindow,
              button.isEnabled, !button.isHiddenOrHasHiddenAncestor,
              button.bounds.width > 0, button.bounds.height > 0 else { return }
        // Also respect focus changes made through accessibility, without input.
        if let responder = window.firstResponder, responder !== entryResponder,
           responder is NSControl, responder !== button { cancel(); return }
        if window.makeFirstResponder(button) { cancel() }
    }
}

/// AppKit owns keyboard focus and Space for these contextual controls, including
/// the borderless Back button under the host's existing keyboard policy.
@MainActor struct PermissionNativeButton: NSViewRepresentable {
    var title: String
    var id: String
    @ObservedObject var focusTransfer: PermissionFocusTransfer
    var enabled = true
    var small = false
    var borderless = false
    var symbol: String? = nil
    var label: String? = nil
    var value: String? = nil
    var overlay = false
    var action: () -> Void

    func makeNSView(context: Context) -> PermissionResponderButton {
        let button = PermissionResponderButton(title: title, target: nil, action: nil)
        button.setButtonType(.momentaryPushIn)
        button.target = button; button.action = #selector(PermissionResponderButton.activate)
        return button
    }
    func updateNSView(_ button: PermissionResponderButton, context: Context) {
        button.title = title; button.isEnabled = enabled
        button.controlSize = small ? .small : .regular
        button.font = .systemFont(ofSize: small ? NSFont.smallSystemFontSize : NSFont.systemFontSize)
        button.bezelStyle = .rounded; button.isBordered = !borderless && !overlay
        button.focusRingType = .exterior
        button.rowFocusRing = overlay
        button.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        button.imagePosition = symbol == nil ? .noImage : .imageLeading
        button.setAccessibilityIdentifier(id); button.setAccessibilityLabel(label ?? title)
        button.setAccessibilityValue(value)
        button.invoke = action
        button.focusOnMount = { [weak focusTransfer, weak button] in
            guard let button else { return }
            focusTransfer?.apply(to: button, id: id)
        }
        button.focusOnMount?()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PermissionResponderButton, context: Context) -> CGSize? {
        // Only compact permission actions accept a proposed native target width.
        if !overlay {
            guard small, let width = proposal.width else { return nil }
            return CGSize(width: width, height: proposal.height ?? nsView.intrinsicContentSize.height)
        }
        return CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: proposal.height ?? 44)
    }
    static func dismantleNSView(_ button: PermissionResponderButton, coordinator: ()) {
        button.focusOnMount = nil; button.invoke = nil
    }
}

@MainActor final class PermissionResponderButton: NSButton {
    var invoke: (() -> Void)?
    var focusOnMount: (() -> Void)?
    var rowFocusRing = false
    override var acceptsFirstResponder: Bool { isEnabled }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); focusOnMount?() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); focusOnMount?() }
    override func layout() { super.layout(); focusOnMount?() }
    override var focusRingMaskBounds: NSRect { !isBordered ? bounds : super.focusRingMaskBounds }
    override func drawFocusRingMask() {
        if !isBordered { NSBezierPath(roundedRect: bounds.insetBy(dx: rowFocusRing ? 2 : 0, dy: 0), xRadius: 4, yRadius: 4).fill() }
        else { super.drawFocusRingMask() }
    }
    @objc func activate() { invoke?() }
}
