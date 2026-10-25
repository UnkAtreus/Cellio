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
    private var lastContentWidths: [String:Double]=[:]
    private var collapsedWhileTracking=false
    func update(button: NSStatusBarButton?, item: NSStatusItem, model: AppModel, tracking: Bool, at now: Date,
                budget: Double?) {
        guard let button else { return }
        let controller=model.menuBar
        let configuration=controller.configuration
        let desired=model.resolveMenuBarPins(configuration)
        let records=model.sortedRecords
        func contents(_ pins: [MenuBarResolvedPin]) -> [MenuBarPinContent] {
            pins.map { MenuBarPinContent($0,records:records,settings:model.deviceSettings,at:now) }
        }
        func widths(_ contents: [MenuBarPinContent], display: MenuBarDisplay) -> [String:Double] {
            Dictionary(uniqueKeysWithValues:contents.map { ($0.resolved.id,Self.contentWidth($0,display:display)) })
        }
        let desiredContents=contents(desired)
        let desiredWidths=widths(desiredContents,display:configuration.display)
        let proposed=MenuBarLayout.project(desired,budget:budget,spacing:configuration.spacing,contentWidths:desiredWidths)
        var layout=proposed
        var displayedContents=desiredContents
        var renderingConfiguration=configuration
        var allocations=desiredWidths
        // Keep structural slots during native menu tracking, but recompute values/status in place.
        // Newly wider content cannot borrow from the selected interval or its neighbour.
        if tracking {
            let frozen=model.resolveMenuBarPins(displayedConfiguration)
            let frozenContents=contents(frozen)
            let currentWidths=widths(frozenContents,display:displayedConfiguration.display)
            let visible=frozen.filter { lastLayout.displayedIDs.contains($0.id) }
            let unsafeContent=lastLayout.displayedIDs.contains { id in
                guard let current=currentWidths[id], current.isFinite,
                      let allocated=lastContentWidths[id] else { return true }
                return current > allocated+0.001
            }
            if visible.count != lastLayout.displayedIDs.count ||
                visible.contains(where: { $0.state == .hidden || $0.state == .coalesced }) || unsafeContent ||
                budget.map({ !$0.isFinite || $0 < lastLayout.width }) ?? true {
                collapsedWhileTracking=true
            }
            renderingConfiguration=displayedConfiguration
            allocations=lastContentWidths
            if collapsedWhileTracking {
                layout=MenuBarLayout.project([],budget:nil); displayedContents=[]
            } else { layout=lastLayout; displayedContents=frozenContents }
        } else {
            collapsedWhileTracking=false
            displayedConfiguration=configuration
            lastLayout=layout
            lastContentWidths=desiredWidths
        }
        if controller.availableLayout != proposed { controller.availableLayout=proposed }
        let selectedContents=layout.displayedIDs.compactMap { id in displayedContents.first { $0.resolved.id == id } }
        item.length=CGFloat(layout.width-MenuBarLayout.nativeTargetOverhead)
        button.imagePosition = .imageOnly
        button.image=Self.image(contents:selectedContents,layout:layout,display:renderingConfiguration.display,
            separator:renderingConfiguration.separator,spacing:renderingConfiguration.spacing,
            allocationWidths:allocations,backingScale:button.window?.backingScaleFactor ?? 1)
        let undisplayed=desired.filter { $0.state != .hidden && $0.state != .coalesced && !layout.displayedIDs.contains($0.id) }.count
        var descriptions=selectedContents.map(\.help)
        if undisplayed > 0 { descriptions.append("\(undisplayed) saved \(undisplayed == 1 ? "item":"items") not displayed · Limited space") }
        let value=descriptions.joined(separator:"\n")
        button.toolTip=(["Cellio"]+descriptions).joined(separator:"\n")
        button.setAccessibilityLabel("Cellio")
        button.setAccessibilityValue(value.isEmpty ? "Accessory battery readings":value)
        button.setAccessibilityHelp("Open Cellio’s menu"+(value.isEmpty ? "":". "+value))
    }
    struct PinGeometry {
        let glyphWidth: CGFloat
        let discriminatorWidth: CGFloat
        let quantityWidth: CGFloat
        let markerWidths: [CGFloat]
        var prefixWidth: CGFloat { glyphWidth+8+(discriminatorWidth > 0 ? discriminatorWidth+2:0) }
        var tailWidth: CGFloat { quantityWidth+(markerWidths.isEmpty ? 0:1+markerWidths.reduce(0,+)) }
        var width: CGFloat { prefixWidth+tailWidth }
    }
    private static func symbolImage(_ name: String) -> NSImage? {
        NSImage(systemSymbolName:name,accessibilityDescription:nil)?
            .withSymbolConfiguration(.init(pointSize:11,weight:.regular))
    }
    private static func symbolWidth(_ name: String, width: CGFloat, height: CGFloat) -> CGFloat {
        guard let image=symbolImage(name), image.size.width > 0, image.size.height > 0 else { return .nan }
        return image.size.width*min(width/image.size.width,height/image.size.height)
    }
    private static var quantityFont: NSFont { .monospacedDigitSystemFont(ofSize:11,weight:.regular) }
    private static func quantityText(_ content: MenuBarPinContent) -> String {
        if case .coarse = content.quantity,
           (content.text as NSString).size(withAttributes:[.font:quantityFont]).width > 38 { return "Level" }
        return content.text
    }
    private static func percentageSlotWidth(_ content: MenuBarPinContent) -> CGFloat {
        let sample: String
        if case .coarse = content.quantity { sample=quantityText(content) }
        else { sample=content.approximate ? "≈100%":"100%" }
        return (sample as NSString).size(withAttributes:[.font:quantityFont]).width
    }
    /// The drawing and public budget use the same occupied spans. Percentage slots remain stable;
    /// gauges and markers contribute only the space they draw, with no empty trailing reserves.
    static func geometry(_ content: MenuBarPinContent, display: MenuBarDisplay) -> PinGeometry {
        let glyph=DeviceSymbols.symbol(name:content.device.name,source:content.device.source,kind:content.device.kind)
        return PinGeometry(glyphWidth:symbolWidth(glyph,width:12,height:12).isFinite ? 12:.nan,
            discriminatorWidth:content.discriminator.isEmpty ? 0:CGFloat(MenuBarLayout.discriminatorWidth(component:content.resolved.pin.componentID)),
            quantityWidth:display == .batteryGauge && content.gauge != nil ? (content.approximate ? 35:27):percentageSlotWidth(content),
            markerWidths:content.markers.map { symbolWidth($0,width:8,height:10) })
    }
    static func contentWidth(_ content: MenuBarPinContent, display: MenuBarDisplay) -> Double {
        Double(geometry(content,display:display).width)
    }
    nonisolated static func separatorRect(intervalStart: CGFloat, spacing: Int, backingScale: CGFloat = 1,
                                         previousDrawnEnd: CGFloat? = nil) -> NSRect {
        let scale=backingScale.isFinite && backingScale > 0 ? backingScale:1
        let nextStart=intervalStart+CGFloat(spacing)
        let ideal=((previousDrawnEnd ?? intervalStart)+nextStart-1)/2
        return NSRect(x:(ideal*scale).rounded()/scale,y:3,width:1,height:12)
    }
    static func image(contents: [MenuBarPinContent], layout: MenuBarLayout, display: MenuBarDisplay,
                      separator: MenuBarSeparator, spacing: Int = MenuBarConfiguration.defaultSpacing,
                      allocationWidths: [String:Double]? = nil, backingScale: CGFloat = 1) -> NSImage {
        // Preserve the native button's four-point image inset; layout.width already
        // includes the observed target overhead, which is not image content.
        let width=CGFloat(layout.width-MenuBarLayout.nativeTargetOverhead-MenuBarLayout.imageInsets)
        let geometries=contents.map { Self.geometry($0,display:display) }
        let quantityTexts=contents.map(Self.quantityText)
        let quantityFont=Self.quantityFont
        let quantityTextWidths=quantityTexts.map { ($0 as NSString).size(withAttributes:[.font:quantityFont]).width }
        let symbolNames=Set(contents.flatMap {
            [DeviceSymbols.symbol(name:$0.device.name,source:$0.device.source,kind:$0.device.kind)]+$0.markers
        }+["battery.75percent"])
        var symbols: [String:NSImage]=[:]
        for name in symbolNames { symbols[name]=symbolImage(name) }
        let image=NSImage(size:NSSize(width:width,height:18),flipped:false) { _ in
            NSColor.black.setFill(); NSColor.black.setStroke()
            func symbol(_ name: String, rect: NSRect) {
                let symbol=symbols[name]
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
            var previousDrawnEnd: CGFloat?
            for (index,content) in contents.enumerated() {
                if index > 0 {
                    if separator == .line {
                        NSBezierPath(rect:Self.separatorRect(intervalStart:x,spacing:spacing,
                            backingScale:backingScale,previousDrawnEnd:previousDrawnEnd)).fill()
                    }
                    x += CGFloat(spacing)
                }
                let origin=x
                let geometry=geometries[index]
                let allocation=CGFloat(allocationWidths?[content.resolved.id] ?? Double(geometry.width))
                symbol(DeviceSymbols.symbol(name:content.device.name,source:content.device.source,kind:content.device.kind),
                       rect:NSRect(x:x,y:4,width:geometry.glyphWidth,height:12))
                x += geometry.glyphWidth+2
                if !content.discriminator.isEmpty {
                    text(content.discriminator,rect:NSRect(x:x,y:3,width:geometry.discriminatorWidth,height:13),font:.systemFont(ofSize:9))
                }
                // Keep the icon-to-quantity gap fixed. Stable digit-slot reserve follows the
                // leading-aligned value instead of opening a hole before it.
                x=origin+geometry.prefixWidth
                let quantityRect=NSRect(x:x,y:2,width:geometry.quantityWidth,height:15)
                var drawnEnd=quantityRect.maxX
                if display == .batteryGauge, let percent=content.gauge {
                    let gaugeX=x+(content.approximate ? 8:0)+0.5
                    if content.approximate { text("≈",rect:NSRect(x:x,y:3,width:8,height:13),font:.systemFont(ofSize:11)) }
                    let outline=NSRect(x:gaugeX,y:5,width:24,height:9)
                    let path=NSBezierPath(roundedRect:outline,xRadius:1.5,yRadius:1.5); path.lineWidth=1; path.stroke()
                    NSBezierPath(rect:NSRect(x:outline.maxX+1,y:7.5,width:1.5,height:4)).fill()
                    if percent > 0 {
                        NSBezierPath(rect:NSRect(x:outline.minX+2,y:7,width:20*CGFloat(percent)/100,height:5)).fill()
                    }
                } else {
                    text(quantityTexts[index],rect:quantityRect,font:quantityFont)
                    drawnEnd=quantityRect.minX+quantityTextWidths[index]
                }
                x += geometry.quantityWidth+(content.markers.isEmpty ? 0:1)
                for (index,marker) in content.markers.enumerated() {
                    let markerWidth=geometry.markerWidths[index]
                    symbol(marker,rect:NSRect(x:x,y:4,width:markerWidth,height:10))
                    x += markerWidth
                }
                previousDrawnEnd=content.markers.isEmpty ? drawnEnd:x
                x=origin+allocation
            }
            if layout.overflow > 0 {
                text("+\(layout.overflow)",rect:NSRect(x:x+2,y:2,width:22,height:15),font:.monospacedDigitSystemFont(ofSize:11,weight:.regular),alignment:.center)
            }
            if contents.isEmpty {
                // The pre-customization icon remains the one visible clickable fallback.
                symbol("battery.75percent",rect:NSRect(x:width-18,y:0,width:18,height:18))
            }
            return true
        }
        image.isTemplate=true
        return image
    }
}
