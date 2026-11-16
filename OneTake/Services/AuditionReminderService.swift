import Foundation
import UserNotifications

/// Ensures local audition reminders present banners and sound even when the app is in the foreground.
final class AuditionReminderNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AuditionReminderNotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge, .list])
    }
}

/// Manages local deadline reminders for active auditions using `UNUserNotificationCenter`.
/// Rebuilt whenever auditions change or notification settings toggle so moved deadlines,
/// sent submissions, and deleted auditions never leave stale alerts behind.
enum AuditionReminderService {
    static let identifierPrefix = "onetake.audition."

    nonisolated struct PlannedReminder: Equatable, Sendable {
        let id: String
        let auditionID: UUID
        let title: String
        let body: String
        let date: Date
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus
    }

    @discardableResult
    static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    static func plannedReminders(
        for auditions: [Audition],
        enabled: Bool = true,
        now: Date = .now
    ) -> [PlannedReminder] {
        guard enabled else { return [] }

        return auditions.compactMap { audition in
            guard audition.status == .active, audition.deadline > now else {
                return nil
            }

            let offsetMinutes = max(0, audition.reminderOffsetMinutes)
            let reminderDate = audition.deadline.addingTimeInterval(-TimeInterval(offsetMinutes * 60))
            guard reminderDate > now else {
                return nil
            }

            let projectTitle = audition.projectName.trimmingCharacters(in: .whitespacesAndNewlines)
            let roleTitle = audition.roleName.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayProject = projectTitle.isEmpty ? "Audition" : projectTitle
            let displayRole = roleTitle.isEmpty ? "Self-Tape" : roleTitle
            let dueText = audition.deadline.formatted(date: .abbreviated, time: .shortened)

            return PlannedReminder(
                id: "\(identifierPrefix)deadline.\(audition.id.uuidString)",
                auditionID: audition.id,
                title: "\(displayProject) due soon",
                body: "Role: \(displayRole) · Due \(dueText).",
                date: reminderDate
            )
        }
    }

    static func reschedule(
        auditions: [Audition],
        enabled: Bool,
        now: Date = .now
    ) {
        guard Bundle.main.bundleIdentifier != nil else { return }

        let planned = plannedReminders(for: auditions, enabled: enabled, now: now)
        let center = UNUserNotificationCenter.current()

        center.getPendingNotificationRequests { pending in
            let staleIDs = pending
                .map(\.identifier)
                .filter { $0.hasPrefix(identifierPrefix) }
            if !staleIDs.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: staleIDs)
            }

            guard enabled, !planned.isEmpty else { return }

            for reminder in planned {
                let content = UNMutableNotificationContent()
                content.title = reminder.title
                content.body = reminder.body
                content.sound = .default

                let components = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second],
                    from: reminder.date
                )
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                let request = UNNotificationRequest(
                    identifier: reminder.id,
                    content: content,
                    trigger: trigger
                )
                center.add(request)
            }
        }
    }
}
