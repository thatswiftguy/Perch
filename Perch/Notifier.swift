import Foundation
import UserNotifications

/// Native notifications for the two transitions worth interrupting the user for:
/// a session became blocked, or a session finished.
@MainActor
final class Notifier {
    private(set) var isAuthorized = false
    private(set) var authorizationError: String?

    private let preferences: Preferences

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    func requestAuthorization() {
        // UNUserNotificationCenter traps rather than returning an error when the running
        // binary isn't a signed bundle, so guard on that before touching it at all.
        guard Bundle.main.bundleIdentifier != nil else {
            authorizationError = "Run Perch from the built .app bundle, not the raw binary."
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
            [weak self] granted, error in
            Task { @MainActor in
                self?.isAuthorized = granted
                self?.authorizationError = error?.localizedDescription
                if let error {
                    Log.write("notification authorization failed: \(error.localizedDescription)")
                } else {
                    Log.debug("notification authorization granted=\(granted)")
                }
            }
        }
    }

    func needsInput(session: String, reason: String) {
        guard preferences.notifyOnNeedsInput else { return }
        post(title: "\(session) needs you", body: reason, sound: true)
    }

    func finished(session: String, message: String?, backgroundTasks: Int) {
        guard preferences.notifyOnFinish else { return }
        var body = message.map(Self.firstLine) ?? "Turn complete."
        if backgroundTasks > 0 {
            body += "  (\(backgroundTasks) background task\(backgroundTasks == 1 ? "" : "s") still running)"
        }
        post(title: "\(session) finished", body: body, sound: false)
    }

    private func post(title: String, body: String, sound: Bool) {
        guard isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        ) { error in
            // A silent failure here means the user stops being told their sessions need
            // them, which is the app's whole job — so it never fails quietly.
            if let error {
                Log.write("notification failed: \(error.localizedDescription)")
            } else {
                Log.debug("notified: \(title) — \(body)")
            }
        }
    }

    private static func firstLine(_ s: String) -> String {
        let line = s.split(separator: "\n").first.map(String.init) ?? s
        return line.count > 140 ? String(line.prefix(140)) + "…" : line
    }
}
