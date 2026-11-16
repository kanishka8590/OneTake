import SwiftUI
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
    }
}

struct NotificationPreferencesView: View {
    let appState: AppState
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
                Toggle("Product Updates", isOn: Bindable(appState.settings).notifyProductUpdates)
                    .tint(Theme.Colors.accent)
            } footer: {
                Text(authorizationNote ?? "We only send the reminders you choose.")
            }
        }
        .navigationTitle("Notifications")
        .task {
            await requestAuthorization()
        }
        .onChange(of: appState.settings.notifyAuditions) { _, isEnabled in
            AuditionReminderService.reschedule(
                auditions: appState.auditions,
                enabled: isEnabled
            )
        }
    }

    private func requestAuthorization() async {
        do {
            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            authorizationNote = allowed
                ? "Notifications are enabled."
                : "Notifications are off. You can change this in Settings."
        } catch {
            authorizationNote = "Notification permissions are unavailable."
        }
    }
}

struct PrivacyAndDataView: View {
    let appState: AppState
    @State private var showingPolicy = false
    @State private var confirmation: DataAction?

    private enum DataAction: Identifiable {
        case local, account
        var id: Int { self == .local ? 0 : 1 }
    }

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
                Button("Delete all local data", role: .destructive) { confirmation = .local }
                Button("Delete account", role: .destructive) { confirmation = .account }
            } footer: {
                Text("Deleting local data removes auditions, recordings, practice sessions, and your profile from this device.")
            }
        }
        .navigationTitle("Privacy & data")
        .task {
            await appState.refreshLocalStorageUsage()
        }
        .sheet(isPresented: $showingPolicy) {
            PrivacyPolicyView()
        }
        .confirmationDialog(
            confirmation == .account ? "Delete account?" : "Delete all local data?",
            item: $confirmation
        ) { action in
            Button(action == .account ? "Delete account" : "Delete local data", role: .destructive) {
                appState.deleteAllLocalData()
                if action == .account {
                    appState.logout()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(
                action == .account
                    ? "This removes your account data from this device. Contact support@onetake.app for any server-side request."
                    : "This cannot be undone."
            )
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
