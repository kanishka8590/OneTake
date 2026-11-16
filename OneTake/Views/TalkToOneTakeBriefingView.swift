import SwiftUI
import AVFoundation

struct TalkToOneTakeBriefingView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let audition: Audition
    var isSlate: Bool = false
    var initialScript: String = ""
    let onReadyToRecord: (String) -> Void

    @State private var editableScript: String = ""

    init(
        audition: Audition,
        isSlate: Bool = false,
        scriptPreview: String = "",
        onReadyToRecord: @escaping (String) -> Void
    ) {
        self.audition = audition
        self.isSlate = isSlate
        self.initialScript = scriptPreview
        self.onReadyToRecord = onReadyToRecord
        self._editableScript = State(initialValue: scriptPreview)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.canvasBackground
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        headerAvatarSection

                        if isSlate {
                            yourSlateSection
                        }

                        sayThisSection
                        onetakeTalksBackSection

                        Spacer(minLength: 24)

                        Button {
                            onReadyToRecord(editableScript)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "record.circle")
                                Text("Start Recording")
                            }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.Colors.onAction)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Theme.Colors.primaryPlum)
                            .clipShape(Capsule())
                        }
                        .padding(.top, 4)
                        .padding(.bottom, 32)
                    }
                    .padding(.horizontal, 20)
                }
            }
            .navigationTitle("Talk to OneTake")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                VoiceAuthorizationService.shared.requestAccess()
                populateSlateScriptIfNeeded()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    // MARK: - Header & Avatar

    private var headerAvatarSection: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Theme.Colors.lavenderSurface)
                    .frame(width: 52, height: 52)

                Image(systemName: "waveform.circle")
                    .font(.system(size: 32))
                    .foregroundStyle(Theme.Colors.accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Talk to OneTake")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.Colors.textPrimary)

                Text("Voice commands let you stay in character without touching the screen.")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(2)
            }
        }
        .padding(.top, 12)
    }

    // MARK: - YOUR SLATE Section (Slate mode only)

    private var yourSlateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("YOUR SLATE")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.Colors.textSecondary)

                Spacer()

                Text("This scrolls in the teleprompter when recording starts.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            .padding(.horizontal, 4)

            TextEditor(text: $editableScript)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.Colors.textPrimary)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 130)
                .padding(10)
                .background(Theme.Colors.controlSurface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.Colors.controlBorder, lineWidth: 1))
                .padding(16)
                .background(Theme.Colors.lavenderSurface.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    /// Fallback template if navigated here directly before `SlateProfileSetupView`
    /// populated the script preview. Uses the shared `SlateScriptTemplate`.
    private func populateSlateScriptIfNeeded() {
        guard isSlate, editableScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let profile = appState.currentUser
        editableScript = SlateScriptTemplate.build(
            name: profile?.name ?? "",
            height: profile?.height ?? "",
            age: (profile?.age ?? 0) > 0 ? "\(profile?.age ?? 0)" : "",
            basedIn: profile?.basedIn ?? "",
            representation: profile?.representation ?? "Self-represented",
            previousWork: profile?.previousWork ?? [],
            roleName: audition.roleName,
            projectName: audition.projectName
        )
    }

    // MARK: - SAY THIS Section

    private var sayThisSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SAY THIS")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.Colors.textSecondary)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                voiceCommandRow(phrase: "\"Action\"", actionDescription: "Starts Recording")
                Divider().padding(.horizontal, 16)
                voiceCommandRow(phrase: "\"Cut\"", actionDescription: "Stops Recording")
                Divider().padding(.horizontal, 16)
                voiceCommandRow(phrase: "\"How do I look?\"", actionDescription: "Checks framing and light")
            }
            .background(Theme.Colors.cardSurface)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 2)
        }
    }

    private func voiceCommandRow(phrase: String, actionDescription: String) -> some View {
        HStack(spacing: 12) {
            Text(phrase)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.Colors.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Theme.Colors.lavenderSurface)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Spacer()

            Text(actionDescription)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.Colors.textPrimary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - ONETAKE TALKS BACK Section

    private var onetakeTalksBackSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ONETAKE TALKS BACK")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.Colors.textSecondary)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                HStack {
                    Text("Framing tips out loud")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.Colors.textPrimary)

                    Spacer()

                    Toggle("", isOn: Bindable(appState.settings).framingTipsOutLoud)
                        .tint(Theme.Colors.accent)
                        .labelsHidden()
                        .accessibilityLabel("Framing tips out loud")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Divider().padding(.horizontal, 16)

                HStack {
                    Text("Count down out loud")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.Colors.textPrimary)

                    Spacer()

                    Toggle("", isOn: Bindable(appState.settings).countdownOutLoud)
                        .tint(Theme.Colors.accent)
                        .labelsHidden()
                        .accessibilityLabel("Count down out loud")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .background(Theme.Colors.cardSurface)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 2)
        }
    }
}
