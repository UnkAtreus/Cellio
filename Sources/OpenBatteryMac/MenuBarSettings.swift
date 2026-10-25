import AppKit
import SwiftUI
import OpenBatteryCore

@MainActor struct MenuBarSettingsContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var controller: MenuBarController
    @State private var confirmReset=false
    @State private var now=Date()
    @FocusState private var focus: String?
    private var resolved: [MenuBarResolvedPin] { model.resolveMenuBarPins(controller.configuration) }
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Text("Pin battery readings next to Cellio in the menu bar. Pinning doesn’t change monitoring, alerts, or Show in menu.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if controller.unavailable {
                SettingsGroup {
                    VStack(alignment:.leading,spacing:8) {
                        Text("Menu bar settings unavailable").font(.headline)
                        Text("Cellio’s menu is still available. Your device, monitoring and alert settings are unchanged.")
                            .fixedSize(horizontal:false,vertical:true)
                        HStack {
                            Button("Try Again") { controller.reload() }.accessibilityIdentifier("cellio.menubar.readRetry")
                            Button("Reset Menu Bar Settings…") { controller.revokePending(); confirmReset=true }
                                .accessibilityIdentifier("cellio.menubar.reset")
                        }
                    }.padding(12)
                }
            }
            SettingsGroup {
                HStack {
                    Text("Battery display").frame(maxWidth:.infinity,alignment:.leading)
                    Picker("Battery display",selection:Binding(get:{controller.configuration.display},set:{controller.setDisplay($0)})) {
                        Text("Percentage").tag(MenuBarDisplay.percentage)
                        Text("Battery Gauge").tag(MenuBarDisplay.batteryGauge)
                    }.labelsHidden().pickerStyle(.menu).frame(width:152)
                        .accessibilityIdentifier("cellio.menubar.display")
                }.padding(.horizontal,12).frame(height:44)
                Divider().padding(.leading,12)
                HStack {
                    Text("Separator").frame(maxWidth:.infinity,alignment:.leading)
                    Picker("Separator",selection:Binding(get:{controller.configuration.separator},set:{controller.setSeparator($0)})) {
                        Text("None").tag(MenuBarSeparator.none)
                        Text("Line").tag(MenuBarSeparator.line)
                    }.labelsHidden().pickerStyle(.menu).frame(width:152)
                        .accessibilityIdentifier("cellio.menubar.separator")
                }.padding(.horizontal,12).frame(height:44)
                Divider().padding(.leading,12)
                ViewThatFits(in:.horizontal) {
                    HStack {
                        Text("Item spacing").fixedSize().frame(maxWidth:.infinity,alignment:.leading)
                        spacingControls
                    }.frame(height:44)
                    VStack(alignment:.leading,spacing:6) {
                        Text("Item spacing")
                        spacingControls.frame(maxWidth:.infinity,alignment:.trailing)
                    }.padding(.vertical,10)
                }.padding(.horizontal,12)
            }.disabled(controller.unavailable)
            HStack {
                Text("Pinned Items").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Text("\(controller.configuration.pins.count) of 3").foregroundStyle(.secondary)
            }.padding(.top,4)
            MenuBarPinTable(rows:rowContent,selection:controller.selection,select:controller.select)
                .frame(height:MenuBarPinTable.reservedHeight,alignment:.top).focused($focus,equals:"list")
                .overlay {
                    if controller.configuration.pins.isEmpty {
                        Text("No pinned items. Cellio’s menu icon stays visible.")
                            .foregroundStyle(.secondary).font(.callout).multilineTextAlignment(.center)
                            .padding(12).allowsHitTesting(false)
                    }
                }
            HStack(spacing:8) {
                Button("Add…") { controller.beginAdd() }.focused($focus,equals:"add")
                    .disabled(controller.unavailable || controller.configuration.pins.count >= 3 || model.deviceSettings.updatesBlocked)
                    .help(controller.configuration.pins.count >= 3 ? "Remove an item before adding another.":"Add an exact device battery reading.")
                    .accessibilityIdentifier("cellio.menubar.add")
                Spacer(minLength:8)
                Button { controller.move(-1) } label: { Image(systemName:"arrow.up") }
                    .accessibilityLabel("Move Up").help("Move Up")
                    .disabled(controller.unavailable || !controller.canMove(-1)).accessibilityIdentifier("cellio.menubar.up")
                Button { controller.move(1) } label: { Image(systemName:"arrow.down") }
                    .accessibilityLabel("Move Down").help("Move Down")
                    .disabled(controller.unavailable || !controller.canMove(1)).accessibilityIdentifier("cellio.menubar.down")
                Button("Remove") { controller.remove() }
                    .disabled(controller.unavailable || controller.selection == nil)
                    .help("Unpin this reading. Device settings are kept.").accessibilityIdentifier("cellio.menubar.remove")
            }.frame(height:28)
            Text("Pin up to 3 battery readings. Items that don’t fit remain saved. Earlier items appear first.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if !controller.adding {
                failureControls.background(MenuBarFeedbackReveal(request:controller.issue == nil ? nil:controller.revision))
            }
        }
        .sheet(isPresented:Binding(get:{controller.adding},set:{ if !$0 { controller.cancelAdd() } })) { addSheet }
        .alert("Reset menu bar settings?",isPresented:$confirmReset) {
            Button("Reset Menu Bar Settings",role:.destructive) { controller.reset() }
            Button("Cancel",role:.cancel) { controller.revokePending() }
        } message: {
            Text("Removes saved pins and restores Percentage, no separator, and 8 pt item spacing. Device, dropdown, monitoring and alert settings are kept.")
        }
        .onChange(of:controller.adding) { adding in if !adding { focus=controller.selection == nil ? "add":"list" } }
        .onDisappear { controller.leavePage() }
        .onReceive(Timer.publish(every:15,on:.main,in:.common).autoconnect()) { now=$0 }
    }
    private var spacingControls: some View {
        HStack(spacing:8) {
            MenuBarSpacingSlider(value:controller.configuration.spacing,onChange:controller.setSpacing)
                .frame(width:136,height:26)
            Text("\(controller.configuration.spacing) pt")
                .monospacedDigit().frame(width:38,alignment:.trailing)
                .accessibilityHidden(true)
                .accessibilityIdentifier("cellio.menubar.spacing.value")
            Button("Reset") { controller.resetSpacing() }
                .fixedSize().disabled(controller.configuration.spacing == MenuBarConfiguration.defaultSpacing)
                .accessibilityLabel("Reset item spacing")
                .accessibilityIdentifier("cellio.menubar.spacing.reset")
        }
    }
    private var rowContent: [MenuBarPinTable.Row] {
        let records=model.sortedRecords
        return resolved.map { pin in
            let content=MenuBarPinContent(pin,records:records,settings:model.deviceSettings,at:now)
            let state: String
            switch pin.state {
            case .hidden: state="Hidden device · Pin kept"
            case .review: state="Review device"
            case .coalesced: state="Same battery reading · Earlier pin displayed"
            default:
                state=controller.availableLayout.displayedIDs.contains(pin.id)
                    ? content.quantity.display+" · "+content.status.summary.replacingOccurrences(of:"\n",with:" · ")
                    : "Not displayed · Limited space"
            }
            return .init(id:pin.id,title:content.device.name+" · "+KnownBatteryDevice.componentName(pin.pin.componentID),status:state,help:content.help+" · "+state)
        }
    }
    @ViewBuilder private var failureControls: some View {
        if let issue=controller.issue {
            VStack(alignment:.leading,spacing:6) {
                Text(issue).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    .accessibilityIdentifier("cellio.menubar.failure")
                if controller.canRetry {
                    Button("Try Again") { controller.retry(settings:model.deviceSettings) }
                        .accessibilityIdentifier("cellio.menubar.saveRetry")
                }
            }
        }
    }
    private var addSheet: some View {
        let device=model.knownDevices.first(where: { $0.id == controller.addDevice })
        let pinnedComponents=device.map { device in
            device.orderedComponentIDs.filter { controller.isPinned(device:device,component:$0,settings:model.deviceSettings) }
        } ?? []
        let availableComponents=(device?.orderedComponentIDs ?? []).filter { !pinnedComponents.contains($0) }
        return VStack(alignment:.leading,spacing:14) {
            Text("Add Menu Bar Item").font(.headline).accessibilityAddTraits(.isHeader)
            Picker("Device",selection:Binding(get:{controller.addDevice},set:{controller.chooseDevice($0,settings:model.deviceSettings)})) {
                Text("Choose a device").tag("")
                ForEach(model.knownDevices) { device in Text(device.name).tag(device.id) }
            }.pickerStyle(.menu).accessibilityIdentifier("cellio.menubar.add.device")
            Picker("Battery",selection:Binding(get:{availableComponents.contains(controller.addComponent) ? controller.addComponent:""},set:{controller.chooseComponent($0)})) {
                Text("Choose a battery").tag("")
                ForEach(availableComponents,id:\.self) { component in
                    Text(KnownBatteryDevice.componentName(component)).tag(component)
                }
            }.pickerStyle(.menu).disabled(controller.addDevice.isEmpty || availableComponents.isEmpty)
                .accessibilityIdentifier("cellio.menubar.add.battery")
            if !pinnedComponents.isEmpty {
                Text("Already pinned: "+pinnedComponents.map { KnownBatteryDevice.componentName($0) }.joined(separator:", "))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
            if let device=model.knownDevices.first(where: { $0.id == controller.addDevice }), device.knownComponentIDs.isEmpty {
                Text("No battery components reported yet.").foregroundStyle(.secondary)
            }
            failureControls
            HStack {
                Spacer()
                Button("Cancel") { controller.cancelAdd() }.keyboardShortcut(.cancelAction)
                Button("Add") { controller.add(settings:model.deviceSettings) }.keyboardShortcut(.defaultAction)
                    .disabled(!controller.canAdd(settings:model.deviceSettings)).accessibilityIdentifier("cellio.menubar.add.commit")
            }
        }.padding(20).frame(width:380)
    }
}

/// Native continuous slider: each drag or keyboard tick is one atomic layout transaction.
private struct MenuBarSpacingSlider: NSViewRepresentable {
    let value: Int
    let onChange: (Int) -> Void
    @Environment(\.isEnabled) private var isEnabled
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSlider {
        let slider=NSSlider(value:Double(value),minValue:Double(MenuBarConfiguration.spacingRange.lowerBound),
                            maxValue:Double(MenuBarConfiguration.spacingRange.upperBound),
                            target:context.coordinator,action:#selector(Coordinator.changed(_:)))
        slider.isContinuous=true
        slider.numberOfTickMarks=MenuBarConfiguration.spacingRange.count
        slider.allowsTickMarkValuesOnly=true
        slider.setAccessibilityLabel("Item spacing")
        slider.setAccessibilityIdentifier("cellio.menubar.spacing")
        return slider
    }
    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.owner=self
        slider.integerValue=value
        slider.isEnabled=isEnabled
        slider.setAccessibilityValueDescription("\(value) points")
    }
    final class Coordinator: NSObject {
        var owner: MenuBarSpacingSlider
        init(_ owner: MenuBarSpacingSlider) { self.owner=owner }
        @objc func changed(_ slider: NSSlider) {
            let range=MenuBarConfiguration.spacingRange
            let value=min(range.upperBound,max(range.lowerBound,Int(slider.doubleValue.rounded())))
            slider.integerValue=value
            owner.onChange(value)
        }
    }
}

/// Reveal the page's actual feedback and Retry through its existing outer scroll owner.
private struct MenuBarFeedbackReveal: NSViewRepresentable {
    let request: Int?
    func makeNSView(context: Context) -> FeedbackAnchor { FeedbackAnchor() }
    func updateNSView(_ view: FeedbackAnchor, context: Context) {
        guard view.request != request else { return }
        view.request=request
        guard let request else { return }
        DispatchQueue.main.async { [weak view] in
            guard let view, view.request == request, view.window != nil,
                  let scroll=view.enclosingScrollView as? RetainedSettingsScrollView else { return }
            scroll.revealConnectionFeedback(view)
        }
    }
    static func dismantleNSView(_ view: FeedbackAnchor, coordinator: ()) { view.request=nil }
    final class FeedbackAnchor: NSView { var request: Int? }
}

/// A native single-selection table without a second scrolling owner.
struct MenuBarPinTable: NSViewRepresentable {
    // Three 44pt rows plus the native inset style's 5pt top/bottom padding.
    static let reservedHeight: CGFloat = 3 * 44 + 2 * 5
    struct Row: Equatable { let id: String; let title: String; let status: String; let help: String }
    let rows: [Row]
    let selection: String?
    let select: (String?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> TableReservoir {
        let reservoir=TableReservoir(frame:.zero)
        let table=reservoir.table
        let column=NSTableColumn(identifier:NSUserInterfaceItemIdentifier("pin"))
        column.resizingMask = .autoresizingMask; table.addTableColumn(column)
        table.headerView=nil; table.rowHeight=44; table.intercellSpacing = .zero
        table.allowsMultipleSelection=false; table.allowsEmptySelection=true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.style = .inset; table.backgroundColor = .controlBackgroundColor
        table.dataSource=context.coordinator; table.delegate=context.coordinator
        table.setAccessibilityLabel("Pinned Items"); table.setAccessibilityIdentifier("cellio.menubar.pins")
        return reservoir
    }
    func updateNSView(_ reservoir: TableReservoir, context: Context) {
        let table=reservoir.table
        let coordinator=context.coordinator
        let changed=coordinator.owner.rows != rows
        coordinator.updating=true; coordinator.owner=self
        if changed { table.reloadData() }
        if let index=rows.firstIndex(where: { $0.id == selection }) { table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false) }
        else { table.deselectAll(nil) }
        coordinator.updating=false
    }
    /// Keep native content sizing from centering a short table inside SwiftUI's reservation.
    final class TableReservoir: NSView {
        let table=NSTableView(frame:.zero)
        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { table.acceptsFirstResponder }
        override func becomeFirstResponder() -> Bool { window?.makeFirstResponder(table) ?? false }
        override init(frame: NSRect) {
            super.init(frame:frame)
            table.translatesAutoresizingMaskIntoConstraints=false
            addSubview(table)
            NSLayoutConstraint.activate([
                table.topAnchor.constraint(equalTo:topAnchor),
                table.leadingAnchor.constraint(equalTo:leadingAnchor),
                table.trailingAnchor.constraint(equalTo:trailingAnchor),
                table.heightAnchor.constraint(equalToConstant:MenuBarPinTable.reservedHeight)
            ])
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    }
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var owner: MenuBarPinTable
        var updating=false
        init(_ owner: MenuBarPinTable) { self.owner=owner }
        func numberOfRows(in tableView: NSTableView) -> Int { owner.rows.count }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table=notification.object as? NSTableView else { return }
            owner.select(owner.rows.indices.contains(table.selectedRow) ? owner.rows[table.selectedRow].id:nil)
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let value=owner.rows[row]
            let cell=NSTableCellView(frame:NSRect(x:0,y:0,width:tableView.bounds.width,height:44))
            let title=NSTextField(labelWithString:value.title), detail=NSTextField(labelWithString:value.status)
            title.font = .systemFont(ofSize:12); detail.font = .systemFont(ofSize:11)
            detail.textColor = .secondaryLabelColor
            for (field,y) in [(title,CGFloat(23)),(detail,CGFloat(5))] {
                field.frame=NSRect(x:6,y:y,width:max(1,tableView.bounds.width-24),height:16)
                field.autoresizingMask = [.width]; field.lineBreakMode = .byTruncatingTail
                cell.addSubview(field)
            }
            cell.textField=title; cell.toolTip=value.help
            cell.setAccessibilityElement(true); cell.setAccessibilityLabel(value.title)
            cell.setAccessibilityValue(value.status); cell.setAccessibilityHelp(value.help)
            return cell
        }
    }
}
