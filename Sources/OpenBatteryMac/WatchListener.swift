import Foundation
import Network
import Security
import OpenBatteryCore

// This file is macOS-only; pairing secrets never enter the reducer or diagnostics.
enum PairingKeychain {
    enum ReadError:Error { case status(OSStatus), invalidData }
    static func read(using operation:(CFDictionary,UnsafeMutablePointer<CFTypeRef?>?)->OSStatus = SecItemCopyMatching) throws -> Data? {
        let q:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"org.openbattery.watch-pairing",kSecAttrAccount as String:"mac",kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var result:CFTypeRef?
        let status=operation(q as CFDictionary,&result)
        if status==errSecItemNotFound { return nil }
        guard status==errSecSuccess else { throw ReadError.status(status) }
        guard let data=result as? Data else { throw ReadError.invalidData }
        return data
    }
    static func save(_ data:Data) throws {
        let q:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"org.openbattery.watch-pairing",kSecAttrAccount as String:"mac"]
        let status=SecItemUpdate(q as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if status==errSecItemNotFound { var add=q; add[kSecValueData as String]=data; add[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly; guard SecItemAdd(add as CFDictionary,nil)==errSecSuccess else { throw ParseFailure.invalid("Cannot store pairing secret in Keychain") } }
        else if status != errSecSuccess { throw ParseFailure.invalid("Cannot update pairing secret in Keychain") }
    }
    static func remove() { SecItemDelete([kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"org.openbattery.watch-pairing",kSecAttrAccount as String:"mac"] as CFDictionary) }
}
struct PairingCredentials:Codable { var id:UUID; var secret:Data }
final class WatchListener {
    private let queue=DispatchQueue(label:"openbattery.watch-listener")
    private var listener:NWListener?; private var connections:[UUID:NWConnection]=[:]
    private var credentials:PairingCredentials?
    private var receipt=WatchReceipt()
    private let storeURL:URL
    private let defaults:UserDefaults
    private let readPairing:()throws->Data?
    private let savePairing:(Data)throws->Void
    private let removePairing:()->Void
    private var deliveryOwnership=WatchDeliveryOwnership()
    private struct Delivery {
        let generation:UInt64
        let onSample:(WatchSample)->Void
        let onStatus:(String)->Void
    }
    init(storeURL:URL?=nil,defaults:UserDefaults = .standard,
         readPairing:@escaping()throws->Data? = { try PairingKeychain.read() },
         savePairing:@escaping(Data)throws->Void = PairingKeychain.save,
         removePairing:@escaping()->Void = PairingKeychain.remove) {
        self.defaults=defaults; self.readPairing=readPairing; self.savePairing=savePairing; self.removePairing=removePairing
        if let storeURL { self.storeURL=storeURL }
        else {
            let directory=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("openbattery",isDirectory:true)
            self.storeURL=directory.appendingPathComponent("watch-receipt.json")
            try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        }
        if let data=try? Data(contentsOf:self.storeURL),let saved=try? JSONDecoder().decode(WatchReceipt.self,from:data) { receipt=saved }
    }
    var history:[(sample:WatchSample,receivedAt:Date)] { queue.sync { var values:[(WatchSample,Date)]=[]; if let s=receipt.quantitySample { values.append((s,receipt.quantityReceivedAt ?? s.date)) }; if let s=receipt.latest { values.append((s,receipt.latestReceivedAt ?? s.date)) }; return values } }
    func pairing() throws -> PairingCredentials {
        try queue.sync {
            if !defaults.bool(forKey:"watchPairingRevoked") {
                if let credentials { return credentials }
                if let data=try readPairing() {
                    guard let existing=try? JSONDecoder().decode(PairingCredentials.self,from:data),existing.secret.count==32 else {
                        throw ParseFailure.invalid("Stored pairing credentials are invalid")
                    }
                    credentials=existing; return existing
                }
            }
            var bytes=[UInt8](repeating:0,count:32); guard SecRandomCopyBytes(kSecRandomDefault,32,&bytes)==errSecSuccess else { throw ParseFailure.invalid("Secure random generation failed") }
            let value=PairingCredentials(id:UUID(),secret:Data(bytes))
            try savePairing(JSONEncoder().encode(value))
            defaults.set(false,forKey:"watchPairingRevoked"); credentials=value; return value
        }
    }
    func start(onSample:@escaping(WatchSample)->Void,onStatus:@escaping(String)->Void) {
        do { _=try pairing() } catch { onStatus("Watch listener unavailable: \(error)"); return }
        queue.sync {
            guard self.listener==nil else { return }
            // Capture immutable callbacks for this listener. A late callback must
            // never look up callbacks belonging to a replacement listener.
            let delivery=Delivery(generation:self.deliveryOwnership.begin(),onSample:onSample,onStatus:onStatus)
            do {
                let parameters=NWParameters.tcp; parameters.allowLocalEndpointReuse=true
                let listener=try NWListener(using:parameters,on:58271); self.listener=listener
                listener.stateUpdateHandler={ [weak self] state in
                    guard let self,self.deliveryOwnership.owns(delivery.generation) else { return }
                    switch state {
                    case .ready:delivery.onStatus("Listening on TCP 58271. Local HTTP authenticates but does not encrypt battery data.")
                    case .failed(let e):delivery.onStatus("Listener unavailable: \(e)"); self.stopOnQueue()
                    default:break
                    }
                }
                listener.newConnectionHandler={ [weak self] connection in
                    guard let self,self.deliveryOwnership.owns(delivery.generation) else { connection.cancel(); return }
                    self.accept(connection,delivery:delivery)
                }; listener.start(queue:self.queue)
            } catch { self.deliveryOwnership.invalidate(); delivery.onStatus("Listener failed to start: \(error)") }
        }
    }
    // Complete invalidation before returning to the main actor. Re-enable and
    // new pairing creation cannot overtake a queued stop/revoke operation.
    func stop() { queue.sync { stopOnQueue() } }
    private func stopOnQueue() {
        deliveryOwnership.invalidate()
        listener?.cancel(); listener=nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
    }
    func revoke() {
        queue.sync {
            self.stopOnQueue(); self.credentials=nil
            self.defaults.set(true,forKey:"watchPairingRevoked"); self.removePairing()
            self.receipt=WatchReceipt(); try? FileManager.default.removeItem(at:self.storeURL)
        }
    }
    private func accept(_ connection:NWConnection,delivery:Delivery) {
        guard deliveryOwnership.owns(delivery.generation),connections.count<4 else { connection.cancel(); return }
        let id=UUID(); connections[id]=connection; connection.start(queue:queue)
        let timeout=DispatchWorkItem { [weak self] in self?.finish(id,code:503,message:"Request timed out") }
        queue.asyncAfter(deadline:.now()+5,execute:timeout)
        receive(id,buffer:Data(),timeout:timeout,delivery:delivery)
    }
    private func receive(_ id:UUID,buffer:Data,timeout:DispatchWorkItem,delivery:Delivery) {
        guard let connection=connections[id] else { return }
        connection.receive(minimumIncompleteLength:1,maximumLength:4096) { [weak self] data,_,complete,error in
            guard let self,self.deliveryOwnership.owns(delivery.generation),self.connections[id] != nil else { return }; var buffer=buffer; if let data { buffer.append(data) }
            do {
                guard buffer.count<=8192+4096 else { throw ParseFailure.invalid("body-too-large") }
                if let request=try HTTPRequest.parse(buffer) {
                    timeout.cancel()
                    guard let credentials=self.credentials else { self.finish(id,code:503,message:"Listener is not paired"); return }
                    let sample=try request.authenticatedSample(pairingID:credentials.id,secret:credentials.secret,now:Date())
                    var next=self.receipt
                    let changed=try next.accept(sample,receivedAt:Date())
                    if changed { do { try JSONEncoder().encode(next).write(to:self.storeURL,options:[.atomic]); self.receipt=next; delivery.onSample(sample) } catch { self.finish(id,code:503,message:"Could not persist sample"); return } }
                    self.finish(id,code:200,message:changed ? "retained":"unchanged")
                } else if complete || error != nil { timeout.cancel(); self.finish(id,code:400,message:"Incomplete request") }
                else { self.receive(id,buffer:buffer,timeout:timeout,delivery:delivery) }
            } catch {
                timeout.cancel(); let code:Int
                switch error { case ParseFailure.invalid("unauthorized"):code=401; case ParseFailure.invalid("different-device"):code=409; case ParseFailure.invalid("body-too-large"),ParseFailure.invalid("headers-too-large"):code=413; default:code=400 }
                self.finish(id,code:code,message:code==401 ? "Authentication failed":String(describing:error))
            }
        }
    }
    private func finish(_ id:UUID,code:Int,message:String) {
        guard let connection=connections.removeValue(forKey:id) else { return }
        let body=Data(message.utf8), phrase=[200:"OK",400:"Bad Request",401:"Unauthorized",409:"Conflict",413:"Payload Too Large",503:"Service Unavailable"][code] ?? "Error"
        var response=Data("HTTP/1.1 \(code) \(phrase)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8); response.append(body)
        connection.send(content:response,completion:.contentProcessed { _ in connection.cancel() })
    }
}
