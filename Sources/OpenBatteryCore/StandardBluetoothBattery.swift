import Foundation

/// This profile is deliberately limited to the observed literal product name.
/// Names select the profile; only discovered standard capability permits a read.
public enum StandardBluetoothBatteryProfile {
    public static func includes(name: String?) -> Bool { name?.lowercased() == "maxfit8" }
    public static func identity(_ uuid: UUID) -> String {
        "standard-bluetooth-" + SystemReportParser.opaqueIdentity(uuid.uuidString.lowercased())
    }
    public static func percent(_ bytes: Data) -> Int? {
        guard bytes.count == 1, let byte = bytes.first, byte <= 100 else { return nil }
        return Int(byte)
    }
}

public enum BluetoothBatteryAuthorization: Equatable { case authorized, notDetermined, denied, restricted }
public enum BluetoothBatteryAvailability: Equatable { case starting, poweredOn, poweredOff, unauthorized, unsupported, resetting, unknown }
public enum BluetoothBatteryCollectionState: Equatable { case idle, noKeyboard, reading, readReturned, unavailable, unresolved }
/// Read-only UI facts; diagnostics are never interpreted as presentation state.
public struct BluetoothBatteryPresentationState: Equatable {
    public let authorization: BluetoothBatteryAuthorization
    public let availability: BluetoothBatteryAvailability?
    public let collection: BluetoothBatteryCollectionState
    public let awaitingPermission: Bool
}
public struct BluetoothBatteryPeripheral {
    /// Retrieval evidence admits a candidate, never a battery value or device class.
    public enum Provenance: Equatable { case unverified, batteryServiceRetrieval }
    public let uuid: UUID
    public let name: String?
    public let provenance: Provenance
    public init(uuid: UUID, name: String?, provenance: Provenance = .unverified) {
        self.uuid = uuid; self.name = name; self.provenance = provenance
    }
}

/// The transport exposes only connected retrieval and the three standard read operations.
/// In particular there is no scan, subscription, serial, write, or disconnection operation.
public protocol StandardBluetoothBatteryTransport: AnyObject {
    var availability: BluetoothBatteryAvailability { get }
    func retrieveConnected() -> [BluetoothBatteryPeripheral]
    func connect(_ uuid: UUID)
    func discoverBatteryService(_ uuid: UUID)
    func discoverBatteryLevel(_ uuid: UUID)
    func readBatteryLevel(_ uuid: UUID)
}

public enum BluetoothBatteryTransportEvent {
    case availability(BluetoothBatteryAvailability)
    case connected(UUID)
    case connectionFailed(UUID, String)
    case services(UUID, count: Int, error: String?)
    case batteryLevels(UUID, count: Int, readable: Bool, error: String?)
    case value(UUID, Data?, error: String?)
    case disconnected(UUID)
}

public struct StandardBluetoothBatteryUpdate {
    public let observation: Observation?
    public let statusKey: String
    public let status: String
    public let context: DeviceCollectionContext
}

public protocol StandardBluetoothBatteryProviding: AnyObject {
    func refresh()
    func requestAccessFromUserAction()
    func stop()
}

/// A serialized polling state machine, independent of CoreBluetooth and testable without hardware.
/// The GUI adapter invokes every method and transport callback on the main queue.
public final class StandardBluetoothBatteryProvider: StandardBluetoothBatteryProviding {
    private enum Stage: String { case connecting, services, characteristics, read }
    private struct Attempt {
        var stage: Stage
        let context: DeviceCollectionContext
        let deadline: Date
        var quarantined = false
    }
    private struct Session {
        let uuid: UUID
        let name: String
        let legacy: Bool
        let kind: PhysicalDeviceKind
        var attempt: Attempt?
        var route: BatteryRouteMetadata {
            .init(type: .bluetooth, kind: kind, topology: legacy
                ? "Allowlisted standard Bluetooth BAS endpoint" : "Standard Bluetooth BAS endpoint")
        }
    }
    private let settings: DeviceSettingsStore
    private let authorization: () -> BluetoothBatteryAuthorization
    private let makeTransport: (@escaping (BluetoothBatteryTransportEvent) -> Void) -> StandardBluetoothBatteryTransport
    private let clock: BatteryClock
    private let timeout: TimeInterval
    private var transport: StandardBluetoothBatteryTransport?
    private var sessions: [UUID: Session] = [:]
    private var stopped = false
    private var pendingRefresh = false
    private var collectionResult: BluetoothBatteryCollectionState = .idle
    public var presentationDidChange: (() -> Void)?
    public var presentationState: BluetoothBatteryPresentationState {
        let access = authorization()
        let attempts = sessions.values.compactMap(\.attempt)
        let collection: BluetoothBatteryCollectionState
        if attempts.contains(where: { $0.quarantined }) { collection = .unresolved }
        else if !attempts.isEmpty { collection = .reading }
        else { collection = collectionResult }
        return BluetoothBatteryPresentationState(authorization: access, availability: transport?.availability,
            collection: collection, awaitingPermission: !stopped && pendingRefresh && transport != nil && access == .notDetermined)
    }
    public var completion: ((StandardBluetoothBatteryUpdate) -> Void)?

    public init(settings: DeviceSettingsStore, clock: BatteryClock = SystemBatteryClock(), timeout: TimeInterval = 15,
                authorization: @escaping () -> BluetoothBatteryAuthorization,
                makeTransport: @escaping (@escaping (BluetoothBatteryTransportEvent) -> Void) -> StandardBluetoothBatteryTransport) {
        self.settings = settings; self.clock = clock; self.timeout = timeout
        self.authorization = authorization; self.makeTransport = makeTransport
    }

    public func refresh() { refresh(explicitAccess: false) }
    public func requestAccessFromUserAction() { refresh(explicitAccess: true) }
    public func stop() { stopped = true; pendingRefresh = false }

    private func refresh(explicitAccess: Bool) {
        defer { presentationDidChange?() }
        guard !stopped else { return }
        expire()
        guard !settings.updatesBlocked else { status("Bluetooth battery updates paused: device settings unavailable"); return }
        switch authorization() {
        case .authorized: break
        case .notDetermined:
            guard explicitAccess else {
                status("Allow Bluetooth in Permissions.")
                return
            }
        case .denied:
            unavailable("Bluetooth access denied. Allow Cellio in System Settings > Privacy & Security > Bluetooth.")
            return
        case .restricted:
            unavailable("Bluetooth access is restricted on this Mac.")
            return
        }
        pendingRefresh = true
        if transport == nil {
            // The only creation path accepts an undetermined authorization after explicit action.
            transport = makeTransport { [weak self] event in self?.receive(event) }
        }
        guard let transport else { return }
        guard transport.availability == .poweredOn else {
            unavailable(availabilityDescription(transport.availability))
            return
        }
        guard authorization() == .authorized else { status("Waiting for native Bluetooth authorization"); return }
        pendingRefresh = false
        collect(using: transport)
    }

    private func collect(using transport: StandardBluetoothBatteryTransport) {
        let context = settings.context()
        var found: [BluetoothBatteryPeripheral] = []
        var indices: [UUID: Int] = [:]
        for peripheral in transport.retrieveConnected() where peripheral.provenance == .batteryServiceRetrieval
            || StandardBluetoothBatteryProfile.includes(name: peripheral.name) {
            if let index = indices[peripheral.uuid] {
                let previous = found[index]
                // Merge evidence by route UUID, preserving any literal legacy match.
                found[index] = BluetoothBatteryPeripheral(uuid: peripheral.uuid,
                    name: StandardBluetoothBatteryProfile.includes(name: previous.name) ? previous.name : peripheral.name,
                    provenance: previous.provenance == .batteryServiceRetrieval ? previous.provenance : peripheral.provenance)
            } else {
                indices[peripheral.uuid] = found.count
                found.append(peripheral)
            }
        }
        collectionResult = found.isEmpty ? .noKeyboard : .idle
        let ids = Set(found.map(\.uuid))
        for device in settings.rawDevices where device.source == .standardBluetooth && settings.accepts(device.id, from: context)
            && !ids.contains(where: { StandardBluetoothBatteryProfile.identity($0) == device.id }) {
            let session = sessions.values.first { StandardBluetoothBatteryProfile.identity($0.uuid) == device.id }
            failure(id: device.id, session: session, message: session?.legacy == true
                ? "No already-connected Maxfit8 keyboard was found" : "No compatible already-connected Bluetooth battery device was found",
                at: clock.now(), context: context, connection: .unavailable)
        }
        status(found.isEmpty ? "No compatible already-connected Bluetooth battery device found. Connect it in macOS Bluetooth settings, then refresh."
            : "Standard Bluetooth battery · sensor age unknown", context: context)
        for peripheral in found {
            let id = StandardBluetoothBatteryProfile.identity(peripheral.uuid)
            guard canCollect(id, context: context) else { continue }
            if let attempt = sessions[peripheral.uuid]?.attempt {
                if attempt.quarantined { status("Previous Bluetooth operation unresolved; waiting for its callback before retrying", key: id, context: context) }
                continue // No overlap, including after timeout or off/on policy changes.
            }
            let known = settings.rawDevices.first { $0.id == id && $0.source == .standardBluetooth }
            let legacy = StandardBluetoothBatteryProfile.includes(name: peripheral.name)
            // Only the legacy profile discovers before proof. A generic candidate stays
            // private to this attempt until a valid, attributed, policy-current read.
            if legacy {
                settings.discover(id: id, name: "Maxfit8", source: .standardBluetooth, componentIDs: ["battery"], kind: .keyboard)
            }
            guard canCollect(id, context: context) else { continue }
            let kind = legacy ? PhysicalDeviceKind.keyboard : known?.kind ?? .unknown
            sessions[peripheral.uuid] = Session(uuid: peripheral.uuid,
                name: legacy ? "Maxfit8" : safeName(peripheral.name), legacy: legacy, kind: kind,
                attempt: Attempt(stage: .connecting, context: context, deadline: clock.now().addingTimeInterval(timeout)))
            transport.connect(peripheral.uuid)
        }
    }

    private func safeName(_ name: String?) -> String {
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 256,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0)
                  || CharacterSet.illegalCharacters.contains($0) || CharacterSet(charactersIn: "\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}").contains($0) }) else {
            return "Bluetooth device"
        }
        return name
    }

    private func canCollect(_ id: String, context: DeviceCollectionContext) -> Bool {
        !stopped && authorization() == .authorized && transport?.availability == .poweredOn
            && settings.accepts(id, from: context)
    }

    /// A timer and every callback check the same deadline. An expired operation stays
    /// quarantined until its exact stage callback arrives; a refresh cannot relabel it.
    public func expire() {
        defer { presentationDidChange?() }
        guard !stopped else { return }
        let now = clock.now()
        for uuid in Array(sessions.keys) {
            guard let session = sessions[uuid], var attempt = session.attempt, !attempt.quarantined else { continue }
            let id = StandardBluetoothBatteryProfile.identity(uuid)
            let allowed = canCollect(id, context: attempt.context)
            guard !allowed || now >= attempt.deadline else { continue }
            attempt.quarantined = true; sessions[uuid]?.attempt = attempt
            if allowed {
                failure(id: id, session: session, message: "Bluetooth battery \(attempt.stage.rawValue) timed out; waiting for the outstanding callback", at: now, context: attempt.context)
            }
        }
    }

    public func receive(_ event: BluetoothBatteryTransportEvent) {
        defer { presentationDidChange?() }
        guard !stopped else { return }
        expire()
        switch event {
        case .availability(let availability):
            if availability == .poweredOn {
                if pendingRefresh, transport != nil { refresh() }
            } else {
                // Losing the radio does not resolve any in-flight operation. Keep its
                // quarantine across recovery so a delayed old Read cannot become fresh.
                unavailable(availabilityDescription(availability))
            }
        case .connected(let uuid):
            guard let attempt = take(uuid, stage: .connecting) else { return }
            advance(uuid, attempt: attempt, stage: .services)
            transport?.discoverBatteryService(uuid)
        case .connectionFailed(let uuid, let error):
            guard let attempt = take(uuid, stage: .connecting) else { return }
            fail(uuid, attempt: attempt, "Bluetooth connection failed: \(error)", connection: .unavailable)
        case .services(let uuid, let count, let error):
            guard let attempt = take(uuid, stage: .services) else { return }
            if let error { fail(uuid, attempt: attempt, "Battery Service discovery failed: \(error)"); return }
            guard count == 1 else {
                fail(uuid, attempt: attempt, count == 0 ? "Standard Battery Service (180F) unavailable" : "Ambiguous standard battery: multiple Battery Service instances")
                return
            }
            advance(uuid, attempt: attempt, stage: .characteristics)
            transport?.discoverBatteryLevel(uuid)
        case .batteryLevels(let uuid, let count, let readable, let error):
            guard let attempt = take(uuid, stage: .characteristics) else { return }
            if let error { fail(uuid, attempt: attempt, "Battery Level discovery failed: \(error)"); return }
            guard count == 1, readable else {
                fail(uuid, attempt: attempt, count > 1 ? "Ambiguous standard battery: multiple Battery Level characteristics" : "Readable standard Battery Level (2A19) unavailable")
                return
            }
            advance(uuid, attempt: attempt, stage: .read)
            transport?.readBatteryLevel(uuid)
        case .value(let uuid, let bytes, let error):
            guard let attempt = take(uuid, stage: .read) else { return }
            if let error { fail(uuid, attempt: attempt, "Battery Level read failed: \(error)"); return }
            guard let bytes, let percent = StandardBluetoothBatteryProfile.percent(bytes) else {
                fail(uuid, attempt: attempt, "Invalid Battery Level: expected exactly one byte in 0...100")
                return
            }
            let now = clock.now(), id = StandardBluetoothBatteryProfile.identity(uuid)
            guard let session = sessions[uuid], canCollect(id, context: attempt.context) else { return }
            settings.discover(id: id, name: session.name, source: .standardBluetooth, componentIDs: ["battery"], kind: session.kind)
            guard canCollect(id, context: attempt.context) else { return }
            collectionResult = .readReturned
            let observation = Observation(id: ComponentID(device: id), name: session.name, source: .standardBluetooth,
                connection: .connected, quantity: .reportedPercent(percent), charge: .unknown,
                observedAt: now, measuredAt: nil, sampleMeasuredAt: nil, collectedAt: now, route: session.route)
            completion?(StandardBluetoothBatteryUpdate(observation: observation, statusKey: id,
                status: "Standard Battery Level read · charging and sensor age unknown", context: attempt.context))
        case .disconnected(let uuid):
            guard let session = sessions[uuid] else { return }
            // A disconnect does not prove a queued read callback was drained.
            let context = session.attempt?.context ?? settings.context()
            if var attempt = session.attempt { attempt.quarantined = true; sessions[uuid]?.attempt = attempt }
            if canCollect(StandardBluetoothBatteryProfile.identity(uuid), context: context) {
                failure(id: StandardBluetoothBatteryProfile.identity(uuid), session: session,
                    message: session.legacy ? "Bluetooth keyboard connection unavailable" : "Bluetooth device connection unavailable",
                    at: clock.now(), context: context, connection: .unavailable)
            }
        }
    }

    /// Consume only the pending operation's callback. A quarantined/invalidated
    /// callback drains that operation without emitting or advancing to a new read.
    private func take(_ uuid: UUID, stage: Stage) -> Attempt? {
        guard let attempt = sessions[uuid]?.attempt, attempt.stage == stage else { return nil }
        sessions[uuid]?.attempt = nil
        guard !attempt.quarantined, canCollect(StandardBluetoothBatteryProfile.identity(uuid), context: attempt.context) else { return nil }
        return attempt
    }
    private func advance(_ uuid: UUID, attempt: Attempt, stage: Stage) {
        var next = attempt; next.stage = stage; sessions[uuid]?.attempt = next
    }
    private func fail(_ uuid: UUID, attempt: Attempt, _ message: String, connection: ConnectionState = .connected) {
        guard let session = sessions[uuid] else { return }
        failure(id: StandardBluetoothBatteryProfile.identity(uuid), session: session, message: message, at: clock.now(), context: attempt.context, connection: connection)
    }
    private func failure(id: String, session: Session?, message: String, at: Date, context: DeviceCollectionContext, connection: ConnectionState = .connected) {
        guard !stopped, settings.accepts(id, from: context) else { return }
        collectionResult = .unavailable
        let known = settings.rawDevices.first { $0.id == id && $0.source == .standardBluetooth }
        // Display names (including saved names) do not establish literal profile authority.
        let legacy = session?.legacy == true
        guard legacy || known != nil else {
            status(message, context: context) // No device row for a failed provisional candidate.
            return
        }
        let observation = Observation(id: ComponentID(device: id), name: legacy ? "Maxfit8" : known?.name ?? "Bluetooth device", source: .standardBluetooth,
            connection: connection, quantity: .unknown, collectedAt: at, error: message,
            route: session?.route ?? .init(type: .bluetooth, kind: known?.kind ?? .unknown,
                topology: "Standard Bluetooth BAS endpoint"))
        completion?(StandardBluetoothBatteryUpdate(observation: observation, statusKey: id, status: message, context: context))
    }
    private func quarantineAll() {
        for uuid in Array(sessions.keys) where sessions[uuid]?.attempt != nil { sessions[uuid]?.attempt?.quarantined = true }
    }
    private func unavailable(_ message: String) {
        quarantineAll()
        let context = settings.context()
        status(message, context: context)
        for device in settings.rawDevices where device.source == .standardBluetooth {
            let session = sessions.values.first { StandardBluetoothBatteryProfile.identity($0.uuid) == device.id }
            failure(id: device.id, session: session, message: message, at: clock.now(), context: context, connection: .unavailable)
        }
    }
    private func status(_ message: String, key: String = "standardBluetooth", context: DeviceCollectionContext? = nil) {
        guard !stopped else { return }
        completion?(StandardBluetoothBatteryUpdate(observation: nil, statusKey: key, status: message, context: context ?? settings.context()))
    }
    private func availabilityDescription(_ state: BluetoothBatteryAvailability) -> String {
        switch state {
        case .starting: return "Waiting for Bluetooth access and radio state"
        case .poweredOn: return "Bluetooth available"
        case .poweredOff: return "Bluetooth is powered off. Turn it on in macOS, then refresh."
        case .unauthorized: return "Bluetooth access unavailable. Check Privacy & Security > Bluetooth in System Settings."
        case .unsupported: return "Bluetooth Low Energy is unavailable on this Mac"
        case .resetting: return "Bluetooth is resetting; refresh when it is available"
        case .unknown: return "Bluetooth state is unknown; refresh when it is available"
        }
    }
}
