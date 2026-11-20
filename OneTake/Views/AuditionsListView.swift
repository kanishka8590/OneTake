import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers

enum AuditionListFilter: String, CaseIterable, Identifiable {
    case active = "Active"
    case sent = "Sent"
    case all = "All"

    var id: String { rawValue }
}

private enum PendingAddSource {
    case photo
    case scan
    case file
    case typeIt
}

/// The editor is presented only when it has a complete parsed casting call.
/// This prevents SwiftUI from constructing an empty sheet while a separate
/// boolean and its payload are updated in different render passes.
private struct AuditionEditorPresentation: Identifiable {
    let id = UUID()
    let parsedCall: ParsedCastingCall
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

    private var selectedFilter: AuditionListFilter {
        get { appState.auditionListFilter }
        nonmutating set { appState.auditionListFilter = newValue }
    }

    private var selectedFilterBinding: Binding<AuditionListFilter> {
        Binding(
            get: { appState.auditionListFilter },
            set: { appState.auditionListFilter = $0 }
        )
    }

    @State private var showingAddSourceSheet = false
    @State private var pendingAddSource: PendingAddSource?
    @State private var auditionToDelete: Audition?
    @State private var showingDeleteConfirmation = false
    @State private var auditionToEdit: Audition?

    // Import & parsing states
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showingPhotoPicker = false
    @State private var showingDocumentScanner = false
    @State private var showingFileImporter = false
    @State private var showingPasteEditor = false
    @State private var pastedScriptBuffer = ""
    @State private var pendingScannedImages: [UIImage] = []
    @State private var pendingPastedText: String?

    // Parsing progress, errors & navigation
    @State private var isParsingCall = false
    @State private var parsingSourceTitle = ""
    @State private var editorPresentation: AuditionEditorPresentation?
    @State private var importErrorMessage: String?
    @State private var showingImportError = false

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

    private var spotlightAudition: Audition? {
        guard selectedFilter != .sent, !filteredAuditions.isEmpty else { return nil }
        return filteredAuditions.first { $0.status == .active && $0.hasDeadline }
            ?? filteredAuditions.first { $0.status == .active }
            ?? filteredAuditions.first
    }

    private var compactAuditions: [Audition] {
        guard let spotlight = spotlightAudition else { return filteredAuditions }
        return filteredAuditions.filter { $0.id != spotlight.id }
    }

    var body: some View {
        NavigationStack {
            List {
                if let spotlight = spotlightAudition {
                    Section {
                        auditionListRow(spotlight, isSpotlight: true)
                    } header: {
                        Text("UP NEXT")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .padding(.leading, 2)
                    }
                }

                if !compactAuditions.isEmpty {
                    Section {
                        ForEach(compactAuditions) { audition in
                            auditionListRow(audition, isSpotlight: false)
                        }
                    } header: {
                        if spotlightAudition != nil {
                            Text("ALL AUDITIONS")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Theme.Colors.textSecondary)
                                .padding(.leading, 2)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollEdgeHaptics()
            .background(Theme.Colors.canvasBackground.ignoresSafeArea())
            .overlay {
                if isParsingCall {
                    parsingOverlay
                } else if filteredAuditions.isEmpty {
                    emptyStateView
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
            }
            .navigationTitle("Auditions")
            .navigationBarTitleDisplayMode(.large)
            .onChange(of: selectedFilter) { _, _ in
                Haptics.selectionTick()
            }
            .toolbar {
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .topBarTrailing) {
                        filterToolbarMenu
                    }
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                    ToolbarItem(placement: .topBarTrailing) {
                        addAuditionToolbarButton
                    }
                } else {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        filterToolbarMenu
                        addAuditionToolbarButton
                    }
                }
            }
            // Compact Add Source Bottom Sheet
            .sheet(isPresented: $showingAddSourceSheet, onDismiss: triggerPendingAddSource) {
                addAuditionBottomSheet
                    .presentationDetents([.height(225)])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(28)
                    .presentationBackground(Theme.Colors.canvasBackground)
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
            .sheet(isPresented: $showingDocumentScanner, onDismiss: processPendingScannedImages) {
                DocumentScannerRepresentable { scannedImages in
                    pendingScannedImages = scannedImages
                    showingDocumentScanner = false
                } onCancel: {
                    pendingScannedImages = []
                    showingDocumentScanner = false
                } onError: { error in
                    pendingScannedImages = []
                    showingDocumentScanner = false
                    presentImportError(error.localizedDescription)
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
            .sheet(isPresented: $showingPasteEditor, onDismiss: processPendingPastedText) {
                pasteEditorSheet
            }
            // The parsed call itself is the presentation trigger, so an editor
            // can never appear before its content is ready.
            .sheet(item: $editorPresentation) { presentation in
                AuditionDetailsEditorView(parsedCall: presentation.parsedCall) { _ in
                    editorPresentation = nil
                }
                .presentationDragIndicator(.visible)
                .presentationBackground(Theme.Colors.canvasBackground)
                .environment(appState)
            }
            .sheet(item: $auditionToEdit) { existing in
                AuditionDetailsEditorView(existingAudition: existing) { _ in
                    auditionToEdit = nil
                }
                .presentationDragIndicator(.visible)
                .presentationBackground(Theme.Colors.canvasBackground)
                .environment(appState)
            }
            // Import / parse error alert
            .alert("Import Failed", isPresented: $showingImportError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importErrorMessage ?? "Unable to read the selected casting call.")
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

    // MARK: - Toolbar Controls

    private var filterTintColor: Color {
        switch selectedFilter {
        case .active: return Theme.Colors.accent
        case .sent: return Theme.Colors.successGreen
        case .all: return Theme.Colors.warningAmber
        }
    }

    private var filterToolbarMenu: some View {
        Menu {
            Picker("Filter", selection: selectedFilterBinding) {
                ForEach(AuditionListFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(filterTintColor)
        }
        .accessibilityLabel("Filter auditions")
        .accessibilityValue(selectedFilter.rawValue)
    }

    private var addAuditionToolbarButton: some View {
        Button {
            showingAddSourceSheet = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.Colors.accent)
        }
        .accessibilityLabel("Add audition")
    }

    // MARK: - Compact "Add an Audition" Bottom Sheet

    private var addAuditionBottomSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
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
                .accessibilityLabel("Close")
            }

            HStack(spacing: 0) {
                sourceOptionButton(title: "Photo", systemImage: "photo") {
                    pendingAddSource = .photo
                    showingAddSourceSheet = false
                }
                .frame(maxWidth: .infinity)

                sourceOptionButton(title: "Scan", systemImage: "doc.viewfinder") {
                    pendingAddSource = .scan
                    showingAddSourceSheet = false
                }
                .frame(maxWidth: .infinity)

                sourceOptionButton(title: "File", systemImage: "folder") {
                    pendingAddSource = .file
                    showingAddSourceSheet = false
                }
                .frame(maxWidth: .infinity)

                sourceOptionButton(title: "Type it", systemImage: "keyboard") {
                    pendingAddSource = .typeIt
                    showingAddSourceSheet = false
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 20)
    }

    private func triggerPendingAddSource() {
        guard let source = pendingAddSource else { return }
        pendingAddSource = nil
        switch source {
        case .photo:
            showingPhotoPicker = true
        case .scan:
            showingDocumentScanner = true
        case .file:
            showingFileImporter = true
        case .typeIt:
            pastedScriptBuffer = ""
            showingPasteEditor = true
        }
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
                        .foregroundStyle(Theme.Colors.accent)
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
                        self.isParsingCall = false
                        self.presentImportError("Could not load any images from the selected photos.")
                    }
                    return
                }

                let result = try await CastingCallParserService.shared.parseImages(images)
                await MainActor.run {
                    if result.rawExtractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.isParsingCall = false
                        self.presentImportError("No readable text was found in the selected photos.")
                    } else {
                        self.finishParsing(with: result)
                    }
                }
            } catch {
                await MainActor.run {
                    self.isParsingCall = false
                    self.presentImportError(error.localizedDescription)
                }
            }
        }
    }

    private func processScannedImages(_ images: [UIImage]) {
        Task {
            await MainActor.run {
                parsingSourceTitle = images.count > 1 ? "\(images.count) Pages Scanned" : "Document Scan"
                isParsingCall = true
            }

            do {
                let result = try await CastingCallParserService.shared.parseImages(images)
                await MainActor.run {
                    if result.rawExtractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.isParsingCall = false
                        self.presentImportError("No readable text was detected in the scanned document.")
                    } else {
                        self.finishParsing(with: result)
                    }
                }
            } catch {
                await MainActor.run {
                    self.isParsingCall = false
                    self.presentImportError(error.localizedDescription)
                }
            }
        }
    }

    /// Scanner delegates run before their sheet has fully disappeared. Delay
    /// extraction until `onDismiss` so the eventual editor presentation never
    /// competes with the scanner dismissal animation.
    private func processPendingScannedImages() {
        let images = pendingScannedImages
        pendingScannedImages = []
        guard !images.isEmpty else { return }
        processScannedImages(images)
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }
            parsingSourceTitle = urls.count > 1 ? "\(urls.count) Files" : (urls.first?.lastPathComponent ?? "File Import")
            isParsingCall = true

            Task {
                do {
                    let parsed = try await CastingCallParserService.shared.parseMultipleFiles(urls: urls)
                    await MainActor.run {
                        if parsed.rawExtractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            self.isParsingCall = false
                            self.presentImportError("No readable text could be extracted from the selected file(s).")
                        } else {
                            self.finishParsing(with: parsed)
                        }
                    }
                } catch {
                    await MainActor.run {
                        self.isParsingCall = false
                        self.presentImportError(error.localizedDescription)
                    }
                }
            }
        case .failure(let error):
            presentImportError(error.localizedDescription)
        }
    }

    private func presentImportError(_ message: String) {
        Haptics.error()
        importErrorMessage = message
        showingImportError = true
    }

    // MARK: - Paste Editor Sheet

    private func processPendingPastedText() {
        guard let text = pendingPastedText else { return }
        pendingPastedText = nil
        parsingSourceTitle = "Pasted Notice"
        isParsingCall = true

        Task {
            let result = await CastingCallParserService.shared.parseText(text)
            await MainActor.run { finishParsing(with: result) }
        }
    }

    private var pasteEditorSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("Paste casting call notice, flyer, or sides text below:")
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
            .navigationTitle("Type or Paste Notice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingPasteEditor = false }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Read Call") {
                        pendingPastedText = pastedScriptBuffer
                        showingPasteEditor = false
                    }
                    .disabled(pastedScriptBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    /// Main-actor handoff publishes one complete, identifiable payload. This
    /// replaces the old boolean-plus-optional state, which could show a blank
    /// editor on the first import.
    @MainActor
    private func finishParsing(with parsed: ParsedCastingCall?) {
        isParsingCall = false
        guard let parsed else {
            Haptics.warning()
            return
        }
        Haptics.success()
        editorPresentation = AuditionEditorPresentation(parsedCall: parsed)
    }

    private var parsingOverlay: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Theme.Colors.accent)
                Text("Reading the Call…")
                    .font(Theme.Typography.sectionHeader)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text(parsingSourceTitle)
                    .font(Theme.Typography.captionBadge)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(1)
            }
            .padding(28)
            .frame(maxWidth: 280)
            .background(Theme.Colors.cardSurface, in: RoundedRectangle(cornerRadius: 22))
            .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Reading \(parsingSourceTitle)")
    }

    // MARK: - Empty State View

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Theme.Colors.lavenderSurface)
                    .frame(width: 80, height: 80)

                Image(systemName: "movieclapper")
                    .font(.system(size: 36))
                    .foregroundStyle(Theme.Colors.accent)
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
            .padding(.top, 8)
            .padding(.horizontal, 32)
        }
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private func auditionListRow(_ audition: Audition, isSpotlight: Bool) -> some View {
        ZStack {
            if isSpotlight {
                AuditionSpotlightCard(audition: audition)
            } else {
                AuditionCardRow(audition: audition)
            }

            NavigationLink {
                AuditionPackageHubView(audition: audition)
            } label: {
                EmptyView()
            }
            .opacity(0)
        }
        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: isSpotlight ? 10 : 5, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .contextMenu {
            Button {
                auditionToEdit = audition
            } label: {
                Label("Edit Details", systemImage: "pencil")
            }

            if audition.status == .active {
                Button {
                    withAnimation {
                        appState.updateAuditionStatus(audition, to: .sent)
                    }
                } label: {
                    Label("Mark as Sent", systemImage: "paperplane")
                }
            } else {
                Button {
                    withAnimation {
                        appState.updateAuditionStatus(audition, to: .active)
                    }
                } label: {
                    Label("Reactivate", systemImage: "arrow.uturn.backward")
                }
            }

            Divider()

            Button(role: .destructive) {
                auditionToDelete = audition
                showingDeleteConfirmation = true
            } label: {
                Label("Delete Audition", systemImage: "trash")
            }
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
                    Label("Mark Sent", systemImage: "paperplane")
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
                .tint(Theme.Colors.accent)
            }
        }
    }
}

// MARK: - Option 3: Up Next Spotlight Card + Compact Ring Card

private extension Audition {
    var cardMetadataLine: String {
        let role = roleName.trimmingCharacters(in: .whitespacesAndNewlines)
        if role.isEmpty {
            return production.rawValue
        }
        return "\(role) · \(production.rawValue)"
    }
}

private struct AuditionSpotlightCard: View {
    let audition: Audition

    private var customHeroImage: UIImage? {
        guard let relPath = audition.heroImagePath,
              let url = MediaStorage.resolveURL(for: relPath) else {
            return nil
        }
        return UIImage(contentsOfFile: url.path)
    }

    private var artworkName: String {
        if let custom = audition.heroArtworkName, !custom.isEmpty {
            return custom
        }
        return audition.production == .theater ? Theme.Artwork.dramaBanner : Theme.Artwork.auditionBanner
    }

    private var badgeFillColor: Color {
        if audition.isOverdue {
            return Theme.Colors.errorCrimson.opacity(0.78)
        }
        if audition.hasDeadline && audition.daysUntilDeadline <= 1 && audition.status == .active {
            return Theme.Colors.warningAmber.opacity(0.78)
        }
        return Color.black.opacity(0.56)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear
                .frame(height: 158)
                .background {
                    Group {
                        if let customHeroImage {
                            Image(uiImage: customHeroImage)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Image(artworkName)
                                .resizable()
                                .scaledToFill()
                        }
                    }
                }
                .clipped()

            LinearGradient(
                stops: [
                    .init(color: Color.black.opacity(0.18), location: 0.0),
                    .init(color: Color.black.opacity(0.55), location: 0.52),
                    .init(color: Color.black.opacity(0.95), location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 8) {
                Text(audition.deadlineUrgencyLabel())
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(badgeFillColor, in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.20), lineWidth: 0.8))

                Text(audition.projectName)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                HStack {
                    Text(audition.cardMetadataLine)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.84))
                        .lineLimit(1)

                    Spacer()

                    Text(audition.status == .sent ? "Submitted" : "\(audition.packageReadyCount) of 3 ready")
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.92))
                }
            }
            .padding(16)
        }
        .frame(height: 158)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.15), lineWidth: 0.8)
        )
    }
}

struct AuditionCardRow: View {
    let audition: Audition

    private var isUntitled: Bool {
        audition.projectName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("Untitled Audition") == .orderedSame
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(audition.projectName)
                    .font(.system(size: 17, weight: .bold))
                    .italic(isUntitled)
                    .foregroundStyle(isUntitled ? Theme.Colors.textSecondary : Theme.Colors.textPrimary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(audition.cardMetadataLine)
                        .foregroundStyle(Theme.Colors.textSecondary)
                    Text("·")
                        .foregroundStyle(Theme.Colors.textSecondary.opacity(0.6))
                    Text(audition.deadlineUrgencyLabel())
                        .foregroundStyle(deadlineColor)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                .font(.system(size: 13))
                .lineLimit(1)
            }

            Spacer()

            AuditionReadinessRing(readyCount: audition.packageReadyCount, isSent: audition.status == .sent)
        }
        .compactListCardStyle()
    }

    private var deadlineColor: Color {
        if audition.status == .sent || !audition.hasDeadline {
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
}

private struct AuditionReadinessRing: View {
    let readyCount: Int
    let isSent: Bool

    var body: some View {
        if isSent {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(Theme.Colors.successGreen)
        } else {
            CompactProgressRing(
                progress: Double(readyCount) / 3.0,
                label: "\(readyCount)",
                tint: readyCount == 3 ? Theme.Colors.successGreen : Theme.Colors.accent
            )
        }
    }
}
