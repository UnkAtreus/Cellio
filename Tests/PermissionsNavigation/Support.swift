import Foundation

// Compile-only notification boundary. Tests exercise settings navigation only.
enum AlertNotificationState { case notDetermined, denied, authorized, alertsDisabled, limited, unknown, unavailable }
@MainActor protocol AlertNotificationBoundary {
    func inspect(_ completion: @escaping @MainActor (AlertNotificationState) -> Void)
    func requestAuthorization(completion: @escaping @MainActor (Bool) -> Void)
}
