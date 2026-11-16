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

        var parts: [String] = []
        parts.append("Hi, my name is \(trimmedName.isEmpty ? "your name" : trimmedName).")

        if !trimmedHeight.isEmpty {
            parts.append("I am \(trimmedHeight) tall.")
        }
        if !trimmedAge.isEmpty, trimmedAge != "0" {
            parts.append("I am \(trimmedAge) years old.")
        }
        if !trimmedBasedIn.isEmpty {
            parts.append("I am based in \(trimmedBasedIn).")
        }
        if !trimmedRep.isEmpty {
            parts.append("I am represented by \(trimmedRep).")
        }

        let role = trimmedRole.isEmpty ? "this role" : trimmedRole
        let project = trimmedProject.isEmpty ? "this project" : trimmedProject
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

    @State private var actorName: String = ""
    @State private var height: String = ""
    @State private var age: String = ""
    @State private var basedIn: String = ""
    @State private var representation: String = ""
    @State private var previousWorkTags: [String] = []
    @State private var generatedSlateScript: String = ""

    // Editing modal state
    @State private var editingField: SlateField? = nil
    @State private var editBuffer: String = ""

    // Flow navigation
    @State private var showingBriefing = false
    @State private var pendingSlateScript: String?
    @State private var slateRecorderRoute: SlateRecorderRoute?
    @State private var returnToBriefingAfterRecorder = false
    @State private var finalSlateScriptToRecord = ""

    enum SlateField: String, Identifiable {
        case name = "Name"
        case height = "Height"
        case age = "Age"
        case basedIn = "Based in"
        case representation = "Representation"
        case previousWork = "Previous Work"

        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.canvasBackground
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("How casting meets you")
                                .font(.system(size: 26, weight: .bold))
                                .foregroundStyle(Theme.Colors.textPrimary)

                            Text("Review your slate details before rolling camera.")
                                .font(.system(size: 14, weight: .regular))
                                .foregroundStyle(Theme.Colors.textSecondary)
                        }
                        .padding(.top, 12)
                        .padding(.horizontal, 4)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("SLATE PREVIEW")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Theme.Colors.textSecondary)
                                .padding(.horizontal, 4)

                            VStack(spacing: 0) {
                                slatePreviewRow(
                                    value: actorName.isEmpty ? "Add your name" : actorName,
                                    label: "Name",
                                    field: .name,
                                    isDimmedValue: actorName.isEmpty
                                )
                                Divider().padding(.horizontal, 16)

                                slatePreviewRow(
                                    value: height.isEmpty ? "Add height" : height,
                                    label: "height",
                                    field: .height,
                                    isDimmedValue: height.isEmpty
                                )
                                Divider().padding(.horizontal, 16)

                                slatePreviewRow(
                                    value: age.isEmpty ? "Add age" : age,
                                    label: "age",
                                    field: .age,
                                    isDimmedValue: age.isEmpty
                                )
                                Divider().padding(.horizontal, 16)

                                slatePreviewRow(
                                    value: basedIn.isEmpty ? "Add city" : basedIn,
                                    label: "based in",
                                    field: .basedIn,
                                    isDimmedValue: basedIn.isEmpty
                                )
                                Divider().padding(.horizontal, 16)

                                slatePreviewRow(
                                    value: representation.isEmpty ? "Self-represented" : representation,
                                    label: "representation",
                                    field: .representation,
                                    isDimmedValue: representation.isEmpty
                                )
                                Divider().padding(.horizontal, 16)

                                slatePreviewRow(
                                    value: previousWorkTags.isEmpty ? "Previous Experience" : previousWorkTags.joined(separator: ", "),
                                    label: "Add",
                                    field: .previousWork,
                                    isDimmedValue: previousWorkTags.isEmpty
                                )
                            }
                            .background(Theme.Colors.cardSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .shadow(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 2)
                        }

                        Spacer(minLength: 40)

                        Button {
                            updateGeneratedScript()
                            finalSlateScriptToRecord = generatedSlateScript
                            showingBriefing = true
                        } label: {
                            Text("Continue")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.Colors.onAction)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Theme.Colors.primaryPlum)
                                .clipShape(Capsule())
                        }
                        .padding(.bottom, 24)
                    }
                    .padding(.horizontal, 20)
                }
            }
            .navigationTitle("Slate Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear {
                loadProfileDefaults()
            }
            .sheet(item: $editingField) { field in
                editFieldSheet(for: field)
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

    // MARK: - Slate Preview Row

    private func slatePreviewRow(
        value: String,
        label: String,
        field: SlateField,
        isDimmedValue: Bool = false
    ) -> some View {
        Button {
            editBuffer = initialEditValue(for: field)
            editingField = field
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Text(value)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(isDimmedValue ? Theme.Colors.textSecondary : Theme.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Spacer()

                Text(label)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Theme.Colors.textSecondary)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textSecondary.opacity(0.4))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func initialEditValue(for field: SlateField) -> String {
        switch field {
        case .name: return actorName
        case .height: return height
        case .age: return age
        case .basedIn: return basedIn
        case .representation: return representation
        case .previousWork: return previousWorkTags.joined(separator: ", ")
        }
    }

    // MARK: - Edit Field Sheet

    private func editFieldSheet(for field: SlateField) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text("Edit \(field.rawValue)")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.Colors.textPrimary)

                TextField(field.rawValue, text: $editBuffer)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .keyboardType(field == .age ? .numberPad : .default)
                    .padding(14)
                    .background(Theme.Colors.controlSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.Colors.controlBorder, lineWidth: 1))

                Spacer()

                Button {
                    commitEdit(for: field)
                    editingField = nil
                } label: {
                    Text("Save")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.Colors.onAction)
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
                    Button("Cancel") { editingField = nil }
                }
            }
        }
        .presentationDetents([.height(240)])
    }

    private func commitEdit(for field: SlateField) {
        let trimmed = editBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch field {
        case .name:
            actorName = trimmed
        case .height:
            height = trimmed
        case .age:
            age = trimmed
        case .basedIn:
            basedIn = trimmed
        case .representation:
            representation = trimmed
        case .previousWork:
            if trimmed.isEmpty {
                previousWorkTags = []
            } else {
                previousWorkTags = trimmed
                    .components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        }
        persistProfileEdits()
        updateGeneratedScript()
    }

    private func persistProfileEdits() {
        let parsedAge = Int(age.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        if let user = appState.currentUser {
            user.name = actorName
            user.height = height
            user.age = parsedAge
            user.basedIn = basedIn
            user.representation = representation.isEmpty ? "Self-represented" : representation
            user.previousWork = previousWorkTags
        } else {
            let profile = UserProfile(
                name: actorName,
                height: height,
                age: parsedAge,
                basedIn: basedIn,
                representation: representation.isEmpty ? "Self-represented" : representation,
                previousWork: previousWorkTags
            )
            appState.modelContext?.insert(profile)
            appState.currentUser = profile
        }
        appState.saveChanges()
    }

    // MARK: - Defaults & Script Generator

    private func loadProfileDefaults() {
        if let user = appState.currentUser {
            actorName = user.name
            height = user.height
            age = user.age > 0 ? "\(user.age)" : ""
            basedIn = user.basedIn
            representation = user.representation
            previousWorkTags = user.previousWork
        } else {
            actorName = ""
            height = ""
            age = ""
            basedIn = ""
            representation = "Self-represented"
            previousWorkTags = []
        }
        updateGeneratedScript()
    }

    private func updateGeneratedScript() {
        generatedSlateScript = SlateScriptTemplate.build(
            name: actorName,
            height: height,
            age: age,
            basedIn: basedIn,
            representation: representation,
            previousWork: previousWorkTags,
            roleName: audition.roleName,
            projectName: audition.projectName
        )
    }
}
