import SwiftUI
import AVFoundation

struct TalkToOneTakeBriefingView: View {
    @Environment(\.dismiss) private var dismiss

    let audition: Audition
    var isSlate: Bool = false
    var initialScript: String = ""
    let onReadyToRecord: (String) -> Void

    @State private var editableScript: String = ""
    @State private var isEditingScriptSheet = false
    @State private var scriptEditBuffer: String = ""

    // ONETAKE TALKS BACK toggles
    @State private var framingTipsOutLoud: Bool = true
    @State private var countdownOutLoud: Bool = true

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
        self._scriptEditBuffer = State(initialValue: scriptPreview)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.canvasBackground
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Header / Avatar
                        headerAvatarSection

                        // In Slate mode: YOUR SLATE section
                        if isSlate && !editableScript.isEmpty {
                            yourSlateSection
                        }

                        // SAY THIS Section
                        sayThisSection

                        // ONETAKE TALKS BACK Section
                        onetakeTalksBackSection

                        Spacer(minLength: 24)

                        // Start Recording Primary CTA
                        Button {
                            dismiss()
                            onReadyToRecord(editableScript)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "record.circle")
                                Text("Start Recording")
                            }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.white)
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
                // Slate and audition both pass through this one white briefing.
                VoiceAuthorizationService.shared.requestAccess()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(isPresented: $isEditingScriptSheet) {
                editScriptSheet
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

                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(Theme.Colors.primaryPlum)
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
    // "This scrolls as you record. Double tap to edit." + lavender-tinted rounded box

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
                .background(Color.white.opacity(0.75))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(16)
            .background(Theme.Colors.lavenderSurface.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: - Edit Script Sheet

    private var editScriptSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Edit Slate Script")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.Colors.textPrimary)

                TextEditor(text: $scriptEditBuffer)
                    .font(.system(size: 15))
                    .padding(12)
                    .background(Theme.Colors.lavenderSurface.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .frame(minHeight: 180)

                Spacer()

                Button {
                    let trimmed = scriptEditBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        editableScript = trimmed
                    }
                    isEditingScriptSheet = false
                } label: {
                    Text("Save Changes")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.Colors.primaryPlum)
                        .clipShape(Capsule())
                }
            }
            .padding(24)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isEditingScriptSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - SAY THIS Section
    // "Action" -> Starts Recording, "Cut" -> Stops Recording, "How do I look?" -> Checks framing and light

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
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 2)
        }
    }

    private func voiceCommandRow(phrase: String, actionDescription: String) -> some View {
        HStack(spacing: 12) {
            Text(phrase)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.Colors.primaryPlum)
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
    // Toggles: Framing tips out loud, Count down out loud

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

                    Toggle("", isOn: $framingTipsOutLoud)
                        .tint(Theme.Colors.primaryPlum)
                        .labelsHidden()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Divider().padding(.horizontal, 16)

                HStack {
                    Text("Count down out loud")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.Colors.textPrimary)

                    Spacer()

                    Toggle("", isOn: $countdownOutLoud)
                        .tint(Theme.Colors.primaryPlum)
                        .labelsHidden()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 2)
        }
    }
}
