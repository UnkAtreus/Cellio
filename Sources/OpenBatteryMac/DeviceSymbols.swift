import Foundation
import OpenBatteryCore

/// UI identity only: names and explicit source kinds never imply battery support.
enum DeviceSymbols {
    static func symbol(name:String,source:BatterySource?,kind:PhysicalDeviceKind? = nil)->String {
        switch kind {
        case .headset: return "headphones"
        case .keyboard: return "keyboard"
        case .mouse: return "computermouse"
        case .watch: return "applewatch"
        default: break
        }
        if name.lowercased() == "maxfit8" { return "keyboard" }
        let name=name.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator:" ")
        func matches(_ product:String)->Bool {
            name.range(of:"(?:^| )(?:"+product+")(?: |$)",options:.regularExpression) != nil
        }
        if source == .watchCompanion || matches("apple watch") { return "applewatch" }
        if matches("airpods pro") { return "airpodspro" }
        if matches("airpods max") { return "airpodsmax" }
        if matches("airpods") { return "airpods" }
        if kind == .earbuds { return "earbuds" }
        if matches("mx (?:master|anywhere)(?: ?[0-9]+s?)?|mx vertical|magic mouse") { return "computermouse" }
        if matches("mx keys|magic keyboard") { return "keyboard" }
        // No `trackpad` symbol in the installed catalog (including macOS 13).
        if matches("magic trackpad") { return "questionmark.square.dashed" }
        if source == .headset || matches("pro x ?2 lightspeed") { return "headphones" }
        return "questionmark.square.dashed"
    }
}
