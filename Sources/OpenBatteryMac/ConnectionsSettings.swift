import AppKit
import SwiftUI
import OpenBatteryCore

@MainActor struct ConnectionsSettings: View {
    @ObservedObject var model: AppModel
    let deviceID: String
    @Binding var selecting: Bool
    let details: () -> Void
    @State private var selection=Set<String>()
    @State private var saving=false
    @State private var confirming=false
    @State private var recoveryTask: Task<Void,Never>?
    @State private var operationID=UUID()
    @State private var issue: String?
    @State private var selectionOrder: [String] = []
    @State private var feedbackReveal=0
    @State private var sourcesExpanded=false
    @StateObject private var sourcesControl=SourcesButtonCoordinator()
    @FocusState private var sourceFocus: String?
    @FocusState private var linkFocus: Bool
    @FocusState private var retryFocus: Bool
    private var feedbackMessage: String? { issue ?? model.connectionIssue ?? selectionError }
    private var members: [String] { model.deviceSettings.members(of:deviceID) }
    private var catalog: PhysicalDeviceCatalog { model.deviceSettings.physicalCatalog }
    private var selectionError: String? {
        guard !selection.isEmpty else { return nil }
        do { _ = try model.previewConnections(current:deviceID,selected:Array(selection)); return nil }
        catch { return error.localizedDescription }
    }
    private var candidates: [KnownBatteryDevice] {
        let all=model.knownDevices.filter { $0.id != deviceID }
        return all.sorted { a,b in
            let ia=selectionOrder.firstIndex(of:a.id) ?? Int.max, ib=selectionOrder.firstIndex(of:b.id) ?? Int.max
            return ia == ib ? a.id < b.id:ia < ib
        }
    }
    private func routeText(_ id: String) -> String {
        let saved=model.deviceSettings.members(of:id)
        if saved.count > 1 { return "\(saved.count) saved connections · selected as a complete group" }
        return catalog.routes.first { $0.id == (saved.first ?? id) }?.metadata.type.label ?? BatteryRouteType.unknown.label
    }
    private func status(_ route: String) -> String {
        if let state=model.routeConnections[route] {
            switch state { case .connected: return "Connected"; case .disconnected: return "Disconnected"; case .unavailable: return "Connection unavailable"; case .unknown: return "Connection unknown" }
        }
        let records=model.rawRecords.filter { $0.observation.id.device == route }
        if records.contains(where: { $0.observation.connection == .connected }) { return "Connected" }
        if !records.isEmpty && records.allSatisfy({ $0.observation.connection == .disconnected }) { return "Disconnected" }
        return records.contains(where: { $0.observation.connection == .unavailable }) ? "Connection unavailable":"Connection unknown"
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text(selecting ? "Link connections":"Connections").font(.title2).fontWeight(.semibold)
            if selecting {
                Text("Choose entries that belong to this same physical device.").font(.callout).foregroundStyle(.secondary)
                ConnectionSelectionTable(rows:candidates.map { device in
                    let ids=model.deviceSettings.members(of:device.id)
                    let record=model.rawRecords.first { ids.contains($0.observation.id.device) && $0.observation.quantity.isKnown }
                    let reading=record.map { "\($0.retained ? "Last known · ":"")\($0.ageDescription(at:Date()))" } ?? "No reading"
                    return ConnectionSelectionRow(id:device.id,name:device.name,symbol:DeviceSymbols.symbol(name:device.name,source:device.source,kind:device.kind),detail:routeText(device.id)+" · "+Set(ids.map(status)).sorted().joined(separator:" / ")+" · "+reading)
                },selection:$selection,onReturn:review,onCancel:cancel)
                .disabled(recoveryTask != nil)
                .frame(height:CGFloat(max(1,candidates.count))*68)
                Text("Choose complete entries. Incompatible or unproved component mappings cannot be linked. Connection details preserve the original route identities.")
                    .font(.caption).foregroundStyle(.secondary)
                VStack(alignment:.leading,spacing:12) {
                    feedback
                    HStack {
                        Spacer()
                        Button("Cancel",action:cancel).keyboardShortcut(.cancelAction)
                        Button(saving ? "Linking…":"Link…",action:review).disabled(selection.isEmpty || selectionError != nil || saving || confirming || recoveryTask != nil)
                            .focused($linkFocus).accessibilityIdentifier("cellio.connections.review")
                    }.frame(height:32)
                }.background(ConnectionFeedbackReveal(request:issue == nil ? 0:feedbackReveal))
            } else {
                if catalog.groups.first(where: { $0.id == deviceID })?.settingsDiffered == true {
                    Text("Some connection settings differed and remain off.").font(.caption).foregroundStyle(.secondary)
                }
                let summary=connectionSummary
                SettingsGroup {
                    ForEach(Array(summary.rows.enumerated()),id:\.element.type) { index,row in
                        if index > 0 { Divider().padding(.leading,12) }
                        VStack(alignment:.leading,spacing:6) {
                            HStack {
                                Text(row.type.label).fontWeight(.medium)
                                Spacer(minLength:8)
                                Text(ConnectionSummaryPolicy.label(row.state)).foregroundStyle(.secondary)
                            }
                            batteryOriginLine(row.usedForBattery)
                        }.padding(12).frame(maxWidth:.infinity,alignment:.leading)
                    }
                }
                if let context=summary.unknownContext {
                    Text(context).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).frame(height:32,alignment:.topLeading)
                        .frame(maxWidth:.infinity,alignment:.leading)
                }
                HStack {
                    Button("Link connections…") {
                        selection=[]; issue=nil
                        selectionOrder=model.knownDevices.filter { $0.id != deviceID }.sorted { $0.id < $1.id }.map(\.id)
                        selecting=true
                    }.accessibilityIdentifier("cellio.connections.select")
                    Spacer()
                    Button("Connection details…",action:details)
                }.frame(height:32)
                VStack(alignment:.leading,spacing:0) {
                    SourcesButton(deviceID:deviceID,sourceCount:members.count,
                                  expanded:$sourcesExpanded,focus:sourcesControl)
                        .fixedSize()
                    if sourcesExpanded {
                    VStack(alignment:.leading,spacing:12) {
                        Text("More than one source can report the same connection. Unlinking separates one saved source in Cellio.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                        SettingsGroup {
                            ForEach(Array(members.enumerated()),id:\.element) { index,member in
                                if index > 0 { Divider().padding(.leading,12) }
                                savedSource(member,usedForBattery:summary.members.first { $0.id == member }?.usedForBattery == true)
                            }
                        }
                    }.padding(.top,8)
                    .onDisappear {
                        sourcesControl.childrenRemoved(deviceID:deviceID)
                    }
                    }
                }
                VStack(alignment:.leading,spacing:12) { feedback }
                    .background(ConnectionFeedbackReveal(request:issue == nil ? 0:feedbackReveal))
            }
        }.disabled(saving || confirming)
            .onDisappear { invalidateOperation() }
            .onChange(of:deviceID) { _ in invalidateOperation(); selection=[]; issue=nil }
            .onChange(of:selecting) { _ in invalidateOperation() }
            .onDisappear { sourcesControl.cancel() }
            .onChange(of:deviceID) { _ in sourcesControl.cancel() }
            .onChange(of:selecting) { _ in sourcesControl.cancel() }
            .onChange(of:issue) { message in
                // Unlink keeps its original transaction; reveal its existing failure feedback.
                if !selecting, message != nil { feedbackReveal &+= 1; sourceFocus=nil; retryFocus=true }
            }
    }
    private var connectionSummary: ConnectionSummaryPolicy {
        let origins=Set(model.physicalProjection.origins.filter { $0.key.device == deviceID }.values)
        return ConnectionSummaryPolicy(members:members.map { member in
            let states=model.rawRecords.filter { $0.observation.id.device == member }.map { $0.observation.connection }
            return .init(id:member,type:catalog.routes.first { $0.id == member }?.metadata.type ?? .unknown,
                         state:model.routeConnections[member] ?? ConnectionSummaryPolicy.fallbackState(states),
                         usedForBattery:origins.contains(member))
        })
    }
    private func batteryOriginLine(_ selected: Bool) -> some View {
        // Reserve the secondary line even when provenance moves to another source.
        Text("Used for battery").font(.caption).foregroundStyle(.secondary)
            .opacity(selected ? 1:0).accessibilityHidden(!selected)
    }
    private func savedSource(_ member: String, usedForBattery: Bool) -> some View {
        let type=catalog.routes.first { $0.id == member }?.metadata.type ?? .unknown
        let device=model.deviceSettings.rawDevices.first { $0.id == member }
        let collector=ConnectionSummaryPolicy.collectorLabel(device?.source)
        return VStack(alignment:.leading,spacing:6) {
            HStack {
                Text(type.label+" · "+collector).fontWeight(.medium)
                Spacer(minLength:8)
                Text(status(member)).foregroundStyle(.secondary)
            }
            batteryOriginLine(usedForBattery)
            Text(device?.name ?? member).font(.caption)
                .accessibilityLabel((device?.name ?? "Saved source")+", "+member)
            if members.count > 1 {
                Button("Unlink source…") { confirmUnlink(member) }.font(.caption)
                    .focused($sourceFocus,equals:member)
                    .accessibilityLabel("Unlink source, \(type.label), \(collector), \(member)")
            }
        }.padding(12).frame(maxWidth:.infinity,alignment:.leading)
    }
    @ViewBuilder private var feedback: some View {
        if let message=feedbackMessage {
            Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if !saving {
                Button("Try Again",action:retry)
                    .disabled(recoveryTask != nil)
                    .focused($retryFocus).accessibilityIdentifier("cellio.connections.retry")
            }
        }
    }
    private func revealFailure(_ message: String) {
        issue=message
        feedbackReveal &+= 1
        linkFocus=false; retryFocus=true
    }
    private func invalidateOperation() {
        recoveryTask?.cancel(); recoveryTask=nil
        operationID=UUID(); confirming=false
    }
    private func cancel() { guard !saving, !confirming else { return }; invalidateOperation(); selection=[]; issue=nil; selecting=false }
    private func retry() {
        guard !saving, !confirming, recoveryTask == nil else { return }
        let ticket=operationID, wasSelecting=selecting
        // Own one retry across the native action boundary; navigation can revoke it.
        recoveryTask=Task { @MainActor in
            guard !Task.isCancelled, ticket == operationID, selecting == wasSelecting else { return }
            let recovered=model.retryConnectionStorageSave()
            guard !Task.isCancelled, ticket == operationID, selecting == wasSelecting else { return }
            recoveryTask=nil
            guard recovered else { revealFailure(model.connectionIssue ?? ConnectionGroupingError.storage.localizedDescription); return }
            issue=nil; retryFocus=false
            if selecting { review() }
        }
    }
    private func review() {
        guard selecting, !saving, !confirming, recoveryTask == nil, !selection.isEmpty else { return }
        do {
            let preview=try model.previewConnections(current:deviceID,selected:Array(selection))
            issue=nil
            let raw=Dictionary(uniqueKeysWithValues:model.deviceSettings.rawDevices.map { ($0.id,$0) })
            let membership=preview.members.map { route in
                "\(raw[route]?.name ?? "Accessory") · \(catalog.routes.first { $0.id == route }?.metadata.type.label ?? BatteryRouteType.unknown.label)\n\(route)"
            }.joined(separator:"\n\n")
            let ticket=operationID
            confirming=true
            nativeConfirmation(title:"Link these connections?",message:"Confirm these entries are the same physical device. They will share monitoring, menu and notification settings in Cellio.",detail:preview.summary+"\n\n"+(preview.settingsDiffered ? "Settings that were off stay off. Review the shared settings before linking.\n\n":"")+membership,action:"Link") { accepted in
                guard ticket == operationID, selecting else { return }
                confirming=false
                guard accepted else { linkFocus=true; return }
                saving=true
                Task { @MainActor in
                    await Task.yield()
                    guard ticket == operationID, selecting else { saving=false; return }
                    let linked=model.linkConnections(preview)
                    saving=false
                    if linked { selection=[]; selecting=false; issue=nil; linkFocus=true }
                    else { revealFailure(model.connectionIssue ?? ConnectionGroupingError.storage.localizedDescription) }
                }
            }
        } catch { revealFailure(error.localizedDescription) }
    }
    private func confirmUnlink(_ member: String) {
        guard !saving, !confirming else { return }
        confirming=true
        // Snapshot membership/settings for confirmation, while ordinary samples remain free to change.
        let before=catalog.groups.first { $0.id == deviceID }
        let ticket=operationID
        nativeConfirmation(title:"Unlink this source?",message:"This source will appear as a separate device in Cellio. Each device keeps the current shared settings. This won’t disconnect it from your Mac.",detail:member,action:"Unlink") { accepted in
            guard ticket == operationID else { return }
            confirming=false
            guard accepted else { return }
            guard model.deviceSettings.physicalCatalog.groups.first(where: { $0.id == deviceID }) == before else { issue=ConnectionGroupingError.changed.localizedDescription; return }
            saving=true
            Task { @MainActor in
                await Task.yield()
                guard ticket == operationID else { saving=false; return }
                if !model.unlinkConnection(member:member,from:deviceID) { issue=model.connectionIssue } else { issue=nil }
                saving=false
            }
        }
    }
}

/// Read-only presentation inside an already established membership. No identity inference.
/// Internal value types keep the evidence policy available to independent source-only checks.
struct ConnectionSummaryPolicy {
    struct Member {
        let id: String
        let type: BatteryRouteType
        let state: ConnectionState
        let usedForBattery: Bool
    }
    struct Row {
        let type: BatteryRouteType
        let state: ConnectionState
        let usedForBattery: Bool
    }
    let members: [Member]
    var rows: [Row] {
        let known: [BatteryRouteType] = [.bluetooth,.wiredUSB,.wirelessReceiver]
        let types=known.filter { type in members.contains { $0.type == type } }
        return (types.isEmpty ? [.unknown]:types).map { type in
            let sources=members.filter { $0.type == type }
            return Row(type:type,state:Self.aggregate(sources.map(\.state)),usedForBattery:sources.contains { $0.usedForBattery })
        }
    }
    var unknownContext: String? {
        let unknown=members.filter { $0.type == .unknown }
        guard !unknown.isEmpty, members.contains(where: { $0.type != .unknown }) else { return nil }
        if unknown.contains(where: { $0.usedForBattery }) { return "Used for battery · Connection type unknown" }
        if unknown.contains(where: { $0.state == .connected }) { return "Active connection type unknown" }
        return "Some saved sources have no connection type."
    }
    /// A positive member can establish an active transport; every member must confirm disconnection.
    /// Unavailable is conclusive only when no unresolved member remains.
    static func aggregate(_ states: [ConnectionState]) -> ConnectionState {
        if states.contains(.connected) { return .connected }
        guard !states.isEmpty, !states.contains(.unknown) else { return .unknown }
        if states.allSatisfy({ $0 == .disconnected }) { return .disconnected }
        return states.contains(.unavailable) ? .unavailable:.unknown
    }
    /// Without a current route state, contradictory component evidence remains unresolved.
    static func fallbackState(_ states: [ConnectionState]) -> ConnectionState {
        guard let first=states.first, states.allSatisfy({ $0 == first }) else { return .unknown }
        return first
    }
    static func label(_ state: ConnectionState) -> String {
        switch state {
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
        case .unavailable: return "Connection unavailable"
        case .unknown: return "Connection unknown"
        }
    }
    /// Collector labels use saved collector evidence only; they never supply a transport type.
    static func collectorLabel(_ source: BatterySource?) -> String {
        switch source {
        case .systemReport: return "macOS report"
        case .standardBluetooth: return "Bluetooth battery"
        case .hidUnified, .hidLegacy: return "Logitech report"
        case .headset: return "Headset receiver"
        case .usbPresence: return "USB presence"
        case .watchCompanion: return "Watch companion"
        case nil: return "Saved source"
        }
    }
}

/// One visible native control; SwiftUI owns disclosure content, AppKit owns its responder.
private struct SourcesButton: NSViewRepresentable {
    let deviceID: String
    let sourceCount: Int
    @Binding var expanded: Bool
    let focus: SourcesButtonCoordinator
    func makeCoordinator() -> SourcesButtonCoordinator { focus }
    func makeNSView(context: Context) -> NativeSourcesButton {
        let button=NativeSourcesButton()
        button.cell=SourcesButtonCell(textCell:"")
        button.target=context.coordinator; button.action=#selector(SourcesButtonCoordinator.toggle(_:))
        button.bezelStyle = .rounded; button.setButtonType(.momentaryPushIn)
        button.font=NSFont.systemFont(ofSize:NSFont.systemFontSize)
        button.imagePosition = .imageLeading
        button.setAccessibilityIdentifier("cellio.connections.sources")
        return button
    }
    func updateNSView(_ button: NativeSourcesButton, context: Context) {
        let title="Saved sources (\(sourceCount))"
        button.title=title
        let image=NSImage(systemSymbolName:expanded ? "chevron.down":"chevron.right",accessibilityDescription:nil)?.copy() as? NSImage
        image?.size=NSSize(width:10,height:12); button.image=image
        button.isEnabled=context.environment.isEnabled
        button.setAccessibilityLabel(title)
        button.setAccessibilityValue(expanded ? "Expanded":"Collapsed")
        button.invalidateIntrinsicContentSize()
        context.coordinator.update(button:button,deviceID:deviceID,expanded:expanded) { expanded=$0 }
    }
    static func dismantleNSView(_ button: NativeSourcesButton, coordinator: SourcesButtonCoordinator) {
        coordinator.detach(button)
        button.target=nil; button.action=nil
    }
}

private final class NativeSourcesButton: NSButton {
    // AX focus and makeFirstResponder must work independently of the OS Tab policy.
    override var acceptsFirstResponder: Bool { isEnabled }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override var intrinsicContentSize: NSSize {
        let attributes: [NSAttributedString.Key:Any]=[.font:font ?? NSFont.systemFont(ofSize:NSFont.systemFontSize)]
        let width=(title as NSString).size(withAttributes:attributes).width
        let reference=("Saved sources (3)" as NSString).size(withAttributes:attributes).width
        // Preserve the existing 150 × 24 one-digit trigger; extra count digits grow naturally.
        return NSSize(width:150+ceil(width)-ceil(reference),height:24)
    }
}

/// Match the original 10 × 12 chevron slot and six-point label gap within the native bezel.
private final class SourcesButtonCell: NSButtonCell {
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        var result=super.titleRect(forBounds:rect)
        let width=(title as NSString).size(withAttributes:[.font:font ?? NSFont.systemFont(ofSize:NSFont.systemFontSize)]).width
        result.origin.x=rect.midX-(width+16)/2+16
        result.size.width=width
        return result
    }
    override func imageRect(forBounds rect: NSRect) -> NSRect {
        let width=(title as NSString).size(withAttributes:[.font:font ?? NSFont.systemFont(ofSize:NSFont.systemFontSize)]).width
        return NSRect(x:rect.midX-(width+16)/2,y:rect.midY-6,width:10,height:12)
    }
}

@MainActor private final class SourcesButtonCoordinator: NSObject, ObservableObject {
    private weak var button: NativeSourcesButton?
    private weak var requestWindow: NSWindow?
    private var deviceID: String?
    private var expanded=false
    private var setExpanded: ((Bool)->Void)?
    private var request: UUID?

    func update(button: NativeSourcesButton, deviceID: String, expanded: Bool, setExpanded: @escaping (Bool)->Void) {
        if self.deviceID != deviceID || expanded || !button.isEnabled { cancel() }
        self.button=button; self.deviceID=deviceID
        self.expanded=expanded; self.setExpanded=setExpanded
        // An ordinary model/render update deliberately preserves a pending collapse request.
    }
    @objc func toggle(_ sender: NativeSourcesButton) {
        guard sender === button, sender.isEnabled, let window=sender.window else { return }
        cancel()
        if expanded {
            request=UUID(); requestWindow=window
        }
        expanded.toggle()
        setExpanded?(expanded)
    }
    func childrenRemoved(deviceID: String) {
        guard self.deviceID == deviceID, !expanded,
              let ticket=request, let button, let window=requestWindow else { return }
        // One main-queue turn after the child disappearance, with no timer or retry loop.
        DispatchQueue.main.async { [weak self, weak button, weak window] in
            guard let self, let button, let window,
                  self.request == ticket, self.deviceID == deviceID, !self.expanded,
                  self.button === button, button.window === window, window.isKeyWindow,
                  button.isEnabled, !button.isHiddenOrHasHiddenAncestor else { return }
            // Refresh collapsed geometry and reveal this control through the existing owner.
            (button.enclosingScrollView as? RetainedSettingsScrollView)?.revealConnectionFeedback(button)
            guard self.request == ticket, self.button === button, button.window === window,
                  window.isKeyWindow, button.isEnabled else { return }
            self.cancel()
            window.makeFirstResponder(button)
        }
    }
    func cancel() { request=nil; requestWindow=nil }
    func detach(_ button: NativeSourcesButton) {
        guard self.button === button else { return }
        cancel(); self.button=nil; setExpanded=nil; deviceID=nil
    }
}

/// Reveal feedback and its native actions together through the existing scroll owner.
private struct ConnectionFeedbackReveal: NSViewRepresentable {
    let request: Int
    func makeNSView(context: Context) -> FeedbackAnchor { FeedbackAnchor() }
    func updateNSView(_ view: FeedbackAnchor, context: Context) {
        guard request > 0, view.request != request else { return }
        view.request=request
        DispatchQueue.main.async { [weak view] in
            guard let view, view.window != nil,
                  let scroll=view.enclosingScrollView as? RetainedSettingsScrollView else { return }
            scroll.revealConnectionFeedback(view)
        }
    }
    final class FeedbackAnchor: NSView { var request=0 }
}

@MainActor private func nativeConfirmation(title: String, message: String, detail: String, action: String, completion: @escaping (Bool)->Void) {
    let alert=NSAlert(); alert.messageText=title; alert.informativeText=message
    alert.addButton(withTitle:action); alert.addButton(withTitle:"Cancel")
    let text=NSTextView(frame:NSRect(x:0,y:0,width:390,height:240))
    text.string=detail; text.isEditable=false; text.isSelectable=true; text.drawsBackground=false
    text.font=NSFont.systemFont(ofSize:NSFont.smallSystemFontSize); text.textColor = .labelColor
    text.autoresizingMask=[.width]; text.textContainer?.widthTracksTextView=true
    let scroll=NSScrollView(frame:NSRect(x:0,y:0,width:390,height:180)); scroll.hasVerticalScroller=true
    scroll.drawsBackground=false; scroll.documentView=text; alert.accessoryView=scroll
    if let window=NSApp.keyWindow { alert.beginSheetModal(for:window) { completion($0 == .alertFirstButtonReturn) } }
    else { completion(alert.runModal() == .alertFirstButtonReturn) }
}

private struct ConnectionSelectionRow: Equatable { var id: String; var name: String; var symbol: String; var detail: String }
/// A native, keyboard-accessible multiselection table. The existing outer pane owns scrolling.
private struct ConnectionSelectionTable: NSViewRepresentable {
    var rows: [ConnectionSelectionRow]
    @Binding var selection: Set<String>
    var onReturn: ()->Void
    var onCancel: ()->Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> ConnectionTable {
        let table=ConnectionTable()
        let column=NSTableColumn(identifier:NSUserInterfaceItemIdentifier("entry")); table.addTableColumn(column)
        table.headerView=nil; table.rowHeight=68; table.intercellSpacing = .zero
        table.allowsMultipleSelection=true; table.allowsEmptySelection=true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource=context.coordinator; table.delegate=context.coordinator; table.reloadData()
        table.setAccessibilityLabel("Connections belonging to the same physical device")
        table.setAccessibilityIdentifier("cellio.connections.selection")
        return table
    }
    func updateNSView(_ table: ConnectionTable, context: Context) {
        let old=context.coordinator.parent.rows
        context.coordinator.updating=true; context.coordinator.parent=self
        table.isEnabled=context.environment.isEnabled
        table.onReturn=onReturn; table.onCancel=onCancel
        if old != rows { table.reloadData() }
        table.selectRowIndexes(IndexSet(rows.indices.filter { selection.contains(rows[$0].id) }),byExtendingSelection:false)
        context.coordinator.updating=false
    }
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: ConnectionSelectionTable
        var updating=false
        init(_ parent: ConnectionSelectionTable) { self.parent=parent }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.rows.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let item=parent.rows[row]
            let cell=NSTableCellView()
            let image=NSImageView(); image.image=NSImage(systemSymbolName:item.symbol,accessibilityDescription:nil)
            let title=NSTextField(labelWithString:item.name); title.lineBreakMode = .byTruncatingTail
            let subtitle=NSTextField(labelWithString:item.detail); subtitle.font=NSFont.systemFont(ofSize:11); subtitle.textColor = .secondaryLabelColor; subtitle.lineBreakMode = .byTruncatingTail
            for view in [image,title,subtitle] { view.translatesAutoresizingMaskIntoConstraints=false; cell.addSubview(view) }
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:10),image.centerYAnchor.constraint(equalTo:cell.centerYAnchor),image.widthAnchor.constraint(equalToConstant:24),image.heightAnchor.constraint(equalToConstant:24),
                title.leadingAnchor.constraint(equalTo:image.trailingAnchor,constant:10),title.trailingAnchor.constraint(equalTo:cell.trailingAnchor,constant:-10),title.topAnchor.constraint(equalTo:cell.topAnchor,constant:12),
                subtitle.leadingAnchor.constraint(equalTo:title.leadingAnchor),subtitle.trailingAnchor.constraint(equalTo:title.trailingAnchor),subtitle.topAnchor.constraint(equalTo:title.bottomAnchor,constant:5)
            ])
            cell.textField=title; cell.imageView=image
            cell.setAccessibilityLabel(item.name+", "+item.detail+", "+item.id)
            return cell
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table=notification.object as? NSTableView else { return }
            parent.selection=Set(table.selectedRowIndexes.compactMap { parent.rows.indices.contains($0) ? parent.rows[$0].id:nil })
        }
    }
}
private final class ConnectionTable: NSTableView {
    var onReturn: (() -> Void)?
    var onCancel: (() -> Void)?
    private var spaceRow: Int?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?(); return }
        guard isEnabled else { return }
        if event.keyCode == 36 { onReturn?(); return }
        if event.keyCode == 49, let row = selectedRow >= 0 ? selectedRow:spaceRow, row < numberOfRows {
            spaceRow=row
            if selectedRowIndexes.contains(row) { deselectRow(row) } else { selectRowIndexes(IndexSet(integer:row),byExtendingSelection:true) }
            return
        }
        super.keyDown(with:event)
        if selectedRow >= 0 { spaceRow=selectedRow }
    }
}
