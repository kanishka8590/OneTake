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
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Stay in character without touching the screen.")
                            .font(Theme.Typography.bodyRegular)
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                }

                if isSlate {
                    Section {
                        TextEditor(text: $editableScript)
                            .font(Theme.Typography.bodyRegular)
                            .foregroundStyle(Theme.Colors.textPrimary)
                            .frame(minHeight: 110)
                    } header: {
                        Text("Your Slate")
                    } footer: {
                        Text("This scrolls in the teleprompter when recording starts.")
                    }
                }

                Section("Voice Commands") {
                    LabeledContent("\"Action\"") {
                        Text("Starts recording")
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                    LabeledContent("\"Cut\"") {
                        Text("Stops recording")
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                    LabeledContent("\"How do I look?\"") {
                        Text("Checks framing and light")
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                }

                Section("Spoken Audio") {
                    Toggle("Framing tips out loud", isOn: Bindable(appState.settings).framingTipsOutLoud)
                        .tint(Theme.Colors.accent)
                    Toggle("Count down out loud", isOn: Bindable(appState.settings).countdownOutLoud)
                        .tint(Theme.Colors.accent)
                }
            }
            .scrollContentBackground(.hidden)
            .scrollEdgeHaptics()
            .background(Theme.Colors.canvasBackground.ignoresSafeArea())
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

                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        dismissActiveKeyboard()
                    }
                }
            }
            .floatingBottomActionBar {
                Button {
                    onReadyToRecord(editableScript)
                } label: {
                    Label("Record", systemImage: "record.circle")
                        .primaryCapsuleButton()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Start Recording")
            }
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
            previousWork: [],
            roleName: audition.roleName,
            projectName: audition.projectName
        )
    }
}
