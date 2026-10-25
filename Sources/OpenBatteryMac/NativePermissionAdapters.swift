import Foundation
import AppKit
import CoreBluetooth
import IOKit.hidsystem

/// Injectable public workspace boundary; no destination observation is inferred.
@MainActor protocol NativeSettingsWorkspace {
    func settingsApplicationURL() -> URL?
    func openTarget(_ url: URL, application: URL, completion: @escaping @MainActor (Bool, Error?) -> Void)
    func openApplication(_ url: URL, completion: @escaping @MainActor (Bool) -> Void)
}
@MainActor struct MacSettingsWorkspace: NativeSettingsWorkspace {
    func settingsApplicationURL() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences")
    }
    func openTarget(_ url: URL, application: URL, completion: @escaping @MainActor (Bool, Error?) -> Void) {
        NSWorkspace.shared.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { app, error in
            Task { @MainActor in completion(app != nil && error == nil, error) }
        }
    }
    func openApplication(_ url: URL, completion: @escaping @MainActor (Bool) -> Void) {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { app, error in
            Task { @MainActor in completion(app != nil && error == nil) }
        }
    }
}
extension NativeSettingsDestination {
    var compatibilityURL: URL {
        let route: String
        switch self {
        case .inputMonitoring: route = "com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent"
        case .notifications: route = "com.apple.Notifications-Settings.extension"
        case .bluetoothPrivacy: route = "com.apple.settings.PrivacySecurity.extension?Privacy_Bluetooth"
        case .bluetoothRadio: route = "com.apple.BluetoothSettings"
        }
        return URL(string: "x-apple.systempreferences:" + route)!
    }
}

/// Native boundary only. No device catalog, scanning, pairing, connection or read.
@MainActor final class MacNativePermissionAdapter: NSObject, NativePermissionAdapter, CBCentralManagerDelegate {
    private let notifications: AlertNotificationBoundary
    private let gate: NativePermissionRequestGate
    private let workspace: NativeSettingsWorkspace
    private let majorVersion: () -> Int
    private var central: CBCentralManager?
    private var bluetoothCompletion: (@MainActor (Bool) -> Void)?
    init(notifications: AlertNotificationBoundary, gate: NativePermissionRequestGate,
         workspace: NativeSettingsWorkspace? = nil,
         majorVersion: @escaping () -> Int = { ProcessInfo.processInfo.operatingSystemVersion.majorVersion }) {
        self.notifications = notifications; self.gate = gate
        self.workspace = workspace ?? MacSettingsWorkspace(); self.majorVersion = majorVersion
        super.init()
    }
    private var bluetoothAccess: NativeAccess {
        switch CBManager.authorization {
        case .notDetermined: return .notDetermined
        case .allowedAlways: return .allowed
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .unavailable
        }
    }
    private var inputAccess: NativeAccess {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .allowed
        case kIOHIDAccessTypeDenied: return .denied
        case kIOHIDAccessTypeUnknown: return .notDetermined
        default: return .unavailable
        }
    }
    private func makeCentral() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main,
                                       options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
    }
    func inspect(_ kind: NativePermissionKind, completion: @escaping @MainActor (NativePermissionFact?) -> Void) {
        switch kind {
        case .bluetooth:
            let access = bluetoothAccess
            // Undetermined inspection never constructs a manager.
            if access == .allowed { makeCentral() }
            let radio: NativeBluetoothRadio?
            switch central?.state {
            case .poweredOn: radio = .poweredOn
            case .poweredOff: radio = .poweredOff
            case .resetting: radio = .resetting
            case .unknown, nil: radio = access == .allowed ? .starting : nil
            default: radio = .unavailable
            }
            completion(.init(access: access, radio: radio))
        case .inputMonitoring: completion(.init(access: inputAccess))
        case .notifications:
            notifications.inspect { result in
                let access: NativeAccess
                switch result {
                case .notDetermined: access = .notDetermined
                case .denied: access = .denied
                case .authorized: access = .allowed
                case .alertsDisabled: access = .alertsOff
                case .limited: access = .limited
                case .unknown, .unavailable: access = .unavailable
                }
                completion(.init(access: access))
            }
        }
    }
    func request(_ kind: NativePermissionKind, completion: @escaping @MainActor () -> Void) {
        switch kind {
        case .bluetooth:
            gate.perform(kind, fallback: false, start: { done in
                guard bluetoothAccess == .notDetermined else { done(true); return }
                bluetoothCompletion = done
                makeCentral()
            }, completion: { _ in completion() })
        case .inputMonitoring:
            gate.perform(kind, fallback: false, start: { done in
                guard inputAccess == .notDetermined else { done(true); return }
                // Ignore the request's Boolean: only IOHIDCheckAccess proves access.
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
                    Task { @MainActor in done(true) }
                }
            }, completion: { _ in completion() })
        case .notifications:
            // The same boundary/gate serves explicit alert enable and Preview.
            notifications.requestAuthorization { [weak self] _ in
                self?.notificationAccessDidChange?()
                completion()
            }
        }
    }
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor [weak self] in self?.receiveBluetoothState() }
    }
    private func receiveBluetoothState() {
        if bluetoothAccess != .notDetermined {
            let done = bluetoothCompletion; bluetoothCompletion = nil; done?(true)
        }
        changed?()
    }
    // Radio delegate changes trigger a passive check in the retained controller.
    var changed: (() -> Void)?
    var notificationAccessDidChange: (() -> Void)?
    func openSettings(completion: @escaping @MainActor (Bool) -> Void) {
        guard let application = workspace.settingsApplicationURL() else { completion(false); return }
        workspace.openApplication(application, completion: completion)
    }
    func openSettings(_ destination: NativeSettingsDestination, isCurrent: @escaping @MainActor () -> Bool,
                      completion: @escaping @MainActor (Bool) -> Void) {
        guard isCurrent() else { return }
        guard let application = workspace.settingsApplicationURL() else { completion(false); return }
        let openGeneric: @MainActor () -> Void = { [workspace] in
            // The controller owns the single timeout and all invalidation.
            guard isCurrent() else { return }
            workspace.openApplication(application, completion: completion)
        }
        let major = majorVersion()
        guard major == 26 || major == 27 else { openGeneric(); return }
        guard isCurrent() else { return }
        var receivedTargetCompletion = false
        workspace.openTarget(destination.compatibilityURL, application: application) { accepted, error in
            guard !receivedTargetCompletion, isCurrent() else { return }
            receivedTargetCompletion = true
            if error != nil { openGeneric() }
            else { completion(accepted) }
        }
    }
}
