import Foundation
import CoreFoundation

/// The OS accessory cache supplies a quantity, not a sensor clock or a live link.
public enum AccessoryPowerParser {
    public static func parse(_ data: Data, collectedAt: Date) throws -> [Observation] {
        guard data.count <= 2 * 1024 * 1024 else { throw invalid("Stream exceeds 2 MiB") }
        var stream = XMLDocuments(bytes: Array(data))
        var observations: [Observation] = []
        var identities = Set<String>()
        var count = 0
        while let document = try stream.next() {
            count += 1
            guard count <= 256 else { throw invalid("Too many documents") }
            // Validate XML without resolving the standard Apple DTD (or any other resource).
            let validation = XMLValidation()
            let parser = XMLParser(data: document)
            parser.delegate = validation
            parser.shouldResolveExternalEntities = false
            parser.externalEntityResolvingPolicy = .never
            guard parser.parse(), !validation.invalid else { throw invalid("Malformed XML plist") }
            var format = PropertyListSerialization.PropertyListFormat.xml
            let value = try PropertyListSerialization.propertyList(from: document, options: [], format: &format)
            guard format == .xml, let record = value as? [String: Any] else { throw invalid("Expected XML plist dictionary") }
            guard record["Type"] as? String == "Accessory Source",
                  record["Transport Type"] as? String == "Bluetooth",
                  record["Accessory Category"] as? String == "Headset",
                  StrictJSON.integer(record["Vendor ID"]) == 148,
                  StrictJSON.integer(record["Product ID"]) == 4,
                  StrictJSON.integer(record["Vendor ID Source"]) == 1,
                  record["Part Identifier"] as? String == "Single" else { continue }
            guard let presence = record["Is Present"] as? NSNumber,
                  CFGetTypeID(presence) == CFBooleanGetTypeID() else { throw invalid("Invalid presence") }
            // Absence carries no battery claim. In particular it cannot invent a zero.
            guard presence.boolValue else { continue }
            guard let rawID = record["Accessory Identifier"] as? String,
                  let uuid = UUID(uuidString: rawID),
                  uuid.uuidString != "00000000-0000-0000-0000-000000000000",
                  let name = record["Name"] as? String,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  name.utf8.count <= 256, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  let capacity = StrictJSON.integer(record["Current Capacity"]), (0...100).contains(capacity),
                  StrictJSON.integer(record["Max Capacity"]) == 100 else { throw invalid("Invalid qualified accessory") }
            let id = "accessory-power-" + SystemReportParser.opaqueIdentity(uuid.uuidString.lowercased())
            guard identities.insert(id).inserted else { throw invalid("Duplicate accessory UUID") }
            observations.append(Observation(id: ComponentID(device: id), name: name, source: .systemReport,
                connection: .unknown, quantity: .reportedPercent(capacity), charge: .unknown,
                observedAt: nil, measuredAt: nil, sampleMeasuredAt: nil,
                collectedAt: collectedAt, route: .init(type: .bluetooth, kind: .headset,
                topology: "macOS OS-cached Bluetooth headset accessory power; live link and receiver mapping unproved")))
        }
        // Nothing escapes until every document, including the last one, has passed.
        return observations.sorted { $0.id.device < $1.id.device }
    }

    private static func invalid(_ message: String) -> ParseFailure { .invalid("Accessory power: " + message) }

    private final class XMLValidation: NSObject, XMLParserDelegate {
        var invalid = false
        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { invalid = true; parser.abortParsing() }
        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { invalid = true; parser.abortParsing() }
        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { invalid = true; parser.abortParsing(); return nil }
    }

    /// Frame separately serialized XML plists without mistaking quoted text, comments,
    /// or CDATA for document boundaries. XMLParser validates each complete frame.
    private struct XMLDocuments {
        let bytes: [UInt8]
        var offset = 0
        private func matches(_ text: String, at index: Int) -> Bool {
            let token = Array(text.utf8)
            return index + token.count <= bytes.count && bytes[index..<index + token.count].elementsEqual(token)
        }
        private func whitespace(_ byte: UInt8) -> Bool { byte == 32 || byte == 9 || byte == 10 || byte == 13 }
        private mutating func through(_ terminator: String) throws {
            while offset < bytes.count {
                if matches(terminator, at: offset) { offset += terminator.utf8.count; return }
                offset += 1
            }
            throw AccessoryPowerParser.invalid("Truncated XML")
        }
        mutating func next() throws -> Data? {
            while offset < bytes.count && whitespace(bytes[offset]) { offset += 1 }
            guard offset < bytes.count else { return nil }
            let start = offset
            if matches("\u{FEFF}", at: offset) { offset += 3 }
            var depth = 0
            var rooted = false
            while offset < bytes.count {
                if bytes[offset] != 60 {
                    guard rooted || whitespace(bytes[offset]) else { throw AccessoryPowerParser.invalid("Invalid framing") }
                    offset += 1; continue
                }
                if matches("<!--", at: offset) { offset += 4; try through("-->"); continue }
                if matches("<![CDATA[", at: offset) {
                    guard depth > 0 else { throw AccessoryPowerParser.invalid("CDATA outside plist") }
                    offset += 9; try through("]]>"); continue
                }
                if matches("<?", at: offset) { offset += 2; try through("?>"); continue }
                if matches("<!DOCTYPE", at: offset) {
                    guard !rooted else { throw AccessoryPowerParser.invalid("Misplaced DTD") }
                    offset += 9
                    var quote: UInt8?
                    var closed = false
                    while offset < bytes.count {
                        let byte = bytes[offset]; offset += 1
                        if let q = quote { if byte == q { quote = nil } }
                        else if byte == 34 || byte == 39 { quote = byte }
                        else if byte == 91 { throw AccessoryPowerParser.invalid("Internal DTD is unsupported") }
                        else if byte == 62 { closed = true; break }
                    }
                    guard closed else { throw AccessoryPowerParser.invalid("Truncated DTD") }
                    continue
                }
                guard !matches("<!", at: offset) else { throw AccessoryPowerParser.invalid("Unsupported declaration") }
                let closing = matches("</", at: offset)
                let tagStart = offset
                offset += closing ? 2 : 1
                if !rooted {
                    guard !closing, matches("plist", at: offset), offset + 5 < bytes.count,
                          whitespace(bytes[offset + 5]) || bytes[offset + 5] == 62 else { throw AccessoryPowerParser.invalid("Expected plist root") }
                }
                var quote: UInt8?
                var closed = false
                while offset < bytes.count {
                    let byte = bytes[offset]; offset += 1
                    if let q = quote { if byte == q { quote = nil } }
                    else if byte == 34 || byte == 39 { quote = byte }
                    else if byte == 62 { closed = true; break }
                }
                guard closed else { throw AccessoryPowerParser.invalid("Truncated tag") }
                let empty = offset > tagStart + 1 && bytes[offset - 2] == 47
                if closing { depth -= 1 }
                else { rooted = true; if !empty { depth += 1 } }
                guard depth >= 0, depth <= 128 else { throw AccessoryPowerParser.invalid("Invalid XML nesting") }
                if rooted && depth == 0 { return Data(bytes[start..<offset]) }
            }
            throw AccessoryPowerParser.invalid("Truncated document")
        }
    }
}
