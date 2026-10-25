import Foundation

public protocol AlertPersistence {
    func load() throws -> Data?
    func save(_ data: Data) throws
}
public final class MemoryAlertPersistence: AlertPersistence {
    public var data: Data?
    public init(data: Data? = nil) { self.data = data }
    public func load() throws -> Data? { data }
    public func save(_ data: Data) throws { self.data = data }
}
public enum AlertStorageError: Error { case invalidDocument, saveFailed }
public struct DeviceAlertConfiguration: Codable, Equatable {
    public var included = true
    public var customThreshold = 20
    public var usesCustomThreshold = false
    public var components = ComponentSelection()
    public init() {}
    public var summary: String {
        components.mode == .all ? "All components" : KnownBatteryDevice.order(components.ids).map(KnownBatteryDevice.componentName).joined(separator: ", ")
    }
}
public struct AlertConfiguration: Codable, Equatable {
    public var enabled = false
    public var threshold = 20
    public var devices: [String: DeviceAlertConfiguration] = [:]
    public init() {}
    public func device(_ id: String) -> DeviceAlertConfiguration { devices[id] ?? .init() }
    public func threshold(for id: String) -> Int { let d = device(id); return d.usesCustomThreshold ? d.customThreshold : threshold }
}
public enum AlertAttemptState: String, Codable { case reserved, accepted, failed }
public struct AlertEpisode: Codable {
    public var id: ComponentID
    public var watermark: Date?
    public var latched = false
    public var requestID: String?
    public var attemptState: AlertAttemptState?
    public var attempts = 0
    public var attemptedAt: Date?
    public init(id: ComponentID) { self.id = id }
}
public struct AlertCandidate {
    public let id: ComponentID
    public let percent: Int
}
public struct AlertReservation {
    public let requestID: String
    public let deviceID: String
    public let title: String
    public let components: [AlertCandidate]
    public var body: String { components.map { "\(KnownBatteryDevice.componentName($0.id.component)): \($0.percent)%" }.joined(separator: " · ") }
}

/// Synchronous policy and durable reservation boundary. No OS, timers, or user stores.
/// A reserved attempt restored after a crash is ambiguous and is never retried.
public final class LowBatteryAlertPolicy {
    private struct VisibilityResume: Codable {
        var since: Date
        var components: [String]
    }
    private struct Document: Codable {
        var version = 1
        var configuration = AlertConfiguration()
        var episodes: [AlertEpisode] = []
        var visibilityResumes: [String: VisibilityResume]?
    }
    private let persistence: AlertPersistence
    private var document = Document()
    public private(set) var issue: String?
    public private(set) var corrupt = false
    public var configuration: AlertConfiguration { document.configuration }
    public var episodes: [AlertEpisode] { document.episodes }
    public var ownedRequestIDs: [String] { Array(Set(document.episodes.compactMap(\.requestID))) }
    public init(persistence: AlertPersistence = MemoryAlertPersistence()) {
        self.persistence = persistence
        reload()
    }
    private static func validID(_ id: String, max: Int = 512) -> Bool {
        !id.isEmpty && id.utf8.count <= max && !id.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    private static func valid(_ config: AlertConfiguration) -> Bool {
        (1...99).contains(config.threshold) && config.devices.count <= 1024 && config.devices.allSatisfy { id, d in
            validID(id) && (1...99).contains(d.customThreshold) && d.components.ids.count <= 64 &&
            Set(d.components.ids).count == d.components.ids.count && d.components.ids.allSatisfy { validID($0, max: 128) } &&
            (d.components.mode == .all ? d.components.ids.isEmpty : !d.components.ids.isEmpty)
        }
    }
    private func reload() {
        do {
            var next = Document()
            if let data = try persistence.load() {
                guard data.count <= 1_048_576,
                      let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      StrictJSON.integer(raw["version"]) == 1,
                      let config = raw["configuration"] as? [String: Any], StrictJSON.integer(config["threshold"]) != nil,
                      let devices = config["devices"] as? [String: Any],
                      devices.values.allSatisfy({ ($0 as? [String: Any]).flatMap { StrictJSON.integer($0["customThreshold"]) } != nil }),
                      let episodes = raw["episodes"] as? [[String: Any]],
                      episodes.allSatisfy({ StrictJSON.integer($0["attempts"]) != nil }) else { throw AlertStorageError.invalidDocument }
                next = try JSONDecoder().decode(Document.self, from: data)
                if let resumes=next.visibilityResumes {
                    guard resumes.count <= 8192, resumes.allSatisfy({ id, resume in
                        Self.validID(id) && resume.since.timeIntervalSince1970.isFinite && resume.components.count <= 64 && Set(resume.components).count == resume.components.count && resume.components.allSatisfy { Self.validID($0,max:128) }
                    }) else { throw AlertStorageError.invalidDocument }
                }
                guard Self.valid(next.configuration), next.episodes.count <= 8192,
                      Set(next.episodes.map(\.id)).count == next.episodes.count,
                      next.episodes.allSatisfy({ e in
                          Self.validID(e.id.device) && Self.validID(e.id.component, max: 128) && (0...3).contains(e.attempts) &&
                          (e.watermark?.timeIntervalSince1970.isFinite ?? true) && (e.attemptedAt?.timeIntervalSince1970.isFinite ?? true) &&
                          (e.latched ? (e.watermark != nil && e.attempts > 0 && e.requestID.flatMap(Self.requestUUID) != nil && e.attemptState != nil && e.attemptedAt != nil) : (e.attempts == 0 && e.requestID == nil && e.attemptState == nil && e.attemptedAt == nil))
                      }), Dictionary(grouping: next.episodes.filter(\.latched), by: { $0.requestID! }).values.allSatisfy({ group in
                          Set(group.map { $0.id.device }).count == 1 && Set(group.map(\.attempts)).count == 1 && Set(group.map(\.attemptState)).count == 1 && Set(group.map(\.attemptedAt)).count == 1
                      }) else { throw AlertStorageError.invalidDocument }
            }
            document = next; corrupt = false; issue = nil
        } catch { corrupt = true; issue = "Alert storage is unreadable. Delivery is blocked. Retry reading or explicitly reset alert storage. (\(error))" }
    }
    private static func requestUUID(_ id: String) -> UUID? {
        let prefix = "cellio.low-battery."
        return id.hasPrefix(prefix) ? UUID(uuidString: String(id.dropFirst(prefix.count))) : nil
    }
    @discardableResult private func persist() -> Bool {
        guard !corrupt else { return false }
        do {
            guard Self.valid(document.configuration), document.episodes.count <= 8192 else { throw AlertStorageError.invalidDocument }
            let data = try JSONEncoder().encode(document)
            guard data.count <= 1_048_576 else { throw AlertStorageError.invalidDocument }
            try persistence.save(data); issue = nil; return true
        } catch { issue = "Alert changes aren’t saved. Delivery is blocked until Retry succeeds. (\(error))"; return false }
    }
    public func retry() { if corrupt { reload() } else { _ = persist() } }
    /// Explicit reset replaces unreadable bytes; master returns off. Never called automatically.
    public func reset() { document = Document(); corrupt = false; _ = persist() }
    @discardableResult public func configure(_ config: AlertConfiguration) -> Bool {
        guard !corrupt, Self.valid(config) else { return false }
        document.configuration = config
        guard issue == nil else { return false }
        return persist()
    }
    public static func quantityTime(_ record: BatteryRecord) -> Date? {
        switch record.observation.source {
        case .watchCompanion, .systemReport: return record.observation.measuredAt
        default: return record.observation.observedAt
        }
    }
    /// Quantity validity is shared by recovery and sending. Charging is valid
    /// recovery evidence; alert scope and permission are deliberately absent.
    public static func recoveryIneligibility(_ record: BatteryRecord, monitoring: Bool, now: Date) -> String? {
        let o = record.observation
        guard monitoring else { return "Monitoring paused" }
        guard record.error == nil, o.error == nil, !o.charge.isError else { return "Reading error" }
        guard !record.retained else { return "Last known reading" }
        guard o.source == .watchCompanion ? (o.connection == .unknown || o.connection == .connected) : o.connection == .connected else { return "Device not connected" }
        guard case .reportedPercent(let value) = o.quantity, (0...100).contains(value) else { return "Reported percentage unavailable" }
        guard let time = quantityTime(record) else { return "Source age unknown" }
        guard time <= now, !record.isStale(at: now), now.timeIntervalSince(time) <= (o.source == .watchCompanion ? 900 : 120) else { return "Reading is old or source clock is ahead" }
        return nil
    }
    public static func ineligibility(_ record: BatteryRecord, monitoring: Bool, now: Date) -> String? {
        if let reason = recoveryIneligibility(record, monitoring: monitoring, now: now) { return reason }
        guard record.observation.charge == .unknown || record.observation.charge == .discharging else { return "Charging" }
        return nil
    }
    private func index(_ id: ComponentID) -> Int? {
        if let i = document.episodes.firstIndex(where: { $0.id == id }) { return i }
        guard document.episodes.count < 8192, Self.validID(id.device), Self.validID(id.component, max: 128) else {
            issue = "Alert bookkeeping is full or invalid. Delivery is blocked."; return nil
        }
        document.episodes.append(AlertEpisode(id: id)); return document.episodes.count - 1
    }
    /// Activation/setting/monitoring baselines consume displayed quantities, never reset episodes.
    public func baseline(_ records: [BatteryRecord], now: Date = Date()) {
        guard !corrupt else { return }
        for r in records {
            guard let t = Self.quantityTime(r), t.timeIntervalSince1970.isFinite, t <= now, let i = index(r.observation.id) else { continue }
            if document.episodes[i].watermark.map({ t > $0 }) ?? true { document.episodes[i].watermark = t }
        }
        if issue == nil { _ = persist() }
    }
    /// Process the latest accepted batch once. All dedup intent is saved before returning any work.
    public func process(records: [BatteryRecord], devices: [KnownBatteryDevice], authorized: Bool, now: Date, monitoringAllowed: Bool = true, configurationOverride: AlertConfiguration? = nil) -> [AlertReservation] {
        let configuration = configurationOverride ?? self.configuration
        guard !corrupt, issue == nil else { return [] }
        let catalog = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        var candidates: [String: [AlertCandidate]] = [:]
        var changed = false
        for r in records.sorted(by: { ($0.observation.id.device, $0.observation.id.component) < ($1.observation.id.device, $1.observation.id.component) }) {
            let id = r.observation.id
            guard let device = catalog[id.device],
                  let time = Self.quantityTime(r), time.timeIntervalSince1970.isFinite, time <= now, let i = index(id) else { continue }
            if let resume=document.visibilityResumes?[id.device], time <= resume.since { continue }
            guard document.episodes[i].watermark.map({ time > $0 }) ?? true else { continue }
            document.episodes[i].watermark = time; changed = true
            let config = configuration.device(id.device)
            guard Self.recoveryIneligibility(r, monitoring: monitoringAllowed && device.preferences.monitorBattery, now: now) == nil,
                  case .reportedPercent(let value) = r.observation.quantity else { continue }
            if var resume=document.visibilityResumes?[id.device], !resume.components.contains(id.component) {
                guard resume.components.count < 64 else { issue="Alert bookkeeping is full. Delivery is blocked."; continue }
                resume.components.append(id.component); document.visibilityResumes?[id.device]=resume
                // First newly eligible quantity establishes a baseline, including a high value.
                // Preserve the old low latch until a subsequent genuinely newer recovery.
                continue
            }
            let threshold = configuration.threshold(for: id.device)
            if value >= min(100, threshold + 5) {
                if document.episodes[i].latched {
                    document.episodes[i] = AlertEpisode(id: id); document.episodes[i].watermark = time
                }
                continue
            }
            guard configuration.enabled, authorized, config.included, config.components.includes(id.component),
                  Self.ineligibility(r, monitoring: true, now: now) == nil else { continue }
            guard value <= threshold else { continue }
            let e = document.episodes[i]
            if !e.latched || (e.attemptState == .failed && e.attempts < 3 && e.attemptedAt.map { now.timeIntervalSince($0) >= 60 } == true) {
                candidates[id.device, default: []].append(AlertCandidate(id: id, percent: value))
            }
        }
        // Keep consumed quantities and recovery, but undo tentative attempts if
        // their save fails: no work has escaped to the OS in this process.
        let unreservedEpisodes = document.episodes
        var work: [AlertReservation] = []
        for device in candidates.keys.sorted() {
            let values = candidates[device]!
            // Retry an owned coalesced request only when every still-latched member has
            // a new qualifying low in this batch. An incomplete retry group must
            // not prevent newly low components from receiving their first attempt.
            let groups = Dictionary(grouping: values, by: { c in document.episodes.first { $0.id == c.id }?.requestID ?? "new" })
            let retry = groups.keys.sorted().first { key in
                key != "new" && Set(document.episodes.filter { $0.latched && $0.requestID == key }.map(\.id))
                    .isSubset(of: Set(groups[key]!.map(\.id)))
            }
            let selectedKey = retry ?? (groups["new"] == nil ? nil : "new")
            if let key = selectedKey {
                let group = groups[key]! + (key == "new" ? [] : (groups["new"] ?? []))
                let request = key == "new" ? "cellio.low-battery." + UUID().uuidString : key
                let attempt = group.compactMap { c in document.episodes.first { $0.id == c.id }?.attempts }.max()! + 1
                for c in group {
                    let i = document.episodes.firstIndex { $0.id == c.id }!
                    document.episodes[i].latched = true; document.episodes[i].requestID = request
                    document.episodes[i].attemptState = .reserved; document.episodes[i].attempts = attempt; document.episodes[i].attemptedAt = now
                }
                work.append(AlertReservation(requestID: request, deviceID: device, title: catalog[device]?.name ?? "Accessory", components: group))
            }
        }
        guard issue == nil else { document.episodes = unreservedEpisodes; return [] }
        if changed || !work.isEmpty {
            guard persist() else { document.episodes = unreservedEpisodes; return [] }
        }
        return work
    }
    /// Structural migration consumes old quantities, preserves all suppression, and never rearms from an alternate route.
    /// Save this before exposing new membership. A failed migration blocks delivery through the existing issue boundary.
    @discardableResult public func migrateConnections(sources: [String], targets: [String], records: [BatteryRecord], now: Date) -> Bool {
        guard !corrupt, issue == nil else { return false }
        let ids=Set(sources+targets)
        if let since=sources.compactMap({ document.visibilityResumes?[$0]?.since }).max() {
            var resumes=document.visibilityResumes ?? [:]
            // A new logical identity must not escape the first-new-quantity baseline after Restore.
            // Keep existing identities' consumed components and resume clocks unchanged.
            for target in targets where resumes[target] == nil {
                resumes[target]=VisibilityResume(since:since,components:[])
            }
            guard resumes.count <= 8192 else { issue="Alert bookkeeping is full. Delivery is blocked."; return false }
            document.visibilityResumes=resumes
        }
        let relevant=document.episodes.filter { ids.contains($0.id.device) }
        let raw=records.filter { ids.contains($0.observation.id.device) }
        let components=Set(relevant.map { $0.id.component }).union(raw.map { $0.observation.id.component })
        for component in components {
            let old=relevant.filter { $0.id.component == component }
            let times=old.compactMap(\.watermark)+raw.filter { $0.observation.id.component == component }.compactMap(Self.quantityTime).filter { $0 <= now && $0.timeIntervalSince1970.isFinite }
            let watermark=times.max()
            let latched=old.filter(\.latched)
            for device in ids.sorted() {
                let id=ComponentID(device:device,component:component)
                guard let i=index(id) else { return false }
                var episode=AlertEpisode(id:id); episode.watermark=watermark
                if !latched.isEmpty, watermark != nil {
                    episode.latched=true; episode.requestID="cellio.low-battery."+UUID().uuidString
                    // An in-flight or failed pre-structure attempt is ambiguous; structural change cannot retry it.
                    episode.attemptState = .accepted; episode.attempts=max(1,latched.map(\.attempts).max() ?? 1)
                    episode.attemptedAt=latched.compactMap(\.attemptedAt).max() ?? now
                }
                document.episodes[i]=episode
            }
        }
        return persist()
    }
    /// Revoke ambiguous delivery without resetting episodes or replaying a canceled attempt.
    /// Persist the per-component resumed baseline so a relaunch cannot replay retained lows.
    @discardableResult public func transitionVisibility(ids: [String], records: [BatteryRecord], restoring: Bool, now: Date) -> Bool {
        guard !corrupt, issue == nil else { return false }
        let affected=Set(ids)
        guard affected.count <= 8192, affected.allSatisfy({ Self.validID($0) }) else { return false }
        if restoring {
            var resumes=document.visibilityResumes ?? [:]
            for id in affected { resumes[id]=VisibilityResume(since:now,components:[]) }
            guard resumes.count <= 8192 else { return false }
            document.visibilityResumes=resumes
        }
        for record in records where affected.contains(record.observation.id.device) {
            guard let time=Self.quantityTime(record), time.timeIntervalSince1970.isFinite, time <= now, let i=index(record.observation.id) else { continue }
            if document.episodes[i].watermark.map({ time > $0 }) ?? true { document.episodes[i].watermark=time }
        }
        for i in document.episodes.indices where affected.contains(document.episodes[i].id.device) && document.episodes[i].latched {
            // A revoked add/HUD completion cannot become retryable on a failed visibility save.
            document.episodes[i].attemptState = .accepted
        }
        return persist()
    }
    /// Keep hidden route aliases aligned with genuine logical recovery, so an obsolete raw latch cannot return on fallback.
    public func mirrorConnectionEpisodes(from logical: String, to routes: [String]) {
        guard !corrupt, issue == nil else { return }
        let episodes=document.episodes.filter { $0.id.device == logical }
        var changed=false
        for episode in episodes {
            for route in routes where route != logical {
                let id=ComponentID(device:route,component:episode.id.component)
                guard let i=index(id), (document.episodes[i].watermark ?? .distantPast) <= (episode.watermark ?? .distantPast) else { continue }
                let old=document.episodes[i]
                guard old.watermark != episode.watermark || old.latched != episode.latched || (old.latched && old.attemptState != .accepted) else { continue }
                var copy=episode; copy.id=id
                if copy.latched { copy.requestID="cellio.low-battery."+UUID().uuidString; copy.attemptState = .accepted }
                document.episodes[i]=copy; changed=true
            }
        }
        if changed { _ = persist() }
    }
    public func complete(requestID: String, accepted: Bool) {
        guard !corrupt else { return }
        var changed = false
        for i in document.episodes.indices where document.episodes[i].requestID == requestID && document.episodes[i].attemptState == .reserved {
            document.episodes[i].attemptState = accepted ? .accepted : .failed
            changed = true
        }
        if changed && issue == nil { _ = persist() }
    }
}
