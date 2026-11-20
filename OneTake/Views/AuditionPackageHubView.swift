import SwiftUI
import SwiftData
import PhotosUI

enum PackageDeliverable: String, CaseIterable, Identifiable {
    case headshots
    case slate
    case audition

    var id: String { rawValue }

    var stepNumber: Int {
        switch self {
        case .headshots: return 1
        case .slate: return 2
        case .audition: return 3
        }
    }

    var title: String {
        switch self {
        case .headshots: return "Headshot"
        case .slate: return "Slate"
        case .audition: return "Audition Clip"
        }
    }

    var icon: String {
        switch self {
        case .headshots: return "person.crop.rectangle.badge.plus"
        case .slate: return "person.badge.shield.checkmark"
        case .audition: return "movieclapper"
        }
    }
}

enum PackageReviewTarget: Identifiable {
    case headshots([HeadshotAsset])
    case slate(VideoTake)
    case audition(VideoTake)

    var id: String {
        switch self {
        case .headshots: return "headshots"
        case .slate(let take): return "slate-\(take.id)"
        case .audition(let take): return "audition-\(take.id)"
        }
    }
}

struct AuditionPackageHubView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @Bindable var audition: Audition

    // Sheet / flow triggers
    @State private var showingHeadshotFlow = false
    @State private var showingSlateSetup = false
    @State private var showingAuditionMode = false
    @State private var showingDetailsEditor = false
    @State private var showingPackageValidation = false
    @State private var showingDeleteConfirmation = false

    // Issue 8: Active review target enum
    @State private var activeReviewTarget: PackageReviewTarget? = nil

    // Upfront photo/video picker state
    @State private var selectedHeadshotPhotoItems: [PhotosPickerItem] = []
    @State private var showingHeadshotsPicker = false

    @State private var selectedSlateVideoItem: PhotosPickerItem?
    @State private var showingSlateVideoPicker = false

    @State private var selectedAuditionVideoItem: PhotosPickerItem?
    @State private var showingAuditionVideoPicker = false

    // Hero artwork picker
    @State private var selectedHeroPhotoItem: PhotosPickerItem?
    @State private var showingHeroPhotoPicker = false
    @State private var customHeroImage: UIImage?

    // Imported photos review
    @State private var showingHeadshotImportReview = false
    @State private var importedHeadshotImages: [UIImage] = []

    // Transient confirmation banners
    @State private var bannerMessage: String?
    @State private var bannerColor: Color = Theme.Colors.successGreen
    @State private var bannerTask: Task<Void, Never>?
    @State private var pendingImportedVideoPath: String?

    // MARK: - Deliverables State

    private func isDeliverableComplete(_ deliverable: PackageDeliverable) -> Bool {
        switch deliverable {
        case .headshots:
            return audition.isHeadshotsReady
        case .slate:
            return audition.isSlateReady
        case .audition:
            return audition.isAuditionReady
        }
    }

    private var incompleteDeliverables: [PackageDeliverable] {
        PackageDeliverable.allCases.filter { !isDeliverableComplete($0) }
    }

    private var completedDeliverables: [PackageDeliverable] {
        PackageDeliverable.allCases.filter { isDeliverableComplete($0) }
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .top) {
            Theme.Colors.canvasBackground
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Full-bleed Apple TV–style Hero (edge-to-edge top/left/right, blurred bottom dissolve)
                    headerSection

                    VStack(alignment: .leading, spacing: 22) {
                        // PACKAGE header + 3-segment progress bar with labeled items
                        packageProgressSection

                        // Deliverables Section
                        deliverablesSection

                        // Export Package Button (Visible when at least 1 item ready)
                        if audition.packageReadyCount > 0 {
                            Button {
                                showingPackageValidation = true
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "square.and.arrow.up")
                                    Text("Export Package")
                                }
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.Colors.onAction)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Theme.Colors.primaryPlum)
                                .clipShape(Capsule())
                            }
                            .padding(.top, 4)
                            .padding(.bottom, 36)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .ignoresSafeArea(edges: .top)
            .scrollEdgeHaptics()

            // Transient confirmation banner overlay
            if let banner = bannerMessage {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(bannerColor)
                    Text(banner)
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Spacer()
                }
                .padding(14)
                .background(Theme.Colors.cardSurface)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 4)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(99)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showingDetailsEditor = true
                    } label: {
                        Label("Edit Audition Details", systemImage: "pencil")
                    }

                    Menu {
                        heroBackdropMenuItems()
                    } label: {
                        Label("Change Hero Image", systemImage: "photo.on.rectangle")
                    }

                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label("Delete Audition", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.Colors.accent)
                }
                .accessibilityLabel("Audition options")
            }
        }
        .onDisappear {
            bannerTask?.cancel()
            cleanupPendingImportedVideoIfUnused()
        }
        .confirmationDialog(
            "Delete Audition?",
            isPresented: $showingDeleteConfirmation
        ) {
            Button("Delete \"\(audition.projectName)\"", role: .destructive) {
                appState.deleteAudition(audition)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove the audition, takes, and cue recordings.")
        }
        // Capture Sheets
        .sheet(isPresented: $showingHeadshotFlow) {
            HeadshotCaptureView(audition: audition, onCompleted:  {
                showBanner("Headshots saved successfully!")
            })
            .presentationBackground(Theme.Colors.canvasBackground)
        }
        .sheet(isPresented: $showingSlateSetup) {
            SlateProfileSetupView(audition: audition) {
                showBanner("Slate saved successfully!")
            }
            .presentationBackground(Theme.Colors.canvasBackground)
        }
        .sheet(isPresented: $showingAuditionMode) {
            AuditionModeAndCuesView(audition: audition) {
                showBanner("Audition take saved successfully!")
            }
            .presentationBackground(Theme.Colors.canvasBackground)
        }
        .sheet(isPresented: $showingDetailsEditor) {
            AuditionDetailsEditorView(existingAudition: audition) { _ in
                showBanner("Audition details updated!")
            }
            .presentationDragIndicator(.visible)
            .presentationBackground(Theme.Colors.canvasBackground)
        }
        .sheet(isPresented: $showingPackageValidation) {
            PackageValidationAndExportView(audition: audition)
                .presentationBackground(Theme.Colors.canvasBackground)
        }
        // Issue 8: Direct Review FullScreenCover
        .fullScreenCover(item: $activeReviewTarget, onDismiss: { cleanupPendingImportedVideoIfUnused() }) { target in
            switch target {
            case .headshots(let assets):
                HeadshotReviewView(
                    audition: audition,
                    initialFront: nil,
                    initialLeft: nil,
                    initialRight: nil,
                    assets: assets
                ) {
                    activeReviewTarget = nil
                    showBanner("Headshots updated successfully!")
                }
            case .slate(let take):
                let resolvedURL = MediaStorage.resolveURL(for: take.filePath) ?? URL(fileURLWithPath: take.filePath)
                TakeReviewView(
                    audition: audition,
                    rawVideoURL: resolvedURL,
                    totalDurationSeconds: take.durationSeconds,
                    isSlate: true,
                    qualityMetrics: PreTakeQualityMetrics(),
                    initialNoiseCleaned: take.noiseCleaned
                ) { approvedTake in
                    applyApprovedTake(approvedTake, replacing: take, isSlate: true)
                    activeReviewTarget = nil
                    showBanner("Slate video saved!")
                } onRetake: {
                    activeReviewTarget = nil
                    showingSlateSetup = true
                }
            case .audition(let take):
                let resolvedURL = MediaStorage.resolveURL(for: take.filePath) ?? URL(fileURLWithPath: take.filePath)
                TakeReviewView(
                    audition: audition,
                    rawVideoURL: resolvedURL,
                    totalDurationSeconds: take.durationSeconds,
                    isSlate: false,
                    qualityMetrics: PreTakeQualityMetrics(),
                    initialNoiseCleaned: take.noiseCleaned
                ) { approvedTake in
                    applyApprovedTake(approvedTake, replacing: take, isSlate: false)
                    activeReviewTarget = nil
                    showBanner("Audition take saved!")
                } onRetake: {
                    activeReviewTarget = nil
                    showingAuditionMode = true
                }
            }
        }
        // Upfront Photos Pickers
        .photosPicker(
            isPresented: $showingHeadshotsPicker,
            selection: $selectedHeadshotPhotoItems,
            maxSelectionCount: 3,
            matching: .images
        )
        .onChange(of: selectedHeadshotPhotoItems) { _, items in
            guard !items.isEmpty else { return }
            loadUpfrontHeadshotPhotos(items)
        }
        .photosPicker(
            isPresented: $showingSlateVideoPicker,
            selection: $selectedSlateVideoItem,
            matching: .videos
        )
        .onChange(of: selectedSlateVideoItem) { _, item in
            guard let item = item else { return }
            selectedSlateVideoItem = nil
            loadUpfrontSlateVideo(item)
        }
        .photosPicker(
            isPresented: $showingAuditionVideoPicker,
            selection: $selectedAuditionVideoItem,
            matching: .videos
        )
        .onChange(of: selectedAuditionVideoItem) { _, item in
            guard let item = item else { return }
            selectedAuditionVideoItem = nil
            loadUpfrontAuditionVideo(item)
        }
        .photosPicker(
            isPresented: $showingHeroPhotoPicker,
            selection: $selectedHeroPhotoItem,
            matching: .images
        )
        .onChange(of: selectedHeroPhotoItem) { _, item in
            guard let item else { return }
            selectedHeroPhotoItem = nil
            saveCustomHeroPhoto(item)
        }
        .task(id: audition.heroImagePath) {
            loadCustomHeroImageFromDisk()
        }
        .sheet(isPresented: $showingHeadshotImportReview) {
            if !importedHeadshotImages.isEmpty {
                HeadshotReviewView(
                    audition: audition,
                    initialFront: importedHeadshotImages.indices.contains(0) ? importedHeadshotImages[0] : nil,
                    initialLeft: importedHeadshotImages.indices.contains(1) ? importedHeadshotImages[1] : nil,
                    initialRight: importedHeadshotImages.indices.contains(2) ? importedHeadshotImages[2] : nil
                ) {
                    showingHeadshotImportReview = false
                    importedHeadshotImages = []
                    showBanner("Headshots saved successfully!")
                }
            }
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        let baseHeight: CGFloat = 290

        return GeometryReader { geo in
            let minY = geo.frame(in: .scrollView(axis: .vertical)).minY
            let stretch = max(0, minY)
            let heroHeight = baseHeight + stretch

            ZStack(alignment: .bottom) {
                // Full-bleed edge-to-edge backdrop with progressive bottom blur & canvas dissolve
                ZStack {
                    heroBackdropView
                        .frame(width: geo.size.width, height: heroHeight)
                        .clipped()

                    heroBackdropView
                        .frame(width: geo.size.width, height: heroHeight)
                        .clipped()
                        .blur(radius: 22)
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0.45),
                                    .init(color: .black.opacity(0.75), location: 0.72),
                                    .init(color: .black, location: 0.94)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    // Mid-hero legibility scrim + bottom dissolve into canvasBackground (#000000 in Dark Mode)
                    LinearGradient(
                        stops: [
                            .init(color: Color.black.opacity(0.24), location: 0.0),
                            .init(color: Color.black.opacity(0.08), location: 0.34),
                            .init(color: Color.black.opacity(0.58), location: 0.68),
                            .init(color: Theme.Colors.canvasBackground.opacity(0.85), location: 0.88),
                            .init(color: Theme.Colors.canvasBackground, location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .frame(width: geo.size.width, height: heroHeight)
                .clipped()

                // Centered editorial typography anchored below the nav bar clearance
                VStack(spacing: 8) {
                    Text(cleanDeadlineString)
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.95))
                        .lineLimit(1)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.52), in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.22), lineWidth: 0.8))

                    Text(audition.projectName)
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .padding(.horizontal, 16)

                    Text(heroMetadataLine)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.bottom, 22)
            }
            .frame(width: geo.size.width, height: heroHeight)
            .offset(y: -stretch)
        }
        .frame(height: baseHeight)
    }

    @ViewBuilder
    private var heroBackdropView: some View {
        if let customHeroImage {
            Image(uiImage: customHeroImage)
                .resizable()
                .scaledToFill()
        } else {
            Image(headerArtwork)
                .resizable()
                .scaledToFill()
        }
    }

    @ViewBuilder
    private func heroBackdropMenuItems() -> some View {
        Button {
            showingHeroPhotoPicker = true
        } label: {
            Label("Choose Photo from Library", systemImage: "photo.on.rectangle.angled")
        }

        Section("Studio Backdrops") {
            Button {
                selectBuiltInHeroArtwork(Theme.Artwork.auditionBanner)
            } label: {
                Label("Cinema Set", systemImage: "film")
            }

            Button {
                selectBuiltInHeroArtwork(Theme.Artwork.dramaBanner)
            } label: {
                Label("Stage & Drama", systemImage: "theatermasks")
            }

            Button {
                selectBuiltInHeroArtwork(Theme.Artwork.practiceBanner)
            } label: {
                Label("Rehearsal Studio", systemImage: "sparkles")
            }
        }

        if audition.heroImagePath != nil || audition.heroArtworkName != nil {
            Button(role: .destructive) {
                resetHeroBackdropToDefault()
            } label: {
                Label("Reset to Default", systemImage: "arrow.counterclockwise")
            }
        }
    }

    private var defaultHeaderArtwork: String {
        audition.production == .theater ? Theme.Artwork.dramaBanner : Theme.Artwork.auditionBanner
    }

    private var headerArtwork: String {
        audition.heroArtworkName ?? defaultHeaderArtwork
    }

    private var heroMetadataLine: String {
        let role = audition.roleName.trimmingCharacters(in: .whitespacesAndNewlines)
        if role.isEmpty {
            return audition.production.rawValue
        }
        return "\(audition.production.rawValue) · \(role)"
    }

    private func selectBuiltInHeroArtwork(_ artworkName: String) {
        Haptics.selectionTick()
        if let oldPath = audition.heroImagePath {
            MediaStorage.removeFile(at: oldPath)
            audition.heroImagePath = nil
        }
        customHeroImage = nil
        audition.heroArtworkName = artworkName
        appState.saveChanges()
    }

    private func resetHeroBackdropToDefault() {
        Haptics.selectionTick()
        if let oldPath = audition.heroImagePath {
            MediaStorage.removeFile(at: oldPath)
            audition.heroImagePath = nil
        }
        customHeroImage = nil
        audition.heroArtworkName = nil
        appState.saveChanges()
    }

    private func loadCustomHeroImageFromDisk() {
        guard let relPath = audition.heroImagePath,
              let url = MediaStorage.resolveURL(for: relPath),
              let image = UIImage(contentsOfFile: url.path) else {
            customHeroImage = nil
            return
        }
        customHeroImage = image
    }

    private func saveCustomHeroPhoto(_ item: PhotosPickerItem) {
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let decoded = UIImage(data: data) else {
                    await MainActor.run {
                        showBanner("Could not load selected photo.", isSuccess: false)
                    }
                    return
                }
                let prepared = Self.downscaledHeroImage(decoded, maxDimension: 1400)
                guard let jpegData = prepared.jpegData(compressionQuality: 0.85) else {
                    await MainActor.run {
                        showBanner("Could not process selected photo.", isSuccess: false)
                    }
                    return
                }
                let relPath = "HeroBanners/hero_\(audition.id.uuidString).jpg"
                let savedRelPath = try MediaStorage.saveData(jpegData, relativePath: relPath)
                await MainActor.run {
                    if let oldPath = audition.heroImagePath, oldPath != savedRelPath {
                        MediaStorage.removeFile(at: oldPath)
                    }
                    audition.heroArtworkName = nil
                    audition.heroImagePath = savedRelPath
                    customHeroImage = prepared
                    appState.saveChanges()
                    Haptics.success()
                }
            } catch {
                await MainActor.run {
                    showBanner("Could not update hero image.", isSuccess: false)
                }
            }
        }
    }

    nonisolated private static func downscaledHeroImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else { return image }
        let scale = maxDimension / longest
        let targetSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private var cleanDeadlineString: String {
        audition.deadlineUrgencyLabel()
    }

    // MARK: - PACKAGE Progress Bar Section

    private var packageProgressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("PACKAGE")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.Colors.textSecondary)

                Spacer()

                Text("\(audition.packageReadyCount) of 3 ready")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(audition.packageReadyCount == 3 ? Theme.Colors.successGreen : Theme.Colors.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(audition.packageReadyCount == 3 ? Theme.Colors.successGreen.opacity(0.12) : Theme.Colors.lavenderSurface)
                    .clipShape(Capsule())
            }

            // 3-segment progress bar (each segment colored by its own boolean)
            HStack(spacing: 8) {
                Capsule()
                    .fill(audition.isHeadshotsReady ? Theme.Colors.successGreen : Theme.Colors.lavenderSurface)
                    .frame(height: 6)
                Capsule()
                    .fill(audition.isSlateReady ? Theme.Colors.successGreen : Theme.Colors.lavenderSurface)
                    .frame(height: 6)
                Capsule()
                    .fill(audition.isAuditionReady ? Theme.Colors.successGreen : Theme.Colors.lavenderSurface)
                    .frame(height: 6)
            }

            // Labels under progress bar
            HStack {
                Text("Headshot")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(audition.isHeadshotsReady ? Theme.Colors.successGreen : Theme.Colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("Slate")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(audition.isSlateReady ? Theme.Colors.successGreen : Theme.Colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)

                Text("Audition Clip")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(audition.isAuditionReady ? Theme.Colors.successGreen : Theme.Colors.textSecondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    // MARK: - Deliverables Section

    private var deliverablesSection: some View {
        VStack(spacing: 12) {
            // 1. Completed Items as Compact White Rounded Rows
            ForEach(completedDeliverables) { deliverable in
                completedRow(for: deliverable)
            }

            // 2. Current Incomplete Deliverable (Focus Card)
            if let hero = incompleteDeliverables.first {
                heroFocusCard(for: hero)

                // 3. Any Remaining Incomplete Item After It as a Simple Compact Row
                let remaining = incompleteDeliverables.dropFirst()
                ForEach(Array(remaining)) { item in
                    simpleRemainingRow(for: item)
                }
            } else if audition.packageReadyCount == 3 {
                // All 3 Completed Card
                allCompletedCard
            }
        }
    }

    // MARK: - Completed Row
    // Compact white rounded rows with green checkmark.seal, bold title, purple status, and Review button
    private func completedRow(for deliverable: PackageDeliverable) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 20))
                .foregroundStyle(Theme.Colors.successGreen)

            VStack(alignment: .leading, spacing: 2) {
                Text(deliverableTitle(deliverable))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.Colors.textPrimary)

                Text(completedStatusText(deliverable))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Colors.accent)
            }

            Spacer()

            Button("Review") {
                triggerReview(for: deliverable)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.Colors.accent)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Theme.Colors.lavenderSurface)
            .clipShape(Capsule())
        }
        .padding(14)
        .background(Theme.Colors.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 2)
    }

    private func deliverableTitle(_ deliverable: PackageDeliverable) -> String {
        switch deliverable {
        case .headshots: return "Headshot"
        case .slate: return "Slate"
        case .audition: return "Audition Clip"
        }
    }

    private func completedStatusText(_ deliverable: PackageDeliverable) -> String {
        switch deliverable {
        case .headshots: return "3 Photos Saved"
        case .slate: return "Video Saved"
        case .audition: return "Video Saved"
        }
    }

    // MARK: - Current Incomplete Focus Card
    // UP NEXT • PIECE X OF 3 with ≈ 2 min, bold title, 1-line subtitle, primary pill & soft lavender pill

    private func heroFocusCard(for deliverable: PackageDeliverable) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Eyebrow row: UP NEXT • PIECE X OF 3 on left, ≈ 2 min on right
            HStack {
                Text("UP NEXT • PIECE \(deliverable.stepNumber) OF 3")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.Colors.accent)

                Spacer()

                Text("≈ 2 min")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.Colors.textSecondary)
            }

            // Bold Title
            Text(focusCardTitle(deliverable))
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Theme.Colors.textPrimary)

            // Single short 1-line subtitle
            Text(focusCardSubtitle(deliverable))
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Theme.Colors.textSecondary)
                .lineLimit(1)

            // Buttons: Dark plum primary + soft lavender secondary
            HStack(spacing: 10) {
                Button {
                    startAction(for: deliverable)
                } label: {
                    Text(focusPrimaryButtonTitle(deliverable))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.Colors.onAction)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Theme.Colors.primaryPlum)
                        .clipShape(Capsule())
                }

                Button {
                    startImport(for: deliverable)
                } label: {
                    Text(focusSecondaryButtonTitle(deliverable))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.Colors.accent)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 14)
                        .background(Theme.Colors.lavenderSurface)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(20)
        .background(Theme.Colors.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.primary.opacity(0.06), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 2)
    }

    private func focusCardTitle(_ deliverable: PackageDeliverable) -> String {
        switch deliverable {
        case .headshots: return "Your Headshots"
        case .slate: return "Your Slate"
        case .audition: return "Your Audition"
        }
    }

    private func focusCardSubtitle(_ deliverable: PackageDeliverable) -> String {
        switch deliverable {
        case .headshots: return "Front, left profile, and right profile with auto-crop."
        case .slate: return "Introduce yourself clearly using the teleprompter."
        case .audition: return "Lights, Camera and Action!"
        }
    }

    private func focusPrimaryButtonTitle(_ deliverable: PackageDeliverable) -> String {
        switch deliverable {
        case .headshots: return "Capture Headshots"
        case .slate: return "Record your Slate"
        case .audition: return "Record your Audition"
        }
    }

    private func focusSecondaryButtonTitle(_ deliverable: PackageDeliverable) -> String {
        switch deliverable {
        case .headshots: return "Import Photos"
        case .slate, .audition: return "Import Video"
        }
    }

    // MARK: - Simple Remaining Incomplete Row

    private func simpleRemainingRow(for deliverable: PackageDeliverable) -> some View {
        Button {
            startAction(for: deliverable)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Theme.Colors.lavenderSurface)
                        .frame(width: 32, height: 32)

                    Image(systemName: deliverable.icon)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.Colors.accent)
                }

                Text(deliverableTitle(deliverable))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textPrimary)

                Spacer()

                Text(deliverable == .headshots ? "Not captured" : "Not recorded")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Colors.textSecondary)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textSecondary.opacity(0.5))
            }
            .padding(14)
            .background(Theme.Colors.cardSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    // MARK: - All Completed Card

    private var allCompletedCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 32))
                .foregroundStyle(Theme.Colors.successGreen)

            Text("Submission Package Ready!")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Theme.Colors.textPrimary)

            Text("Headshots, slate, and audition clips are fully completed.")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Theme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(Theme.Colors.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Actions

    private func startAction(for deliverable: PackageDeliverable) {
        switch deliverable {
        case .headshots: showingHeadshotFlow = true
        case .slate: showingSlateSetup = true
        case .audition: showingAuditionMode = true
        }
    }

    private func startImport(for deliverable: PackageDeliverable) {
        switch deliverable {
        case .headshots: showingHeadshotsPicker = true
        case .slate: showingSlateVideoPicker = true
        case .audition: showingAuditionVideoPicker = true
        }
    }

    // MARK: - Issue 8 Review Handler

    private func triggerReview(for deliverable: PackageDeliverable) {
        switch deliverable {
        case .headshots:
            activeReviewTarget = .headshots(audition.headshots)
        case .slate:
            if let take = audition.slateTakes.first(where: { $0.id == audition.selectedSlateTakeID }) ?? audition.slateTakes.last {
                activeReviewTarget = .slate(take)
            } else {
                showingSlateSetup = true
            }
        case .audition:
            if let take = audition.auditionTakes.first(where: { $0.id == audition.selectedAuditionTakeID }) ?? audition.auditionTakes.last {
                activeReviewTarget = .audition(take)
            } else {
                showingAuditionMode = true
            }
        }
    }

    // MARK: - Review Approval & Import Cleanup

    private func applyApprovedTake(_ approvedTake: VideoTake, replacing originalTake: VideoTake, isSlate: Bool) {
        var updatedTake = approvedTake
        updatedTake.filePath = MediaStorage.storedRelativePath(for: approvedTake.filePath)
        let oldRelPath = MediaStorage.storedRelativePath(for: originalTake.filePath)

        if isSlate {
            if let index = audition.slateTakes.firstIndex(where: { $0.id == originalTake.id }) {
                audition.slateTakes[index] = updatedTake
            } else {
                audition.slateTakes.append(updatedTake)
            }
            audition.selectedSlateTakeID = updatedTake.id
            for idx in audition.requirements.indices {
                if audition.requirements[idx].title.lowercased().contains("slate") {
                    audition.requirements[idx].isCompleted = true
                }
            }
        } else {
            if let index = audition.auditionTakes.firstIndex(where: { $0.id == originalTake.id }) {
                audition.auditionTakes[index] = updatedTake
            } else {
                audition.auditionTakes.append(updatedTake)
            }
            audition.selectedAuditionTakeID = updatedTake.id
            for idx in audition.requirements.indices {
                let lower = audition.requirements[idx].title.lowercased()
                if lower.contains("audition") || lower.contains("self-tape") {
                    audition.requirements[idx].isCompleted = true
                }
            }
        }

        if oldRelPath != updatedTake.filePath {
            MediaStorage.removeFile(at: originalTake.filePath)
        }
        if pendingImportedVideoPath == oldRelPath {
            pendingImportedVideoPath = nil
        }

        appState.saveChanges()
    }

    private func cleanupPendingImportedVideoIfUnused() {
        guard let pendingPath = pendingImportedVideoPath else { return }
        pendingImportedVideoPath = nil
        let normalized = MediaStorage.storedRelativePath(for: pendingPath)
        let isUsedInTakes = (audition.slateTakes + audition.auditionTakes)
            .contains { MediaStorage.storedRelativePath(for: $0.filePath) == normalized }
        if !isUsedInTakes {
            MediaStorage.removeFile(at: normalized)
        }
    }

    // MARK: - Upfront Import Loaders

    private func loadUpfrontHeadshotPhotos(_ items: [PhotosPickerItem]) {
        Task {
            var images: [UIImage] = []
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    images.append(img)
                }
            }

            guard !images.isEmpty else {
                await MainActor.run {
                    self.selectedHeadshotPhotoItems = []
                    self.showBanner("Could not load selected photos.", isSuccess: false)
                }
                return
            }

            await MainActor.run {
                self.importedHeadshotImages = images
                self.selectedHeadshotPhotoItems = []
                self.showingHeadshotImportReview = true
                if images.count < 3 {
                    self.showBanner("Selected \(images.count) of 3 photos — pick remaining angles in Review.", isSuccess: false)
                }
            }
        }
    }

    private func loadUpfrontSlateVideo(_ item: PhotosPickerItem) {
        loadUpfrontVideo(item, isSlate: true)
    }

    private func loadUpfrontAuditionVideo(_ item: PhotosPickerItem) {
        loadUpfrontVideo(item, isSlate: false)
    }

    private func loadUpfrontVideo(_ item: PhotosPickerItem, isSlate: Bool) {
        Task {
            guard let movie = try? await item.loadTransferable(type: MovieTransferable.self) else {
                await MainActor.run {
                    showBanner("Could not import video.", isSuccess: false)
                }
                return
            }
            defer { try? FileManager.default.removeItem(at: movie.url) }

            let ext = movie.url.pathExtension.isEmpty ? "mp4" : movie.url.pathExtension
            let kind = isSlate ? "Slate" : "Audition"
            let relPath = "Takes_\(audition.id)/Imported_\(kind)_\(UUID().uuidString.prefix(6)).\(ext)"

            do {
                let storedRelPath = try MediaStorage.copyItem(from: movie.url, toRelativePath: relPath)
                guard let persistedURL = MediaStorage.resolveURL(for: storedRelPath) else {
                    await MainActor.run {
                        showBanner("Could not save imported video.", isSuccess: false)
                    }
                    return
                }

                let metadata = await PackageExportHelper.inspectVideoMetadata(at: persistedURL)
                let duration = metadata?.durationSeconds ?? 0
                let sizeMB = metadata?.fileSizeMB ?? MediaStorage.fileSizeMB(at: storedRelPath)
                let aspectRatio = metadata?.aspectRatioString ?? "16:9"
                let isPortrait = metadata?.isPortrait ?? false

                let take = VideoTake(
                    title: "Imported \(kind) Take",
                    filePath: storedRelPath,
                    durationSeconds: duration,
                    fileSizeMB: sizeMB,
                    aspectRatioString: aspectRatio,
                    isPortrait: isPortrait,
                    trimEndSeconds: duration
                )

                await MainActor.run {
                    self.pendingImportedVideoPath = storedRelPath
                    self.activeReviewTarget = isSlate ? .slate(take) : .audition(take)
                }
            } catch {
                await MainActor.run {
                    showBanner("Video import failed: \(error.localizedDescription)", isSuccess: false)
                }
            }
        }
    }

    // MARK: - Banner Trigger

    private func showBanner(_ message: String, isSuccess: Bool = true) {
        bannerTask?.cancel()
        if isSuccess {
            Haptics.success()
        } else {
            Haptics.error()
        }
        withAnimation {
            bannerMessage = message
            bannerColor = isSuccess ? Theme.Colors.successGreen : Theme.Colors.warningAmber
        }
        bannerTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation {
                    bannerMessage = nil
                }
            }
        }
    }
}
