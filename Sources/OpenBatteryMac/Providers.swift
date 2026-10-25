import Foundation
import Darwin
import IOKit.hid
import OpenBatteryCore

struct ProviderBatch:DevicePolicyBatchContext {
    var observations:[Observation]=[]
    var failures:[String:String]=[:]
    var status:[String:String]=[:]
    var devicePolicyContext:DeviceCollectionContext?
    var routes:[SavedBatteryRoute]=[]
    var connections:[String:ConnectionState]=[:]
    var successfulSources: Set<String> = []
}

struct SystemReportCommandResult {
    let data:Data
    let terminationStatus:Int32
}

protocol SystemReportCommandRunning {
    func run(executable:URL, arguments:[String], byteLimit:Int, timeout:TimeInterval,
             isCanceled:() -> Bool) throws -> SystemReportCommandResult
    func cancelCurrent()
}

/// Internal bounded executor; tests may supply a controlled executable, arguments,
/// positive byteLimit <= 2 MiB and finite timeout in (0, 10] seconds. Product calls
/// remain fixed in SystemReportProvider; this is not a product command callback.
/// Synchronous on the caller's queue, single flight. Every exit path closes the
/// pipe and reaps a launched child, including EOF while a silent child is alive.
final class BoundedSystemReportCommandRunner:SystemReportCommandRunning {
    private let lock=NSLock()
    private var current:Process?
    private var cancellationGeneration:UInt64=0

    func cancelCurrent() {
        lock.lock(); defer { lock.unlock() }
        // Invalidate admission even if the child has not been published yet.
        cancellationGeneration &+= 1
        if let process=current, process.isRunning { process.terminate() }
    }

    func run(executable:URL, arguments:[String], byteLimit:Int, timeout:TimeInterval,
             isCanceled:() -> Bool) throws -> SystemReportCommandResult {
        guard executable.isFileURL, byteLimit > 0, byteLimit <= 2 * 1024 * 1024,
              timeout.isFinite, timeout > 0, timeout <= 10 else {
            throw ParseFailure.invalid("Invalid bounded process executable or limits")
        }
        lock.lock(); let generation=cancellationGeneration; lock.unlock()
        func checkCancellation() throws {
            // Caller code can acquire the provider lock: never invoke it under
            // the runner lock. Recheck the generation after that callback.
            let canceled=isCanceled()
            lock.lock(); let invalidated=cancellationGeneration != generation; lock.unlock()
            guard !canceled, !invalidated else { throw ParseFailure.invalid("System report canceled") }
        }
        try checkCancellation()
        let process=Process(), pipe=Pipe()
        process.executableURL=executable; process.arguments=arguments
        process.standardOutput=pipe; process.standardError=FileHandle.nullDevice
        var launched=false
        defer {
            if launched {
                if process.isRunning {
                    process.terminate()
                    let grace=ProcessInfo.processInfo.systemUptime + 0.1
                    while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { Thread.sleep(forTimeInterval:0.01) }
                    if process.isRunning { kill(process.processIdentifier,SIGKILL) }
                }
                process.waitUntilExit()
            }
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
            lock.lock()
            if current === process { current=nil }
            lock.unlock()
        }
        // Cancellation between the unlocked callback and admission changes the
        // generation, preventing launch. If launch wins, cancelCurrent sees that
        // exact child under this same lock. No caller code runs under the lock.
        lock.lock()
        guard current == nil, cancellationGeneration == generation else { lock.unlock(); throw ParseFailure.invalid("System report canceled or already running") }
        current=process
        let deadline=ProcessInfo.processInfo.systemUptime + timeout
        do { try process.run(); launched=true; lock.unlock() }
        catch { current=nil; lock.unlock(); throw error }
        try pipe.fileHandleForWriting.close()
        let fd=pipe.fileHandleForReading.fileDescriptor
        let flags=fcntl(fd,F_GETFL)
        guard flags != -1, fcntl(fd,F_SETFL,flags | O_NONBLOCK) != -1 else { throw ParseFailure.invalid("System report pipe unavailable") }
        var output=Data(), eof=false
        var buffer=[UInt8](repeating:0,count:16384)
        while true {
            try checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ParseFailure.timeout }
            if !eof {
                let n=buffer.withUnsafeMutableBytes { Darwin.read(fd,$0.baseAddress!,$0.count) }
                if n > 0 {
                    guard n <= byteLimit-output.count else { throw ParseFailure.invalid("System report exceeded byte limit") }
                    output.append(contentsOf:buffer.prefix(n))
                    continue
                } else if n == 0 { eof=true }
                else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { throw ParseFailure.invalid("System report output failed") }
            }
            if eof && !process.isRunning { break }
            Thread.sleep(forTimeInterval:0.01)
        }
        process.waitUntilExit()
        try checkCancellation()
        return SystemReportCommandResult(data:output,terminationStatus:process.terminationStatus)
    }
}

final class SystemReportProvider {
    private let worker=DispatchQueue(label:"openbattery.system-report",qos:.utility)
    private let lock=NSLock()
    private var running=false
    private var canceled=false
    private var pendingCancellations=0
    private let commandRunner:SystemReportCommandRunning

    init(commandRunner:SystemReportCommandRunning = BoundedSystemReportCommandRunner()) { self.commandRunner=commandRunner }
    func cancel() {
        // Fence admission while cancelCurrent runs, without holding the flag lock
        // across a runner call (run may itself be checking the cancellation flag).
        // Keep the fence until every cancel returns: an old cancel must not reach
        // a resumed collection after the previous worker releases running.
        lock.lock(); canceled=true; pendingCancellations += 1; lock.unlock()
        commandRunner.cancelCurrent()
        lock.lock(); pendingCancellations -= 1; lock.unlock()
    }
    private var isCanceled:Bool { lock.lock(); defer { lock.unlock() }; return canceled }
    func collect(clock:BatteryClock=SystemBatteryClock(), completion:@escaping(ProviderBatch)->Void) {
        lock.lock(); if running || pendingCancellations > 0 { lock.unlock(); return }; running=true; canceled=false; lock.unlock()
        worker.async {
            let at=clock.now()
            var result=ProviderBatch()
            for scope in ["systemReport","accessory-power"] {
                do {
                    guard !self.isCanceled else { throw ParseFailure.invalid("System report canceled") }
                    let original = scope == "systemReport"
                    let command=try self.commandRunner.run(
                        executable:URL(fileURLWithPath:original ? "/usr/sbin/system_profiler":"/usr/bin/pmset"),
                        arguments:original ? ["SPBluetoothDataType","-json"]:["-g","accps","-xml"],
                        byteLimit:2 * 1024 * 1024, timeout:10, isCanceled:{ self.isCanceled })
                    guard !self.isCanceled, command.terminationStatus == 0 else { throw ParseFailure.invalid("Collection canceled or command failed") }
                    let observations = try original ? SystemReportParser.parse(command.data,collectedAt:at):AccessoryPowerParser.parse(command.data,collectedAt:at)
                    guard !self.isCanceled else { throw ParseFailure.invalid("System report canceled") }
                    result.observations.append(contentsOf:observations)
                    result.successfulSources.insert(scope)
                    result.status[scope]=original ? "Experimental system report · measurement age unknown":"OS-cached accessory power · measurement age and connection unknown"
                } catch {
                    result.status[scope]="Collection unavailable: \(error)"
                    result.failures[scope]="\(scope == "systemReport" ? "System report":"Accessory power") collection failed"
                }
            }
            // run() has finished cleanup for every attempted command before delivery.
            // Release ownership first so a queued resume can collect again.
            self.lock.lock(); self.running=false; self.lock.unlock()
            completion(result)
        }
    }
}

/// Registry metadata only. This collector never creates or opens an IOHIDDevice.
private final class USBKeyboardPresence {
    private var connections: [UInt64:String] = [:]
    private static func bootSessionID() -> String? {
        var size=0
        guard sysctlbyname("kern.bootsessionuuid",nil,&size,nil,0) == 0, (2...128).contains(size) else { return nil }
        var bytes=[UInt8](repeating:0,count:size)
        guard bytes.withUnsafeMutableBytes({ sysctlbyname("kern.bootsessionuuid",$0.baseAddress,&size,nil,0) }) == 0,
              size > 1, size <= bytes.count, bytes[size-1] == 0,
              let raw=String(bytes:bytes.prefix(size-1),encoding:.utf8), let boot=UUID(uuidString:raw) else { return nil }
        return boot.uuidString
    }
    func collect(into batch: inout ProviderBatch, at now: Date, accepts: (String)->Bool) {
        guard let bootSessionID=Self.bootSessionID() else {
            batch.status["usbPresence"]="USB presence boot identity unavailable"
            for id in connections.values where accepts(id) { batch.connections[id] = .unavailable }
            return
        }
        let properties: [String:Any] = [kIOHIDVendorIDKey:0x36b0, kIOHIDProductIDKey:0x3050,
            kIOHIDTransportKey:"USB", kIOHIDPrimaryUsagePageKey:1, kIOHIDPrimaryUsageKey:6]
        let query: [String:Any] = [kIOProviderClassKey:"IOHIDDevice", kIOPropertyMatchKey:properties]
        var iterator:io_iterator_t=0
        let status=IOServiceGetMatchingServices(kIOMainPortDefault,query as CFDictionary, &iterator)
        guard status == kIOReturnSuccess else {
            batch.status["usbPresence"]="USB presence metadata unavailable"
            for id in connections.values where accepts(id) { batch.connections[id] = .unavailable }
            return
        }
        defer { IOObjectRelease(iterator) }
        var present=Set<UInt64>()
        while case let service=IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            // Verify the exact metadata gate again; no descriptor/element/report is read.
            func property(_ key: String) -> Any? { IORegistryEntryCreateCFProperty(service,key as CFString,kCFAllocatorDefault,0)?.takeRetainedValue() }
            guard USBKeyboardPresenceIdentity.qualifies(
                vendor:(property(kIOHIDVendorIDKey) as? NSNumber)?.intValue,
                product:(property(kIOHIDProductIDKey) as? NSNumber)?.intValue,
                transport:property(kIOHIDTransportKey) as? String,
                usagePage:(property(kIOHIDPrimaryUsagePageKey) as? NSNumber)?.intValue,
                usage:(property(kIOHIDPrimaryUsageKey) as? NSNumber)?.intValue) else { continue }
            var registryID:UInt64=0
            guard IORegistryEntryGetRegistryEntryID(service,&registryID) == kIOReturnSuccess, registryID != 0,
                  present.insert(registryID).inserted else { continue }
            // Stable across collectors/processes for this boot and registry entry only.
            guard let id=USBKeyboardPresenceIdentity.connectionKey(bootSessionID:bootSessionID,registryEntryID:registryID) else { continue }
            connections[registryID]=id
            guard accepts(id) else { continue }
            let route=BatteryRouteMetadata(type:.wiredUSB,kind:.keyboard,topology:"USB 36B0:3050 keyboard primary collection 1/6; presence metadata only")
            batch.observations.append(Observation(id:ComponentID(device:id),name:"Maxfit8",source:.usbPresence,connection:.connected,quantity:.absent,collectedAt:now,route:route))
        }
        guard IOIteratorIsValid(iterator) != 0 else {
            batch.status["usbPresence"]="USB presence metadata changed during enumeration"
            // An incomplete enumeration proves neither presence nor removal.
            batch.observations.removeAll { $0.source == .usbPresence }
            for id in connections.values where accepts(id) { batch.connections[id] = .unavailable }
            return
        }
        for registryID in Array(connections.keys) where !present.contains(registryID) {
            if let id=connections.removeValue(forKey:registryID), accepts(id) { batch.status["removed:"+id]="disconnected" }
        }
    }
}

/// Positive OS receiver generation, independent of HID interface objects and
/// receiver serial labels. Registry entry IDs are scoped to the actual boot.
private struct Legacy07OSReceiver {
    private static let lock=NSLock()
    private static var known:[String:Self]=[:]
    static var knownReceivers:[Self] { lock.lock(); defer { lock.unlock() }; return Array(known.values) }
    let registryID:UInt64
    let generation:String
    static func identify(_ device:IOHIDDevice) -> Self? {
        var entry=IOHIDDeviceGetService(device)
        guard entry != 0 else { return nil }
        IOObjectRetain(entry)
        defer { IOObjectRelease(entry) }
        for _ in 0..<16 {
            if IOObjectConformsTo(entry,"IOUSBHostDevice") != 0 || IOObjectConformsTo(entry,"IOUSBDevice") != 0 {
                func integer(_ key:String) -> Int? { (IORegistryEntryCreateCFProperty(entry,key as CFString,kCFAllocatorDefault,0)?.takeRetainedValue() as? NSNumber)?.intValue }
                var id:UInt64=0
                guard integer("idVendor")==0x046d, integer("idProduct")==0xc52b,
                      IORegistryEntryGetRegistryEntryID(entry,&id)==kIOReturnSuccess, id != 0 else { return nil }
                var size=0
                guard sysctlbyname("kern.bootsessionuuid",nil,&size,nil,0)==0, (2...128).contains(size) else { return nil }
                var bytes=[UInt8](repeating:0,count:size)
                guard bytes.withUnsafeMutableBytes({ sysctlbyname("kern.bootsessionuuid",$0.baseAddress,&size,nil,0) })==0,
                      size>1, size<=bytes.count, bytes[size-1]==0,
                      let raw=String(bytes:bytes.prefix(size-1),encoding:.utf8), let boot=UUID(uuidString:raw) else { return nil }
                let receiver=Self(registryID:id,generation:"\(boot.uuidString):\(id)")
                lock.lock(); known[receiver.generation]=receiver; lock.unlock()
                return receiver
            }
            var parent:io_registry_entry_t=0
            guard IORegistryEntryGetParentEntry(entry,kIOServicePlane,&parent)==kIOReturnSuccess, parent != 0 else { return nil }
            IOObjectRelease(entry); entry=parent
        }
        return nil
    }
    var live:Bool {
        guard let matching=IORegistryEntryIDMatching(registryID) else { return false }
        let service=IOServiceGetMatchingService(kIOMainPortDefault,matching)
        guard service != 0 else { return false }
        IOObjectRelease(service); return true
    }
}

private final class HIDChannel:ReportTransport {
    let device:IOHIDDevice; let descriptor:HIDDescriptor; let advertisedReports:[UInt8:Int]
    private let buffer:UnsafeMutablePointer<UInt8>; private let bufferSize=512
    private let ownerRunLoop:CFRunLoop; private let ownerThread:Thread
    private var opened=false
    private let canceled:() -> Bool
    var frames:[[UInt8]]=[]; var removed=false; var event: (() -> Void)?
    init(device:IOHIDDevice,descriptor:HIDDescriptor,canceled:@escaping () -> Bool) throws {
        self.device=device; self.descriptor=descriptor; advertisedReports=descriptor.hidPlusReports
        ownerRunLoop=CFRunLoopGetCurrent(); ownerThread=Thread.current; self.canceled=canceled
        buffer=UnsafeMutablePointer<UInt8>.allocate(capacity:bufferSize); buffer.initialize(repeating:0,count:bufferSize)
        // Throwing after stored properties are initialized invokes deinit. Only
        // deinit frees this buffer; a failed open has acquired no HID resources.
        let result=IOHIDDeviceOpen(device,IOOptionBits(0)); guard result==kIOReturnSuccess else { throw ParseFailure.invalid("HID access denied, busy or unavailable (\(result))") }
        opened=true
        let context=Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device,buffer,bufferSize,{ context,result,_,_,reportID,report,length in
            guard let context,result==kIOReturnSuccess else { return }; let channel=Unmanaged<HIDChannel>.fromOpaque(context).takeUnretainedValue()
            guard channel.opened,!channel.removed,[UInt32(0x10),0x11,0x51].contains(reportID),length>0,length<=channel.bufferSize else { return }
            let frame=Array(UnsafeBufferPointer(start:report,count:length))
            if channel.frames.count>=64 { channel.frames.removeFirst() }; channel.frames.append(frame)
            if HIDInputEvent.requestsRefresh(frame) { channel.event?() }
        },context)
        IOHIDDeviceRegisterRemovalCallback(device,{ context,_,_ in guard let context else { return }; let channel=Unmanaged<HIDChannel>.fromOpaque(context).takeUnretainedValue(); channel.removed=true; channel.event?() },context)
        IOHIDDeviceScheduleWithRunLoop(device,ownerRunLoop,CFRunLoopMode.defaultMode.rawValue)
    }
    func close() {
        guard opened else { return }
        precondition(Thread.current === ownerThread,"HID teardown must run on its owner thread")
        // All callbacks and exchanges run on this same thread. Remove callback
        // contexts and scheduling while self and the report buffer are alive.
        opened=false; event=nil
        IOHIDDeviceRegisterRemovalCallback(device,nil,nil)
        IOHIDDeviceRegisterInputReportCallback(device,buffer,bufferSize,nil,nil)
        IOHIDDeviceUnscheduleFromRunLoop(device,ownerRunLoop,CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device,IOOptionBits(0))
        frames.removeAll()
    }
    deinit { close(); buffer.deinitialize(count:bufferSize); buffer.deallocate() }
    func exchange(_ output:[UInt8],timeout:TimeInterval,match:([UInt8]) throws -> [UInt8]?) throws -> [UInt8] {
        precondition(Thread.current === ownerThread)
        guard !canceled() else { throw ParseFailure.invalid("HID collection canceled") }
        guard opened,!removed,let id=output.first,let evidence=descriptor.reports[id],output.count==evidence.outputBytes else { throw ParseFailure.offline }
        frames.removeAll(keepingCapacity:true)
        let status=output.withUnsafeBufferPointer { IOHIDDeviceSetReport(device,kIOHIDReportTypeOutput,CFIndex(id),$0.baseAddress!,output.count) }
        guard status==kIOReturnSuccess else { throw ParseFailure.invalid("HID output unavailable (\(status))") }
        let deadline=ProcessInfo.processInfo.systemUptime + min(timeout,0.5)
        while ProcessInfo.processInfo.systemUptime<deadline && !removed && !canceled() {
            while !frames.isEmpty { guard ProcessInfo.processInfo.systemUptime<deadline,!removed,!canceled() else { break }; let frame=frames.removeFirst(); do { if let reply=try match(frame) { return reply } } catch ParseFailure.unmatched { continue } catch { throw error } }
            CFRunLoopRunInMode(.defaultMode,0.01,true)
        }
        guard !canceled() else { throw ParseFailure.invalid("HID collection canceled") }
        throw removed ? ParseFailure.offline : ParseFailure.timeout
    }
}

final class HIDProvider:DevicePolicyProvider {
    private var deviceSettings:DeviceSettingsStore?
    func useDeviceSettings(_ settings:DeviceSettingsStore) { lock.lock(); deviceSettings=settings; lock.unlock() }
    private func policyContext()->DeviceCollectionContext? { lock.lock(); defer { lock.unlock() }; return deviceSettings?.context() }
    private func shouldQuery(_ device:String,context:DeviceCollectionContext?)->Bool {
        guard let context else { return true }
        lock.lock(); let settings=deviceSettings; lock.unlock()
        return settings?.accepts(device,from:context) ?? context.shouldQuery(device)
    }
    private func remember(_ id:String,name:String,source:BatterySource?) {
        lock.lock(); let settings=deviceSettings; lock.unlock()
        settings?.discover(id:id,name:name,source:source)
    }
    private func archiveDirectAliases(transport:String,identity:String,descriptor:HIDDescriptor)->Bool {
        lock.lock(); let settings=deviceSettings; lock.unlock()
        return settings?.archiveDirectBluetoothAliases(transport:transport,channelIdentity:identity,descriptor:descriptor) ?? true
    }
    private let lock=NSLock(); private var refresh=true; private var inputWake=false; private var stopped=false; private var started=false
    private let finished=DispatchGroup()
    private var channels:[String:HIDChannel]=[:]; private var clients:[String:HIDPlusClient]=[:]; private var metadata=HIDMetadataCache()
    private let usbPresence=USBKeyboardPresence()
    var completion:((ProviderBatch)->Void)?
    func start() { lock.lock(); guard !started,!stopped else { lock.unlock(); return }; started=true; finished.enter(); lock.unlock(); let thread=Thread { [self] in defer { finished.leave() }; run() }; thread.name="openbattery HID run loop"; thread.qualityOfService = .utility; thread.start() }
    func requestRefresh() { lock.lock(); refresh=true; lock.unlock() }
    private func requestInputWake() { lock.lock(); inputWake=true; lock.unlock() }
    @discardableResult func stop(waitUntilStopped timeout:TimeInterval=0) -> Bool { lock.lock(); stopped=true; lock.unlock(); return timeout>0 ? finished.wait(timeout:.now()+timeout) == .success:false }
    private var isStopped:Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    private func run() {
        let manager=IOHIDManagerCreate(kCFAllocatorDefault,IOOptionBits(0))
        IOHIDManagerSetDeviceMatching(manager,[kIOHIDVendorIDKey:0x046d] as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(manager,CFRunLoopGetCurrent(),CFRunLoopMode.defaultMode.rawValue)
        let opened=IOHIDManagerOpen(manager,IOOptionBits(0)); var schedule=HIDCollectionSchedule()
        defer { for channel in channels.values { channel.close() }; clients.removeAll(); channels.removeAll(); IOHIDManagerUnscheduleFromRunLoop(manager,CFRunLoopGetCurrent(),CFRunLoopMode.defaultMode.rawValue); if opened==kIOReturnSuccess { IOHIDManagerClose(manager,IOOptionBits(0)) } }
        while true {
            lock.lock(); let shouldStop=stopped,requested=refresh,event=inputWake; refresh=false; inputWake=false; lock.unlock(); if shouldStop { return }
            if let trigger=schedule.take(now:ProcessInfo.processInfo.systemUptime,manual:requested,event:event) {
                let batch=scan(manager,managerStatus:opened,trigger:trigger)
                if !isStopped { completion?(batch) }
            }
            CFRunLoopRunInMode(.defaultMode,0.2,true)
        }
    }
    private func collectLegacy07(device:IOHIDDevice,descriptor:HIDDescriptor,receiver:Legacy07OSReceiver,modernIdentity:String,context:DeviceCollectionContext?,trigger:HIDCollectionTrigger) -> HIDLegacy07Collection {
        let coordinator=HIDLegacy07Coordinator.shared
        let channelKey="legacy07-channel-"+receiver.generation
        var result=HIDLegacy07Collection()
        guard receiver.live else {
            result.retired=coordinator.remove(generation:receiver.generation)
            return result
        }
        guard !isStopped else { return coordinator.invalidate(generation:receiver.generation,message:"Register07 collection stopped") }
        // Wire admission includes all known snapshot policies in the coordinator.
        // Channel close/open itself cannot reset generation state.
        do {
            let channel:HIDChannel
            if let cached=channels[channelKey],!cached.removed { channel=cached }
            else {
                channels[channelKey]?.close(); clients.removeValue(forKey:channelKey); channels.removeValue(forKey:channelKey)
                channel=try HIDChannel(device:device,descriptor:descriptor,canceled:{ [weak self] in self?.isStopped ?? true })
                channels[channelKey]=channel; clients[channelKey]=HIDPlusClient(transport:channel)
                // The coordinator admits legacy only on its normal interval;
                // events retain the existing modern refresh behavior.
                channel.event={ [weak self] in self?.requestInputWake() }
            }
            let client=clients[channelKey] ?? HIDPlusClient(transport:channel)
            var modern=HIDLegacy07Collection()
            result=coordinator.collect(generation:receiver.generation,vendor:0x046d,product:0xc52b,transportName:"USB",descriptor:descriptor,transport:channel,
                monotonic:{ ProcessInfo.processInfo.systemUptime },collectionTime:{ Date() },
                live:{ !self.isStopped && !channel.removed && receiver.live },
                allows:{ self.shouldQuery($0,context:context) },
                trigger:trigger,
                probeAllowed:{ slot in
                    let id=modernIdentity+"-\(slot)"
                    return self.shouldQuery(id,context:context)
                },
                modernFailure:{ slot,error in
                    let id=modernIdentity+"-\(slot)"
                    modern.connections[id]=HIDModernProbeFailure.connection(removed:channel.removed,error:error)
                    self.metadata[id]=nil
                    modern.failures[id]=HIDModernProbeFailure.message(error)
                },
                probe:{ slot,timeout,onTimeout in try client.probeLegacy07(device:slot,ping:UInt8.random(in:1...255),timeout:timeout,onTimeout:onTimeout) },
                modern:{ slot,alreadyProbed in
                    // A successful modern classification continues the established
                    // feature/metadata path. Poisoned unknown slots must first pass
                    // the unchanged modern-only probe, with its original retry.
                    let id=modernIdentity+"-\(slot)"
                    guard self.shouldQuery(id,context:context), !self.isStopped else { return }
                    do {
                        if !alreadyProbed { try client.probe(device:slot,ping:UInt8.random(in:1...255)) }
                        self.remember(id,name:self.metadata[id]?.name ?? "Receiver accessory \(slot)",source:nil)
                        modern.connections[id] = .connected
                        var battery:(BatteryReading,BatterySource)?
                        do { battery=try client.battery(device:slot) }
                        catch { modern.failures[id]="Accessory battery unavailable: \(error)" }
                        let batteryTime=Date()
                        if self.metadata[id]==nil { self.metadata[id]=client.metadata(device:slot) }
                        let kind:PhysicalDeviceKind
                        switch self.metadata[id]?.type { case 0,2:kind = .keyboard; case 3,5:kind = .mouse; case 4:kind = .trackpad; default:kind = .unknown }
                        let route=BatteryRouteMetadata(type:.unknown,kind:kind,topology:"Descriptor-qualified HID++ endpoint; physical topology unproved")
                        modern.routes.append(SavedBatteryRoute(id:id,metadata:route))
                        if let (reading,source)=battery {
                            modern.observations.append(Observation(id:ComponentID(device:id),name:self.metadata[id]?.name ?? "Receiver accessory \(slot)",source:source,connection:.connected,quantity:reading.quantity,charge:reading.charge,observedAt:reading.quantity.isKnown ? batteryTime:nil,collectedAt:Date(),route:route))
                        }
                    } catch { modern.connections[id]=HIDModernProbeFailure.connection(removed:channel.removed,error:error); self.metadata[id]=nil; modern.failures[id]=HIDModernProbeFailure.message(error) }
                })
            // The final native publication fence also covers OS removal and a
            // concurrent policy edit between the coordinator return and discovery.
            let withheld=result.observations.contains { !self.shouldQuery($0.id.device,context:context) || self.isStopped || !receiver.live }
            if withheld {
                let invalid=coordinator.invalidate(generation:receiver.generation,message:"Register07 native publication canceled",poison:true)
                result.failures.merge(invalid.failures,uniquingKeysWith:{ _,new in new })
                result.connections.merge(invalid.connections,uniquingKeysWith:{ _,new in new })
                result.observations=[]
            }
            let published=Set(result.observations.map { $0.id.device })
            result.routes.removeAll { !published.contains($0.id) }
            for observation in result.observations {
                lock.lock(); let settings=deviceSettings; lock.unlock()
                settings?.discover(id:observation.id.device,name:"K800",source:.hidLegacy,componentIDs:["battery"],kind:.keyboard)
            }
            result.observations += modern.observations; result.routes += modern.routes
            result.failures.merge(modern.failures,uniquingKeysWith:{ _,new in new })
            result.connections.merge(modern.connections,uniquingKeysWith:{ _,new in new })
        } catch {
            result.diagnostic="Experimental register07 interface denied, busy or unavailable: \(error)"
            result=coordinator.invalidate(generation:receiver.generation,message:result.diagnostic!)
        }
        if result.observations.contains(where:{ $0.source == .hidLegacy && $0.route?.topology.hasPrefix("Experimental HID++1 register07;")==true && (!self.shouldQuery($0.id.device,context:context) || self.isStopped || !receiver.live) }) {
            let invalid=coordinator.invalidate(generation:receiver.generation,message:"Register07 final publication canceled",poison:true)
            let legacyIDs=Set(result.observations.filter { $0.route?.topology.hasPrefix("Experimental HID++1 register07;")==true }.map { $0.id.device })
            result.observations.removeAll { legacyIDs.contains($0.id.device) }; result.routes.removeAll { legacyIDs.contains($0.id) }
            result.failures.merge(invalid.failures,uniquingKeysWith:{ _,new in new })
            result.connections.merge(invalid.connections,uniquingKeysWith:{ _,new in new })
        }
        if !receiver.live { result.retired += coordinator.remove(generation:receiver.generation) }
        return result
    }
    private func scan(_ manager:IOHIDManager,managerStatus:IOReturn,trigger:HIDCollectionTrigger) -> ProviderBatch {
        let context=policyContext()
        var out=ProviderBatch(); out.devicePolicyContext=context; let now=Date()
        usbPresence.collect(into:&out,at:now,accepts:{ self.shouldQuery($0,context:context) })
        if managerStatus != kIOReturnSuccess { out.status["HID"]="Accessory access denied, busy or unavailable (\(managerStatus)). Check Input Monitoring in System Settings." }
        let deviceSet=(IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        // Prefer the interface with complete legacy evidence, then consume the
        // actual receiver once. Unqualified directions are never synthesized.
        let devices=deviceSet.sorted { a,b in
            func eligible(_ d:IOHIDDevice) -> Bool {
                guard (IOHIDDeviceGetProperty(d,kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue==0x046d,
                      (IOHIDDeviceGetProperty(d,kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue==0xc52b,
                      (IOHIDDeviceGetProperty(d,kIOHIDTransportKey as CFString) as? String)=="USB",
                      let data=IOHIDDeviceGetProperty(d,kIOHIDReportDescriptorKey as CFString) as? Data, let descriptor=try? HIDDescriptor(data) else { return false }
                return descriptor.legacy07Eligible
            }
            return eligible(a) && !eligible(b)
        }
        var receiverInterfaces=HIDReceiverInterfaceAdmission()
        var present=Set<String>(); var supported=0
        var directChannels=Set<String>()
        for device in devices {
            if isStopped { return out }
            let vendor=(IOHIDDeviceGetProperty(device,kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue ?? 0
            let pid=(IOHIDDeviceGetProperty(device,kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue ?? 0
            guard vendor==0x046d else { continue }
            var registryID:UInt64=0; IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device),&registryID)
            let serial=IOHIDDeviceGetProperty(device,kIOHIDSerialNumberKey as CFString) as? String
            let transport=IOHIDDeviceGetProperty(device,kIOHIDTransportKey as CFString) as? String ?? "unknown"
            let identity=HIDDeviceIdentity.key(vendor:vendor,product:pid,transport:transport,serial:serial,registryID:registryID)
            present.insert(identity)
            let label=IOHIDDeviceGetProperty(device,kIOHIDProductKey as CFString) as? String ?? "Logitech accessory"
            guard let data=IOHIDDeviceGetProperty(device,kIOHIDReportDescriptorKey as CFString) as? Data, let descriptor=try? HIDDescriptor(data) else { continue }
            let headset=pid==0x0af7
            let receiver=(transport=="USB" && pid==0xc52b) ? Legacy07OSReceiver.identify(device):nil
            if let receiver {
                guard receiverInterfaces.admit(generation:receiver.generation,vendor:vendor,product:pid,transport:transport,descriptor:descriptor) else { continue }
                HIDLegacy07Coordinator.shared.beginReceiver(generation:receiver.generation)
            }
            defer { if let receiver { HIDLegacy07Coordinator.shared.endReceiver(generation:receiver.generation) } }
            if HIDLegacy07.eligible(vendor:vendor,product:pid,transport:transport,descriptor:descriptor), let receiver {
                // A previously cached modern interface cannot remain a second
                // reader when this actual receiver selects its legacy interface.
                channels[identity]?.close(); channels.removeValue(forKey:identity); clients.removeValue(forKey:identity)
                supported+=1
                let result=collectLegacy07(device:device,descriptor:descriptor,receiver:receiver,modernIdentity:identity,context:context,trigger:trigger)
                present.insert("legacy07-channel-"+receiver.generation)
                out.observations += result.observations; out.routes += result.routes
                out.failures.merge(result.failures,uniquingKeysWith: { _,new in new })
                out.connections.merge(result.connections,uniquingKeysWith: { _,new in new })
                if let diagnostic=result.diagnostic { out.status[identity]=diagnostic }
                for id in result.retired { out.status["removed:"+id]="disconnected" }
                continue
            }
            guard headset ? descriptor.hasHeadsetReport : !descriptor.hidPlusReports.isEmpty else {
                if headset { out.observations.append(Observation(id:ComponentID(device:identity),name:"PRO X 2 LIGHTSPEED",source:.headset,connection:.unavailable,collectedAt:now,error:"Headset detected; battery interface unavailable")) }
                continue
            }
            let directBluetooth = !headset && HIDRoutingPlan.isDirectBluetooth(transport:transport)
            // Descriptor-ineligible interfaces cannot consume this identity. The
            // opaque key contains serial/product/transport (or a connection ID),
            // never the product label; distinct channels stay independent.
            if directBluetooth {
                guard directChannels.insert(identity).inserted else { continue }
                guard archiveDirectAliases(transport:transport,identity:identity,descriptor:descriptor) else { continue }
            }
            supported+=1
            if headset { remember(identity,name:"PRO X 2 LIGHTSPEED",source:.headset) }
            // Headsets are one device; receiver peripherals retain independent slot policy.
            if headset && !shouldQuery(identity,context:context) { continue }
            do {
                let channel:HIDChannel
                if let cached=channels[identity],!cached.removed,CFEqual(cached.device,device) { channel=cached } else {
                    // Release old clients/contexts before registering a replacement.
                    channels[identity]?.close(); clients.removeValue(forKey:identity); channels.removeValue(forKey:identity); metadata.invalidate(channel:identity)
                    channel=try HIDChannel(device:device,descriptor:descriptor,canceled:{ [weak self] in self?.isStopped ?? true }); channels[identity]=channel; clients[identity]=HIDPlusClient(transport:channel); channel.event={ [weak self] in self?.requestInputWake() }
                }
                if headset {
                    out.routes.append(SavedBatteryRoute(id:identity,metadata:.init(type:.wirelessReceiver,kind:.headset,topology:"Descriptor-qualified PRO X 2 Centurion radio peripheral via receiver")))
                    do { let reading=try HeadsetClient(transport:channel).battery(); out.observations.append(Observation(id:ComponentID(device:identity),name:"PRO X 2 LIGHTSPEED",source:.headset,connection:.connected,quantity:reading.quantity,charge:reading.charge,observedAt:reading.quantity.isKnown ? now:nil,collectedAt:now)) }
                    catch { out.observations.append(Observation(id:ComponentID(device:identity),name:"PRO X 2 LIGHTSPEED",source:.headset,connection:(channel.removed || (error as? ParseFailure) == .offline) ? .disconnected:.unavailable,collectedAt:now,error:"Headset battery unavailable: \(error)")) }
                } else {
                    let client=clients[identity] ?? HIDPlusClient(transport:channel)
                    var found=0
                    var slotFailures:[String]=[]
                    // Direct Bluetooth uses 255 on the wire with the old -1 logical ID.
                    for target in HIDRoutingPlan.targets(transport:transport,channelIdentity:identity) {
                        if isStopped { return out }
                        let slot=target.wireAddress
                        let id=target.logicalID
                        let fallbackName=directBluetooth ? label:"Receiver accessory \(slot)"
                        guard shouldQuery(id,context:context) else { continue }
                        do {
                            try client.probe(device:slot,ping:UInt8.random(in:1...255))
                            // Successful discovery is metadata even if the battery query fails.
                            remember(id,name:metadata[id]?.name ?? fallbackName,source:nil)
                            out.connections[id] = .connected
                            var battery: (BatteryReading,BatterySource)?
                            do { battery=try client.battery(device:slot); found+=1 }
                            catch { out.failures[id]="Accessory battery unavailable: \(error)"; slotFailures.append("address \(slot): \(error)") }
                            let batteryTime=Date()
                            if metadata[id]==nil { metadata[id]=client.metadata(device:slot) }
                            let kind:PhysicalDeviceKind
                            switch metadata[id]?.type { case 0,2: kind = .keyboard; case 3,5: kind = .mouse; case 4: kind = .trackpad; default: kind = .unknown }
                            // Only the independently established Bolt receiver topology authorizes radio labels/identity.
                            let boltReceiver = transport == "USB" && pid == 0xc548
                            let route=BatteryRouteMetadata(type:directBluetooth ? .bluetooth:boltReceiver ? .wirelessReceiver:.unknown,kind:kind,topology:directBluetooth ? "OS HID Bluetooth endpoint, address 255":boltReceiver ? "Descriptor-qualified Bolt receiver peripheral, address \(slot)":"Descriptor-qualified HID++ endpoint; physical topology unproved")
                            let proof=(directBluetooth || boltReceiver) ? try? client.physicalIdentity(device:slot):nil
                            out.routes.append(SavedBatteryRoute(id:id,metadata:route,identity:proof))
                            if let (reading,source)=battery {
                                out.observations.append(Observation(id:ComponentID(device:id),name:metadata[id]?.name ?? fallbackName,source:source,connection:.connected,quantity:reading.quantity,charge:reading.charge,observedAt:reading.quantity.isKnown ? batteryTime:nil,collectedAt:now,route:route))
                            }
                        } catch { out.connections[id]=HIDModernProbeFailure.connection(removed:channel.removed,error:error); metadata[id]=nil; out.failures[id]=HIDModernProbeFailure.message(error); slotFailures.append("address \(slot): \(error)") }
                    }
                    let summary = found == 0 ? "\(label): accessory battery unavailable":"\(label): \(found) accessory battery channel(s)"
                    let failures = slotFailures.isEmpty ? "":" (\(slotFailures.joined(separator:"; ")))"
                    out.status[identity] = summary + failures + (found == 0 ? ". Last readings, if any, remain stale.":"")
                }
            } catch { out.status[identity]="\(label): battery interface denied, busy or unavailable"; out.failures[identity]="Battery interface unavailable" }
        }
        for identity in Array(channels.keys) where !present.contains(identity) || channels[identity]?.removed==true {
            channels[identity]?.close()
            channels.removeValue(forKey:identity); clients.removeValue(forKey:identity); metadata.invalidate(channel:identity); out.failures[identity]="Device removed"; out.status["removed:"+identity]="disconnected"
        }
        // A missing interface/manager result cannot clear a generation. Only a
        // confirmed absence of the exact OS USB registry entry retires it; a new
        // boot/entry key receives distinct state even with the same serial label.
        for receiver in Legacy07OSReceiver.knownReceivers {
            if !receiver.live {
                for id in HIDLegacy07Coordinator.shared.remove(generation:receiver.generation) {
                    out.status["removed:"+id]="disconnected"; out.connections[id] = .disconnected
                }
            } else if !present.contains("legacy07-channel-"+receiver.generation) {
                let invalid=HIDLegacy07Coordinator.shared.invalidate(generation:receiver.generation,message:"Register07 interface unavailable")
                out.failures.merge(invalid.failures,uniquingKeysWith:{ _,new in new })
                out.connections.merge(invalid.connections,uniquingKeysWith:{ _,new in new })
            }
        }
        if out.status["HID"]==nil { out.status["HID"]="Experimental accessory reader · \(supported) eligible interface(s)" }
        return out
    }
}
