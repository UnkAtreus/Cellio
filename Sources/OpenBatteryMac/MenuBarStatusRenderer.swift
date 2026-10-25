import AppKit
import OpenBatteryCore

/// Public own-button geometry only. nil deliberately means icon-only, never an assumed 280pt.
enum MenuBarGeometryPolicy {
    static func budget(ownFrame: NSRect?, screenFrame: NSRect?, safeTopLeft: NSRect? = nil,
                       safeTopRight: NSRect? = nil, hasUnsafeTop: Bool = false) -> Double? {
        guard let ownFrame, let screenFrame, ownFrame.width > 0, ownFrame.height > 0,
              [ownFrame.minX,ownFrame.maxX,ownFrame.minY,ownFrame.maxY,ownFrame.width,ownFrame.height,
               screenFrame.minX,screenFrame.maxX,screenFrame.minY,screenFrame.maxY,screenFrame.width,screenFrame.height].allSatisfy(\.isFinite),
              screenFrame.width > 0, screenFrame.height > 0,
              ownFrame.maxX <= screenFrame.maxX+1, ownFrame.maxX > screenFrame.minX,
              ownFrame.minY >= screenFrame.maxY-80, ownFrame.maxY <= screenFrame.maxY+4 else { return nil }
        let anchor=NSPoint(x:ownFrame.maxX-12,y:screenFrame.maxY-10)
        let safe: NSRect
        if hasUnsafeTop {
            guard let segment=[safeTopLeft,safeTopRight].compactMap({ $0 }).first(where: { $0.contains(anchor) }),
                  segment.width > 0 else { return nil }
            safe=segment
        } else { safe=screenFrame }
        let width=ownFrame.maxX-safe.minX-8
        return width >= MenuBarLayout.iconWidth ? min(MenuBarLayout.maximumWidth,Double(width)):nil
    }
    @MainActor static func budget(button: NSStatusBarButton?) -> Double? {
        guard let button, let window=button.window, let screen=window.screen else { return nil }
        let frame=window.convertToScreen(button.convert(button.bounds,to:nil))
        return budget(ownFrame:frame,screenFrame:screen.frame,safeTopLeft:screen.auxiliaryTopLeftArea,
                      safeTopRight:screen.auxiliaryTopRightArea,hasUnsafeTop:screen.safeAreaInsets.top > 0)
    }
}

/// Draws one template image in the original native status button. AppKit owns highlighting/AXPress.
@MainActor final class MenuBarStatusRenderer {
    private var displayedConfiguration=MenuBarConfiguration()
    private var lastLayout=MenuBarLayout.project([],budget:nil)
    func update(button: NSStatusBarButton?, item: NSStatusItem, model: AppModel, tracking: Bool, at now: Date,
                budget: Double?) {
        guard let button else { return }
        let controller=model.menuBar
        let configuration=controller.configuration
        let desired=model.resolveMenuBarPins(configuration)
        let proposed=MenuBarLayout.project(desired,budget:budget)
        var layout=proposed
        var resolved=desired
        // Keep structural slots during native menu tracking, but recompute values/status in place.
        // Hide and unsafe geometry are essential changes and immediately collapse optional content.
        if tracking {
            let frozen=model.resolveMenuBarPins(displayedConfiguration)
            let visible=frozen.filter { lastLayout.displayedIDs.contains($0.id) }
            if visible.contains(where: { $0.state == .hidden || $0.state == .coalesced }) || budget.map({ $0 < lastLayout.width }) ?? true {
                layout=MenuBarLayout.project([],budget:nil); resolved=[]
            } else { layout=lastLayout; resolved=frozen }
        } else { displayedConfiguration=configuration }
        if !tracking { lastLayout=layout }
        if controller.availableLayout != proposed { controller.availableLayout=proposed }
        let records=model.sortedRecords
        let contents=layout.displayedIDs.compactMap { id in resolved.first { $0.id == id } }.map {
            MenuBarPinContent($0,records:records,settings:model.deviceSettings,at:now)
        }
        item.length=CGFloat(layout.width-MenuBarLayout.nativeTargetOverhead)
        button.imagePosition = .imageOnly
        button.image=Self.image(contents:contents,layout:layout,display:configuration.display,separator:configuration.separator)
        let undisplayed=desired.filter { $0.state != .hidden && $0.state != .coalesced && !layout.displayedIDs.contains($0.id) }.count
        var descriptions=contents.map(\.help)
        if undisplayed > 0 { descriptions.append("\(undisplayed) saved \(undisplayed == 1 ? "item":"items") not displayed · Limited space") }
        let value=descriptions.joined(separator:"\n")
        button.toolTip=(["Cellio"]+descriptions).joined(separator:"\n")
        button.setAccessibilityLabel("Cellio")
        button.setAccessibilityValue(value.isEmpty ? "Accessory battery readings":value)
        button.setAccessibilityHelp("Open Cellio’s menu"+(value.isEmpty ? "":". "+value))
    }
    static func image(contents: [MenuBarPinContent], layout: MenuBarLayout, display: MenuBarDisplay,
                      separator: MenuBarSeparator) -> NSImage {
        // Preserve the native button's four-point image inset; layout.width already
        // includes the observed target overhead, which is not image content.
        let width=CGFloat(layout.width-MenuBarLayout.nativeTargetOverhead)-4
        let image=NSImage(size:NSSize(width:width,height:18),flipped:false) { _ in
            NSColor.black.setFill(); NSColor.black.setStroke()
            func symbol(_ name: String, rect: NSRect) {
                let symbol=NSImage(systemSymbolName:name,accessibilityDescription:nil)?
                    .withSymbolConfiguration(.init(pointSize:11,weight:.regular))
                guard let symbol, symbol.size.width > 0, symbol.size.height > 0 else { return }
                let scale=min(rect.width/symbol.size.width,rect.height/symbol.size.height)
                let size=NSSize(width:symbol.size.width*scale,height:symbol.size.height*scale)
                symbol.draw(in:NSRect(x:rect.midX-size.width/2,y:rect.midY-size.height/2,width:size.width,height:size.height),
                            from:.zero,operation:.sourceOver,fraction:1)
            }
            func text(_ value: String, rect: NSRect, font: NSFont, alignment: NSTextAlignment = .left) {
                let paragraph=NSMutableParagraphStyle(); paragraph.alignment=alignment; paragraph.lineBreakMode = .byClipping
                (value as NSString).draw(in:rect,withAttributes:[.font:font,.foregroundColor:NSColor.black,.paragraphStyle:paragraph])
            }
            var x: CGFloat=0
            for (index,content) in contents.enumerated() {
                if index > 0 {
                    if separator == .line { NSBezierPath(rect:NSRect(x:x+1.5,y:3,width:0.5,height:12)).fill() }
                    x += CGFloat(MenuBarLayout.gap)
                }
                let origin=x
                symbol(DeviceSymbols.symbol(name:content.device.name,source:content.device.source,kind:content.device.kind),
                       rect:NSRect(x:x,y:3,width:12,height:12))
                x += 14
                if !content.discriminator.isEmpty {
                    let discriminatorWidth=CGFloat(MenuBarLayout.discriminatorWidth(component:content.resolved.pin.componentID))
                    text(content.discriminator,rect:NSRect(x:x,y:3,width:discriminatorWidth,height:13),font:.systemFont(ofSize:9))
                    x += discriminatorWidth+2
                }
                let quantityRect=NSRect(x:x,y:2,width:38,height:15)
                if display == .batteryGauge, let percent=content.gauge {
                    let gaugeX=x+(content.approximate ? 8:2)
                    if content.approximate { text("≈",rect:NSRect(x:x,y:3,width:8,height:13),font:.systemFont(ofSize:11)) }
                    let outline=NSRect(x:gaugeX,y:5,width:24,height:9)
                    let path=NSBezierPath(roundedRect:outline,xRadius:1.5,yRadius:1.5); path.lineWidth=1; path.stroke()
                    NSBezierPath(rect:NSRect(x:outline.maxX+1,y:7.5,width:1.5,height:4)).fill()
                    if percent > 0 {
                        NSBezierPath(rect:NSRect(x:outline.minX+2,y:7,width:20*CGFloat(percent)/100,height:5)).fill()
                    }
                } else {
                    let font=NSFont.monospacedDigitSystemFont(ofSize:11,weight:.regular)
                    let measured=(content.text as NSString).size(withAttributes:[.font:font]).width
                    let value: String
                    if case .coarse = content.quantity, measured > quantityRect.width { value="Level" }
                    else { value=content.text }
                    text(value,rect:quantityRect,font:font,alignment:.right)
                }
                x += 39
                for (index,marker) in content.markers.enumerated() {
                    symbol(marker,rect:NSRect(x:x+CGFloat(index)*8,y:4,width:8,height:10))
                }
                x=origin+CGFloat(MenuBarLayout.pinWidth(component:content.resolved.pin.componentID))
            }
            if layout.overflow > 0 {
                text("+\(layout.overflow)",rect:NSRect(x:x+2,y:2,width:22,height:15),font:.monospacedDigitSystemFont(ofSize:11,weight:.regular),alignment:.center)
            }
            // The exact pre-customization Cellio menu icon remains the trailing anchor.
            symbol("battery.75percent",rect:NSRect(x:width-18,y:0,width:18,height:18))
            return true
        }
        image.isTemplate=true
        return image
    }
}
