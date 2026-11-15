import SwiftUI
import SwiftData
import PhotosUI

enum ActiveEditorSheet: Identifiable {
    case projectName
    case roleName
    case deadline
    case recipientEmail
    case requirements
    case attachSides

    var id: Int { hashValue }
}

struct AuditionDetailsEditorView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var parsedCall: ParsedCastingCall? = nil
    var existingAudition: Audition? = nil
    var onSaved: ((Audition) -> Void)?

    @State private var activeSheet: ActiveEditorSheet?
    @State private var showingSaveSuccess = false

    // Editable properties
    @State private var projectName: String = ""
    @State private var productionType: ProductionType = .featureFilm
    @State private var roleName: String = ""
    @State private var roleDescription: String = ""
    @State private var deadline: Date = Date()
    @State private var reminderOffsetMinutes: Int = 60
    @State private var recipientEmail: String = ""
    @State private var requirements: [SubmissionRequirement] = []
    @State private var scriptText: String = ""
    @State private var scriptFileName: String? = nil
    @State private var cueLines: [CueLine] = []

    // Importer states for Script Sides (supports multi-photo and multi-file)
    @State private var selectedSidesPhotoItems: [PhotosPickerItem] = []
    @State private var showingSidesPhotoPicker = false
    @State private var showingDocumentScanner = false
    @State private var showingFileImporter = false
    @State private var showingPasteEditor = false
    @State private var pastedScriptBuffer = ""
    @State private var isProcessingSides = false

    private var isEditingExisting: Bool {
        existingAudition != nil
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.canvasBackground
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        // Notice Header Banner
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
                                    value: projectName.isEmpty ? "Tap to add" : projectName,
                                    icon: "film"
                                ) {
                                    activeSheet = .projectName
                                }

                                Divider().padding(.leading, 44)

                                editableRow(
                                    title: "Role & Character",
                                    value: roleName.isEmpty ? "Tap to add" : roleName,
                                    icon: "person.text.rectangle"
                                ) {
                                    activeSheet = .roleName
                                }

                                Divider().padding(.leading, 44)

                                HStack {
                                    Image(systemName: "tag.fill")
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
                                    value: "\(deadline.formatted(date: .abbreviated, time: .shortened))",
                                    icon: "calendar.badge.clock"
                                ) {
                                    activeSheet = .deadline
                                }

                                Divider().padding(.leading, 44)

                                editableRow(
                                    title: "Recipient Email",
                                    value: recipientEmail.isEmpty ? "Not specified (add email)" : recipientEmail,
                                    icon: "envelope.fill"
                                ) {
                                    activeSheet = .recipientEmail
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
                                    activeSheet = .requirements
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
                                            Image(systemName: req.isCompleted ? "checkmark.circle.fill" : "circle")
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

                        // Section 4: Script Sides (Strict Separation: No breakdown/instructions in script)
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Script Sides")
                                    .font(Theme.Typography.sectionHeader)
                                    .foregroundStyle(Theme.Colors.textPrimary)

                                Spacer()

                                if !scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Button {
                                        activeSheet = .attachSides
                                    } label: {
                                        Text("Change Sides")
                                            .font(Theme.Typography.captionBadge)
                                            .foregroundStyle(Theme.Colors.accent)
                                    }
                                }
                            }
                            .padding(.horizontal, 4)

                            if scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                // Add Script Sides (Optional) Card
                                addScriptSidesOptionalCard
                            } else {
                                // Sides Attached Card
                                sidesAttachedCard
                            }
                        }

                        // Save Audition Button
                        Button {
                            saveAudition()
                        } label: {
                            Text(isEditingExisting ? "Save Changes" : "Save the Audition")
                                .primaryCapsuleButton()
                        }
                        .padding(.top, 8)
                        .padding(.bottom, 36)
                    }
                    .padding(.horizontal, Theme.Layout.screenHPadding)
                    .padding(.top, 16)
                }
            }
            .navigationTitle(isEditingExisting ? "Edit Audition Details" : "Audition Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                initializeValues()
            }
            .sheet(item: $activeSheet) { sheet in
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
            // Multi-Photo Picker for Sides
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
            // Document Scanner for Sides
            .sheet(isPresented: $showingDocumentScanner) {
                DocumentScannerRepresentable { images in
                    showingDocumentScanner = false
                    guard !images.isEmpty else { return }
                    processSidesScannedImages(images)
                } onCancel: {
                    showingDocumentScanner = false
                }
            }
            // Multi-File Importer for Sides
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.pdf, .plainText, .data],
                allowsMultipleSelection: true
            ) { result in
                handleSidesFileImport(result)
            }
            // Paste Editor for Sides
            .sheet(isPresented: $showingPasteEditor) {
                pasteSidesEditorSheet
            }
        }
    }

    // MARK: - Initializer

    private func initializeValues() {
        if let existing = existingAudition {
            projectName = existing.projectName
            productionType = existing.production
            roleName = existing.roleName
            roleDescription = existing.roleDescription
            deadline = existing.deadline
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
            deadline = call.deadline
            recipientEmail = call.recipientEmail
            requirements = call.requirements
            // STRICT SEPARATION: ONLY set scriptText if genuine dialogue/monologue lines were detected
            if let script = call.detectedScriptText, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                scriptText = script
                scriptFileName = "Extracted Sides"
                cueLines = call.cueLines
            } else {
                scriptText = ""
                scriptFileName = nil
                cueLines = []
            }
        }
    }

    // MARK: - Header Card

    private var headerCard: some View {
        HStack(spacing: 14) {
            Image(systemName: isEditingExisting ? "pencil.circle.fill" : "sparkles")
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

    // MARK: - "Add Script Sides (Optional)" Card (Requirement 3)

    private var addScriptSidesOptionalCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.fill")
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

            // 4 Option Buttons in a clean horizontal row
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
                Image(systemName: "doc.text.fill")
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
                    activeSheet = .attachSides
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
    private func editableRow(title: String, value: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.Colors.accent)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.Typography.captionBadge)
                        .foregroundStyle(Theme.Colors.textSecondary)

                    Text(value)
                        .font(Theme.Typography.bodyRegular)
                        .foregroundStyle(Theme.Colors.textPrimary)
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

    // MARK: - Save Action (Creates or Updates)

    private func saveAudition() {
        let rules = existingAudition?.validationRules ?? ValidationRules(
            isFromNotice: true,
            requiredHeadshotRatio: parsedCall?.requiredHeadshotRatio ?? .ratio4x5,
            maxSlateSeconds: parsedCall?.maxSlateSeconds ?? 45.0,
            maxClipSeconds: parsedCall?.maxClipSeconds ?? 180.0,
            requiredPortrait: nil,
            fileNamePattern: "\(roleName.replacingOccurrences(of: " ", with: "_"))_Audition",
            maxPerClipSizeMB: parsedCall?.maxPerClipSizeMB ?? 100.0
        )

        let cleanScriptText = scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : scriptText

        if let existing = existingAudition {
            existing.projectName = projectName.trimmingCharacters(in: .whitespaces)
            existing.production = productionType
            existing.roleName = roleName.trimmingCharacters(in: .whitespaces)
            existing.roleDescription = roleDescription.trimmingCharacters(in: .whitespaces)
            existing.deadline = deadline
            existing.reminderOffsetMinutes = reminderOffsetMinutes
            existing.recipientEmail = recipientEmail.trimmingCharacters(in: .whitespaces)
            existing.requirements = requirements
            existing.scriptText = cleanScriptText
            existing.scriptFileName = cleanScriptText == nil ? nil : scriptFileName
            existing.cueLines = cueLines
            existing.validationRules = rules

            try? appState.modelContext?.save()
            appState.loadData()
            onSaved?(existing)
            dismiss()
        } else {
            let audition = Audition(
                projectName: projectName.trimmingCharacters(in: .whitespaces),
                productionType: productionType.rawValue,
                roleName: roleName.trimmingCharacters(in: .whitespaces),
                roleDescription: roleDescription.trimmingCharacters(in: .whitespaces),
                deadline: deadline,
                reminderOffsetMinutes: reminderOffsetMinutes,
                recipientEmail: recipientEmail.trimmingCharacters(in: .whitespaces),
                requirements: requirements,
                scriptText: cleanScriptText,
                scriptFileName: cleanScriptText == nil ? nil : scriptFileName,
                cueLines: cueLines,
                validationRules: rules
            )

            appState.addAudition(audition)
            onSaved?(audition)
            dismiss()
        }
    }

    // MARK: - Process Sides Imports

    private func loadSidesPhotos(_ items: [PhotosPickerItem]) {
        Task {
            var images: [UIImage] = []
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    images.append(image)
                }
            }

            guard !images.isEmpty else { return }
            var combinedText = ""
            for img in images {
                let txt = (try? await CastingCallParserService.shared.extractRawText(from: img)) ?? ""
                if !txt.isEmpty {
                    combinedText += (combinedText.isEmpty ? "" : "\n\n") + txt
                }
            }

            let parsed = CastingCallParserService.shared.parseSidesText(
                combinedText,
                defaultRole: roleName.isEmpty ? "ACTOR" : roleName
            )

            await MainActor.run {
                self.scriptText = parsed.scriptText
                self.scriptFileName = items.count > 1 ? "\(items.count) Sides Photos" : "Sides Photo"
                self.cueLines = parsed.cueLines
            }
        }
    }

    private func processSidesScannedImages(_ images: [UIImage]) {
        Task {
            var combinedText = ""
            for img in images {
                let txt = (try? await CastingCallParserService.shared.extractRawText(from: img)) ?? ""
                if !txt.isEmpty {
                    combinedText += (combinedText.isEmpty ? "" : "\n\n") + txt
                }
            }

            let parsed = CastingCallParserService.shared.parseSidesText(
                combinedText,
                defaultRole: roleName.isEmpty ? "ACTOR" : roleName
            )

            await MainActor.run {
                self.scriptText = parsed.scriptText
                self.scriptFileName = images.count > 1 ? "\(images.count) Scanned Pages" : "Scanned Sides.jpg"
                self.cueLines = parsed.cueLines
            }
        }
    }

    private func handleSidesFileImport(_ result: Result<[URL], Error>) {
        if case .success(let urls) = result, !urls.isEmpty {
            Task {
                var combinedText = ""
                for url in urls {
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer {
                        if accessing {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }

                    guard let data = try? Data(contentsOf: url) else { continue }
                    let filename = url.lastPathComponent.lowercased()

                    let extracted: String
                    if filename.hasSuffix(".pdf") {
                        extracted = (try? await CastingCallParserService.shared.extractRawText(fromPDF: data)) ?? ""
                    } else if filename.hasSuffix(".docx") {
                        extracted = (try? await CastingCallParserService.shared.extractRawText(fromDocx: data)) ?? ""
                    } else {
                        extracted = String(data: data, encoding: .utf8) ?? ""
                    }

                    if !extracted.isEmpty {
                        combinedText += (combinedText.isEmpty ? "" : "\n\n") + extracted
                    }
                }

                let parsed = CastingCallParserService.shared.parseSidesText(
                    combinedText,
                    defaultRole: roleName.isEmpty ? "ACTOR" : roleName
                )

                await MainActor.run {
                    self.scriptText = parsed.scriptText
                    self.scriptFileName = urls.count > 1 ? "\(urls.count) Files Attached" : (urls.first?.lastPathComponent ?? "Sides")
                    self.cueLines = parsed.cueLines
                }
            }
        }
    }

    // MARK: - Native Sheet Editors

    private var editProjectNameSheet: some View {
        NavigationStack {
            Form {
                Section("Project Name") {
                    TextField("Enter project title", text: $projectName)
                }
            }
            .navigationTitle("Project Name")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { activeSheet = nil }
                }
            }
        }
        .presentationDetents([.fraction(0.35)])
    }

    private var editRoleNameSheet: some View {
        NavigationStack {
            Form {
                Section("Character / Role Name") {
                    TextField("Enter role name", text: $roleName)
                }
                Section("Role Description") {
                    TextField("Character brief / age / details", text: $roleDescription, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle("Role Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { activeSheet = nil }
                }
            }
        }
        .presentationDetents([.fraction(0.55)])
    }

    private var editDeadlineSheet: some View {
        NavigationStack {
            Form {
                Section("Deadline") {
                    DatePicker("Submission Deadline", selection: $deadline, displayedComponents: [.date, .hourAndMinute])
                }

                Section("Reminder") {
                    Picker("Notify Me", selection: $reminderOffsetMinutes) {
                        Text("30 minutes before").tag(30)
                        Text("1 hour before").tag(60)
                        Text("2 hours before").tag(120)
                        Text("1 day before").tag(1440)
                    }
                }
            }
            .navigationTitle("Deadline & Reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { activeSheet = nil }
                }
            }
        }
        .presentationDetents([.fraction(0.5)])
    }

    private var editRecipientEmailSheet: some View {
        NavigationStack {
            Form {
                Section("Casting / Submission Email") {
                    TextField("e.g. casting@agency.com", text: $recipientEmail)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("Recipient Email")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { activeSheet = nil }
                }
            }
        }
        .presentationDetents([.fraction(0.35)])
    }

    @State private var newRequirementTitle = ""
    private var editRequirementsSheet: some View {
        NavigationStack {
            List {
                Section("Current Requirements") {
                    ForEach(requirements) { req in
                        HStack {
                            Text(req.title)
                                .font(Theme.Typography.bodyRegular)
                            Spacer()
                        }
                    }
                    .onDelete { indexSet in
                        requirements.remove(atOffsets: indexSet)
                    }
                }

                Section("Add Requirement") {
                    HStack {
                        TextField("New requirement...", text: $newRequirementTitle)
                        Button {
                            guard !newRequirementTitle.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                            requirements.append(SubmissionRequirement(title: newRequirementTitle.trimmingCharacters(in: .whitespaces)))
                            newRequirementTitle = ""
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(Theme.Colors.accent)
                        }
                    }
                }
            }
            .navigationTitle("Edit Requirements")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { activeSheet = nil }
                }
            }
        }
        .presentationDetents([.fraction(0.65)])
    }

    private var attachSidesSheet: some View {
        NavigationStack {
            List {
                Section("Choose Source") {
                    Button {
                        activeSheet = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            showingSidesPhotoPicker = true
                        }
                    } label: {
                        Label("Photo / Camera Roll", systemImage: "photo")
                    }

                    Button {
                        activeSheet = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            showingDocumentScanner = true
                        }
                    } label: {
                        Label("Scan Document", systemImage: "doc.viewfinder")
                    }

                    Button {
                        activeSheet = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            showingFileImporter = true
                        }
                    } label: {
                        Label("Files (PDF, DOCX, TXT)", systemImage: "folder")
                    }

                    Button {
                        activeSheet = nil
                        pastedScriptBuffer = scriptText
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            showingPasteEditor = true
                        }
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
                        let txt = pastedScriptBuffer
                        showingPasteEditor = false
                        let parsed = CastingCallParserService.shared.parseSidesText(
                            txt,
                            defaultRole: roleName.isEmpty ? "ACTOR" : roleName
                        )
                        self.scriptText = parsed.scriptText
                        self.scriptFileName = "Pasted Sides.txt"
                        self.cueLines = parsed.cueLines
                    }
                }
            }
        }
    }
}
