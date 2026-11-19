import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers

enum ActiveEditorSheet: Identifiable {
    case projectName
    case roleName
    case deadline
    case recipientEmail
    case requirements
    case attachSides

    var id: Int { hashValue }
}

private enum PendingSidesSource {
    case photo
    case scan
    case file
    case paste
}

private struct EditorSnapshot: Equatable {
    var projectName: String
    var productionType: ProductionType
    var roleName: String
    var roleDescription: String
    var hasDeadline: Bool
    var deadline: Date
    var reminderOffsetMinutes: Int
    var recipientEmail: String
    var requirements: [SubmissionRequirement]
    var scriptText: String
    var scriptFileName: String?
    var cueLines: [CueLine]
}

struct AuditionDetailsEditorView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var parsedCall: ParsedCastingCall? = nil
    var existingAudition: Audition? = nil
    var onSaved: ((Audition) -> Void)?

    @State private var activeSheet: ActiveEditorSheet?
    @State private var pendingSidesSource: PendingSidesSource?
    @State private var initialSnapshot: EditorSnapshot?
    @State private var hasInitialized = false

    // Editable properties
    @State private var projectName: String = ""
    @State private var productionType: ProductionType = .featureFilm
    @State private var roleName: String = ""
    @State private var roleDescription: String = ""
    @State private var hasDeadline: Bool = false
    @State private var deadline: Date = AuditionDetailsEditorView.defaultDeadlineDate()
    @State private var reminderOffsetMinutes: Int = 60
    @State private var recipientEmail: String = ""
    @State private var requirements: [SubmissionRequirement] = []
    @State private var scriptText: String = ""
    @State private var scriptFileName: String? = nil
    @State private var cueLines: [CueLine] = []

    // Sub-sheet draft buffers (committed only on Done)
    @State private var draftProjectName: String = ""
    @State private var draftRoleName: String = ""
    @State private var draftRoleDescription: String = ""
    @State private var draftHasDeadline: Bool = false
    @State private var draftDeadline: Date = AuditionDetailsEditorView.defaultDeadlineDate()
    @State private var draftDeadlineText: String = ""
    @State private var lastParsedFromTyping: Date? = nil
    @FocusState private var isDeadlineFieldFocused: Bool
    @State private var draftReminderOffsetMinutes: Int = 60
    @State private var draftRecipientEmail: String = ""
    @State private var draftRequirements: [SubmissionRequirement] = []
    @State private var newRequirementTitle = ""

    // Importer states for Script Sides (supports multi-photo and multi-file)
    @State private var selectedSidesPhotoItems: [PhotosPickerItem] = []
    @State private var showingSidesPhotoPicker = false
    @State private var showingDocumentScanner = false
    @State private var pendingScannedSidesImages: [UIImage] = []
    @State private var showingFileImporter = false
    @State private var showingPasteEditor = false
    @State private var pastedScriptBuffer = ""
    @State private var isProcessingSides = false

    // Alerts & confirmations
    @State private var validationErrorMessage: String?
    @State private var showingValidationAlert = false
    @State private var showingPastDeadlineAlert = false
    @State private var importErrorMessage: String?
    @State private var showingImportError = false
    @State private var showingDiscardConfirmation = false

    private var isEditingExisting: Bool {
        existingAudition != nil
    }

    private var currentSnapshot: EditorSnapshot {
        EditorSnapshot(
            projectName: projectName,
            productionType: productionType,
            roleName: roleName,
            roleDescription: roleDescription,
            hasDeadline: hasDeadline,
            deadline: deadline,
            reminderOffsetMinutes: reminderOffsetMinutes,
            recipientEmail: recipientEmail,
            requirements: requirements,
            scriptText: scriptText,
            scriptFileName: scriptFileName,
            cueLines: cueLines
        )
    }

    private var hasUnsavedChanges: Bool {
        guard let initialSnapshot else { return false }
        return currentSnapshot != initialSnapshot
    }

    private var isProjectNameValid: Bool {
        !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isRoleNameValid: Bool {
        !roleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isRecipientEmailValid: Bool {
        let trimmed = recipientEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let pattern = #"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#
        return trimmed.range(of: pattern, options: .regularExpression) != nil
    }

    private var isDeadlineInPast: Bool {
        hasDeadline && deadline < Date()
    }

    private static func defaultDeadlineDate() -> Date {
        let threeDays = Calendar.current.date(byAdding: .day, value: 3, to: Date()) ?? Date()
        return Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: threeDays) ?? threeDays
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.canvasBackground
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        headerCard

                        // Section 1: Audition & Production Info
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Audition Information")
                                .font(Theme.Typography.sectionHeader)
                                .foregroundStyle(Theme.Colors.textPrimary)
                                .padding(.horizontal, 4)

                            VStack(spacing: 0) {
                                editableRow(
                                    title: "Project Name",
                                    value: isProjectNameValid ? projectName : "Required — tap to add",
                                    icon: "film",
                                    isWarning: !isProjectNameValid
                                ) {
                                    openSheet(.projectName)
                                }

                                Divider().padding(.leading, 44)

                                editableRow(
                                    title: "Role & Character",
                                    value: isRoleNameValid ? roleName : "Required — tap to add",
                                    icon: "person.text.rectangle",
                                    isWarning: !isRoleNameValid
                                ) {
                                    openSheet(.roleName)
                                }

                                Divider().padding(.leading, 44)

                                HStack {
                                    Image(systemName: "tag")
                                        .font(.system(size: 16))
                                        .foregroundStyle(Theme.Colors.accent)
                                        .frame(width: 28)

                                    Text("Production Type")
                                        .font(Theme.Typography.bodyRegular)
                                        .foregroundStyle(Theme.Colors.textPrimary)

                                    Spacer()

                                    Picker("", selection: $productionType) {
                                        ForEach(ProductionType.allCases, id: \.self) { type in
                                            Text(type.rawValue).tag(type)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .tint(Theme.Colors.accent)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                            }
                            .cardStyle()
                        }

                        // Section 2: Deadline & Casting Email
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Submission Deadlines")
                                .font(Theme.Typography.sectionHeader)
                                .foregroundStyle(Theme.Colors.textPrimary)
                                .padding(.horizontal, 4)

                            VStack(spacing: 0) {
                                editableRow(
                                    title: "Deadline & Reminder",
                                    value: hasDeadline ? deadline.formatted(date: .abbreviated, time: .shortened) : "Not specified (add deadline)",
                                    icon: "calendar.badge.clock",
                                    isWarning: isDeadlineInPast
                                ) {
                                    openSheet(.deadline)
                                }

                                if isDeadlineInPast {
                                    HStack(spacing: 6) {
                                        Image(systemName: "exclamationmark.triangle")
                                            .font(.system(size: 12))
                                            .foregroundStyle(Theme.Colors.warningAmber)
                                        Text("This deadline is in the past. Local reminders will not fire.")
                                            .font(.system(size: 12))
                                            .foregroundStyle(Theme.Colors.warningAmber)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 10)
                                }

                                Divider().padding(.leading, 44)

                                editableRow(
                                    title: "Recipient Email",
                                    value: recipientEmail.isEmpty ? "Not specified (add email)" : recipientEmail,
                                    icon: "envelope",
                                    isWarning: !isRecipientEmailValid
                                ) {
                                    openSheet(.recipientEmail)
                                }

                                if !isRecipientEmailValid {
                                    HStack(spacing: 6) {
                                        Image(systemName: "exclamationmark.circle")
                                            .font(.system(size: 12))
                                            .foregroundStyle(Theme.Colors.errorCrimson)
                                        Text("Please enter a valid email address.")
                                            .font(.system(size: 12))
                                            .foregroundStyle(Theme.Colors.errorCrimson)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 10)
                                }
                            }
                            .cardStyle()
                        }

                        // Section 3: Requirements Checklist
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Submission Requirements")
                                    .font(Theme.Typography.sectionHeader)
                                    .foregroundStyle(Theme.Colors.textPrimary)

                                Spacer()

                                Button {
                                    openSheet(.requirements)
                                } label: {
                                    Text("Edit")
                                        .font(Theme.Typography.captionBadge)
                                        .foregroundStyle(Theme.Colors.accent)
                                }
                            }
                            .padding(.horizontal, 4)

                            VStack(alignment: .leading, spacing: 10) {
                                if requirements.isEmpty {
                                    Text("No extra notice requirements.")
                                        .font(Theme.Typography.bodyRegular)
                                        .foregroundStyle(Theme.Colors.textSecondary)
                                        .padding()
                                } else {
                                    ForEach(requirements) { req in
                                        HStack(spacing: 12) {
                                            Image(systemName: req.isCompleted ? "checkmark.circle" : "circle")
                                                .foregroundStyle(req.isCompleted ? Theme.Colors.successGreen : Theme.Colors.textSecondary)

                                            Text(req.title)
                                                .font(Theme.Typography.bodyRegular)
                                                .foregroundStyle(Theme.Colors.textPrimary)

                                            Spacer()
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 8)
                                    }
                                }
                            }
                            .padding(.vertical, 8)
                            .cardStyle()
                        }

                        // Section 4: Script Sides
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Script Sides")
                                    .font(Theme.Typography.sectionHeader)
                                    .foregroundStyle(Theme.Colors.textPrimary)

                                Spacer()

                                if !scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Button {
                                        openSheet(.attachSides)
                                    } label: {
                                        Text("Change Sides")
                                            .font(Theme.Typography.captionBadge)
                                            .foregroundStyle(Theme.Colors.accent)
                                    }
                                }
                            }
                            .padding(.horizontal, 4)

                            if scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                addScriptSidesOptionalCard
                            } else {
                                sidesAttachedCard
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Layout.screenHPadding)
                    .padding(.top, 16)
                    .padding(.bottom, 28)
                }

                if isProcessingSides {
                    ZStack {
                        Color.black.opacity(0.18).ignoresSafeArea()
                        VStack(spacing: 12) {
                            ProgressView()
                                .controlSize(.large)
                                .tint(Theme.Colors.accent)
                            Text("Extracting Sides…")
                                .font(Theme.Typography.sectionHeader)
                                .foregroundStyle(Theme.Colors.textPrimary)
                        }
                        .padding(24)
                        .background(Theme.Colors.cardSurface, in: RoundedRectangle(cornerRadius: 20))
                        .shadow(color: .black.opacity(0.16), radius: 16, y: 6)
                    }
                }
            }
            .navigationTitle(isEditingExisting ? "Edit Audition Details" : "Audition Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if hasUnsavedChanges {
                            showingDiscardConfirmation = true
                        } else {
                            dismiss()
                        }
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        attemptSaveAudition()
                    }
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Colors.accent)
                    .accessibilityLabel(isEditingExisting ? "Save Changes" : "Save the Audition")
                }
            }
            .onAppear {
                if !hasInitialized {
                    initializeValues()
                    hasInitialized = true
                }
            }
            .sheet(item: $activeSheet, onDismiss: triggerPendingSidesSource) { sheet in
                switch sheet {
                case .projectName:
                    editProjectNameSheet
                case .roleName:
                    editRoleNameSheet
                case .deadline:
                    editDeadlineSheet
                case .recipientEmail:
                    editRecipientEmailSheet
                case .requirements:
                    editRequirementsSheet
                case .attachSides:
                    attachSidesSheet
                }
            }
            .photosPicker(
                isPresented: $showingSidesPhotoPicker,
                selection: $selectedSidesPhotoItems,
                maxSelectionCount: 10,
                matching: .images
            )
            .onChange(of: selectedSidesPhotoItems) { _, items in
                guard !items.isEmpty else { return }
                let toProcess = items
                selectedSidesPhotoItems = []
                loadSidesPhotos(toProcess)
            }
            .sheet(isPresented: $showingDocumentScanner, onDismiss: processPendingSidesScannedImages) {
                DocumentScannerRepresentable { images in
                    pendingScannedSidesImages = images
                    showingDocumentScanner = false
                } onCancel: {
                    pendingScannedSidesImages = []
                    showingDocumentScanner = false
                } onError: { error in
                    pendingScannedSidesImages = []
                    showingDocumentScanner = false
                    presentImportError(error.localizedDescription)
                }
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.pdf, .plainText, .data],
                allowsMultipleSelection: true
            ) { result in
                handleSidesFileImport(result)
            }
            .sheet(isPresented: $showingPasteEditor) {
                pasteSidesEditorSheet
            }
            .alert("Cannot Save Audition", isPresented: $showingValidationAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(validationErrorMessage ?? "Please check the required fields.")
            }
            .alert("Deadline Is in the Past", isPresented: $showingPastDeadlineAlert) {
                Button("Edit Deadline", role: .cancel) {
                    openSheet(.deadline)
                }
                Button("Save Anyway") {
                    commitSaveAudition()
                }
            } message: {
                Text("The submission deadline has already passed, so deadline reminders will not be scheduled. Save anyway?")
            }
            .alert("Sides Import Failed", isPresented: $showingImportError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importErrorMessage ?? "Unable to extract script sides from the selected source.")
            }
            .confirmationDialog(
                "Discard Unsaved Changes?",
                isPresented: $showingDiscardConfirmation,
                titleVisibility: .visible
            ) {
                Button("Discard Changes", role: .destructive) {
                    dismiss()
                }
                Button("Keep Editing", role: .cancel) {}
            } message: {
                Text("Your edits to this audition haven't been saved yet.")
            }
            .presentationDragIndicator(.visible)
            .presentationBackground(Theme.Colors.canvasBackground)
        }
    }

    // MARK: - Initializer & Sheet Routing

    private func initializeValues() {
        if let existing = existingAudition {
            projectName = existing.projectName
            productionType = existing.production
            roleName = existing.roleName
            roleDescription = existing.roleDescription
            hasDeadline = existing.hasDeadline
            deadline = existing.hasDeadline ? existing.deadline : Self.defaultDeadlineDate()
            reminderOffsetMinutes = existing.reminderOffsetMinutes
            recipientEmail = existing.recipientEmail
            requirements = existing.requirements
            scriptText = existing.scriptText ?? ""
            scriptFileName = existing.scriptFileName
            cueLines = existing.cueLines
        } else if let call = parsedCall {
            projectName = call.projectName
            productionType = call.productionType
            roleName = call.roleName
            roleDescription = call.roleDescription
            hasDeadline = call.hasDetectedDeadline
            deadline = call.hasDetectedDeadline ? call.deadline : Self.defaultDeadlineDate()
            recipientEmail = call.recipientEmail
            requirements = call.requirements
            if let script = call.detectedScriptText, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                scriptText = script
                scriptFileName = "Extracted Sides"
                cueLines = call.cueLines
            } else {
                scriptText = ""
                scriptFileName = nil
                cueLines = []
            }
        } else {
            hasDeadline = false
            deadline = Self.defaultDeadlineDate()
        }
        initialSnapshot = currentSnapshot
    }

    private func openSheet(_ sheet: ActiveEditorSheet) {
        switch sheet {
        case .projectName:
            draftProjectName = projectName
        case .roleName:
            draftRoleName = roleName
            draftRoleDescription = roleDescription
        case .deadline:
            draftHasDeadline = hasDeadline
            draftDeadline = hasDeadline ? deadline : Self.defaultDeadlineDate()
            draftDeadlineText = hasDeadline ? draftDeadline.formatted(date: .abbreviated, time: .shortened) : ""
            lastParsedFromTyping = nil
            draftReminderOffsetMinutes = reminderOffsetMinutes
        case .recipientEmail:
            draftRecipientEmail = recipientEmail
        case .requirements:
            draftRequirements = requirements
            newRequirementTitle = ""
        case .attachSides:
            break
        }
        activeSheet = sheet
    }

    private func triggerPendingSidesSource() {
        guard let source = pendingSidesSource else { return }
        pendingSidesSource = nil
        switch source {
        case .photo:
            showingSidesPhotoPicker = true
        case .scan:
            showingDocumentScanner = true
        case .file:
            showingFileImporter = true
        case .paste:
            pastedScriptBuffer = scriptText
            showingPasteEditor = true
        }
    }

    // MARK: - Header Card

    private var headerCard: some View {
        HStack(spacing: 14) {
            Image(systemName: isEditingExisting ? "pencil.circle" : "sparkles")
                .font(.system(size: 24))
                .foregroundStyle(Theme.Colors.accent)
                .frame(width: 48, height: 48)
                .background(Theme.Colors.lavenderSurface)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(isEditingExisting ? "Edit Saved Audition" : "Extracted from Notice")
                    .font(Theme.Typography.captionBadge)
                    .foregroundStyle(Theme.Colors.accent)

                Text(isEditingExisting ? "Update casting call info, requirements, or script sides." : "Verify & customize your breakdown before starting.")
                    .font(Theme.Typography.bodyRegular)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            Spacer()
        }
        .padding(14)
        .cardStyle()
    }

    // MARK: - "Add Script Sides (Optional)" Card

    private var addScriptSidesOptionalCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .foregroundStyle(Theme.Colors.accent)
                        .font(.system(size: 16))

                    Text("Add Script Sides (Optional)")
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.Colors.textPrimary)
                }

                Text("Attach dialogue sides for teleprompter scrolling & audio scene partner cues, or skip to capture freeform.")
                    .font(Theme.Typography.captionBadge)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }

            HStack(spacing: 0) {
                sidesImportOptionButton(title: "Photo", systemImage: "photo") {
                    showingSidesPhotoPicker = true
                }

                Spacer()

                sidesImportOptionButton(title: "Scan", systemImage: "doc.viewfinder") {
                    showingDocumentScanner = true
                }

                Spacer()

                sidesImportOptionButton(title: "File", systemImage: "folder") {
                    showingFileImporter = true
                }

                Spacer()

                sidesImportOptionButton(title: "Type it", systemImage: "keyboard") {
                    pastedScriptBuffer = ""
                    showingPasteEditor = true
                }
            }
            .padding(.top, 4)
            .padding(.horizontal, 4)
        }
        .padding(16)
        .cardStyle()
    }

    private func sidesImportOptionButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(Theme.Colors.lavenderSurface)
                        .frame(width: 48, height: 48)

                    Image(systemName: systemImage)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.Colors.accent)
                }

                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Colors.textPrimary)
            }
            .frame(minWidth: 58)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sides Attached Card

    private var sidesAttachedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .foregroundStyle(Theme.Colors.accent)
                    .font(.system(size: 18))

                Text(scriptFileName ?? "Sides Attached")
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1)

                Spacer()

                if !cueLines.isEmpty {
                    Text("\(cueLines.count) Cues")
                        .statusBadge(color: Theme.Colors.accent)
                }
            }

            Text(scriptText)
                .font(Theme.Typography.bodyRegular)
                .foregroundStyle(Theme.Colors.textSecondary)
                .lineLimit(4)

            Divider()

            HStack {
                Button {
                    openSheet(.attachSides)
                } label: {
                    Label("Change Sides", systemImage: "arrow.triangle.2.circlepath")
                        .font(Theme.Typography.captionBadge)
                        .foregroundStyle(Theme.Colors.accent)
                }

                Spacer()

                Button(role: .destructive) {
                    withAnimation {
                        scriptText = ""
                        scriptFileName = nil
                        cueLines = []
                    }
                } label: {
                    Label("Remove", systemImage: "trash")
                        .font(Theme.Typography.captionBadge)
                        .foregroundStyle(Theme.Colors.errorCrimson)
                }
            }
        }
        .padding(16)
        .cardStyle()
    }

    @ViewBuilder
    private func editableRow(
        title: String,
        value: String,
        icon: String,
        isWarning: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(isWarning ? Theme.Colors.warningAmber : Theme.Colors.accent)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.Typography.captionBadge)
                        .foregroundStyle(Theme.Colors.textSecondary)

                    Text(value)
                        .font(Theme.Typography.bodyRegular)
                        .foregroundStyle(isWarning ? Theme.Colors.errorCrimson : Theme.Colors.textPrimary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textSecondary.opacity(0.6))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: Theme.Layout.minTapTarget)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Validation & Save Action

    private func attemptSaveAudition() {
        if !isProjectNameValid {
            validationErrorMessage = "Please enter a project name before saving."
            showingValidationAlert = true
            return
        }
        if !isRoleNameValid {
            validationErrorMessage = "Please enter a role or character name before saving."
            showingValidationAlert = true
            return
        }
        if !isRecipientEmailValid {
            validationErrorMessage = "The recipient email address does not appear to be valid."
            showingValidationAlert = true
            return
        }
        if isDeadlineInPast {
            showingPastDeadlineAlert = true
            return
        }
        commitSaveAudition()
    }

    private func commitSaveAudition() {
        let trimmedProject = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRole = roleName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRoleDesc = roleDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = recipientEmail.trimmingCharacters(in: .whitespacesAndNewlines)

        let rules = existingAudition?.validationRules ?? ValidationRules(
            isFromNotice: true,
            requiredHeadshotRatio: parsedCall?.requiredHeadshotRatio ?? .ratio4x5,
            maxSlateSeconds: parsedCall?.maxSlateSeconds ?? 45.0,
            maxClipSeconds: parsedCall?.maxClipSeconds ?? 180.0,
            requiredPortrait: nil,
            fileNamePattern: "\(trimmedRole.replacingOccurrences(of: " ", with: "_"))_Audition",
            maxPerClipSizeMB: parsedCall?.maxPerClipSizeMB ?? 100.0
        )

        let cleanScriptText = scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : scriptText

        if let existing = existingAudition {
            cleanupOrphanedCueAudio(previousCues: existing.cueLines, newCues: cueLines)

            existing.projectName = trimmedProject
            existing.production = productionType
            existing.roleName = trimmedRole
            existing.roleDescription = trimmedRoleDesc
            existing.deadline = deadline
            existing.hasDeadline = hasDeadline
            existing.reminderOffsetMinutes = reminderOffsetMinutes
            existing.recipientEmail = trimmedEmail
            existing.requirements = requirements
            existing.scriptText = cleanScriptText
            existing.scriptFileName = cleanScriptText == nil ? nil : scriptFileName
            existing.cueLines = cueLines
            existing.validationRules = rules

            appState.saveChanges()
            AuditionReminderService.reschedule(
                auditions: appState.auditions,
                notifyAuditions: appState.settings.notifyAuditions,
                notifySubmissions: appState.settings.notifySubmissions,
                notifyPractice: appState.settings.notifyPractice,
                practiceScripts: appState.practiceScripts
            )
            onSaved?(existing)
            dismiss()
        } else {
            let audition = Audition(
                projectName: trimmedProject,
                productionType: productionType.rawValue,
                roleName: trimmedRole,
                roleDescription: trimmedRoleDesc,
                deadline: deadline,
                hasDeadline: hasDeadline,
                reminderOffsetMinutes: reminderOffsetMinutes,
                recipientEmail: trimmedEmail,
                requirements: requirements,
                scriptText: cleanScriptText,
                scriptFileName: cleanScriptText == nil ? nil : scriptFileName,
                cueLines: cueLines,
                validationRules: rules
            )

            appState.addAudition(audition)
            AuditionReminderService.reschedule(
                auditions: appState.auditions,
                notifyAuditions: appState.settings.notifyAuditions,
                notifySubmissions: appState.settings.notifySubmissions,
                notifyPractice: appState.settings.notifyPractice,
                practiceScripts: appState.practiceScripts
            )
            onSaved?(audition)
            dismiss()
        }
    }

    private func cleanupOrphanedCueAudio(previousCues: [CueLine], newCues: [CueLine]) {
        let keptPaths = Set(newCues.compactMap { cue -> String? in
            guard let path = cue.audioFilePath else { return nil }
            return MediaStorage.storedRelativePath(for: path)
        })
        for oldCue in previousCues {
            guard let path = oldCue.audioFilePath else { continue }
            let normalized = MediaStorage.storedRelativePath(for: path)
            if !keptPaths.contains(normalized) {
                MediaStorage.removeFile(at: path)
            }
        }
    }

    // MARK: - Process Sides Imports

    private func loadSidesPhotos(_ items: [PhotosPickerItem]) {
        isProcessingSides = true
        let fallbackRole = roleName.isEmpty ? "ACTOR" : roleName

        Task {
            do {
                var images: [UIImage] = []
                for item in items {
                    if let data = try await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        images.append(image)
                    }
                }

                guard !images.isEmpty else {
                    await MainActor.run {
                        self.isProcessingSides = false
                        self.presentImportError("Could not load any images from the selected photos.")
                    }
                    return
                }

                var combinedText = ""
                for img in images {
                    let txt = try await CastingCallParserService.shared.extractRawText(from: img)
                    let trimmed = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        combinedText += (combinedText.isEmpty ? "" : "\n\n") + trimmed
                    }
                }

                let parsed = CastingCallParserService.shared.parseSidesText(combinedText, defaultRole: fallbackRole)
                await MainActor.run {
                    self.isProcessingSides = false
                    guard !parsed.scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        self.presentImportError("No readable script text was found in the selected photos. Existing sides were kept unchanged.")
                        return
                    }
                    self.scriptText = parsed.scriptText
                    self.scriptFileName = items.count > 1 ? "\(items.count) Sides Photos" : "Sides Photo"
                    self.cueLines = parsed.cueLines
                }
            } catch {
                await MainActor.run {
                    self.isProcessingSides = false
                    self.presentImportError(error.localizedDescription)
                }
            }
        }
    }

    private func processPendingSidesScannedImages() {
        let images = pendingScannedSidesImages
        pendingScannedSidesImages = []
        guard !images.isEmpty else { return }
        processSidesScannedImages(images)
    }

    private func processSidesScannedImages(_ images: [UIImage]) {
        isProcessingSides = true
        let fallbackRole = roleName.isEmpty ? "ACTOR" : roleName

        Task {
            do {
                var combinedText = ""
                for img in images {
                    let txt = try await CastingCallParserService.shared.extractRawText(from: img)
                    let trimmed = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        combinedText += (combinedText.isEmpty ? "" : "\n\n") + trimmed
                    }
                }

                let parsed = CastingCallParserService.shared.parseSidesText(combinedText, defaultRole: fallbackRole)
                await MainActor.run {
                    self.isProcessingSides = false
                    guard !parsed.scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        self.presentImportError("No readable text was detected in the scanned pages. Existing sides were kept unchanged.")
                        return
                    }
                    self.scriptText = parsed.scriptText
                    self.scriptFileName = images.count > 1 ? "\(images.count) Scanned Pages" : "Scanned Sides.jpg"
                    self.cueLines = parsed.cueLines
                }
            } catch {
                await MainActor.run {
                    self.isProcessingSides = false
                    self.presentImportError(error.localizedDescription)
                }
            }
        }
    }

    private func handleSidesFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            presentImportError(error.localizedDescription)
        case .success(let urls):
            guard !urls.isEmpty else { return }
            isProcessingSides = true
            let fallbackRole = roleName.isEmpty ? "ACTOR" : roleName

            Task {
                do {
                    var combinedText = ""
                    var firstError: Error?

                    for url in urls {
                        let accessing = url.startAccessingSecurityScopedResource()
                        defer {
                            if accessing {
                                url.stopAccessingSecurityScopedResource()
                            }
                        }

                        do {
                            let data = try Data(contentsOf: url)
                            let filename = url.lastPathComponent.lowercased()

                            let extracted: String
                            if filename.hasSuffix(".pdf") {
                                extracted = try await CastingCallParserService.shared.extractRawText(fromPDF: data)
                            } else if filename.hasSuffix(".docx") {
                                extracted = try await CastingCallParserService.shared.extractRawText(fromDocx: data)
                            } else if let image = UIImage(data: data) {
                                extracted = try await CastingCallParserService.shared.extractRawText(from: image)
                            } else {
                                extracted = String(data: data, encoding: .utf8) ?? ""
                            }

                            let trimmed = extracted.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                combinedText += (combinedText.isEmpty ? "" : "\n\n") + trimmed
                            }
                        } catch {
                            if firstError == nil {
                                firstError = error
                            }
                        }
                    }

                    if combinedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let firstError {
                        throw firstError
                    }

                    let parsed = CastingCallParserService.shared.parseSidesText(combinedText, defaultRole: fallbackRole)
                    await MainActor.run {
                        self.isProcessingSides = false
                        guard !parsed.scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            self.presentImportError("No readable script text was found in the selected files. Existing sides were kept unchanged.")
                            return
                        }
                        self.scriptText = parsed.scriptText
                        self.scriptFileName = urls.count > 1 ? "\(urls.count) Files Attached" : (urls.first?.lastPathComponent ?? "Sides")
                        self.cueLines = parsed.cueLines
                    }
                } catch {
                    await MainActor.run {
                        self.isProcessingSides = false
                        self.presentImportError(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func presentImportError(_ message: String) {
        importErrorMessage = message
        showingImportError = true
    }

    // MARK: - Native Sheet Editors (Draft-buffered with Cancel / Done)

    private var editProjectNameSheet: some View {
        NavigationStack {
            Form {
                Section("Project Name") {
                    TextField("Enter project title", text: $draftProjectName)
                }
            }
            .navigationTitle("Project Name")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { activeSheet = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        projectName = draftProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
                        activeSheet = nil
                    }
                    .disabled(draftProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.fraction(0.35)])
    }

    private var editRoleNameSheet: some View {
        NavigationStack {
            Form {
                Section("Character / Role Name") {
                    TextField("Enter role name", text: $draftRoleName)
                }
                Section("Role Description") {
                    TextField("Character brief / age / details", text: $draftRoleDescription, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle("Role Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { activeSheet = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        roleName = draftRoleName.trimmingCharacters(in: .whitespacesAndNewlines)
                        roleDescription = draftRoleDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                        activeSheet = nil
                    }
                    .disabled(draftRoleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.fraction(0.55)])
    }

    private var trimmedTypedDeadline: String {
        draftDeadlineText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parsedTypedDeadline: Date? {
        CastingCallParserService.shared.parseUserDeadlineInput(trimmedTypedDeadline)
    }

    private var isTypedDeadlineInvalid: Bool {
        draftHasDeadline && !trimmedTypedDeadline.isEmpty && parsedTypedDeadline == nil
    }

    private var editDeadlineSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Specify Deadline", isOn: $draftHasDeadline)
                        .onChange(of: draftHasDeadline) { _, isOn in
                            if !isOn {
                                draftDeadlineText = ""
                                lastParsedFromTyping = nil
                            } else if draftDeadlineText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                draftDeadlineText = draftDeadline.formatted(date: .abbreviated, time: .shortened)
                                lastParsedFromTyping = nil
                            }
                        }

                    TextField("Type deadline (e.g. Nov 30, 5:00 PM)", text: $draftDeadlineText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($isDeadlineFieldFocused)
                        .onChange(of: draftDeadlineText) { _, newValue in
                            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else {
                                lastParsedFromTyping = nil
                                return
                            }
                            if !draftHasDeadline {
                                draftHasDeadline = true
                            }
                            if let parsed = CastingCallParserService.shared.parseUserDeadlineInput(trimmed) {
                                lastParsedFromTyping = parsed
                                draftDeadline = parsed
                            }
                        }

                    if draftHasDeadline {
                        DatePicker("Pick Date & Time", selection: $draftDeadline, displayedComponents: [.date, .hourAndMinute])
                            .onChange(of: draftDeadline) { _, newDate in
                                if let typed = lastParsedFromTyping, abs(typed.timeIntervalSince(newDate)) < 1.0 {
                                    return
                                }
                                lastParsedFromTyping = nil
                                isDeadlineFieldFocused = false
                                draftDeadlineText = newDate.formatted(date: .abbreviated, time: .shortened)
                            }
                    }
                } header: {
                    Text("Deadline")
                } footer: {
                    if !draftHasDeadline {
                        Text("Deadline not specified. Type a date and time above (like \"Nov 30, 5:00 PM\" or \"30/11/2026\") or turn on Specify Deadline.")
                    } else if isTypedDeadlineInvalid {
                        Text("Couldn't recognize \"\(trimmedTypedDeadline)\". Try e.g. \"Nov 30, 5:00 PM\", \"30/11/2026 17:00\", or pick a date below.")
                            .foregroundStyle(Theme.Colors.warningAmber)
                    } else {
                        Text("Submission deadline: \(draftDeadline.formatted(date: .abbreviated, time: .shortened))")
                    }
                }

                if draftHasDeadline {
                    Section("Reminder") {
                        Picker("Notify Me", selection: $draftReminderOffsetMinutes) {
                            Text("30 minutes before").tag(30)
                            Text("1 hour before").tag(60)
                            Text("2 hours before").tag(120)
                            Text("1 day before").tag(1440)
                        }
                    }
                }
            }
            .navigationTitle("Deadline & Reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { activeSheet = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        hasDeadline = draftHasDeadline
                        if draftHasDeadline {
                            if let parsed = parsedTypedDeadline {
                                deadline = parsed
                            } else {
                                deadline = draftDeadline
                            }
                            reminderOffsetMinutes = draftReminderOffsetMinutes
                        }
                        activeSheet = nil
                    }
                    .disabled(isTypedDeadlineInvalid)
                }
            }
        }
        .presentationDetents([.fraction(0.65)])
    }

    private var editRecipientEmailSheet: some View {
        NavigationStack {
            Form {
                Section("Casting / Submission Email") {
                    TextField("e.g. casting@agency.com", text: $draftRecipientEmail)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("Recipient Email")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { activeSheet = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        recipientEmail = draftRecipientEmail.trimmingCharacters(in: .whitespacesAndNewlines)
                        activeSheet = nil
                    }
                }
            }
        }
        .presentationDetents([.fraction(0.35)])
    }

    private struct PresetRequirementOption: Identifiable {
        let id: String
        let displayName: String
        let title: String
        let subtitle: String
        let icon: String
        let matchKeywords: [String]
    }

    private var presetRequirementOptions: [PresetRequirementOption] {
        [
            PresetRequirementOption(
                id: "headshots",
                displayName: "Headshots",
                title: "Guided Headshots (3 Angles: Front, Left, Right)",
                subtitle: "Front, Left Profile & Right Profile photos",
                icon: "person.crop.rectangle.stack",
                matchKeywords: ["headshot"]
            ),
            PresetRequirementOption(
                id: "slate",
                displayName: "Slate",
                title: "Slate / Introduction Video",
                subtitle: "Name, agency & role introduction take",
                icon: "person.wave.2",
                matchKeywords: ["slate", "intro"]
            ),
            PresetRequirementOption(
                id: "selftape",
                displayName: "Self-Tape",
                title: "Audition Self-Tape Take",
                subtitle: "Main scene performance self-tape",
                icon: "video",
                matchKeywords: ["self-tape", "self tape", "audition", "monologue", "scene"]
            )
        ]
    }

    private func isPresetSelected(_ option: PresetRequirementOption) -> Bool {
        draftRequirements.contains { req in
            let lower = req.title.lowercased()
            return option.matchKeywords.contains { lower.contains($0) }
        }
    }

    private func setPreset(_ option: PresetRequirementOption, enabled: Bool) {
        if enabled {
            guard !isPresetSelected(option) else { return }
            draftRequirements.append(SubmissionRequirement(title: option.title))
        } else {
            draftRequirements.removeAll { req in
                let lower = req.title.lowercased()
                return option.matchKeywords.contains { lower.contains($0) }
            }
        }
    }

    private func presetRequirementRow(_ option: PresetRequirementOption) -> some View {
        Toggle(isOn: Binding(
            get: { isPresetSelected(option) },
            set: { setPreset(option, enabled: $0) }
        )) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.displayName)
                        .font(Theme.Typography.bodyRegular.weight(.medium))
                    Text(option.subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            } icon: {
                Image(systemName: option.icon)
                    .foregroundStyle(Theme.Colors.accent)
            }
        }
        .tint(Theme.Colors.accent)
    }

    private var editRequirementsSheet: some View {
        NavigationStack {
            List {
                Section("Submission Types") {
                    ForEach(presetRequirementOptions) { option in
                        presetRequirementRow(option)
                    }
                }

                Section("Current Requirements") {
                    if draftRequirements.isEmpty {
                        Text("No submission requirements selected.")
                            .font(Theme.Typography.bodyRegular)
                            .foregroundStyle(Theme.Colors.textSecondary)
                    } else {
                        ForEach(draftRequirements) { req in
                            HStack {
                                Image(systemName: req.isCompleted ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(req.isCompleted ? Theme.Colors.successGreen : Theme.Colors.textSecondary)
                                Text(req.title)
                                    .font(Theme.Typography.bodyRegular)
                                Spacer()
                                Button(role: .destructive) {
                                    draftRequirements.removeAll { $0.id == req.id }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(Theme.Colors.errorCrimson)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(req.title)")
                            }
                        }
                        .onDelete { indexSet in
                            draftRequirements.remove(atOffsets: indexSet)
                        }
                    }
                }

                Section("Add Custom Requirement") {
                    HStack {
                        TextField("New requirement...", text: $newRequirementTitle)
                        Button {
                            let trimmed = newRequirementTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            draftRequirements.append(SubmissionRequirement(title: trimmed))
                            newRequirementTitle = ""
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(Theme.Colors.accent)
                        }
                        .disabled(newRequirementTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("Add requirement")
                    }
                }
            }
            .navigationTitle("Edit Requirements")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { activeSheet = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        requirements = draftRequirements
                        activeSheet = nil
                    }
                }
            }
        }
        .presentationDetents([.large])
    }

    private var attachSidesSheet: some View {
        NavigationStack {
            List {
                Section("Choose Source") {
                    Button {
                        pendingSidesSource = .photo
                        activeSheet = nil
                    } label: {
                        Label("Photo / Camera Roll", systemImage: "photo")
                    }

                    Button {
                        pendingSidesSource = .scan
                        activeSheet = nil
                    } label: {
                        Label("Scan Document", systemImage: "doc.viewfinder")
                    }

                    Button {
                        pendingSidesSource = .file
                        activeSheet = nil
                    } label: {
                        Label("Files (PDF, DOCX, TXT)", systemImage: "folder")
                    }

                    Button {
                        pendingSidesSource = .paste
                        activeSheet = nil
                    } label: {
                        Label("Type or Paste Sides", systemImage: "square.and.pencil")
                    }
                }
            }
            .navigationTitle("Attach Sides")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { activeSheet = nil }
                }
            }
        }
        .presentationDetents([.fraction(0.45)])
    }

    private var pasteSidesEditorSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Paste your sides or character dialogue:")
                    .font(Theme.Typography.captionBadge)
                    .foregroundStyle(Theme.Colors.textSecondary)

                TextEditor(text: $pastedScriptBuffer)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .padding(8)
                    .scrollContentBackground(.hidden)
                    .background(Theme.Colors.controlSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.Colors.controlBorder, lineWidth: 1))

                Spacer()
            }
            .padding()
            .background(Theme.Colors.canvasBackground)
            .navigationTitle("Type or Paste Sides")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingPasteEditor = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use Text") {
                        let txt = pastedScriptBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !txt.isEmpty else { return }
                        let parsed = CastingCallParserService.shared.parseSidesText(
                            txt,
                            defaultRole: roleName.isEmpty ? "ACTOR" : roleName
                        )
                        showingPasteEditor = false
                        guard !parsed.scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            presentImportError("No readable script text was detected. Existing sides were kept unchanged.")
                            return
                        }
                        self.scriptText = parsed.scriptText
                        self.scriptFileName = "Pasted Sides.txt"
                        self.cueLines = parsed.cueLines
                    }
                    .disabled(pastedScriptBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
