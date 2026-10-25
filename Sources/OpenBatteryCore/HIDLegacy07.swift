import Foundation
import Darwin

public enum HIDLegacy07Probe { case modern, legacy }
enum HIDLegacy07ProbeSignal: Error { case detected }

/// Experimental receiver-stored pairing snapshot, never physical identity proof.
public struct HIDLegacy07Pairing: Equatable {
    public let wpid:UInt16
    public let type:UInt8
    public let serial:UInt32
    public init(pairing:[UInt8],extended:[UInt8],slot:UInt8) throws {
        guard (1...6).contains(slot), pairing.count==20, extended.count==20,
              Array(pairing.prefix(5)) == [0x11,0xff,0x83,0xb5,0x20+slot-1],
              Array(extended.prefix(5)) == [0x11,0xff,0x83,0xb5,0x30+slot-1],
              pairing[18...19].allSatisfy({ $0==0 }), extended[14...19].allSatisfy({ $0==0 }) else { throw ParseFailure.invalid("Register07 pairing shape/padding") }
        wpid=UInt16(pairing[7])<<8 | UInt16(pairing[8]); type=pairing[11]
        serial=extended[5...8].reduce(UInt32(0)) { ($0<<8)|UInt32($1) }
        guard wpid==0x2010, type==1, serial != 0, serial != UInt32.max else { throw ParseFailure.unsupported }
    }
}

public enum HIDLegacy07 {
    public static func eligible(vendor:Int,product:Int,transport:String,descriptor:HIDDescriptor) -> Bool {
        vendor==0x046d && product==0xc52b && transport=="USB" && descriptor.legacy07Eligible
    }
    public static func decode(_ bytes:[UInt8],slot:UInt8) throws -> BatteryReading {
        guard (1...6).contains(slot), bytes.count==7, Array(bytes.prefix(4)) == [0x10,slot,0x81,7] else { throw ParseFailure.invalid("Register07 reply") }
        let r0=bytes[4], r1=bytes[5], r2=bytes[6]
        let charge:ChargeState
        switch r1 { case 0:charge = .discharging; case 0x21:charge = .charging; case 0x22:charge = .complete; case 0x23:charge = .chargingError; default:charge = .unknown }
        let names:[UInt8:String]=[1:"Critical",3:"Low",5:"Good",7:"Full"]
        let quantity:Quantity
        if r1==0, r2<=6, let name=names[r0] { quantity = .coarse(name:name,level:Int(r0)) }
        else { quantity = .unknown }
        return BatteryReading(quantity:quantity,charge:charge)
    }
    public static func route(slot:UInt8) -> BatteryRouteMetadata {
        BatteryRouteMetadata(type:.wirelessReceiver,kind:.keyboard,topology:"Experimental HID++1 register07; K800 WPID2010 via USB046D:C52B; receiver-local pairing snapshot; slot \(slot)")
    }
}

public struct HIDLegacy07Collection {
    public var observations:[Observation]=[]
    public var routes:[SavedBatteryRoute]=[]
    public var failures:[String:String]=[:]
    public var connections:[String:ConnectionState]=[:]
    public var modernSlots:[UInt8]=[]
    public var retired:[String]=[]
    public var diagnostic:String?
    public init() {}
}

/// Injectable bounded journal and nonblocking coordination lease. Independent
/// acceptance supplies memory/temporary storage; product uses the private file.
public protocol HIDLegacy07JournalStorage: AnyObject {
    func acquire() throws -> Bool
    func release()
    func load() throws -> Data?
    func store(_ data:Data) throws
}

/// No preferences, catalog data, serial labels or raw pairing serials are stored.
/// Missing/unreadable state cannot authorize an already attached generation.
public final class HIDLegacy07FileJournal:HIDLegacy07JournalStorage {
    private let directory:URL
    private var directoryFD:Int32 = -1, lockFD:Int32 = -1
    private let limit=1_048_576
    public init(directory:URL) { self.directory=directory }
    public static func production() -> HIDLegacy07FileJournal {
        HIDLegacy07FileJournal(directory:FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cellio/Register07",isDirectory:true))
    }
    private func failure() -> Error { ParseFailure.invalid("Register07 private journal unavailable") }
    private func checked(_ fd:Int32,directory:Bool,privateMode:Bool=false) throws {
        var info=stat()
        guard fd>=0, fstat(fd,&info)==0,
              (info.st_mode & S_IFMT)==(directory ? S_IFDIR:S_IFREG),
              (info.st_uid==getuid() || (directory && info.st_uid==0)),
              (!privateMode || (info.st_uid==getuid() && info.st_mode & 0o777 == (directory ? 0o700:0o600))),
              (directory || info.st_nlink==1),
              (directory || (info.st_size>=0 && info.st_size<=limit)) else { throw failure() }
    }
    public func acquire() throws -> Bool {
        guard directory.isFileURL, directory.path.hasPrefix("/"), directoryFD == -1 else { throw failure() }
        // Walk through directory descriptors; never follow a user-controlled link.
        var current=open("/",O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW)
        guard current>=0 else { throw failure() }
        defer { if current>=0 { close(current) } }
        let parts=directory.pathComponents.filter { $0 != "/" }
        guard !parts.isEmpty, !parts.contains("..") else { throw failure() }
        for (index,part) in parts.enumerated() {
            if mkdirat(current,part,0o700) != 0 && errno != EEXIST { throw failure() }
            let next=openat(current,part,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW)
            do {
                try checked(next,directory:true,privateMode:index==parts.count-1)
                var info=stat(); guard fstat(next,&info)==0,
                    info.st_mode & 0o022 == 0 || (info.st_uid==0 && info.st_mode & S_ISVTX != 0) else { throw failure() }
            } catch { if next>=0 { close(next) }; throw error }
            close(current); current=next
        }
        let fd=openat(current,"coordination.lock",O_RDWR|O_CREAT|O_CLOEXEC|O_NOFOLLOW,0o600)
        do { try checked(fd,directory:false,privateMode:true) }
        catch { if fd>=0 { close(fd) }; throw error }
        guard flock(fd,LOCK_EX|LOCK_NB)==0 else { close(fd); return false }
        directoryFD=current; current = -1; lockFD=fd
        return true
    }
    public func release() {
        if lockFD>=0 { flock(lockFD,LOCK_UN); close(lockFD); lockFD = -1 }
        if directoryFD>=0 { close(directoryFD); directoryFD = -1 }
    }
    deinit { release() }
    public func load() throws -> Data? {
        guard lockFD>=0 else { throw failure() }
        let fd=openat(directoryFD,"generations.json",O_RDONLY|O_CLOEXEC|O_NOFOLLOW)
        if fd<0 && errno==ENOENT { return nil }
        defer { if fd>=0 { close(fd) } }
        try checked(fd,directory:false,privateMode:true)
        var info=stat(); guard fstat(fd,&info)==0 else { throw failure() }
        var data=Data(count:Int(info.st_size))
        let count=data.withUnsafeMutableBytes { bytes -> Int in
            var offset=0
            while offset<bytes.count {
                let n=Darwin.read(fd,bytes.baseAddress!.advanced(by:offset),bytes.count-offset)
                if n<0 && errno==EINTR { continue }
                if n<=0 { return -1 }; offset+=n
            }
            return offset
        }
        guard count==data.count else { throw failure() }
        return data
    }
    public func store(_ data:Data) throws {
        guard lockFD>=0, data.count<=limit else { throw failure() }
        let name="pending-"+UUID().uuidString
        let fd=openat(directoryFD,name,O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC|O_NOFOLLOW,0o600)
        guard fd>=0 else { throw failure() }
        defer { close(fd); unlinkat(directoryFD,name,0) }
        try checked(fd,directory:false,privateMode:true)
        let written=data.withUnsafeBytes { bytes -> Bool in
            var offset=0
            while offset<bytes.count {
                let n=Darwin.write(fd,bytes.baseAddress!.advanced(by:offset),bytes.count-offset)
                if n<0 && errno==EINTR { continue }
                if n<=0 { return false }; offset+=n
            }
            return true
        }
        guard written, fsync(fd)==0,
              renameat(directoryFD,name,directoryFD,"generations.json")==0,
              fsync(directoryFD)==0 else { throw failure() }
    }
}

public enum HIDCollectionTrigger { case normal, inputEvent }

/// The provider uses this monotonic schedule. Events never move the next normal
/// deadline; an explicit user refresh qualifies as a normal collection.
public struct HIDCollectionSchedule {
    public private(set) var nextNormal:TimeInterval = -.infinity
    public init() {}
    public mutating func take(now:TimeInterval,manual:Bool,event:Bool) -> HIDCollectionTrigger? {
        if manual || now>=nextNormal { nextNormal=now+60; return .normal }
        return event ? .inputEvent:nil
    }
}

/// Deterministic clock, journal, probe, policy and transport are production seams.
/// The lease covers duplicate native interfaces as well as modern-only traffic.
public final class HIDLegacy07Coordinator {
    public static let shared=HIDLegacy07Coordinator(journal:HIDLegacy07FileJournal.production())
    private struct Binding:Codable {
        let fingerprint:String
        let id:String
        var qualified:Bool
    }
    private final class Generation:Codable {
        var removed=false, poisoned=false, pending=false
        var bindings:[UInt8:Binding]=[:]
        var policyAnchors:[UInt8:String]=[:]
        var legacy=Set<UInt8>(), needsProbe=Set<UInt8>()
        var epoch:UInt64=0
        var nextCollection:TimeInterval=0
    }
    private struct Journal:Codable {
        var version=1
        var generations:[String:Generation]=[:]
    }
    private let lock=NSRecursiveLock()
    private let journal:HIDLegacy07JournalStorage
    private var generations:[String:Generation]=[:]
    private var depth=0, storageReady=false
    public init(journal:HIDLegacy07JournalStorage = HIDLegacy07FileJournal.production()) { self.journal=journal }
    private func enter() {
        lock.lock(); depth+=1
        guard depth==1 else { return }
        storageReady=false
        do {
            guard try journal.acquire() else { return }
            storageReady=true
            if let data=try journal.load() {
                guard data.count<=1_048_576 else { throw ParseFailure.unsupported }
                let loaded=try JSONDecoder().decode(Journal.self,from:data)
                guard loaded.version==1, loaded.generations.count<=256,
                      loaded.generations.allSatisfy({ key,s in
                          !key.isEmpty && key.utf8.count<=128 && s.bindings.count<=6 && s.policyAnchors.count<=6 &&
                          s.legacy.allSatisfy({ (1...6).contains($0) }) && s.needsProbe.isSubset(of:s.legacy) &&
                          s.bindings.allSatisfy({ (1...6).contains($0.key) && $0.value.id.hasPrefix("hid-register07-") && $0.value.id.utf8.count<=128 && $0.value.fingerprint.utf8.count<=128 }) &&
                          s.policyAnchors.allSatisfy({ (1...6).contains($0.key) && $0.value.hasPrefix("hid-register07-") && $0.value.utf8.count<=128 }) && s.nextCollection.isFinite
                      }) else { throw ParseFailure.unsupported }
                for (key,s) in loaded.generations {
                    if s.pending { s.poisoned=true }
                    if let local=generations[key] {
                        s.poisoned = s.poisoned || local.poisoned
                        s.removed = s.removed || local.removed
                        // A missing/regressed record cannot resurrect local epochs.
                        guard s.epoch>=local.epoch else { throw ParseFailure.unsupported }
                    }
                }
                for key in generations.keys where loaded.generations[key]==nil { throw ParseFailure.unsupported }
                generations=loaded.generations
            } else {
                // Keep local quarantine if a journal disappears while running.
                for s in generations.values { s.poisoned=true }
            }
        } catch {
            storageReady=false
            for s in generations.values { s.poisoned=true }
        }
    }
    private func leave() {
        depth-=1
        if depth==0 { journal.release(); storageReady=false }
        lock.unlock()
    }
    private func save() -> Bool {
        guard storageReady, generations.count<=256 else { return false }
        do {
            let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys]
            try journal.store(encoder.encode(Journal(generations:generations)))
            return true
        } catch {
            storageReady=false
            for s in generations.values { s.poisoned=true }
            return false
        }
    }
    private func state(_ key:String) -> Generation {
        if let s=generations[key] { return s }
        let s=Generation()
        // New OS keys alone do not recover missing state. Require a positively
        // removed generation in the durable journal. Never clear an old key.
        s.poisoned = !storageReady || !generations.values.contains(where: { $0.removed }) || key.isEmpty || key.utf8.count>128
        guard generations.count<256 else { s.poisoned=true; return s }
        generations[key]=s
        if !save() { s.poisoned=true }
        return s
    }
    public func beginReceiver(generation:String) { enter() }
    public func endReceiver(generation:String) { leave() }
    public func invalidate(generation:String,message:String,poison:Bool=false) -> HIDLegacy07Collection {
        enter(); defer { leave() }
        let s=state(generation)
        var out=HIDLegacy07Collection(); out.diagnostic=message
        if poison { s.poisoned=true }
        for slot in Array(s.bindings.keys) {
            guard let binding=s.bindings[slot] else { continue }
            out.failures[binding.id]=message; out.connections[binding.id] = .unavailable
            s.bindings[slot]?.qualified=false
        }
        _=save()
        return out
    }
    public func remove(generation:String) -> [String] {
        enter(); defer { leave() }
        let s=state(generation)
        s.removed=true; s.poisoned=true
        let ids=s.bindings.values.map(\.id)
        for slot in Array(s.bindings.keys) { s.bindings[slot]?.qualified=false }
        _=save()
        return ids
    }
    public func isPoisoned(generation:String) -> Bool {
        enter(); defer { leave() }; let s=state(generation)
        return !storageReady || s.poisoned || s.pending || s.removed
    }
    /// One call owns the whole receiver, including its modern probes and slots.
    /// `modern` runs under the same lock, so duplicate interfaces/providers cannot
    /// create concurrent readers. Nil/uncertain native generations never call here.
    public func collect(generation:String,vendor:Int,product:Int,transportName:String,descriptor:HIDDescriptor,
                        transport:ReportTransport,monotonic:() -> TimeInterval,collectionTime:() -> Date,
                        live:() -> Bool,allows:(String) -> Bool,
                        trigger:HIDCollectionTrigger = .normal,
                        probeAllowed:(UInt8) -> Bool = { _ in true },
                        modernFailure:(UInt8,Error) -> Void = { _,_ in },
                        probe:(UInt8,TimeInterval,() -> Void) throws -> HIDLegacy07Probe,
                        modern:(UInt8,Bool) -> Void) -> HIDLegacy07Collection {
        var out=HIDLegacy07Collection()
        guard !generation.isEmpty, HIDLegacy07.eligible(vendor:vendor,product:product,transport:transportName,descriptor:descriptor) else { return out }
        enter(); defer { leave() }
        let s=state(generation)
        guard !s.removed else { return out }
        let start=monotonic(), deadline=start+10
        // Only normal scheduled/manual collections may submit legacy exchanges.
        // An event never advances this deadline, even after the throttle elapsed.
        let legacyAdmitted=trigger == .normal && start>=s.nextCollection && storageReady
        if legacyAdmitted { s.nextCollection=start+60 }
        if s.pending || !storageReady { s.poisoned=true }
        var receiverSubmitted=false
        var metadataInFlight=false
        var probing=false
        let capturedAnchors=s.policyAnchors
        func policy(_ slot:UInt8,_ id:String?=nil) -> Bool {
            live() && !s.removed && allows("legacy07-policy-"+generation) &&
                (capturedAnchors[slot].map(allows) ?? true) &&
                (s.policyAnchors[slot].map(allows) ?? true) && (id.map(allows) ?? true)
        }
        func invalidate(_ slot:UInt8,_ message:String,_ disconnected:Bool=false) {
            if let binding=s.bindings[slot] {
                out.failures[binding.id]=message
                out.connections[binding.id]=disconnected ? .disconnected:.unavailable
                s.bindings[slot]?.qualified=false
            }
        }
        func submit() throws {
            s.pending=true
            guard save() else { s.poisoned=true; throw ParseFailure.invalid("Register07 journal commit failed") }
            receiverSubmitted=true
        }
        func barrier(_ slot:UInt8,_ id:String?=nil) throws {
            guard !s.poisoned, policy(slot,id) else {
                if receiverSubmitted { s.poisoned=true }
                throw ParseFailure.invalid("Register07 canceled or policy changed")
            }
            guard monotonic()<deadline else {
                if receiverSubmitted { s.poisoned=true }
                throw ParseFailure.timeout
            }
        }
        func read(_ output:[UInt8],slot:UInt8,selector:UInt8?=nil,id:String?=nil) throws -> [UInt8] {
            try barrier(slot,id)
            try submit()
            try barrier(slot,id)
            let remaining=deadline-monotonic()
            guard remaining>0 else { s.poisoned=true; throw ParseFailure.timeout }
            do {
                let reply=try transport.exchange(output,timeout:min(0.5,remaining)) { bytes in
                    let target:UInt8=selector == nil ? slot:0xff
                    let command:UInt8=selector == nil ? 0x81:0x83
                    let register:UInt8=selector == nil ? 7:0xb5
                    if bytes.count==7, Array(bytes.prefix(5)) == [0x10,target,0x8f,command,register], bytes[6]==0 { throw ParseFailure.remoteError(bytes[5]) }
                    if let selector {
                        guard bytes.count==20, Array(bytes.prefix(5)) == [0x11,0xff,0x83,0xb5,selector] else { throw ParseFailure.unmatched }
                    } else {
                        guard bytes.count==7, Array(bytes.prefix(4)) == [0x10,slot,0x81,7] else { throw ParseFailure.unmatched }
                    }
                    return bytes
                }
                try barrier(slot,id)
                return reply
            } catch {
                if (error as? ParseFailure) == .timeout || !policy(slot,id) || monotonic()>=deadline { s.poisoned=true }
                throw error
            }
        }
        func metadata(_ slot:UInt8) throws -> HIDLegacy07Pairing {
            let q:UInt8=0x20+slot-1, x:UInt8=0x30+slot-1
            let pairing=try read([0x10,0xff,0x83,0xb5,q,0,0],slot:slot,selector:q)
            let extended=try read([0x10,0xff,0x83,0xb5,x,0,0],slot:slot,selector:x)
            return try HIDLegacy07Pairing(pairing:pairing,extended:extended,slot:slot)
        }
        for slot in UInt8(1)...UInt8(6) {
            metadataInFlight=false; probing=false
            guard policy(slot) else { invalidate(slot,"Register07 collection suppressed"); continue }
            if !legacyAdmitted || s.poisoned {
                if s.poisoned { invalidate(slot,"Register07 generation quarantined") }
                // Poison applies only to legacy. Existing modern readers remain live.
                if (!s.legacy.contains(slot) || (s.poisoned && trigger == .normal)), probeAllowed(slot) {
                    modern(slot,false); out.modernSlots.append(slot)
                }
                continue
            }
            do {
                try barrier(slot)
                if !s.legacy.contains(slot) || s.needsProbe.contains(slot) {
                    guard probeAllowed(slot) else { invalidate(slot,"Register07 probe policy suppressed"); continue }
                    // Initial root exchange is shared with modern detection, never
                    // a speculative fallback ping. Any timeout poisons legacy only.
                    try submit()
                    try barrier(slot)
                    probing=true
                    let result=try probe(slot,min(0.5,deadline-monotonic()),{ s.poisoned=true; _=self.save() })
                    probing=false
                    if result == .modern {
                        s.legacy.remove(slot); s.needsProbe.remove(slot)
                        modern(slot,true); out.modernSlots.append(slot); continue
                    }
                    s.legacy.insert(slot); s.needsProbe.remove(slot)
                    try barrier(slot)
                }
                metadataInFlight=true
                let before=try metadata(slot)
                metadataInFlight=false
                let fingerprint=SystemReportParser.opaqueIdentity("\(before.wpid):\(before.type):\(before.serial)")
                if let old=s.bindings[slot], old.fingerprint != fingerprint {
                    out.retired.append(old.id); out.connections[old.id] = .disconnected
                    out.failures[old.id]="Receiver-local pairing snapshot replaced"
                    s.bindings[slot]=nil
                }
                if s.bindings[slot]==nil {
                    guard s.epoch<UInt64.max else { s.poisoned=true; throw ParseFailure.unsupported }
                    s.epoch += 1
                    let tuple="register07:\(generation):\(slot):\(before.wpid):\(before.type):\(before.serial):\(s.epoch)"
                    let id="hid-register07-"+SystemReportParser.opaqueIdentity(tuple)
                    s.bindings[slot]=Binding(fingerprint:fingerprint,id:id,qualified:false)
                }
                guard let binding=s.bindings[slot] else { throw ParseFailure.unsupported }
                s.policyAnchors[slot]=binding.id
                // Qualified route policy is checked before battery submission and
                // again at publication; no discovery can reset an old policy.
                try barrier(slot,binding.id)
                let battery=try read([0x10,slot,0x81,7,0,0,0],slot:slot,id:binding.id)
                metadataInFlight=true
                let after=try metadata(slot)
                metadataInFlight=false
                guard before==after else {
                    out.retired.append(binding.id)
                    out.connections[binding.id] = .disconnected
                    out.failures[binding.id]="Register07 pre/post pairing mismatch"
                    s.bindings[slot]=nil
                    s.needsProbe.insert(slot)
                    throw ParseFailure.invalid("Register07 pre/post pairing mismatch")
                }
                let reading=try HIDLegacy07.decode(battery,slot:slot)
                try barrier(slot,binding.id)
                let route=HIDLegacy07.route(slot:slot)
                // Journal contains only its opaque fingerprint/route; no unit proof,
                // ownership, cross-transport grouping, or sensor timestamps.
                out.routes.append(SavedBatteryRoute(id:binding.id,metadata:route))
                out.observations.append(Observation(id:ComponentID(device:binding.id),name:"K800",source:.hidLegacy,connection:.connected,quantity:reading.quantity,charge:reading.charge,collectedAt:collectionTime(),route:route))
                out.connections[binding.id] = .connected
                s.bindings[slot]?.qualified=true
            } catch {
                if receiverSubmitted && (!policy(slot) || monotonic()>=deadline) { s.poisoned=true }
                // Initial opt-in root errors belong to the existing modern slot.
                // Publishing this error does not retry or establish legacy authority.
                if probing { modernFailure(slot,error) }
                invalidate(slot,"Experimental register07 unavailable: \(error)",!live())
                if metadataInFlight {
                    if let old=s.bindings[slot] { out.retired.append(old.id) }
                    s.bindings[slot]=nil
                    // A failed/ineligible bracket retires classification. Only a
                    // later normal collection can probe the replacement; there is
                    // no fallback command in the failed exchange.
                    s.needsProbe.insert(slot)
                }
                out.diagnostic="Experimental register07 unavailable: \(error)"
            }
        }
        // A later slot can cross a stop/policy/deadline barrier after an earlier
        // slot completed: discard any no-longer-admissible batch before return.
        if receiverSubmitted && (!live() || monotonic()>=deadline) { s.poisoned=true }
        let candidates=out.observations
        out.observations=[]
        for observation in candidates {
            let slot=s.bindings.first(where: { $0.value.id==observation.id.device })?.key
            guard let slot, !s.poisoned, policy(slot,observation.id.device), monotonic()<deadline else {
                if receiverSubmitted && (!live() || monotonic()>=deadline || slot.map({ !policy($0,observation.id.device) }) == true) { s.poisoned=true }
                if let slot { s.bindings[slot]?.qualified=false }
                out.failures[observation.id.device]="Register07 publication invalidated"
                out.connections[observation.id.device] = .unavailable
                continue
            }
            out.observations.append(observation)
        }
        // Clearing uncertainty is durable only after the entire collection and
        // final policy fence. A failed commit withholds every legacy publication.
        s.pending=false
        if !save() {
            s.poisoned=true
            for observation in out.observations {
                out.failures[observation.id.device]="Register07 journal commit failed"
                out.connections[observation.id.device] = .unavailable
            }
            out.observations=[]
        }
        // Journal I/O can consume the remaining budget or race a stop/policy edit.
        if receiverSubmitted && (!live() || monotonic()>=deadline || out.observations.contains(where: { observation in
            guard let slot=s.bindings.first(where: { $0.value.id==observation.id.device })?.key else { return true }
            return !policy(slot,observation.id.device)
        })) {
            s.poisoned=true
            for observation in out.observations {
                out.failures[observation.id.device]="Register07 publication invalidated"
                out.connections[observation.id.device] = .unavailable
            }
            out.observations=[]
            _=save()
        }
        let published=Set(out.observations.map { $0.id.device })
        out.routes.removeAll { !published.contains($0.id) }
        return out
    }
}
