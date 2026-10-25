import AppKit
import SwiftUI
import OpenBatteryCore

@MainActor final class AlertSettingsRoute: ObservableObject {
    enum Destination { case device(String), notifications }
    @Published private(set) var revision = 0
    private(set) var deviceID: String?
    private(set) var destination: Destination?
    func open(_ id: String) { deviceID = id; destination = .device(id); revision &+= 1 }
    func openNotifications() { deviceID = nil; destination = .notifications; revision &+= 1 }
}

/// String editing retains invalid input visibly. Only complete 1…99 integers commit.
struct AlertThresholdRow: View {
    let title: String
    let identifier: String
    let value: Int
    var enabled = true
    let commit: (Int) -> Void
    @State private var text = ""
    private var parsed: Int? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }), let n = Int(text), (1...99).contains(n) else { return nil }
        return n
    }
    var body: some View {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if enabled && parsed == nil {
                        Text("Enter an integer, 1–99.").font(.caption).foregroundStyle(.red)
                            .accessibilityIdentifier(identifier + ".error")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                TextField("1–99", text: $text).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                    .frame(width: 48).accessibilityLabel(title).accessibilityIdentifier(identifier + ".field")
                    .onChange(of: text) { _ in if let parsed, enabled, parsed != value { commit(parsed) } }
                Text("%").foregroundStyle(.secondary)
                Stepper(title, value: Binding(get: { value }, set: { text = String($0); commit($0) }), in: 1...99)
                    .labelsHidden().fixedSize().accessibilityLabel(title).accessibilityIdentifier(identifier + ".stepper")
            }.padding(.horizontal, 12).frame(height: 44).disabled(!enabled)
        .onAppear { text = String(value) }
        .onChange(of: value) { next in if parsed != next { text = String(next) } }
        .onChange(of: enabled) { _ in text = String(value) }
    }
}
