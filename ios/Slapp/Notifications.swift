import UserNotifications

/// plain words at the right moment — a line finished, a line needs help
enum LineNotifications {
    static func ask() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "notify_lines") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "notify_lines") }
    }

    static func post(_ id: String, title: String, body: String) {
        guard enabled else { return }
        let n = UNMutableNotificationContent()
        n.title = title
        n.body = body
        n.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: n, trigger: nil))
    }
}
