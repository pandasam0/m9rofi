import Foundation
import UserNotifications
import FinanceCore

/// Local notifications only. Nothing leaves the device.
@MainActor
final class NotificationService {
    static let shared = NotificationService()
    private let center = UNUserNotificationCenter.current()

    func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func deliver(store: AppStore, newTransactionIDs: [UUID]) async {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        var alerts = AlertEngine(state: store.state).pending(now: Date(), newTransactionIDs: newTransactionIDs)
        if !store.state.settings.notifyNewExpense { alerts.removeAll { $0.kind == .newExpense } }
        var delivered: [String] = []
        for a in alerts {
            let content = UNMutableNotificationContent()
            content.title = a.title
            content.body = a.body
            content.sound = a.kind == .newExpense ? nil : .default
            content.threadIdentifier = a.kind.rawValue
            var trigger: UNNotificationTrigger?
            if let fire = a.fireDate, fire.timeIntervalSinceNow > 60 {
                let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
                trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            }
            let req = UNNotificationRequest(identifier: a.id, content: content, trigger: trigger)
            do { try await center.add(req); delivered.append(a.id) } catch { continue }
        }
        if !delivered.isEmpty { store.markAlertsFired(delivered) }
        let reviewCount = store.state.transactions.filter(\.needsReview).count
        try? await center.setBadgeCount(reviewCount)
    }

    func removeAll() {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }
}
