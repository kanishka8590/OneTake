import SwiftUI
import UserNotifications

struct RecordingSettingsView: View {
    let appState: AppState
    var body: some View {
        Form {
            Section("Reader cues") {
                Picker("Cue response", selection: Bindable(appState.settings).cueTriggerMode) { ForEach(CueTriggerMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                HStack { Text("Cue delay"); Spacer(); Text(appState.settings.cueDelaySeconds == 0 ? "Immediate" : "+\(Int(appState.settings.cueDelaySeconds))s").foregroundStyle(Theme.Colors.textSecondary) }
                Slider(value: Bindable(appState.settings).cueDelaySeconds, in: 0...5, step: 1).tint(Theme.Colors.primaryPlum)
                HStack { Text("Cue volume"); Spacer(); Text("\(Int(appState.settings.cueVolume * 100))%") }
                Slider(value: Bindable(appState.settings).cueVolume, in: 0...1).tint(Theme.Colors.primaryPlum)
            }
            Section("Recording") {
                Picker("Teleprompter text", selection: Bindable(appState.settings).teleprompterTextSize) { ForEach(TeleprompterTextSize.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                Toggle("Mirror front camera", isOn: Bindable(appState.settings).mirrorFrontCamera).tint(Theme.Colors.primaryPlum)
                Picker("Video quality", selection: Bindable(appState.settings).videoQuality) { ForEach(VideoQuality.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                Picker("Frame rate", selection: Bindable(appState.settings).frameRate) { Text("30fps").tag(30); Text("60fps").tag(60) }
            }
        }.navigationTitle("Recording settings")
    }
}

struct NotificationPreferencesView: View {
    let appState: AppState
    @State private var authorizationNote: String?
    var body: some View {
        Form {
            Section {
                Toggle("Audition Reminders", isOn: Bindable(appState.settings).notifyAuditions).tint(Theme.Colors.primaryPlum)
                Toggle("Submission Reminders", isOn: Bindable(appState.settings).notifySubmissions).tint(Theme.Colors.primaryPlum)
                Toggle("Practice Reminders", isOn: Bindable(appState.settings).notifyPractice).tint(Theme.Colors.primaryPlum)
                Toggle("Product Updates", isOn: Bindable(appState.settings).notifyProductUpdates).tint(Theme.Colors.primaryPlum)
            } footer: { Text(authorizationNote ?? "We only send the reminders you choose.") }
        }
        .navigationTitle("Notification Preferences")
        .onAppear { requestAuthorization() }
    }
    private func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { allowed, error in
            DispatchQueue.main.async { authorizationNote = allowed ? "Notifications are enabled." : (error == nil ? "Notifications are off. You can change this in Settings." : "Notification permissions are unavailable.") }
        }
    }
}

struct PrivacyAndDataView: View {
    let appState: AppState
    @State private var showingPolicy = false
    @State private var confirmation: DataAction?
    private enum DataAction: Identifiable { case local, account; var id: Int { self == .local ? 0 : 1 } }
    var body: some View {
        List {
            Section("Storage on this device") {
                metric("Takes", value: String(format: "%.1f MB", appState.totalStorageUsedMB))
                metric("App data", value: String(format: "%.1f MB", appState.localAppDataUsedMB))
            }
            Section("Privacy") { Button("Privacy Policy") { showingPolicy = true } }
            Section {
                Button("Delete all local data", role: .destructive) { confirmation = .local }
                Button("Delete account", role: .destructive) { confirmation = .account }
            } footer: { Text("Deleting local data removes auditions, recordings, practice sessions, and your profile from this device.") }
        }
        .navigationTitle("Privacy & data")
        .sheet(isPresented: $showingPolicy) { PrivacyPolicyView() }
        .confirmationDialog(confirmation == .account ? "Delete account?" : "Delete all local data?", item: $confirmation) { action in
            Button(action == .account ? "Delete account" : "Delete local data", role: .destructive) {
                appState.deleteAllLocalData()
                if action == .account { appState.logout() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in Text(action == .account ? "This removes your account data from this device. Contact support for any server-side request." : "This cannot be undone.") }
    }
    private func metric(_ label: String, value: String) -> some View { HStack { Text(label); Spacer(); Text(value).foregroundStyle(Theme.Colors.textSecondary) } }
}

private struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View { NavigationStack { ScrollView { Text("OneTake stores audition media and practice data on your device. Private delivery links are unlisted and expire after 30 days. We request camera, microphone, photo, speech, and notification access only for the features you enable.").font(Theme.Typography.bodyRegular).padding() }.navigationTitle("Privacy Policy").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } } } }
}
