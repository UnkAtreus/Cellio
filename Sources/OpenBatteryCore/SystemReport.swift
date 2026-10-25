import Foundation
import CryptoKit
public enum SystemReportParser {
    public static func percent(_ value: Any?) -> Int? {
        guard let s=value as? String else { return nil }
        let t=s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasSuffix("%") else { return nil }; let digits=t.dropLast()
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let n=Int(digits), (0...100).contains(n) else { return nil }; return n
    }
    public static func opaqueIdentity(_ raw: String) -> String { SHA256.hash(data: Data(raw.utf8)).prefix(12).map { String(format:"%02x", $0) }.joined() }
    public static func parse(_ data: Data, collectedAt: Date) throws -> [Observation] {
        guard data.count <= 2 * 1024 * 1024, let root=try JSONSerialization.jsonObject(with:data) as? [String:Any], let controllers=root["SPBluetoothDataType"] as? [[String:Any]] else { throw ParseFailure.invalid("System report schema") }
        var out:[Observation]=[]
        for controller in controllers {
            for (key, connection) in [("device_connected",ConnectionState.connected),("device_not_connected",.disconnected)] {
                guard let entries=controller[key] as? [[String:Any]] else { continue }
                for entry in entries { for (name,raw) in entry { guard let props=raw as? [String:Any] else { continue }
                    let keys=[("left","device_batteryLevelLeft"),("right","device_batteryLevelRight"),("case","device_batteryLevelCase")]
                    let hasParts=keys.contains { props.keys.contains($0.1) }
                    let hasMain=props.keys.contains("device_batteryLevelMain")
                    guard hasParts || hasMain || name.localizedCaseInsensitiveContains("AirPods Pro") else { continue }
                    if hasMain && !hasParts {
                        guard let address=props["device_address"] as? String,
                              !address.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { continue }
                    }
                    let identity="bluetooth-" + opaqueIdentity((props["device_address"] as? String) ?? name)
                    let fields=hasParts || !hasMain ? keys : [("battery","device_batteryLevelMain")]
                    let kind:PhysicalDeviceKind=hasParts || !hasMain ? .earbuds : (props["device_minorType"] as? String == "Headset" ? .headset:.unknown)
                    for (component, field) in fields {
                        let q=percent(props[field]).map(Quantity.reportedPercent) ?? (props[field] == nil ? .absent : .unknown)
                        out.append(Observation(id:ComponentID(device:identity,component:component), name:name,source:.systemReport,connection:connection,quantity:q,observedAt:component != "battery" && q.isKnown ? collectedAt:nil,collectedAt:collectedAt,error: props[field] != nil && !q.isKnown ? "Invalid battery value from experimental system report" : nil,route:.init(type:.bluetooth,kind:kind,topology:"macOS Bluetooth system report component path")))
                    }
                } }
            }
        }
        var unique:[ComponentID:Observation]=[:]
        for item in out { if unique[item.id]?.connection == .connected && item.connection != .connected { continue }; unique[item.id]=item }
        return unique.values.sorted { $0.id.device+$0.id.component < $1.id.device+$1.id.component }
    }
}
