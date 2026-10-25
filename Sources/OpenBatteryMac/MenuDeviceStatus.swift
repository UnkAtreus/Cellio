import Foundation
import OpenBatteryCore

/// A deterministic projection of already selected components. Never consults a
/// store, collection clock, or UI; collecting again cannot refresh sensor age.
struct MenuDeviceStatus: Equatable {
    enum Tone: Equatable { case neutral, caution, current, error }
    let tone: Tone
    let label: String
    let help: String
    let summary: String

    init(tone: Tone, label: String, help: String, summary: String? = nil) {
        self.tone = tone
        self.label = label
        self.help = help
        self.summary = summary ?? label
    }

    static func evaluate(_ device: BatteryMenuDevicePresentation,
                         monitoring: Bool, updatesBlocked: Bool, at now: Date) -> Self {
        let readings = device.components.compactMap(\.reading)
        let known = readings.filter { $0.record.observation.quantity.isKnown }
        let paused = !monitoring || updatesBlocked
        let readError = readings.contains { $0.record.error != nil || $0.record.observation.error != nil }
        let chargeError = readings.contains { $0.record.observation.charge.isError }
        let tone: Tone
        let label: String
        if readError || chargeError {
            tone = .error; label = readError ? "Read error" : "Battery error"
        } else if known.isEmpty {
            tone = .neutral; label = paused ? "Paused" : "No reading"
        } else if paused {
            tone = .caution; label = "Paused"
        } else if known.contains(where: {
            let record = $0.record
            return record.retained || record.observation.connection != .connected
                || record.isStale(at: now) || authoritativeDate(record) == nil
        }) {
            tone = .caution; label = "Last known"
        } else if known.count != device.components.count {
            tone = .caution; label = "Partial"
        } else {
            tone = .current; label = "Current"
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func timestamp(_ date: Date?) -> String { date.map { formatter.string(from: $0) } ?? "unknown" }
        var details = [device.name, "Device ID: \(device.id)", "Status: \(label)",
                       "Snapshot: \(timestamp(now))",
                       updatesBlocked ? "Settings unavailable; updates blocked" : (monitoring ? "Monitoring on" : "Monitoring off")]
        if paused && (readError || chargeError) { details.append("Last recorded error; updates paused") }
        if paused { details.append(known.isEmpty ? "No retained reading" : "Last reading; original source ages preserved") }
        if device.components.isEmpty { details.append("No selected component reading") }
        for component in device.components {
            guard let reading = component.reading else {
                details.append("\(component.title) battery: Not reported; connection unknown; source age unknown; charge state unknown")
                continue
            }
            let record = reading.record
            let observation = record.observation
            var parts = ["\(component.id == "battery" ? "Battery" : component.title+" battery"): \(reading.value)", reading.connection,
                         "Source: \(observation.source.rawValue)", reading.charge,
                         record.ageDescription(at: now),
                         "Measurement: \(timestamp(observation.measuredAt))",
                         "Observation: \(timestamp(observation.observedAt))",
                         "Original sample measurement: \(timestamp(observation.sampleMeasuredAt))",
                         "Collected: \(timestamp(observation.collectedAt))",
                         "Last attempt: \(timestamp(record.lastAttempt))",
                         "Retention: \(record.retained ? "retained" : "not retained")"]
            switch observation.quantity {
            case .reportedPercent(let value): parts.append("Precision: reported percent; original value: \(value)%")
            case .estimatedPercent(let value, _): parts.append("Precision: estimated percent; original value: \(value)%")
            case .coarse(let name, let level):
                parts.append("Precision: coarse; original name: \(name); original level: \(level.map(String.init) ?? "unknown")")
            case .unknown: parts.append("Precision: unknown")
            case .absent: parts.append("Precision: not reported")
            }
            if let date = authoritativeDate(record) {
                parts.append("Authoritative source age: \(String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), max(0, now.timeIntervalSince(date)))) seconds")
            }
            if authoritativeDate(record) == nil { parts.append("Authoritative source age unknown; unknown age alone does not establish staleness") }
            parts.append(record.isStale(at: now) ? "Stale by existing source policy" : "Not stale by existing source policy")
            if let error = record.error { parts.append("Record error (last attempt \(timestamp(record.lastAttempt))): \(error)") }
            if let error = observation.error { parts.append("Observation error (collected \(timestamp(observation.collectedAt))): \(error)") }
            if observation.charge.isError { parts.append("Battery error: \(reading.charge) (\(observation.charge.rawValue)); recorded \(timestamp(observation.collectedAt))") }
            details.append(parts.joined(separator: "; "))
        }
        return Self(tone: tone, label: label, help: details.joined(separator: "\n"),
                    summary: conciseSummary(device, monitoring: monitoring, updatesBlocked: updatesBlocked, at: now))
    }

    /// Only the selected records participate. Collection attempts never date a reading.
    private static func conciseSummary(_ device: BatteryMenuDevicePresentation,
                                       monitoring: Bool, updatesBlocked: Bool, at now: Date) -> String {
        let records = device.components.compactMap { $0.reading?.record }
        let known = records.filter { $0.observation.quantity.isKnown }
        let readError = records.contains { $0.error != nil || $0.observation.error != nil }
        let charges = records.map { $0.observation.charge }
        let hasError = readError || charges.contains(where: \.isError)
        let paused = !monitoring || updatesBlocked
        let missing = known.count < device.components.count
        let ages = known.compactMap { record -> TimeInterval? in
            guard let date = authoritativeDate(record) else { return nil }
            let age = now.timeIntervalSince(date)
            return age.isFinite && age >= 0 ? age : nil
        }
        let ageUnknown = !known.isEmpty && ages.count != known.count
        let age: String
        if known.isEmpty { age = "No reading" }
        else if ageUnknown { age = "Reading age unknown" }
        else {
            let seconds = ages.max() ?? 0
            let elapsed: String
            if seconds < 60 { elapsed = "under 1m" }
            else if seconds < 3600 { elapsed = "\(Int(seconds / 60))m" }
            else if seconds < 86400 { elapsed = "\(Int(seconds / 3600))h" }
            else { elapsed = String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), floor(seconds / 86400)) + "d" }
            age = "\(known.count > 1 ? "Oldest reading" : "Reading") \(elapsed) ago"
        }
        // A deliberate line boundary keeps both clauses readable at native 11pt.
        func summary(_ reason: String, _ qualifier: String? = nil) -> String {
            qualifier.map { reason + "\n" + $0 } ?? reason
        }
        if hasError {
            if paused { return summary("Last recorded error", "Updates paused") }
            let reason: String
            if readError { reason = "Couldn't read battery" }
            else if charges.contains(.invalidBattery) { reason = "Battery error" }
            else if charges.contains(.thermalError) { reason = "Battery temperature error" }
            else { reason = "Charging error" }
            return summary(reason, known.isEmpty ? nil : age)
        }
        if updatesBlocked { return summary("Updates paused", "Settings unavailable") }
        if !monitoring { return summary("Monitoring paused", age) }
        let disconnected = records.filter { $0.observation.connection == .disconnected }.count
        if disconnected > 0 {
            return summary(disconnected == device.components.count ? "Disconnected" : "Some parts disconnected", age)
        }
        if known.contains(where: { $0.retained || $0.isStale(at: now) }) {
            return summary("Last known", age)
        }
        if ageUnknown { return summary("Reading age unknown", missing ? "Some parts not reported" : nil) }
        if known.isEmpty { return "No reading available" }
        if missing { return summary("Some parts not reported", age) }
        // Preserve the existing usable/current-source rule, including connection.
        if known.contains(where: { $0.observation.connection != .connected }) {
            return summary("Last known", age)
        }
        return summary("Current", age)
    }

    private static func authoritativeDate(_ record: BatteryRecord) -> Date? {
        switch record.observation.source {
        case .systemReport, .watchCompanion: return record.observation.measuredAt
        default: return record.observation.observedAt
        }
    }
}
