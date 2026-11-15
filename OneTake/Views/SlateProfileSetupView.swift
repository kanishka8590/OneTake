import SwiftUI
import PhotosUI
import AVFoundation

struct SlateProfileSetupView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @Bindable var audition: Audition
    let onSlateSaved: () -> Void

    @State private var actorName: String = ""
    @State private var height: String = ""
    @State private var age: String = ""
    @State private var basedIn: String = ""
    @State private var previousWorkTags: [String] = []
    @State private var newWorkTag: String = ""
    @State private var generatedSlateScript: String = ""

    // Editing modal state
    @State private var editingField: SlateField? = nil
    @State private var editBuffer: String = ""

    // Flow navigation
    @State private var showingBriefing = false
    @State private var showingTeleprompter = false
    @State private var returnToBriefingAfterRecorder = false
    @State private var finalSlateScriptToRecord = ""

    enum SlateField: String, Identifiable {
        case name = "Name"
        case height = "Height"
        case age = "Age"
        case basedIn = "Based in"
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
                        // Header
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

                        // SLATE PREVIEW White Card Layout
                        VStack(alignment: .leading, spacing: 8) {
                            Text("SLATE PREVIEW")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Theme.Colors.textSecondary)
                                .padding(.horizontal, 4)

                            VStack(spacing: 0) {
                                slatePreviewRow(
                                    value: actorName.isEmpty ? "Your Name" : actorName,
                                    label: "Name",
                                    field: .name
                                )
                                Divider().padding(.horizontal, 16)

                                slatePreviewRow(
                                    value: height.isEmpty ? "5'8\"" : height,
                                    label: "height",
                                    field: .height
                                )
                                Divider().padding(.horizontal, 16)

                                slatePreviewRow(
                                    value: age.isEmpty ? "25" : age,
                                    label: "age",
                                    field: .age
                                )
                                Divider().padding(.horizontal, 16)

                                slatePreviewRow(
                                    value: basedIn.isEmpty ? "Mumbai" : basedIn,
                                    label: "based in",
                                    field: .basedIn
                                )
                                Divider().padding(.horizontal, 16)

                                slatePreviewRow(
                                    value: previousWorkTags.isEmpty ? "Leave blank if none" : previousWorkTags.joined(separator: ", "),
                                    label: "Add",
                                    field: .previousWork,
                                    isDimmedValue: previousWorkTags.isEmpty
                                )
                            }
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .shadow(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 2)
                        }

                        Spacer(minLength: 40)

                        // Dark Plum Continue Button
                        Button {
                            updateGeneratedScript()
                            finalSlateScriptToRecord = generatedSlateScript
                            showingBriefing = true
                        } label: {
                            Text("Continue")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.white)
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
            .sheet(isPresented: $showingBriefing) {
                TalkToOneTakeBriefingView(
                    audition: audition,
                    isSlate: true,
                    scriptPreview: finalSlateScriptToRecord
                ) { updatedScript in
                    showingBriefing = false
                    finalSlateScriptToRecord = updatedScript
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        showingTeleprompter = true
                    }
                }
            }
            .fullScreenCover(isPresented: $showingTeleprompter, onDismiss: {
                if returnToBriefingAfterRecorder {
                    returnToBriefingAfterRecorder = false
                    showingBriefing = true
                }
            }) {
                TeleprompterRecorderView(
                    audition: audition,
                    modeTitle: "Slate Video",
                    scriptLines: [finalSlateScriptToRecord],
                    isSlate: true,
                    onTakeSaved: { savedTake in
                        returnToBriefingAfterRecorder = false
                        showingTeleprompter = false
                        audition.slateTakes.append(savedTake)
                        audition.selectedSlateTakeID = savedTake.id
                        if let idx = audition.requirements.firstIndex(where: { $0.title.lowercased().contains("slate") }) {
                            audition.requirements[idx].isCompleted = true
                        }
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
    // Large bold value on left, subtle right-aligned gray label on right

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
                    .padding(14)
                    .background(Theme.Colors.lavenderSurface.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                Spacer()

                Button {
                    commitEdit(for: field)
                    editingField = nil
                } label: {
                    Text("Save")
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
                    Button("Cancel") { editingField = nil }
                }
            }
        }
        .presentationDetents([.height(240)])
    }

    private func commitEdit(for field: SlateField) {
        let trimmed = editBuffer.trimmingCharacters(in: .whitespaces)
        switch field {
        case .name:
            actorName = trimmed
        case .height:
            height = trimmed
        case .age:
            age = trimmed
        case .basedIn:
            basedIn = trimmed
        case .previousWork:
            if trimmed.isEmpty {
                previousWorkTags = []
            } else {
                previousWorkTags = trimmed.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
        }
        updateGeneratedScript()
    }

    // MARK: - Defaults & Script Generator

    private func loadProfileDefaults() {
        if let user = appState.currentUser {
            actorName = user.name
            height = user.height
            age = user.age > 0 ? "\(user.age)" : ""
            basedIn = user.basedIn
            previousWorkTags = user.previousWork
        } else {
            actorName = "Alex Morgan"
            height = "5'8\""
            age = "25"
            basedIn = "Mumbai"
        }
        updateGeneratedScript()
    }

    private func updateGeneratedScript() {
        var parts: [String] = []
        let name = actorName.isEmpty ? "Alex Morgan" : actorName
        parts.append("Hi, my name is \(name).")

        if !height.isEmpty {
            parts.append("I am \(height) tall.")
        }
        if !age.isEmpty {
            parts.append("I am \(age) years old.")
        }
        if !basedIn.isEmpty {
            parts.append("I am based in \(basedIn).")
        }

        let role = audition.roleName.isEmpty ? "this role" : audition.roleName
        let project = audition.projectName.isEmpty ? "your project" : audition.projectName
        parts.append("Today I am reading for the role of \(role) in \(project).")

        if !previousWorkTags.isEmpty {
            let creds = previousWorkTags.prefix(2).joined(separator: " and ")
            parts.append("Recently, you may have seen my work in \(creds).")
        }

        parts.append("Thank you for your time, and here is my audition.")
        generatedSlateScript = parts.joined(separator: " ")
    }
}
