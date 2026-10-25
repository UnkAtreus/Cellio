import AppKit
import SwiftUI
import OpenBatteryCore

enum AppAppearanceChoice:String,Codable,CaseIterable {
    case system,light,dark
    var title:String { rawValue.capitalized }
    var native:NSAppearance? {
        switch self {
        case .system:return nil
        case .light:return NSAppearance(named:.aqua)
        case .dark:return NSAppearance(named:.darkAqua)
        }
    }
}

enum AppLogoChoice:String,Codable,CaseIterable {
    case light,dark
    var title:String { rawValue.capitalized }
}

/// Inject memory/failing persistence for native probes; initialization never uses NSApp.
protocol AppearancePreferencesPersistence {
    func load() throws -> Data?
    func save(_ data:Data) throws
}

final class MemoryAppearancePreferencesPersistence:AppearancePreferencesPersistence {
    var data:Data?
    init(data:Data?=nil) { self.data=data }
    func load() throws -> Data? { data }
    func save(_ data:Data) throws { self.data=data }
}

enum AppearancePreferencesError:Error { case invalidData,saveFailed }

final class DefaultsAppearancePreferencesPersistence:AppearancePreferencesPersistence {
    static let key="cellio.appearance.v1"
    private let defaults:UserDefaults
    init(defaults:UserDefaults) { self.defaults=defaults }
    static func process(arguments:[String]) throws -> DefaultsAppearancePreferencesPersistence {
        if let suite=try DeviceSettingsStore.qaSuite(arguments:arguments) {
            guard let defaults=UserDefaults(suiteName:suite) else { throw DeviceSettingsError.invalidSuite }
            return .init(defaults:defaults)
        }
        return .init(defaults:.standard)
    }
    func load() throws -> Data? {
        guard let value=defaults.object(forKey:Self.key) else { return nil }
        guard let data=value as? Data else { throw AppearancePreferencesError.invalidData }
        return data
    }
    func save(_ data:Data) throws {
        let previous=defaults.object(forKey:Self.key)
        defaults.set(data,forKey:Self.key)
        guard defaults.synchronize(),defaults.data(forKey:Self.key) == data else {
            if let previous { defaults.set(previous,forKey:Self.key) }
            else { defaults.removeObject(forKey:Self.key) }
            _=defaults.synchronize()
            throw AppearancePreferencesError.saveFailed
        }
    }
}

@MainActor final class AppearancePreferencesController:ObservableObject {
    private struct Document:Codable {
        let version:Int
        let appearance:AppAppearanceChoice
        let logo:AppLogoChoice
        enum CodingKeys:String,CodingKey { case version,appearance,logo }
        init(appearance:AppAppearanceChoice,logo:AppLogoChoice) {
            version=1; self.appearance=appearance; self.logo=logo
        }
        init(from decoder:Decoder) throws {
            let values=try decoder.container(keyedBy:CodingKeys.self)
            version=try values.decode(Int.self,forKey:.version)
            guard version == 1 else { throw AppearancePreferencesError.invalidData }
            appearance=values.contains(.appearance) ? try values.decode(AppAppearanceChoice.self,forKey:.appearance):.system
            logo=values.contains(.logo) ? try values.decode(AppLogoChoice.self,forKey:.logo):.dark
        }
    }
    @Published private(set) var appearance:AppAppearanceChoice = .system
    @Published private(set) var logo:AppLogoChoice = .dark
    @Published private(set) var issue:String?
    @Published private(set) var hasUnsavedChanges=false
    let appearanceOverride:AppAppearanceChoice?
    var effectiveAppearance:AppAppearanceChoice { appearanceOverride ?? appearance }
    var selectedLogoImage:NSImage {
        NSImage(named:NSImage.Name("Cellio_Assets/\(logo.title)")) ?? NSImage()
    }
    var runtimeLogoImage:NSImage? { RuntimeLogoImages.image(for:logo) }
    private let persistence:AppearancePreferencesPersistence
    private weak var application:NSApplication?
    private weak var standardAboutPanel:NSWindow?
    private let menus=NSHashTable<NSMenu>.weakObjects()

    init(persistence:AppearancePreferencesPersistence=MemoryAppearancePreferencesPersistence(),
         appearanceOverride:AppAppearanceChoice?=nil) {
        self.persistence=persistence
        self.appearanceOverride=appearanceOverride
        do {
            if let data=try persistence.load() {
                guard data.count <= 4096,
                      let object=try JSONSerialization.jsonObject(with:data) as? [String:Any],
                      Set(object.keys).isSubset(of:["version","appearance","logo"]) else {
                    throw AppearancePreferencesError.invalidData
                }
                let document=try JSONDecoder().decode(Document.self,from:data)
                appearance=document.appearance; logo=document.logo
            }
        } catch {
            issue="Appearance and logo preferences couldn’t be read. Choose Appearance or Logo to replace this visual record."
        }
    }

    func selectAppearance(_ choice:AppAppearanceChoice) {
        appearance=choice
        applyAppearance()
        save()
    }
    func selectLogo(_ choice:AppLogoChoice) {
        logo=choice
        applyBranding()
        save()
    }
    func retrySave() { if hasUnsavedChanges { save() } }
    private func save() {
        do {
            try persistence.save(JSONEncoder().encode(Document(appearance:appearance,logo:logo)))
            hasUnsavedChanges=false; issue=nil
        } catch {
            hasUnsavedChanges=true
            issue="Changes aren’t saved. Appearance and logo choices may be lost on restart."
        }
    }

    /// Called only by the ordinary GUI launch after snapshot dispatch.
    func apply(to application:NSApplication) {
        self.application=application
        applyAppearance()
        applyBranding()
    }
    private func applyAppearance() {
        guard let application else { return }
        application.appearance=effectiveAppearance.native
        // Windows and standard panels inherit the application, including System.
        for window in application.windows {
            window.appearance=nil
            window.contentView?.appearance=nil
        }
        if let menu=application.mainMenu { configure(menu:menu) }
        for menu in menus.allObjects { configure(menu:menu) }
    }
    func configure(menu:NSMenu) {
        menus.add(menu)
        menu.appearance=effectiveAppearance.native
        for item in menu.items {
            if let submenu=item.submenu { configure(menu:submenu) }
        }
    }
    func reapplyBranding() { applyBranding() }
    private func applyBranding() {
        guard let application else { return }
        if let image=runtimeLogoImage { application.applicationIconImage=image }
        if standardAboutPanel?.isVisible == true {
            let keyWindow=application.keyWindow
            application.orderFrontStandardAboutPanel(options:aboutOptions)
            if let keyWindow,keyWindow !== standardAboutPanel { keyWindow.makeKeyAndOrderFront(nil) }
        }
    }
    private var aboutOptions:[NSApplication.AboutPanelOptionKey:Any] {
        var options:[NSApplication.AboutPanelOptionKey:Any]=[
         .applicationName:"Cellio",.applicationVersion:"1.0",
         .credits:NSAttributedString(string:"Accessory battery readings from experimental AirPods and Logitech providers. Watch requires paired iPhone forwarding; delivery may be delayed.")]
        if let image=runtimeLogoImage { options[.applicationIcon]=image }
        return options
    }
    func showStandardAbout() {
        guard let application else { return }
        applyBranding()
        application.activate(ignoringOtherApps:true)
        application.orderFrontStandardAboutPanel(options:aboutOptions)
        standardAboutPanel=application.keyWindow
    }
}

/// Runtime presentation only; never changes named artwork or the bundled native icon.
@MainActor private enum RuntimeLogoImages {
    private static let dark: NSImage? = Bundle.main.url(forResource:"Cellio",withExtension:"icns")
        .flatMap { NSImage(contentsOf:$0) }
    private static let light: NSImage? = {
        guard let dark,
              let artwork=NSImage(named:NSImage.Name("Cellio_Assets/Light")),
              let native=dark.representations.compactMap({ ($0 as? NSBitmapImageRep)?.cgImage })
                .max(by:{ $0.width*$0.height < $1.width*$1.height }),
              let maskContext=CGContext(data:nil,width:native.width,height:native.height,
                bitsPerComponent:8,bytesPerRow:native.width*4,space:CGColorSpaceCreateDeviceRGB(),
                bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let data=maskContext.data else { return nil }
        maskContext.draw(native,in:CGRect(x:0,y:0,width:native.width,height:native.height))
        let pixels=data.assumingMemoryBound(to:UInt8.self)
        var minX=native.width,minY=native.height,maxX=0,maxY=0
        for y in 0..<native.height {
            for x in 0..<native.width {
                let offset=(y*native.width+x)*4
                let alpha=Int(pixels[offset+3])
                if alpha >= 128 {
                    minX=min(minX,x); minY=min(minY,y)
                    maxX=max(maxX,x+1); maxY=max(maxY,y+1)
                }
                // Approved ICNS shadow-only pixels have alpha <= 33/255.
                // Keep its face coverage/corners without adding that shadow to Light.
                let coverage=UInt8(max(0,alpha-33)*255/(255-33))
                for channel in 0..<4 { pixels[offset+channel]=coverage }
            }
        }
        guard maxX>minX,maxY>minY,let mask=maskContext.makeImage() else { return nil }
        let side=1024
        guard let output=CGContext(data:nil,width:side,height:side,bitsPerComponent:8,
            bytesPerRow:side*4,space:CGColorSpaceCreateDeviceRGB(),
            bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return nil }
        let scale=CGFloat(side)/CGFloat(native.width)
        let face=NSRect(x:CGFloat(minX)*scale,y:CGFloat(minY)*scale,
            width:CGFloat(maxX-minX)*scale,height:CGFloat(maxY-minY)*scale)
        // Paint the full supplied face once, inside the native safe margin.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current=NSGraphicsContext(cgContext:output,flipped:false)
        artwork.draw(in:face,from:.zero,operation:.copy,fraction:1)
        NSGraphicsContext.restoreGraphicsState()
        output.interpolationQuality = .high
        output.setBlendMode(.destinationIn)
        output.draw(mask,in:CGRect(x:0,y:0,width:side,height:side))
        guard let image=output.makeImage() else { return nil }
        return NSImage(cgImage:image,size:dark.size)
    }()
    static func image(for choice:AppLogoChoice)->NSImage? {
        // Missing compiled Light or a failed render retains the native bundle icon.
        choice == .dark ? dark:(light ?? dark)
    }
}

/// AppKit owns popup tracking, keyboard behavior, focus ring and accessibility.
struct AppearancePopup:NSViewRepresentable {
    let title:String
    let options:[String]
    let selection:String
    let identifier:String
    let configureMenu:(NSMenu)->Void
    let choose:(String)->Void
    func makeCoordinator()->Coordinator { Coordinator(self) }
    func makeNSView(context:Context)->NSPopUpButton {
        let popup=NSPopUpButton(frame:.zero,pullsDown:false)
        popup.target=context.coordinator
        popup.action=#selector(Coordinator.select(_:))
        popup.setAccessibilityLabel(title)
        popup.setAccessibilityIdentifier(identifier)
        popup.addItems(withTitles:options)
        return popup
    }
    func updateNSView(_ popup:NSPopUpButton,context:Context) {
        context.coordinator.owner=self
        if popup.titleOfSelectedItem != selection { popup.selectItem(withTitle:selection) }
        if let menu=popup.menu { configureMenu(menu) }
    }
    final class Coordinator:NSObject {
        var owner:AppearancePopup
        init(_ owner:AppearancePopup) { self.owner=owner }
        @objc func select(_ sender:NSPopUpButton) {
            if let choice=sender.titleOfSelectedItem { owner.choose(choice) }
        }
    }
}
