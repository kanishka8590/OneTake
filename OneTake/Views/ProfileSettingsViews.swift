import SwiftUI
import UIKit
import UserNotifications

struct RecordingSettingsView: View {
    let appState: AppState

    var body: some View {
        Form {
            Section("Reader cues") {
                Picker("Cue response", selection: Bindable(appState.settings).cueTriggerMode) {
                    ForEach(CueTriggerMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }

                HStack {
                    Text("Cue delay")
                    Spacer()
                    Text(appState.settings.cueDelaySeconds == 0 ? "Immediate" : "+\(Int(appState.settings.cueDelaySeconds))s")
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                Slider(value: Bindable(appState.settings).cueDelaySeconds, in: 0...5, step: 1)
                    .tint(Theme.Colors.accent)
                    .accessibilityLabel("Cue delay")
                    .accessibilityValue(
                        appState.settings.cueDelaySeconds == 0
                            ? "Immediate"
                            : "\(Int(appState.settings.cueDelaySeconds)) seconds"
                    )

                HStack {
                    Text("Cue volume")
                    Spacer()
                    Text("\(Int(appState.settings.cueVolume * 100))%")
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                Slider(value: Bindable(appState.settings).cueVolume, in: 0...1)
                    .tint(Theme.Colors.accent)
                    .accessibilityLabel("Cue volume")
                    .accessibilityValue("\(Int(appState.settings.cueVolume * 100)) percent")
            }

            Section("Recording & Self-Tape") {
                Picker("Countdown timer", selection: Bindable(appState.settings).countdownSeconds) {
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                }

                Toggle("Auto-trim silence", isOn: Bindable(appState.settings).autoTrimSilence)
                    .tint(Theme.Colors.accent)

                Toggle("Noise reduction by default", isOn: Bindable(appState.settings).noiseReductionDefault)
                    .tint(Theme.Colors.accent)

                Toggle("Mirror front camera", isOn: Bindable(appState.settings).mirrorFrontCamera)
                    .tint(Theme.Colors.accent)

                Picker("Video quality", selection: Bindable(appState.settings).videoQuality) {
                    ForEach(VideoQuality.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }

                Picker("Frame rate", selection: Bindable(appState.settings).frameRate) {
                    Text("30fps").tag(30)
                    Text("60fps").tag(60)
                }
            }

            Section("Teleprompter") {
                Picker("Prompt text size", selection: Bindable(appState.settings).teleprompterTextSize) {
                    ForEach(TeleprompterTextSize.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            }
        }
        .navigationTitle("Recording settings")
        .toolbar(.hidden, for: .tabBar)
    }
}

struct NotificationPreferencesView: View {
    let appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @State private var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @State private var authorizationNote: String?

    var body: some View {
        Form {
            Section {
                Toggle("Audition Reminders", isOn: Bindable(appState.settings).notifyAuditions)
                    .tint(Theme.Colors.accent)
                Toggle("Submission Reminders", isOn: Bindable(appState.settings).notifySubmissions)
                    .tint(Theme.Colors.accent)
                Toggle("Practice Reminders", isOn: Bindable(appState.settings).notifyPractice)
                    .tint(Theme.Colors.accent)

                if authorizationStatus == .denied {
                    Button {
                        openIOSSettings()
                    } label: {
                        Label("Open iOS Settings", systemImage: "gearshape")
                            .foregroundStyle(Theme.Colors.accent)
                    }
                }
            } footer: {
                Text(authorizationNote ?? "We only send the local reminders you choose.")
            }
        }
        .navigationTitle("Notifications")
        .toolbar(.hidden, for: .tabBar)
        .task {
            await requestAuthorizationIfNeeded()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task {
                await refreshAuthorizationStatus()
            }
        }
        .onChange(of: appState.settings.notifyAuditions) { _, _ in
            rescheduleReminders()
        }
        .onChange(of: appState.settings.notifySubmissions) { _, _ in
            rescheduleReminders()
        }
        .onChange(of: appState.settings.notifyPractice) { _, _ in
            rescheduleReminders()
        }
    }

    private func rescheduleReminders() {
        AuditionReminderService.reschedule(
            auditions: appState.auditions,
            notifyAuditions: appState.settings.notifyAuditions,
            notifySubmissions: appState.settings.notifySubmissions,
            notifyPractice: appState.settings.notifyPractice,
            practiceScripts: appState.practiceScripts
        )
    }

    private func requestAuthorizationIfNeeded() async {
        let initialStatus = await AuditionReminderService.authorizationStatus()
        if initialStatus == .notDetermined {
            _ = await AuditionReminderService.requestAuthorization()
        }
        await refreshAuthorizationStatus()
    }

    private func refreshAuthorizationStatus() async {
        let status = await AuditionReminderService.authorizationStatus()
        authorizationStatus = status
        switch status {
        case .authorized, .provisional, .ephemeral:
            authorizationNote = "Local reminders are enabled for deadlines, submission cutoffs, and daily practice."
            rescheduleReminders()
        case .denied:
            authorizationNote = "Notifications are turned off in iOS Settings. Enable notifications to receive deadline and submission reminders."
        case .notDetermined:
            authorizationNote = "We only send the local reminders you choose."
        @unknown default:
            authorizationNote = "Notification permissions are unavailable."
        }
    }

    private func openIOSSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString),
              UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url)
    }
}

struct PrivacyAndDataView: View {
    let appState: AppState
    @State private var showingPolicy = false
    @State private var confirmingDeleteLocalData = false
    @State private var confirmingDeleteAccount = false

    var body: some View {
        List {
            Section("Storage on this device") {
                metric("Takes", value: String(format: "%.1f MB", appState.totalStorageUsedMB))
                metric("App data", value: String(format: "%.1f MB", appState.localAppDataUsedMB))
            }

            Section("Privacy") {
                Button("Privacy Policy") { showingPolicy = true }
            }

            Section {
                Button("Delete all local data", role: .destructive) {
                    confirmingDeleteLocalData = true
                }
                .confirmationDialog(
                    "Delete all local data?",
                    isPresented: $confirmingDeleteLocalData,
                    titleVisibility: .visible
                ) {
                    Button("Delete local data", role: .destructive) {
                        appState.deleteAllLocalData()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This cannot be undone.")
                }

                Button("Delete account", role: .destructive) {
                    confirmingDeleteAccount = true
                }
                .confirmationDialog(
                    "Delete account?",
                    isPresented: $confirmingDeleteAccount,
                    titleVisibility: .visible
                ) {
                    Button("Delete account", role: .destructive) {
                        appState.deleteAllLocalData()
                        appState.logout()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This removes your account data from this device. Contact support@onetake.app for any server-side request.")
                }
            } footer: {
                Text("Deleting local data removes auditions, recordings, practice sessions, and your profile from this device.")
            }
        }
        .navigationTitle("Privacy & data")
        .toolbar(.hidden, for: .tabBar)
        .task {
            await appState.refreshLocalStorageUsage()
        }
        .sheet(isPresented: $showingPolicy) {
            PrivacyPolicyView()
                .presentationBackground(Theme.Colors.canvasBackground)
        }
    }

    private func metric(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
    }
}

private struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Effective Date: November 16, 2026")
                        .font(Theme.Typography.captionBadge)
                        .foregroundStyle(Theme.Colors.textSecondary)

                    policySection(
                        title: "On-Device, Local-First Storage",
                        body: "OneTake is designed as a local-first studio for actors. Your auditions, headshots, slates, self-tape takes, scripts, and rehearsal audio recordings are stored directly on your device and are not uploaded automatically to remote servers."
                    )

                    policySection(
                        title: "Permissions & Audio/Video Processing",
                        body: "Camera, Microphone, Photos, Speech Recognition, and Notifications permissions are requested only when you use those features. Speech recognition and CoreML framing or script classification run on-device to power rehearsal cues and take reviews."
                    )

                    policySection(
                        title: "Private Delivery Links & Demo Mode",
                        body: "When you choose to export or share a private delivery link, links are unlisted and expire after 30 days. Demo Mode loads sample auditions, scripts, and generated local media on your device so you can preview OneTake safely without affecting personal records."
                    )

                    policySection(
                        title: "Your Data Controls",
                        body: "You can remove individual auditions, takes, Demo Mode data, or erase all local data and your local profile at any time from Privacy & Data."
                    )

                    policySection(
                        title: "Contact",
                        body: "Questions or data requests can be sent to support@onetake.app."
                    )
                }
                .padding(Theme.Layout.screenHPadding)
            }
            .background(Theme.Colors.canvasBackground)
            .navigationTitle("Privacy Policy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func policySection(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.Colors.textPrimary)

            Text(body)
                .font(Theme.Typography.bodyRegular)
                .foregroundStyle(Theme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
