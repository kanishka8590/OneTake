import SwiftUI
import PhotosUI
import AVFoundation
import SwiftData

/// Shared slate script generator used by both `SlateProfileSetupView` and `TalkToOneTakeBriefingView`
/// so the generated teleprompter text is always consistent.
nonisolated enum SlateScriptTemplate {
    static func build(
        name: String,
        height: String,
        age: String,
        basedIn: String,
        representation: String,
        previousWork: [String],
        roleName: String,
        projectName: String
    ) -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHeight = height.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAge = age.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBasedIn = basedIn.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRep = representation.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRole = roleName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedProject = projectName.trimmingCharacters(in: .whitespacesAndNewlines)

        let stripDot: (String) -> String = { value in
            var result = value
            while result.hasSuffix(".") {
                result.removeLast()
            }
            return result
        }

        var parts: [String] = []
        let displayName = trimmedName.isEmpty ? "your name" : stripDot(trimmedName)
        parts.append("Hi, my name is \(displayName).")

        if !trimmedHeight.isEmpty {
            parts.append("I am \(stripDot(trimmedHeight)) tall.")
        }
        if !trimmedAge.isEmpty, trimmedAge != "0" {
            parts.append("I am \(trimmedAge) years old.")
        }
        if !trimmedBasedIn.isEmpty {
            parts.append("I am based in \(stripDot(trimmedBasedIn)).")
        }
        if !trimmedRep.isEmpty {
            let cleanRep = stripDot(trimmedRep)
            if cleanRep.caseInsensitiveCompare("Self-represented") == .orderedSame {
                parts.append("I am self-represented.")
            } else {
                parts.append("I am represented by \(cleanRep).")
            }
        }

        let role = trimmedRole.isEmpty ? "this role" : stripDot(trimmedRole)
        let project = trimmedProject.isEmpty ? "this project" : stripDot(trimmedProject)
        parts.append("Today I am reading for the role of \(role) in \(project).")

        let creds = previousWork
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(2)
        if !creds.isEmpty {
            parts.append("Recently, you may have seen my work in \(creds.joined(separator: " and ")).")
        }

        parts.append("I am available for the shooting dates of this project.")
        return parts.joined(separator: " ")
    }
}

private struct SlateRecorderRoute: Identifiable {
    let id = UUID()
    let script: String
}

struct SlateProfileSetupView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @Bindable var audition: Audition
    let onSlateSaved: () -> Void

    @State private var draft = PersonalDetailsDraft()
    @State private var generatedSlateScript: String = ""

    // Flow navigation
    @State private var showingBriefing = false
    @State private var pendingSlateScript: String?
    @State private var slateRecorderRoute: SlateRecorderRoute?
    @State private var returnToBriefingAfterRecorder = false
    @State private var finalSlateScriptToRecord = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("How casting meets you")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(Theme.Colors.textPrimary)

                        Text("Review your slate details before rolling camera.")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                }

                Section {
                    Text(generatedSlateScript)
                        .font(Theme.Typography.bodyRegular)
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 4)
                } header: {
                    Text("Preview")
                }

                Section {
                    PersonalDetailsFormRows(draft: $draft, includeEmail: false)
                } header: {
                    Text("Personal Details")
                } footer: {
                    Text("Your slate script updates live as you edit your details.")
                }
            }
            .scrollContentBackground(.hidden)
            .scrollEdgeHaptics()
            .background(Theme.Colors.canvasBackground.ignoresSafeArea())
            .navigationTitle("Slate Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") {
                        persistProfileEdits()
                        updateGeneratedScript()
                        finalSlateScriptToRecord = generatedSlateScript
                        showingBriefing = true
                    }
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Colors.accent)
                }

                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        dismissActiveKeyboard()
                    }
                }
            }
            .onAppear {
                loadProfileDefaults()
            }
            .onChange(of: draft) { _, _ in
                updateGeneratedScript()
            }
            .sheet(isPresented: $showingBriefing, onDismiss: {
                guard let script = pendingSlateScript else { return }
                pendingSlateScript = nil
                slateRecorderRoute = SlateRecorderRoute(script: script)
            }) {
                TalkToOneTakeBriefingView(
                    audition: audition,
                    isSlate: true,
                    scriptPreview: finalSlateScriptToRecord
                ) { updatedScript in
                    finalSlateScriptToRecord = updatedScript
                    pendingSlateScript = updatedScript
                    showingBriefing = false
                }
            }
            .fullScreenCover(item: $slateRecorderRoute, onDismiss: {
                if returnToBriefingAfterRecorder {
                    returnToBriefingAfterRecorder = false
                    showingBriefing = true
                }
            }) { route in
                TeleprompterRecorderView(
                    audition: audition,
                    modeTitle: "Slate Video",
                    scriptLines: [route.script],
                    isSlate: true,
                    onTakeSaved: { savedTake in
                        returnToBriefingAfterRecorder = false
                        slateRecorderRoute = nil
                        var normalizedTake = savedTake
                        normalizedTake.filePath = MediaStorage.storedRelativePath(for: savedTake.filePath)
                        audition.slateTakes.append(normalizedTake)
                        audition.selectedSlateTakeID = normalizedTake.id
                        if let idx = audition.requirements.firstIndex(where: { $0.title.lowercased().contains("slate") }) {
                            audition.requirements[idx].isCompleted = true
                        }
                        appState.saveChanges()
                        onSlateSaved()
                        dismiss()
                    },
                    onRecorderCancelled: {
                        returnToBriefingAfterRecorder = true
                    }
                )
            }
        }
    }

    private func persistProfileEdits() {
        if let user = appState.currentUser {
            user.name = draft.trimmedName
            user.height = draft.formattedHeight
            user.age = draft.age
            user.basedIn = draft.trimmedBasedIn
            user.representation = draft.resolvedRepresentation
            user.previousWork = []
        } else {
            let profile = UserProfile(
                name: draft.trimmedName,
                height: draft.formattedHeight,
                age: draft.age,
                basedIn: draft.trimmedBasedIn,
                representation: draft.resolvedRepresentation,
                previousWork: []
            )
            appState.modelContext?.insert(profile)
            appState.currentUser = profile
        }
        appState.saveChanges()
    }

    // MARK: - Defaults & Script Generator

    private func loadProfileDefaults() {
        if let user = appState.currentUser {
            draft = PersonalDetailsDraft(user: user)
        } else {
            draft = PersonalDetailsDraft()
        }
        updateGeneratedScript()
    }

    private func updateGeneratedScript() {
        generatedSlateScript = SlateScriptTemplate.build(
            name: draft.trimmedName,
            height: draft.formattedHeight,
            age: draft.ageString,
            basedIn: draft.trimmedBasedIn,
            representation: draft.resolvedRepresentation,
            previousWork: [],
            roleName: audition.roleName,
            projectName: audition.projectName
        )
    }
}
