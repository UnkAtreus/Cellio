import Foundation

// Compile-only notification boundary. Tests exercise settings navigation only.
enum AlertNotificationState { case notDetermined, denied, authorized, alertsDisabled, limited, unknown, unavailable }
@MainActor protocol AlertNotificationBoundary {
    func inspect(_ completion: @escaping @MainActor (AlertNotificationState) -> Void)
    func requestAuthorization(completion: @escaping @MainActor (Bool) -> Void)
}

@MainActor final class FakeNotifications: AlertNotificationBoundary {
    func inspect(_ completion: @escaping @MainActor (AlertNotificationState) -> Void) { completion(.unknown) }
    func requestAuthorization(completion: @escaping @MainActor (Bool) -> Void) { completion(false) }
}
@MainActor final class FakeWorkspace: NativeSettingsWorkspace {
    var app: URL? = URL(fileURLWithPath: "/Applications/System Settings.app")
    var targets: [URL] = []; var genericOpens = 0
    var targetCallbacks: [@MainActor (Bool, Error?) -> Void] = []
    var genericCallbacks: [@MainActor (Bool) -> Void] = []
    func settingsApplicationURL() -> URL? { app }
    func openTarget(_ url: URL, application: URL, completion: @escaping @MainActor (Bool, Error?) -> Void) { targets.append(url); targetCallbacks.append(completion) }
    func openApplication(_ url: URL, completion: @escaping @MainActor (Bool) -> Void) { genericOpens += 1; genericCallbacks.append(completion) }
    func finishTarget(_ index: Int = 0, accepted: Bool = true, error: Error? = nil) { targetCallbacks[index](accepted, error) }
}
