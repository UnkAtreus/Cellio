import SwiftUI
import AppKit
import OpenBatteryCore

@MainActor extension AppModel {
    func installStandardBluetoothBatteryProvider() {
        guard bluetoothBattery == nil else { return }
        let provider = NativeStandardBluetoothBatteryProvider(settings: deviceSettings)
        provider.polling.completion = { [weak self] update in
            // The native transport delivers on the main queue; retain the attempt's policy fence.
            self?.receive(ProviderBatch(observations: update.observation.map { [$0] } ?? [],
                status: [update.statusKey: update.status], devicePolicyContext: update.context), context: update.context)
        }
        provider.polling.presentationDidChange = { [weak self, weak polling = provider.polling] in
            guard let self, let state = polling?.presentationState, self.bluetoothPresentation != state else { return }
            self.bluetoothPresentation = state
        }
        bluetoothBattery = provider
        provider.refresh()
    }
}

/// Devices-only assistance, derived from authorization/radio/collection facts.
@MainActor private struct KeyboardSetupPresentation {
    var caption = ""
    init(model: AppModel) {
        guard let state = model.bluetoothPresentation else { return }
        switch state.authorization {
        case .notDetermined, .denied: caption = "Allow Bluetooth in Permissions."; return
        case .restricted: caption = "Bluetooth access is restricted on this Mac."; return
        case .authorized: break
        }
        switch state.availability {
        case .poweredOff:
            caption = "Bluetooth is off. Turn it on in System Settings → Bluetooth, then refresh."
            return
        case .starting, .resetting:
            caption = "Waiting for Bluetooth…"
            return
        case .poweredOn: break
        case .unauthorized, .unsupported, .unknown, nil:
            caption = "Bluetooth battery readings are unavailable on this Mac."
            return
        }
        // A real row owns reading, retained, paused and error presentation.
        guard !model.knownDevices.contains(where: { $0.source == .standardBluetooth }) else { return }
        switch state.collection {
        case .reading: caption = "Reading Bluetooth batteries…"
        case .noKeyboard: caption = "No compatible connected Bluetooth battery found. Connect your device in macOS Bluetooth settings, then refresh."
        case .unavailable: caption = "Bluetooth battery unavailable. Refresh to try again."
        case .unresolved: caption = "A Bluetooth battery read is still pending. Try again after it finishes."
        case .idle, .readReturned: break
        }
    }
}

struct BluetoothKeyboardConnection: View {
    var openPermissions: () -> Void
    @ObservedObject var focusTransfer: PermissionFocusTransfer
    var body: some View {
        HStack {
            PermissionNativeButton(title: "Permissions…", id: "cellio.bluetooth.connectKeyboard",
                focusTransfer: focusTransfer, label: "Open Permissions settings", action: openPermissions)
                .fixedSize()
                .help("Review Bluetooth access in Permissions.")
            Spacer(minLength: 0)
        }.frame(width: 200, height: 24)
    }
}

struct BluetoothKeyboardAssistance: View {
    @ObservedObject var model: AppModel
    var body: some View {
        let presentation = KeyboardSetupPresentation(model: model)
        if !presentation.caption.isEmpty {
            Text(presentation.caption)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 32, alignment: .topLeading)
                .accessibilityIdentifier("cellio.bluetooth.status")
                .onChange(of: presentation.caption) { caption in
                    guard NSWorkspace.shared.isVoiceOverEnabled, !caption.isEmpty else { return }
                    NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                        userInfo: [.announcement: caption, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
                }
        }
    }
}
