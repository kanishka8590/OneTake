import SwiftUI
import SwiftData
import PhotosUI

enum AuditionListFilter: String, CaseIterable, Identifiable {
    case active = "Active"
    case sent = "Sent"
    case all = "All"

    var id: String { rawValue }
}

enum AddAuditionSourceOption: Identifiable {
    case photo
    case scan
    case file
    case typeIt

    var id: Int { hashValue }
}

struct AuditionsListView: View {
    @Environment(AppState.self) private var envAppState
    private let explicitAppState: AppState?

    init(appState: AppState? = nil) {
        self.explicitAppState = appState
    }

    private var appState: AppState {
        explicitAppState ?? envAppState
    }

    @State private var selectedFilter: AuditionListFilter = .active
    @State private var showingAddSourceSheet = false
    @State private var auditionToDelete: Audition?
    @State private var showingDeleteConfirmation = false

    // Import & parsing states
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showingPhotoPicker = false
    @State private var showingDocumentScanner = false
    @State private var showingFileImporter = false
    @State private var showingPasteEditor = false
    @State private var pastedScriptBuffer = ""

    // Parsing progress & navigation
    @State private var isParsingCall = false
    @State private var parsingSourceTitle = ""
    @State private var parsedCallToEdit: ParsedCastingCall?
    @State private var showingDetailsEditor = false

    var filteredAuditions: [Audition] {
        switch selectedFilter {
        case .active:
            return appState.auditions.filter { $0.status == .active }
        case .sent:
            return appState.auditions.filter { $0.status == .sent }
        case .all:
            return appState.auditions
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.canvasBackground
                    .ignoresSafeArea()

                if filteredAuditions.isEmpty {
                    emptyStateView
                } else {
                    List {
                        ForEach(filteredAuditions) { audition in
                            NavigationLink {
                                AuditionPackageHubView(audition: audition)
                            } label: {
                                AuditionCardRow(audition: audition)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    auditionToDelete = audition
                                    showingDeleteConfirmation = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }

                                if audition.status == .active {
                                    Button {
                                        withAnimation {
                                            appState.updateAuditionStatus(audition, to: .sent)
                                        }
                                    } label: {
                                        Label("Mark Sent", systemImage: "paperplane.fill")
                                    }
                                    .tint(Theme.Colors.successGreen)
                                } else {
                                    Button {
                                        withAnimation {
                                            appState.updateAuditionStatus(audition, to: .active)
                                        }
                                    } label: {
                                        Label("Reactivate", systemImage: "arrow.uturn.backward")
                                    }
                                    .tint(Theme.Colors.primaryPlum)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Auditions")
            .toolbar {
                // Header with native Menu filter
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Filter", selection: $selectedFilter) {
                            ForEach(AuditionListFilter.allCases) { filter in
                                Text(filter.rawValue).tag(filter)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(selectedFilter.rawValue)
                                .font(Theme.Typography.cardTitle)
                                .foregroundStyle(Theme.Colors.textPrimary)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.Colors.primaryPlum)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(Theme.Colors.lavenderSurface.opacity(0.6))
                        .clipShape(Capsule())
                    }
                }

                // Add audition plus button
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddSourceSheet = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Theme.Colors.primaryPlum)
                            .frame(minWidth: Theme.Layout.minTapTarget, minHeight: Theme.Layout.minTapTarget)
                    }
                }
            }
            // Compact Add Source Bottom Sheet
            .sheet(isPresented: $showingAddSourceSheet) {
                addAuditionBottomSheet
                    .presentationDetents([.height(225)])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(28)
            }
            // Multi-Photo Picker
            .photosPicker(
                isPresented: $showingPhotoPicker,
                selection: $selectedPhotoItems,
                maxSelectionCount: 10,
                matching: .images
            )
            .onChange(of: selectedPhotoItems) { _, newItems in
                guard !newItems.isEmpty else { return }
                let items = newItems
                selectedPhotoItems = []
                loadSelectedPhotos(items)
            }
            // Document Camera Scanner
            .sheet(isPresented: $showingDocumentScanner) {
                DocumentScannerRepresentable { scannedImages in
                    showingDocumentScanner = false
                    guard !scannedImages.isEmpty else { return }
                    processScannedImages(scannedImages)
                } onCancel: {
                    showingDocumentScanner = false
                }
            }
            // Multi-File Importer
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.pdf, .plainText, .data],
                allowsMultipleSelection: true
            ) { result in
                handleFileImport(result)
            }
            // Paste Editor
            .sheet(isPresented: $showingPasteEditor) {
                pasteEditorSheet
            }
            // Parsing extraction view
            .fullScreenCover(isPresented: $isParsingCall) {
                CastingCallParsingView(sourceTitle: parsingSourceTitle) { parsed in
                    finishParsing(with: parsed)
                } onCancel: {
                    self.isParsingCall = false
                }
            }
            // Details Editor View
            .sheet(isPresented: $showingDetailsEditor) {
                if let parsed = parsedCallToEdit {
                    AuditionDetailsEditorView(parsedCall: parsed) { _ in
                        showingDetailsEditor = false
                    }
                }
            }
            // Delete confirmation
            .confirmationDialog(
                "Delete Audition?",
                isPresented: $showingDeleteConfirmation,
                presenting: auditionToDelete
            ) { audition in
                Button("Delete \"\(audition.projectName)\"", role: .destructive) {
                    appState.deleteAudition(audition)
                }
                Button("Cancel", role: .cancel) {}
            } message: { audition in
                Text("This will permanently remove the audition, takes, and cue recordings.")
            }
        }
    }

    // MARK: - Compact "Add an Audition" Bottom Sheet

    private var addAuditionBottomSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add an audition")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Theme.Colors.textPrimary)

                    Text("Import the casting call requirements")
                        .font(Theme.Typography.captionBadge)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }

                Spacer()

                Button {
                    showingAddSourceSheet = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .frame(width: 30, height: 30)
                        .background(Theme.Colors.lavenderSurface)
                        .clipShape(Circle())
                }
            }

            // 4-column horizontal grid of evenly sized circular lavender-tinted icon buttons
            HStack(spacing: 0) {
                sourceOptionButton(title: "Photo", systemImage: "photo") {
                    showingAddSourceSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        showingPhotoPicker = true
                    }
                }
                .frame(maxWidth: .infinity)

                sourceOptionButton(title: "Scan", systemImage: "doc.viewfinder") {
                    showingAddSourceSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        showingDocumentScanner = true
                    }
                }
                .frame(maxWidth: .infinity)

                sourceOptionButton(title: "File", systemImage: "folder") {
                    showingAddSourceSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        showingFileImporter = true
                    }
                }
                .frame(maxWidth: .infinity)

                sourceOptionButton(title: "Type it", systemImage: "keyboard") {
                    showingAddSourceSheet = false
                    pastedScriptBuffer = ""
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        showingPasteEditor = true
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .background(Theme.Colors.canvasBackground)
    }

    private func sourceOptionButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Theme.Colors.lavenderSurface)
                        .frame(width: 52, height: 52)

                    Image(systemName: systemImage)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.Colors.primaryPlum)
                }

                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Colors.textPrimary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Process Multi-Photo, Multi-File & Scan Imports

    private func loadSelectedPhotos(_ items: [PhotosPickerItem]) {
        Task {
            await MainActor.run {
                parsingSourceTitle = items.count > 1 ? "\(items.count) Photos" : "Photo Scan"
                isParsingCall = true
            }

            var images: [UIImage] = []
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    images.append(image)
                }
            }

            guard !images.isEmpty else {
                await MainActor.run { isParsingCall = false }
                return
            }

            let result = try? await CastingCallParserService.shared.parseImages(images)
            await MainActor.run {
                self.finishParsing(with: result)
            }
        }
    }

    private func processScannedImages(_ images: [UIImage]) {
        Task {
            await MainActor.run {
                parsingSourceTitle = images.count > 1 ? "\(images.count) Pages Scanned" : "Document Scan"
                isParsingCall = true
            }
            let result = try? await CastingCallParserService.shared.parseImages(images)
            await MainActor.run {
                self.finishParsing(with: result)
            }
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }
            parsingSourceTitle = urls.count > 1 ? "\(urls.count) Files" : (urls.first?.lastPathComponent ?? "File Import")
            isParsingCall = true

            Task {
                let parsed = try? await CastingCallParserService.shared.parseMultipleFiles(urls: urls)
                await MainActor.run {
                    self.finishParsing(with: parsed)
                }
            }
        case .failure(let error):
            print("File import failed: \(error)")
        }
    }

    // MARK: - Paste Editor Sheet

    private var pasteEditorSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("Paste casting call notice, flyer, or sides text below:")
                    .font(Theme.Typography.captionBadge)
                    .foregroundStyle(Theme.Colors.textSecondary)

                TextEditor(text: $pastedScriptBuffer)
                    .padding(8)
                    .background(Theme.Colors.cardSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.black.opacity(0.1), lineWidth: 1))

                Spacer()
            }
            .padding()
            .background(Theme.Colors.canvasBackground)
            .navigationTitle("Type or Paste Notice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingPasteEditor = false }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Read Call") {
                        let text = pastedScriptBuffer
                        showingPasteEditor = false
                        // Wait for the editor sheet to finish dismissing before
                        // presenting the reading screen. Presenting both in one
                        // transaction caused the first import to show blank.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            parsingSourceTitle = "Pasted Notice"
                            isParsingCall = true
                            Task {
                                let result = await CastingCallParserService.shared.parseText(text)
                                await MainActor.run { self.finishParsing(with: result) }
                            }
                        }
                    }
                    .disabled(pastedScriptBuffer.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    /// Modal transitions are intentionally serialized: first dismiss the
    /// reading screen, then show the editor on the following run-loop turn.
    private func finishParsing(with parsed: ParsedCastingCall?) {
        parsedCallToEdit = parsed
        isParsingCall = false
        guard parsed != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            showingDetailsEditor = true
        }
    }

    // MARK: - Empty State View

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Theme.Colors.lavenderSurface)
                    .frame(width: 80, height: 80)

                Image(systemName: "movieclapper.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(Theme.Colors.primaryPlum)
            }

            VStack(spacing: 6) {
                Text(selectedFilter == .sent ? "No Sent Auditions" : "No Auditions Yet")
                    .font(Theme.Typography.sectionHeader)
                    .foregroundStyle(Theme.Colors.textPrimary)

                Text(selectedFilter == .sent ? "Auditions marked as sent will appear here." : "Import a casting call flyer, scan sides, or paste a notice to get started!")
                    .font(Theme.Typography.bodyRegular)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Button {
                showingAddSourceSheet = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                    Text("Add an Audition")
                }
                .primaryCapsuleButton()
            }
            .padding(.top, 8)
            .padding(.horizontal, 32)
        }
        .padding(.horizontal, 24)
    }
}

// MARK: - Audition Card Row with Dynamic Progress: 0 of 3 -> 1 of 3 -> 2 of 3 -> 3 of 3 ready -> Sent

struct AuditionCardRow: View {
    let audition: Audition

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header: Project Name + Status / Ready Badge
            HStack(alignment: .center) {
                Text(audition.projectName)
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1)

                Spacer()

                if audition.status == .sent {
                    Text("Sent • 30-Day Link Active")
                        .statusBadge(color: Theme.Colors.successGreen)
                } else if audition.packageReadyCount == 3 {
                    Text("3 of 3 ready")
                        .statusBadge(color: Theme.Colors.successGreen)
                } else {
                    Text("\(audition.packageReadyCount) of 3 ready")
                        .statusBadge(color: Theme.Colors.primaryPlum)
                }
            }

            // Role and Production Type
            HStack(spacing: 8) {
                Text("Role: \(audition.roleName)")
                    .font(Theme.Typography.bodyRegular)
                    .foregroundStyle(Theme.Colors.textSecondary)

                Text("•")
                    .foregroundStyle(Theme.Colors.textSecondary)

                Text(audition.production.rawValue)
                    .font(Theme.Typography.captionBadge)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }

            // Deadline Indicator
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.system(size: 12))
                    .foregroundStyle(deadlineColor)

                Text(deadlineText)
                    .font(Theme.Typography.captionBadge)
                    .foregroundStyle(deadlineColor)
            }

            // 3-Segmented Progress Bar
            HStack(spacing: 6) {
                ForEach(0..<3) { idx in
                    Capsule()
                        .fill(idx < audition.packageReadyCount ? (audition.status == .sent ? Theme.Colors.successGreen : Theme.Colors.primaryPlum) : Theme.Colors.lavenderSurface)
                        .frame(height: 5)
                }
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 10)
        .frame(minHeight: Theme.Layout.minTapTarget)
    }

    private var deadlineColor: Color {
        if audition.status == .sent {
            return Theme.Colors.textSecondary
        }
        if audition.isOverdue {
            return Theme.Colors.errorCrimson
        }
        let days = audition.daysUntilDeadline
        if days <= 1 {
            return Theme.Colors.warningAmber
        }
        return Theme.Colors.textSecondary
    }

    private var deadlineText: String {
        if audition.status == .sent {
            if let sent = audition.sentDate {
                return "Sent on \(sent.formatted(date: .abbreviated, time: .omitted))"
            }
            return "Submitted"
        }
        if audition.isOverdue {
            return "Overdue (\(audition.deadline.formatted(date: .abbreviated, time: .omitted)))"
        }
        let days = audition.daysUntilDeadline
        if days == 0 {
            return "Due today"
        } else if days == 1 {
            return "Due tomorrow"
        } else {
            return "\(days) days left (\(audition.deadline.formatted(date: .abbreviated, time: .omitted)))"
        }
    }
}
