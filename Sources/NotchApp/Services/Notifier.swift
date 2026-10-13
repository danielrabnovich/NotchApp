import AppKit
import UserNotifications

/// macOS notification banners, used when background work finishes.
@MainActor
enum Notifier {
    private static let delegate = Delegate()
    private static var configured = false

    static func configure() {
        guard !configured, Bundle.main.bundleIdentifier != nil else { return }
        configured = true
        UNUserNotificationCenter.current().delegate = delegate
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String, jobID: UUID? = nil) {
        guard AppSettings.shared.systemNotifications else { return }
        configure()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let jobID { content.userInfo = ["job": jobID.uuidString] }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Debug: a notification with a text reply, as Messages and WhatsApp post them.
    static func debugReplyBanner(from sender: String) {
        configure()
        let reply = UNTextInputNotificationAction(identifier: "reply", title: "Reply", options: [], textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        UNUserNotificationCenter.current().setNotificationCategories([UNNotificationCategory(identifier: "chat", actions: [reply], intentIdentifiers: [])])
        let content = UNMutableNotificationContent()
        content.title = sender.isEmpty ? "Sam" : sender
        content.body = "Are you around later? Want to grab dinner"
        content.categoryIdentifier = "chat"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
            UNUserNotificationCenter.current().getNotificationSettings { s in
                DebugHooks.log("REPLYTEST added error=\(String(describing: error)) auth=\(s.authorizationStatus.rawValue) alert=\(s.alertStyle.rawValue)")
            }
        }
    }

    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
            completionHandler([.banner, .sound])
        }

        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                    withCompletionHandler completionHandler: @escaping () -> Void) {
            if let text = (response as? UNTextInputNotificationResponse)?.userText {
                DebugHooks.log("REPLYTEST got reply: \(text)")
                completionHandler()
                return
            }
            DispatchQueue.main.async { NotchPresenter.shared.open(tab: .ask) }
            completionHandler()
        }
    }
}
