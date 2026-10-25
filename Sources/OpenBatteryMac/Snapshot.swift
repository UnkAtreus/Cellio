import Foundation
import OpenBatteryCore

enum SnapshotRunner {
    private final class Collector {
        let lock=NSLock(); var batches:[ProviderBatch]=[]
        func append(_ batch:ProviderBatch) { lock.lock(); batches.append(batch); lock.unlock() }
        func all()->[ProviderBatch] { lock.lock(); defer { lock.unlock() }; return batches }
    }
    static func run() {
        let started=Date(),collector=Collector(),group=DispatchGroup()
        let report=SystemReportProvider(),hid=HIDProvider()
        group.enter(); report.collect { batch in collector.append(batch); group.leave() }
        group.enter(); let once=NSLock(); var completed=false
        hid.completion={ batch in once.lock(); defer{once.unlock()}; if !completed { completed=true; collector.append(batch); group.leave() } }; hid.start()
        let wait=group.wait(timeout:.now()+55); let hidStopped=hid.stop(waitUntilStopped:2)
        var reducer=BatteryReducer(); var status:[String:String]=[:]
        for batch in collector.all() { for o in batch.observations { reducer.apply(o,now:Date()) }; for (key,value) in batch.status { status[key.hasPrefix("hid-") ? "accessory-"+SystemReportParser.opaqueIdentity(key):key]=redact(value) } }
        for item in WatchListener().history { reducer.apply(item.sample.observation(collectedAt:item.receivedAt),now:Date()) }
        if wait == .timedOut { status["collection"]="A real provider did not finish within 55 seconds" }
        if !hidStopped { status["HID shutdown"]="HID worker did not stop within two seconds" }
        let encoder=JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        struct Snapshot:Encodable { let schemaVersion:Int; let mode:String; let startedAt:Date; let collectedAt:Date; let providers:[String:String]; let readings:[BatteryRecord]; let note:String }
        var records=Array(reducer.records.values)
        for index in records.indices {
            records[index].observation.id.device=SystemReportParser.opaqueIdentity(records[index].observation.id.device)
            let source=records[index].observation.source
            records[index].observation.name = source == .systemReport ? "AirPods / system accessory" : source == .watchCompanion ? "Apple Watch" : redact(records[index].observation.name)
        }
        let snapshot=Snapshot(schemaVersion:1,mode:"real-providers",startedAt:started,collectedAt:Date(),providers:status,readings:records.sorted { $0.observation.id.device+$0.observation.id.component < $1.observation.id.device+$1.observation.id.component },note:"Device identities are hashed; no pairing credentials. Empty/unavailable does not mean zero. Hardware compatibility is unverified unless a real reading appears.")
        if let data=try? encoder.encode(snapshot) { FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10])) }
    }
    static func redact(_ value:String)->String { value.replacingOccurrences(of:"(?i)[0-9a-f]{2}(?:[:-][0-9a-f]{2}){5}",with:"[redacted-address]",options:.regularExpression) }
}
