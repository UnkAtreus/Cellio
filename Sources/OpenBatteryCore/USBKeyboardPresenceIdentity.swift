import Foundation
import CryptoKit

/// Current connection evidence only; neither a serial nor a cross-reconnect unit identity.
public enum USBKeyboardPresenceIdentity {
    public static func qualifies(vendor: Int?, product: Int?, transport: String?, usagePage: Int?, usage: Int?) -> Bool {
        vendor == 0x36b0 && product == 0x3050 && transport == "USB" && usagePage == 1 && usage == 6
    }

    /// Missing/invalid boot evidence cannot create a persistent route.
    public static func connectionKey(bootSessionID: String?, registryEntryID: UInt64) -> String? {
        guard let bootSessionID, let boot=UUID(uuidString:bootSessionID), registryEntryID != 0 else { return nil }
        let evidence="cellio.usb-presence.v1\0"+boot.uuidString.lowercased()+"\0"+String(registryEntryID)
        return "usb-presence-"+SHA256.hash(data:Data(evidence.utf8)).map { String(format:"%02x",$0) }.joined()
    }
}
