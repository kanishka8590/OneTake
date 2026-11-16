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

/// Manages local deadline, submission, and practice reminders using `UNUserNotificationCenter`.
/// Rebuilt whenever auditions, practice scripts, or notification toggles change so moved deadlines,
/// sent submissions, and deleted auditions never leave stale alerts behind.
enum AuditionReminderService {
    static let identifierPrefix = "onetake.audition."
    static let submissionIdentifierPrefix = "onetake.submission."
    static let practiceIdentifier = "onetake.practice.daily"
    private static let managedPrefixes = [identifierPrefix, submissionIdentifierPrefix, "onetake.practice."]

    nonisolated struct PlannedReminder: Equatable, Sendable {
        let id: String
        let auditionID: UUID?
        let title: String
        let body: String
        let date: Date
        let repeatsDaily: Bool

        init(
            id: String,
            auditionID: UUID? = nil,
            title: String,
            body: String,
            date: Date,
            repeatsDaily: Bool = false
        ) {
            self.id = id
            self.auditionID = auditionID
            self.title = title
            self.body = body
            self.date = date
            self.repeatsDaily = repeatsDaily
        }
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
        plannedReminders(
            for: auditions,
            notifyAuditions: enabled,
            notifySubmissions: false,
            notifyPractice: false,
            practiceScripts: [],
            now: now
        )
    }

    static func plannedReminders(
        for auditions: [Audition],
        notifyAuditions: Bool,
        notifySubmissions: Bool,
        notifyPractice: Bool,
        practiceScripts: [PracticeScript] = [],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [PlannedReminder] {
        var result: [PlannedReminder] = []
        let upcoming = auditions.filter { $0.status == .active && $0.deadline > now }
        let minSeparation: TimeInterval = 2 * 3600

        for audition in upcoming {
            let projectTitle = audition.projectName.trimmingCharacters(in: .whitespacesAndNewlines)
            let roleTitle = audition.roleName.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayProject = projectTitle.isEmpty ? "Audition" : projectTitle
            let displayRole = roleTitle.isEmpty ? "Self-Tape" : roleTitle
            let dueText = audition.deadline.formatted(date: .abbreviated, time: .shortened)

            let offsetMinutes = max(0, audition.reminderOffsetMinutes)
            let customDate = audition.deadline.addingTimeInterval(-TimeInterval(offsetMinutes * 60))
            let willScheduleCustom = notifyAuditions && customDate > now

            let twoBefore = audition.deadline.addingTimeInterval(-2 * 3600)
            let willScheduleTwoHours = notifySubmissions && twoBefore > now

            if willScheduleCustom {
                result.append(
                    PlannedReminder(
                        id: "\(identifierPrefix)deadline.\(audition.id.uuidString)",
                        auditionID: audition.id,
                        title: "\(displayProject) due soon",
                        body: "Role: \(displayRole) · Due \(dueText).",
                        date: customDate
                    )
                )
            }

            if notifyAuditions,
               let nineAM = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: audition.deadline),
               nineAM > now,
               nineAM < audition.deadline {
                let collidesWithCustom = willScheduleCustom
                    && abs(customDate.timeIntervalSince(nineAM)) < minSeparation
                let collidesWithTwoHours = willScheduleTwoHours
                    && (twoBefore <= nineAM || twoBefore.timeIntervalSince(nineAM) < minSeparation)
                if !collidesWithCustom && !collidesWithTwoHours {
                    result.append(
                        PlannedReminder(
                            id: "\(identifierPrefix)morning.\(audition.id.uuidString)",
                            auditionID: audition.id,
                            title: "\(displayProject) is due today",
                            body: "Role: \(displayRole) · Due \(dueText).",
                            date: nineAM
                        )
                    )
                }
            }

            if willScheduleTwoHours {
                result.append(
                    PlannedReminder(
                        id: "\(submissionIdentifierPrefix)twohours.\(audition.id.uuidString)",
                        auditionID: audition.id,
                        title: "2 hours left to submit · \(displayProject)",
                        body: "Role: \(displayRole) · Due \(dueText).",
                        date: twoBefore
                    )
                )
            }
        }

        if notifyPractice {
            let nextAuditionWithSides = upcoming
                .filter {
                    let hasScript = !($0.scriptText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                    return hasScript || !$0.cueLines.isEmpty
                }
                .min { $0.deadline < $1.deadline }
            let firstScript = practiceScripts.first

            if nextAuditionWithSides != nil || firstScript != nil {
                let todaySixPM = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now)
                let practiceDate: Date
                if let sixPM = todaySixPM, sixPM > now {
                    practiceDate = sixPM
                } else if let sixPM = todaySixPM, let tomorrowSixPM = calendar.date(byAdding: .day, value: 1, to: sixPM) {
                    practiceDate = tomorrowSixPM
                } else {
                    practiceDate = now.addingTimeInterval(24 * 3600)
                }

                let body: String
                if let next = nextAuditionWithSides {
                    let project = next.projectName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let role = next.roleName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let displayProject = project.isEmpty ? "your audition" : project
                    let displayRole = role.isEmpty ? "Your lines" : role
                    body = "\(displayRole) in \(displayProject) — five minutes is enough."
                } else if let script = firstScript {
                    let title = script.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    let displayTitle = title.isEmpty ? "your scene" : title
                    body = "\(displayTitle) — five minutes of line work keeps you sharp."
                } else {
                    body = "Run your lines — five minutes is enough."
                }

                result.append(
                    PlannedReminder(
                        id: practiceIdentifier,
                        auditionID: nextAuditionWithSides?.id,
                        title: "Run your lines",
                        body: body,
                        date: practiceDate,
                        repeatsDaily: true
                    )
                )
            }
        }

        return result
    }

    static func reschedule(
        auditions: [Audition],
        enabled: Bool,
        now: Date = .now
    ) {
        reschedule(
            auditions: auditions,
            notifyAuditions: enabled,
            notifySubmissions: false,
            notifyPractice: false,
            practiceScripts: [],
            now: now
        )
    }

    static func reschedule(
        auditions: [Audition],
        notifyAuditions: Bool,
        notifySubmissions: Bool,
        notifyPractice: Bool,
        practiceScripts: [PracticeScript] = [],
        now: Date = .now
    ) {
        guard Bundle.main.bundleIdentifier != nil else { return }

        let planned = plannedReminders(
            for: auditions,
            notifyAuditions: notifyAuditions,
            notifySubmissions: notifySubmissions,
            notifyPractice: notifyPractice,
            practiceScripts: practiceScripts,
            now: now
        )
        let center = UNUserNotificationCenter.current()

        center.getPendingNotificationRequests { pending in
            let staleIDs = pending
                .map(\.identifier)
                .filter { id in
                    managedPrefixes.contains { id.hasPrefix($0) }
                }
            if !staleIDs.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: staleIDs)
            }

            guard !planned.isEmpty else { return }

            for reminder in planned {
                let content = UNMutableNotificationContent()
                content.title = reminder.title
                content.body = reminder.body
                content.sound = .default

                let trigger: UNCalendarNotificationTrigger
                if reminder.repeatsDaily {
                    let components = Calendar.current.dateComponents([.hour, .minute], from: reminder.date)
                    trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
                } else {
                    let components = Calendar.current.dateComponents(
                        [.year, .month, .day, .hour, .minute, .second],
                        from: reminder.date
                    )
                    trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                }

                let request = UNNotificationRequest(
                    identifier: reminder.id,
                    content: content,
                    trigger: trigger
                )
                center.add(request)
            }
        }
    }

    static func sendSubmissionConfirmationIfEnabled(for audition: Audition, enabled: Bool) {
        guard enabled, Bundle.main.bundleIdentifier != nil else { return }

        let projectTitle = audition.projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayProject = projectTitle.isEmpty ? "Audition" : projectTitle

        let content = UNMutableNotificationContent()
        content.title = "Submission Sent · \(displayProject)"
        content.body = "Your self-tape package for \(displayProject) was marked as sent."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "\(submissionIdentifierPrefix)sent.\(audition.id.uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
