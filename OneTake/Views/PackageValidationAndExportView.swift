import SwiftUI
import AVFoundation
import AVKit
import UIKit
import MessageUI

/// Phase 3's advisory package check.  Every item is actionable, but none of
/// the checks gate delivery: casting may explicitly accept an exception.
struct PackageValidationAndExportView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Bindable var audition: Audition

    @State private var stage: Stage = .checking
    @State private var compressorRoute: CompressorRoute?
    @State private var compressionFeedbackMessage: String?
    @State private var showingShareChoices = false
    @State private var showingCelebration = false
    @State private var editingFileID: String?
    @State private var names: [String: String] = [:]
    @State private var zipFileName: String = ""
    @State private var tempPackageDirectory: URL?
    @State private var preparingShareStatus: String?
    @State private var shareSheetErrorMessage: String?
    @State private var exportErrorMessage: String?
    @State private var reviewRoute: ReviewRoute?
    @State private var cropRoute: CropRoute?
    @State private var isCyclingHeadshotCrops = false
    @State private var didApplyCropForCurrentAngle = false
    @State private var cropBatchTotalCount = 0
    @State private var slateMetadata: VideoMetadata?
    @State private var clipMetadata: VideoMetadata?

    private typealias VideoMetadata = (isPortrait: Bool, aspectRatioString: String, durationSeconds: Double, fileSizeMB: Double)

    private enum Stage { case checking, ready }
    private enum ReviewRoute: Identifiable {
        case slate(VideoTake)
        case audition(VideoTake)
        var id: UUID {
            switch self {
            case .slate(let take), .audition(let take): take.id
            }
        }
    }
    private struct CropRoute: Identifiable {
        let id = UUID()
        let angle: HeadshotAngle
        let image: UIImage
        let stepIndex: Int
        let totalCount: Int
    }
    private struct CompressorRoute: Identifiable {
        let id = UUID()
        let take: VideoTake
        let isSlate: Bool
        let originalSizeMB: Double
    }

    private var rules: ValidationRules { audition.validationRules }
    private var slate: VideoTake? { audition.selectedSlateTake }
    private var clip: VideoTake? { audition.selectedAuditionTake }

    private var videoInspectionKey: String {
        "\(slate?.id.uuidString ?? "none")|\(slate?.filePath ?? "")|\(clip?.id.uuidString ?? "none")|\(clip?.filePath ?? "")"
    }

    private var expectedOrientation: String {
        switch rules.requiredPortrait {
        case .some(true): return "9:16 Portrait"
        case .some(false): return "16:9 Landscape"
        case .none: return "orientation"
        }
    }

    private var packageName: String {
        PackageExportHelper.sanitizeFileStem(
            "\(actorFileStem)_\(audition.projectName)",
            fallback: "OneTake_Package"
        )
    }

    private var fileSizeTotal: Double {
        PackageExportHelper.actualPackageSizeMB(for: audition)
    }

    private func actualSizeMB(for take: VideoTake, metadata: VideoMetadata?) -> Double {
        if MediaStorage.fileExists(at: take.filePath) {
            let diskSize = MediaStorage.fileSizeMB(at: take.filePath)
            if diskSize > 0 { return diskSize }
            if let metaSize = metadata?.fileSizeMB, metaSize > 0 { return metaSize }
        }
        return take.fileSizeMB
    }

    private var requiredVideoTakes: [VideoTake] {
        [
            audition.requiresSlate ? slate : nil,
            audition.requiresAudition ? clip : nil
        ].compactMap { $0 }
    }

    private var requiresAnyVideo: Bool {
        audition.requiresSlate || audition.requiresAudition
    }

    private var oversizedTake: VideoTake? {
        if audition.requiresSlate, let slate, actualSizeMB(for: slate, metadata: slateMetadata) > rules.maxPerClipSizeMB {
            return slate
        }
        if audition.requiresAudition, let clip, actualSizeMB(for: clip, metadata: clipMetadata) > rules.maxPerClipSizeMB {
            return clip
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            validationView
                .background(Theme.Colors.canvasBackground)
                .navigationTitle("Check your package")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }
                .navigationDestination(
                    isPresented: Binding(
                        get: { stage == .ready },
                        set: { if !$0 { stage = .checking } }
                    )
                ) {
                    readyView
                        .background(Theme.Colors.canvasBackground)
                        .navigationTitle("Ready to Send")
                        .navigationBarTitleDisplayMode(.inline)
                }
            .sheet(item: $compressorRoute) { route in
                VideoCompressorView(
                    audition: audition,
                    take: route.take,
                    isSlate: route.isSlate,
                    initialSizeMB: route.originalSizeMB,
                    isDemoMode: appState.isDemoMode
                ) { originalMB, compressedMB in
                    appState.saveChanges()
                    Task { await refreshVideoMetadata() }
                    let label = route.isSlate ? "Slate" : "Audition Clip"
                    compressionFeedbackMessage = "\(label) compressed: \(formattedSizeString(originalMB)) → \(formattedSizeString(compressedMB))"
                }
                .presentationBackground(Theme.Colors.canvasBackground)
            }
            .fullScreenCover(item: $reviewRoute) { route in
                switch route {
                case .slate(let take): reviewView(take: take, isSlate: true)
                case .audition(let take): reviewView(take: take, isSlate: false)
                }
            }
            .fullScreenCover(item: $cropRoute, onDismiss: { handleCropDismiss() }) { route in
                HeadshotCropView(
                    originalImage: route.image,
                    defaultRatio: rules.requiredHeadshotRatio,
                    angle: route.angle,
                    batchProgress: (current: route.stepIndex, total: route.totalCount)
                ) { image, ratio, preset in
                    saveCrop(image, ratio: ratio, preset: preset, angle: route.angle)
                }
            }
            .sheet(isPresented: $showingShareChoices, onDismiss: {
                if preparingShareStatus == nil {
                    cleanupTempPackageDirectory()
                }
            }) {
                shareChoices
                    .presentationBackground(Theme.Colors.canvasBackground)
            }
            .fullScreenCover(isPresented: $showingCelebration) {
                DeliveryCelebrationView(audition: audition) { dismiss() }
            }
            .alert(
                "Export Unavailable",
                isPresented: Binding(
                    get: { exportErrorMessage != nil },
                    set: { if !$0 { exportErrorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(exportErrorMessage ?? "")
            }
            .onAppear { seedNamesIfNeeded() }
            .onDisappear { cleanupTempPackageDirectory() }
            .onChange(of: exportErrorMessage) { _, msg in
                if msg != nil { Haptics.error() }
            }
            .onChange(of: shareSheetErrorMessage) { _, msg in
                if msg != nil { Haptics.error() }
            }
            .task(id: videoInspectionKey) {
                await refreshVideoMetadata()
            }
        }
    }

    private var validationView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(rules.isFromNotice ? "Following casting instructions from your notice..." : "Following standard casting call submission guidelines and format")
                    .font(Theme.Typography.bodyRegular)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.Colors.lavenderSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                Text("Checking against the Requirements...")
                    .font(Theme.Typography.sectionHeader)
                    .accessibilityAddTraits(.isHeader)

                if audition.requiresHeadshots {
                    validationCard(
                        "Headshots \(rules.requiredHeadshotRatio.rawValue)",
                        detail: headshotValidationDetail,
                        passed: headshotsPass,
                        action: hasMissingHeadshotFiles ? nil : "Fix crops"
                    ) {
                        presentHeadshotCrop()
                    }
                }
                if audition.requiresSlate {
                    validationCard(
                        "Slate under \(Int(rules.maxSlateSeconds))s",
                        detail: durationDetail(slate, metadata: slateMetadata, cap: rules.maxSlateSeconds),
                        passed: slateDurationPass,
                        action: (slate != nil && MediaStorage.fileExists(at: slate?.filePath)) ? "Open Slate Trimmer" : nil
                    ) {
                        if let slate, MediaStorage.fileExists(at: slate.filePath) {
                            reviewRoute = .slate(slate)
                        }
                    }
                }
                if audition.requiresAudition {
                    validationCard(
                        clipDurationTitle,
                        detail: durationDetail(clip, metadata: clipMetadata, cap: rules.maxClipSeconds),
                        passed: clipDurationPass,
                        action: (clip != nil && MediaStorage.fileExists(at: clip?.filePath)) ? "Open Audition Trimmer" : nil
                    ) {
                        if let clip, MediaStorage.fileExists(at: clip.filePath) {
                            reviewRoute = .audition(clip)
                        }
                    }
                }
                if requiresAnyVideo {
                    validationCard(
                        "Video orientation & ratio",
                        detail: orientationDetailText,
                        passed: orientationPass,
                        action: nil,
                        actionHandler: {}
                    )
                }
                validationCard(
                    "File Name",
                    detail: "Auto-formatted as \(formattedFilePrefix)",
                    passed: fileNamePass,
                    action: nil,
                    actionHandler: {}
                )
                if requiresAnyVideo {
                    validationCard(
                        "File Size",
                        detail: fileSizeValidationDetail,
                        passed: fileSizePass,
                        action: oversizedTake.map { "Compress \($0.id == clip?.id ? "Audition Clip" : "Slate")" }
                    ) {
                        if let oversizedTake {
                            openCompressor(for: oversizedTake)
                        }
                    }
                }

                if let compressionFeedbackMessage {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Theme.Colors.successGreen)
                        Text(compressionFeedbackMessage)
                            .font(Theme.Typography.bodyRegular)
                            .foregroundStyle(Theme.Colors.textPrimary)
                        Spacer()
                        Button {
                            withAnimation { self.compressionFeedbackMessage = nil }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.Colors.textSecondary)
                                .frame(width: 28, height: 28)
                        }
                        .accessibilityLabel("Dismiss compression confirmation")
                    }
                    .padding(14)
                    .background(Theme.Colors.successGreen.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                if let oversizedTake {
                    let sizeMB = actualSizeMB(for: oversizedTake, metadata: oversizedTake.id == slate?.id ? slateMetadata : clipMetadata)
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            Image(systemName: "film.stack")
                                .font(.title2)
                                .foregroundStyle(Theme.Colors.warningAmber)
                                .frame(width: 54, height: 42)
                                .background(Theme.Colors.warningAmber.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("A couple of things need attention...").font(Theme.Typography.cardTitle)
                                Text("\(oversizedTake.title) Size is \(formattedSizeString(sizeMB)) — File limit is \(Int(rules.maxPerClipSizeMB)) MB")
                                    .font(Theme.Typography.captionBadge).monospacedDigit().foregroundStyle(Theme.Colors.textSecondary)
                            }
                        }
                        Button { openCompressor(for: oversizedTake) } label: {
                            Label("Compress \(oversizedTake.id == clip?.id ? "Audition Clip" : "Slate")", systemImage: "arrow.down.right.and.arrow.up.left")
                                .secondaryLavenderButton()
                        }
                    }
                    .padding(16).cardStyle()
                }
            }
            .padding(16)
        }
        .scrollEdgeHaptics()
        .floatingBottomActionBar(horizontalPadding: 16) {
            Button { stage = .ready } label: {
                Text("Review Your Package").primaryCapsuleButton()
            }
            .buttonStyle(.plain)
            .accessibilityHint("Continues even when an advisory item needs review")
        }
    }

    private func validationCard(_ title: String, detail: String, passed: Bool, action: String?, actionHandler: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: passed ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(passed ? Theme.Colors.successGreen : Theme.Colors.warningAmber)
                .font(.title3)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(title).font(Theme.Typography.cardTitle)
                    Spacer()
                    Text(passed ? "PASS" : "REVIEW")
                        .statusBadge(color: passed ? Theme.Colors.successGreen : Theme.Colors.warningAmber)
                }
                Text(detail).font(Theme.Typography.captionBadge).foregroundStyle(Theme.Colors.textSecondary)
                if let action, !passed {
                    Button(action, action: actionHandler)
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.Colors.accent)
                        .padding(.top, 2)
                }
            }
        }
        .padding(14).cardStyle()
        .accessibilityElement(children: .combine)
    }

    private var readyView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(packageName).font(Theme.Typography.sectionHeader)
                    let readyCount = availableBundleItems.count
                    Text("\(readyCount) \(readyCount == 1 ? "element" : "elements") · ~\(formattedSizeString(fileSizeTotal))")
                        .font(Theme.Typography.captionBadge)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                .padding(16).cardStyle()

                Text("Bundle summary").font(Theme.Typography.sectionHeader)
                ForEach(bundleItems) { item in bundleFileRow(item) }
            }
            .padding(16)
        }
        .scrollEdgeHaptics()
        .floatingBottomActionBar(horizontalPadding: 16) {
            Button { showingShareChoices = true } label: {
                Label("Share Package", systemImage: "square.and.arrow.up").primaryCapsuleButton()
            }
            .buttonStyle(.plain)
        }
    }

    private struct BundleItem: Identifiable {
        let id: String
        let title: String
        let metadata: String
        let path: String
        let fallbackExtension: String
        let existsOnDisk: Bool
    }

    private var bundleItems: [BundleItem] {
        let prefix = formattedFilePrefix
        var result: [BundleItem] = []

        if audition.requiresHeadshots {
            let heads = HeadshotAngle.allCases.map { angle -> BundleItem in
                let headshot = audition.headshot(for: angle)
                let path = headshot.map { PackageExportHelper.effectiveHeadshotPath(for: $0) } ?? ""
                let exists = MediaStorage.fileExists(at: path)
                let sizeMB = exists ? MediaStorage.fileSizeMB(at: path) : 0
                let ratioText = headshot?.aspectRatio.rawValue ?? rules.requiredHeadshotRatio.rawValue
                let meta = exists ? "JPG · \(ratioText) · \(formattedSizeString(sizeMB))" : "JPG · Missing on disk"
                return BundleItem(
                    id: "headshot-\(angle.rawValue)",
                    title: "\(prefix)_\(angle.rawValue)",
                    metadata: meta,
                    path: path,
                    fallbackExtension: "jpg",
                    existsOnDisk: exists
                )
            }
            result.append(contentsOf: heads)
        }

        if audition.requiresSlate {
            let slatePath = slate?.filePath ?? ""
            let slateExists = MediaStorage.fileExists(at: slatePath)
            let slateMeta: String = {
                guard let slate else { return "MP4 · Not recorded" }
                guard slateExists else { return "MP4 · Missing on disk" }
                let dur = slateMetadata?.durationSeconds ?? slate.durationSeconds
                let size = actualSizeMB(for: slate, metadata: slateMetadata)
                return "MP4 · \(Int(dur.rounded()))s · \(formattedSizeString(size))"
            }()
            result.append(BundleItem(id: "slate", title: "\(prefix)_Slate", metadata: slateMeta, path: slatePath, fallbackExtension: "mp4", existsOnDisk: slateExists))
        }

        if audition.requiresAudition {
            let clipPath = clip?.filePath ?? ""
            let clipExists = MediaStorage.fileExists(at: clipPath)
            let clipMeta: String = {
                guard let clip else { return "MP4 · Not recorded" }
                guard clipExists else { return "MP4 · Missing on disk" }
                let dur = clipMetadata?.durationSeconds ?? clip.durationSeconds
                let size = actualSizeMB(for: clip, metadata: clipMetadata)
                return "MP4 · \(Int(dur.rounded()))s · \(formattedSizeString(size))"
            }()
            result.append(BundleItem(id: "audition", title: "\(prefix)_Audition", metadata: clipMeta, path: clipPath, fallbackExtension: "mp4", existsOnDisk: clipExists))
        }

        return result
    }

    private var availableBundleItems: [BundleItem] {
        bundleItems.filter(\.existsOnDisk)
    }

    private func bundleFileRow(_ item: BundleItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.fallbackExtension == "jpg" ? "photo" : "video")
                .foregroundStyle(item.existsOnDisk ? Theme.Colors.accent : Theme.Colors.warningAmber)
                .frame(width: 34, height: 34)
                .background(Theme.Colors.lavenderSurface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                if editingFileID == item.id {
                    TextField("Filename", text: Binding(get: { names[item.id, default: item.title] }, set: { names[item.id] = $0 }))
                        .textInputAutocapitalization(.words)
                        .font(Theme.Typography.bodyRegular)
                        .foregroundStyle(Theme.Colors.textPrimary)
                } else {
                    Text(names[item.id, default: item.title])
                        .font(Theme.Typography.bodyRegular)
                        .lineLimit(1)
                }
                Text(item.metadata)
                    .font(Theme.Typography.captionBadge)
                    .monospacedDigit()
                    .foregroundStyle(item.existsOnDisk ? Theme.Colors.textSecondary : Theme.Colors.warningAmber)
            }
            Spacer()
            Button { editingFileID = editingFileID == item.id ? nil : item.id } label: {
                Image(systemName: editingFileID == item.id ? "checkmark" : "pencil")
                    .frame(width: Theme.Layout.minTapTarget, height: Theme.Layout.minTapTarget)
            }
            .accessibilityLabel("Rename \(item.title)")
        }
        .padding(12).cardStyle()
    }

    private var effectiveZipArchiveName: String {
        PackageExportHelper.sanitizeFileStem(zipFileName, fallback: packageName)
    }

    private var shareChoices: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Use whatever the casting notice asked for.")
                        .font(Theme.Typography.bodyRegular)
                        .foregroundStyle(Theme.Colors.textSecondary)

                    if PackageExportHelper.canCreateSimulatedPrivateLink(isDemoMode: appState.isDemoMode) {
                        Button { createPrivateLink() } label: {
                            Label("Demo Preview Link (local only)", systemImage: "link")
                                .frame(maxWidth: .infinity, alignment: .leading).padding(16).cardStyle()
                        }
                        Text("Unlisted simulated link, works locally for 30 days (Demo Mode)")
                            .font(Theme.Typography.captionBadge)
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .padding(.top, -12)
                    } else {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "icloud.slash")
                                .foregroundStyle(Theme.Colors.textSecondary)
                            Text("Private cloud links aren't available in offline mode. Use Share Package or Email below to send your real files.")
                                .font(Theme.Typography.captionBadge)
                                .foregroundStyle(Theme.Colors.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Theme.Colors.lavenderSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    Button { sharePackageFiles() } label: {
                        Label("More ways to share", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, alignment: .leading).padding(16).cardStyle()
                    }
                    .disabled(preparingShareStatus != nil)
                    Text("AirDrop, Messages, or Save to Files").font(Theme.Typography.captionBadge).foregroundStyle(Theme.Colors.textSecondary).padding(.top, -12)

                    Button { sharePackageAsZip() } label: {
                        Label("Share as ZIP archive", systemImage: "doc.zipper")
                            .frame(maxWidth: .infinity, alignment: .leading).padding(16).cardStyle()
                    }
                    .disabled(preparingShareStatus != nil)

                    HStack(spacing: 8) {
                        Image(systemName: "pencil")
                            .font(.caption)
                            .foregroundStyle(Theme.Colors.textSecondary)
                        TextField("ZIP archive name", text: $zipFileName)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .font(Theme.Typography.bodyRegular)
                            .disabled(preparingShareStatus != nil)
                        Text(".zip")
                            .font(Theme.Typography.captionBadge)
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .cardStyle()

                    Text("Bundles all ready files into \(effectiveZipArchiveName).zip").font(Theme.Typography.captionBadge).foregroundStyle(Theme.Colors.textSecondary).padding(.top, -10)

                    if let email = appState.resolvedRecipientEmail(for: audition), MFMailComposeViewController.canSendMail() {
                        Button { emailPackageFiles() } label: {
                            Label("Email \(email)", systemImage: "envelope")
                                .frame(maxWidth: .infinity, alignment: .leading).padding(16).cardStyle()
                        }
                        .disabled(preparingShareStatus != nil)
                    }

                    if let status = preparingShareStatus {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(status)
                                .font(Theme.Typography.captionBadge)
                                .foregroundStyle(Theme.Colors.textSecondary)
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(20)
            }
            .scrollEdgeHaptics()
            .background(Theme.Colors.canvasBackground.ignoresSafeArea())
            .navigationTitle("Send it your way")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { showingShareChoices = false }
                }
            }
            .alert(
                "Export Unavailable",
                isPresented: Binding(
                    get: { shareSheetErrorMessage != nil },
                    set: { if !$0 { shareSheetErrorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(shareSheetErrorMessage ?? "")
            }
            .onAppear {
                if zipFileName.isEmpty {
                    zipFileName = packageName
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Validation Computed Properties

    private var hasMissingHeadshotFiles: Bool {
        !HeadshotAngle.allCases.allSatisfy { angle in
            guard let headshot = audition.headshot(for: angle) else { return false }
            return MediaStorage.fileExists(at: headshot.croppedFilePath) || MediaStorage.fileExists(at: headshot.originalFilePath)
        }
    }

    private var headshotValidationDetail: String {
        if hasMissingHeadshotFiles {
            return "All 3 headshot angles (Front, Left, Right) must exist on disk"
        }
        return "\(rules.requiredHeadshotRatio.rawValue) across Front, Left, and Right angles"
    }

    private var headshotsPass: Bool {
        HeadshotAngle.allCases.allSatisfy { angle in
            guard let headshot = audition.headshot(for: angle) else { return false }
            let hasFile = MediaStorage.fileExists(at: headshot.croppedFilePath) || MediaStorage.fileExists(at: headshot.originalFilePath)
            return hasFile && headshot.aspectRatio == rules.requiredHeadshotRatio
        }
    }

    private var slateDurationPass: Bool {
        guard let slate, MediaStorage.fileExists(at: slate.filePath) else { return false }
        let dur = slateMetadata?.durationSeconds ?? slate.durationSeconds
        return dur > 0 && dur <= rules.maxSlateSeconds
    }

    private var clipDurationTitle: String {
        if rules.maxClipSeconds >= 60 {
            return "Clip under \(Int(rules.maxClipSeconds / 60)) mins"
        }
        return "Clip under \(Int(rules.maxClipSeconds))s"
    }

    private var clipDurationPass: Bool {
        guard let clip, MediaStorage.fileExists(at: clip.filePath) else { return false }
        let dur = clipMetadata?.durationSeconds ?? clip.durationSeconds
        return dur > 0 && dur <= rules.maxClipSeconds
    }

    private var orientationDetailText: String {
        if audition.requiresSlate && audition.requiresAudition {
            return "Consistent \(expectedOrientation) across both clips"
        }
        return "Matches required \(expectedOrientation)"
    }

    private var orientationPass: Bool {
        if audition.requiresSlate && audition.requiresAudition {
            let slateInfo = slateMetadata.map { ($0.isPortrait, $0.aspectRatioString) }
            let clipInfo = clipMetadata.map { ($0.isPortrait, $0.aspectRatioString) }
            return PackageExportHelper.validateOrientation(
                slate: slateInfo,
                clip: clipInfo,
                requiredPortrait: rules.requiredPortrait
            )
        }
        if audition.requiresSlate {
            guard let slateMetadata else { return false }
            return rules.requiredPortrait.map { slateMetadata.isPortrait == $0 } ?? true
        }
        if audition.requiresAudition {
            guard let clipMetadata else { return false }
            return rules.requiredPortrait.map { clipMetadata.isPortrait == $0 } ?? true
        }
        return true
    }

    private var actorFileStem: String {
        PackageExportHelper.sanitizeFileStem(appState.currentUser?.name.nonEmpty ?? "Actor", fallback: "Actor")
    }

    private var roleFileStem: String {
        PackageExportHelper.sanitizeFileStem(audition.roleName, fallback: "")
    }

    private var formattedFilePrefix: String {
        let role = roleFileStem.isEmpty ? "Role" : roleFileStem
        return PackageExportHelper.sanitizeFileStem("\(actorFileStem)_\(role)", fallback: "Actor_Role")
    }

    private var fileNamePass: Bool {
        guard !roleFileStem.isEmpty else { return false }
        let itemsToValidate = availableBundleItems.isEmpty ? bundleItems : availableBundleItems
        return itemsToValidate.allSatisfy { item in
            let stem = names[item.id] ?? item.title
            return PackageExportHelper.matchesFileNamePattern(stem, pattern: rules.fileNamePattern)
        }
    }

    private var fileSizePass: Bool {
        let takes = requiredVideoTakes
        guard !takes.isEmpty else { return false }
        let allExist = takes.allSatisfy { MediaStorage.fileExists(at: $0.filePath) }
        return allExist && oversizedTake == nil
    }

    private var fileSizeValidationDetail: String {
        let takes = requiredVideoTakes
        if takes.isEmpty {
            return "No video clips recorded yet · limit \(Int(rules.maxPerClipSizeMB)) MB each"
        }
        if !takes.allSatisfy({ MediaStorage.fileExists(at: $0.filePath) }) {
            return "One or more clip files missing on disk · limit \(Int(rules.maxPerClipSizeMB)) MB each"
        }
        var parts: [String] = []
        if audition.requiresSlate, let slate {
            parts.append("Slate \(formattedSizeString(actualSizeMB(for: slate, metadata: slateMetadata)))")
        }
        if audition.requiresAudition, let clip {
            parts.append("Clip \(formattedSizeString(actualSizeMB(for: clip, metadata: clipMetadata)))")
        }
        return "\(parts.joined(separator: " · ")) (limit \(Int(rules.maxPerClipSizeMB)) MB)"
    }

    private func durationDetail(_ take: VideoTake?, metadata: VideoMetadata?, cap: Double) -> String {
        guard let take else { return "Not recorded · maximum \(Int(cap))s" }
        guard MediaStorage.fileExists(at: take.filePath) else {
            return "File missing on disk · maximum \(Int(cap))s"
        }
        let dur = metadata?.durationSeconds ?? take.durationSeconds
        return "\(Int(dur.rounded()))s · maximum \(Int(cap))s"
    }

    private func formattedSizeString(_ sizeMB: Double) -> String {
        PackageExportHelper.formattedSizeString(sizeMB)
    }

    private func openCompressor(for take: VideoTake) {
        let isSlate = take.id == slate?.id
        let currentMB = actualSizeMB(for: take, metadata: isSlate ? slateMetadata : clipMetadata)
        compressorRoute = CompressorRoute(take: take, isSlate: isSlate, originalSizeMB: currentMB)
    }

    private func refreshVideoMetadata() async {
        if let slateURL = slate?.fileURL {
            slateMetadata = await PackageExportHelper.inspectVideoMetadata(at: slateURL)
        } else {
            slateMetadata = nil
        }
        if let clipURL = clip?.fileURL {
            clipMetadata = await PackageExportHelper.inspectVideoMetadata(at: clipURL)
        } else {
            clipMetadata = nil
        }
    }

    // MARK: - Actions & Export

    private func seedNamesIfNeeded() {
        if names.isEmpty {
            bundleItems.forEach { names[$0.id] = $0.title }
        }
        if zipFileName.isEmpty {
            zipFileName = packageName
        }
    }

    private func createPrivateLink() {
        guard PackageExportHelper.canCreateSimulatedPrivateLink(isDemoMode: appState.isDemoMode) else {
            shareSheetErrorMessage = "Private cloud links aren't available in offline mode. Use Share Package or Email below to send your real files."
            return
        }
        let token = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6)).lowercased()
        let link = PrivateShareLink(urlString: "https://onetake.app/a/\(token)", expiresAt: Calendar.current.date(byAdding: .day, value: 30, to: .now) ?? .now)
        UIPasteboard.general.string = link.urlString
        appState.markAuditionSent(audition, privateLink: link)
        showingShareChoices = false
        showingCelebration = true
    }

    private func sharePackageFiles() {
        cleanupTempPackageDirectory()
        preparingShareStatus = "Preparing files for sharing…"
        let items = exportItemTuples()
        let customNames = names
        let subject = "\(packageName) audition package"

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try PackageExportHelper.materializePackageDirectory(
                        items: items,
                        customNames: customNames
                    )
                }.value

                guard !result.files.isEmpty else {
                    try? FileManager.default.removeItem(at: result.directory)
                    preparingShareStatus = nil
                    shareSheetErrorMessage = "No valid media files were found on disk to share."
                    return
                }

                tempPackageDirectory = result.directory
                preparingShareStatus = nil
                presentNativeShareSheet(items: result.files, subject: subject)
            } catch {
                preparingShareStatus = nil
                shareSheetErrorMessage = "Could not prepare package files: \(error.localizedDescription)"
            }
        }
    }

    private func sharePackageAsZip() {
        cleanupTempPackageDirectory()
        preparingShareStatus = "Creating ZIP archive…"
        let items = exportItemTuples()
        let customNames = names
        let archiveName = effectiveZipArchiveName
        let subject = "\(archiveName) audition package"

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try PackageExportHelper.createPackageZipArchive(
                        items: items,
                        customNames: customNames,
                        archiveName: archiveName
                    )
                }.value

                tempPackageDirectory = result.directory
                preparingShareStatus = nil
                presentNativeShareSheet(items: [result.archiveURL], subject: subject)
            } catch {
                preparingShareStatus = nil
                shareSheetErrorMessage = "Could not create ZIP archive: \(error.localizedDescription)"
            }
        }
    }

    private func emailPackageFiles() {
        cleanupTempPackageDirectory()
        preparingShareStatus = "Preparing email attachments…"
        let items = exportItemTuples()
        let customNames = names
        let recipient = appState.resolvedRecipientEmail(for: audition)
        let subject = "\(packageName) audition package"

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try PackageExportHelper.materializePackageDirectory(
                        items: items,
                        customNames: customNames
                    )
                }.value

                guard !result.files.isEmpty else {
                    try? FileManager.default.removeItem(at: result.directory)
                    preparingShareStatus = nil
                    shareSheetErrorMessage = "No valid media files were found on disk to email."
                    return
                }
                guard PackageExportHelper.isTotalAttachmentSizeAllowedForMail(result.files, maxTotalMB: 25.0) else {
                    let totalMB = PackageExportHelper.totalFileSizeMB(for: result.files)
                    try? FileManager.default.removeItem(at: result.directory)
                    preparingShareStatus = nil
                    shareSheetErrorMessage = "Package size (\(formattedSizeString(totalMB))) exceeds Mail's 25 MB attachment limit. Use \"More ways to share\" or \"Share as ZIP archive\" to send via AirDrop, Messages, or Files."
                    return
                }

                tempPackageDirectory = result.directory
                preparingShareStatus = nil
                presentNativeMailComposer(recipient: recipient, subject: subject, files: result.files)
            } catch {
                preparingShareStatus = nil
                shareSheetErrorMessage = "Could not prepare package for email: \(error.localizedDescription)"
            }
        }
    }

    private func presentNativeShareSheet(items: [URL], subject: String) {
        let presentedController = PackageSharePresenter.presentActivity(items: items, subject: subject) { completed in
            cleanupTempPackageDirectory()
            if completed {
                showingShareChoices = false
                markSentAfterNativeShare()
            }
        }
        if presentedController == nil {
            cleanupTempPackageDirectory()
            shareSheetErrorMessage = "Unable to open system share sheet right now. Please try again."
        }
    }

    private func presentNativeMailComposer(recipient: String?, subject: String, files: [URL]) {
        let didPresent = PackageSharePresenter.presentMail(recipient: recipient, subject: subject, files: files) { sent in
            cleanupTempPackageDirectory()
            if sent {
                showingShareChoices = false
                markSentAfterNativeShare()
            }
        }
        if !didPresent {
            cleanupTempPackageDirectory()
            shareSheetErrorMessage = "Unable to open Mail composer right now. Please try \"More ways to share\" instead."
        }
    }

    private func exportItemTuples() -> [(id: String, title: String, storedPath: String, ext: String)] {
        bundleItems.map { (id: $0.id, title: $0.title, storedPath: $0.path, ext: $0.fallbackExtension) }
    }

    private func cleanupTempPackageDirectory() {
        if let dir = tempPackageDirectory {
            try? FileManager.default.removeItem(at: dir)
            tempPackageDirectory = nil
        }
    }

    private func markSentAfterNativeShare() {
        appState.markAuditionSent(audition)
        showingCelebration = true
    }

    @ViewBuilder
    private func reviewView(take: VideoTake, isSlate: Bool) -> some View {
        let resolvedURL = MediaStorage.resolveURL(for: take.filePath) ?? URL(fileURLWithPath: take.filePath)
        TakeReviewView(
            audition: audition,
            rawVideoURL: resolvedURL,
            totalDurationSeconds: take.durationSeconds,
            isSlate: isSlate,
            qualityMetrics: PreTakeQualityMetrics(),
            initialNoiseCleaned: take.noiseCleaned
        ) { approved in
            var updatedTake = approved
            updatedTake.filePath = MediaStorage.storedRelativePath(for: approved.filePath)
            let oldPath = take.filePath
            if isSlate {
                if let index = audition.slateTakes.firstIndex(where: { $0.id == take.id }) {
                    audition.slateTakes[index] = updatedTake
                } else {
                    audition.slateTakes.append(updatedTake)
                }
                audition.selectedSlateTakeID = updatedTake.id
            } else {
                if let index = audition.auditionTakes.firstIndex(where: { $0.id == take.id }) {
                    audition.auditionTakes[index] = updatedTake
                } else {
                    audition.auditionTakes.append(updatedTake)
                }
                audition.selectedAuditionTakeID = updatedTake.id
            }
            if MediaStorage.storedRelativePath(for: oldPath) != updatedTake.filePath {
                MediaStorage.removeFile(at: oldPath)
            }
            appState.saveChanges()
            reviewRoute = nil
        } onRetake: {
            reviewRoute = nil
        }
    }

    private func presentHeadshotCrop() {
        let mismatched = mismatchedHeadshotAssets()
        cropBatchTotalCount = mismatched.count
        isCyclingHeadshotCrops = true
        didApplyCropForCurrentAngle = false
        presentNextMismatchedHeadshotIfNeeded(mismatched: mismatched)
    }

    private func mismatchedHeadshotAssets() -> [HeadshotAsset] {
        HeadshotAngle.allCases
            .compactMap { audition.headshot(for: $0) }
            .filter { $0.aspectRatio != rules.requiredHeadshotRatio }
    }

    private func presentNextMismatchedHeadshotIfNeeded(mismatched: [HeadshotAsset]? = nil) {
        let remaining = mismatched ?? mismatchedHeadshotAssets()
        guard let asset = remaining.first,
              let image = loadHeadshotImage(for: asset) else {
            isCyclingHeadshotCrops = false
            cropBatchTotalCount = 0
            return
        }
        let total = max(cropBatchTotalCount, remaining.count)
        let step = min(total, max(1, total - remaining.count + 1))
        cropRoute = CropRoute(
            angle: asset.angle,
            image: image,
            stepIndex: step,
            totalCount: total
        )
    }

    private func loadHeadshotImage(for asset: HeadshotAsset) -> UIImage? {
        if let origURL = MediaStorage.resolveURL(for: asset.originalFilePath),
           let origImage = UIImage(contentsOfFile: origURL.path) {
            return origImage
        }
        if let cropURL = MediaStorage.resolveURL(for: asset.croppedFilePath),
           let cropImage = UIImage(contentsOfFile: cropURL.path) {
            return cropImage
        }
        return nil
    }

    private func handleCropDismiss() {
        guard isCyclingHeadshotCrops, didApplyCropForCurrentAngle else {
            isCyclingHeadshotCrops = false
            didApplyCropForCurrentAngle = false
            cropBatchTotalCount = 0
            return
        }
        didApplyCropForCurrentAngle = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard isCyclingHeadshotCrops, cropRoute == nil else { return }
            presentNextMismatchedHeadshotIfNeeded()
        }
    }

    private func saveCrop(_ image: UIImage, ratio: HeadshotAspectRatio, preset: HeadshotCropPreset, angle: HeadshotAngle) {
        guard let index = audition.headshots.firstIndex(where: { $0.angle == angle }),
              let data = image.jpegData(compressionQuality: 0.92) else { return }
        didApplyCropForCurrentAngle = true
        let existingPath = audition.headshots[index].croppedFilePath
        let targetRelPath = existingPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Headshots_\(audition.id)/\(angle.rawValue)_crop.jpg"
            : MediaStorage.storedRelativePath(for: existingPath)
        if let savedRel = try? MediaStorage.saveData(data, relativePath: targetRelPath) {
            audition.headshots[index].croppedFilePath = savedRel
        }
        audition.headshots[index].aspectRatio = ratio
        audition.headshots[index].cropPreset = preset
        appState.saveChanges()
        Haptics.success()
    }
}

private struct VideoCompressorView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var audition: Audition
    let take: VideoTake
    let isSlate: Bool
    let initialSizeMB: Double
    let isDemoMode: Bool
    let onCompressed: (_ originalMB: Double, _ compressedMB: Double) -> Void

    @State private var progress = 0.0
    @State private var isCompressing = false
    @State private var completed = false
    @State private var compressedSizeMB: Double?
    @State private var thumbnailImage: UIImage?
    @State private var simulation: Timer?
    @State private var compressionTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var showingErrorAlert = false

    private var clipLabel: String { isSlate ? "Slate" : "Audition Clip" }

    private var originalSizeMB: Double {
        initialSizeMB > 0 ? initialSizeMB : take.fileSizeMB
    }

    private var targetSize: Double {
        min(originalSizeMB * 0.67, audition.validationRules.maxPerClipSizeMB * 0.85)
    }

    private var headlineText: String {
        if completed { return "\(clipLabel.uppercased()) COMPRESSED" }
        if isCompressing { return "COMPRESSING YOUR \(isSlate ? "SLATE" : "CLIP")..." }
        return "COMPRESS YOUR \(isSlate ? "SLATE" : "CLIP")"
    }

    private var savingsSummary: String? {
        guard let compressedSizeMB, originalSizeMB > 0, compressedSizeMB < originalSizeMB else { return nil }
        let savedMB = originalSizeMB - compressedSizeMB
        let pct = Int(((savedMB / originalSizeMB) * 100).rounded())
        return "Saved \(PackageExportHelper.formattedSizeString(savedMB)) (\(pct)% smaller)"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(.black)
                        .aspectRatio(16 / 9, contentMode: .fit)

                    if let thumbnailImage {
                        Image(uiImage: thumbnailImage)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .overlay(
                                Color.black.opacity(isCompressing ? 0.45 : 0.2)
                                    .clipShape(RoundedRectangle(cornerRadius: 18))
                            )
                    } else {
                        Image(systemName: "film")
                            .font(.system(size: 40))
                            .foregroundStyle(.white.opacity(0.85))
                    }

                    if isCompressing {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(1.2)
                    } else if completed {
                        VStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 44))
                                .foregroundStyle(Theme.Colors.successGreen)
                                .background(Circle().fill(.white).padding(4))
                            if let compressedSizeMB {
                                Text(PackageExportHelper.formattedSizeString(compressedSizeMB))
                                    .font(Theme.Typography.captionBadge)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Theme.Colors.successGreen)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
                .clipped()

                VStack(spacing: 10) {
                    Text(headlineText)
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(completed ? Theme.Colors.successGreen : Theme.Colors.textPrimary)

                    if completed, let finalMB = compressedSizeMB {
                        Text("\(PackageExportHelper.formattedSizeString(originalSizeMB)) → \(PackageExportHelper.formattedSizeString(finalMB))")
                            .font(Theme.Typography.sectionHeader)
                            .monospacedDigit()
                            .foregroundStyle(Theme.Colors.textPrimary)

                        if let savingsSummary {
                            Text(savingsSummary)
                                .font(Theme.Typography.captionBadge)
                                .foregroundStyle(Theme.Colors.successGreen)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(Theme.Colors.successGreen.opacity(0.12))
                                .clipShape(Capsule())
                        }

                        let limitMB = audition.validationRules.maxPerClipSizeMB
                        HStack(spacing: 6) {
                            Image(systemName: finalMB <= limitMB ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(finalMB <= limitMB ? Theme.Colors.successGreen : Theme.Colors.warningAmber)
                            Text(
                                finalMB <= limitMB
                                    ? "Now under the \(Int(limitMB)) MB package limit."
                                    : "Smallest export reached (\(PackageExportHelper.formattedSizeString(finalMB))), still above the \(Int(limitMB)) MB limit. Try trimming the clip shorter."
                            )
                            .font(Theme.Typography.captionBadge)
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .multilineTextAlignment(.center)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity)
                        .background(
                            (finalMB <= limitMB ? Theme.Colors.successGreen : Theme.Colors.warningAmber)
                                .opacity(0.08)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.top, 4)
                    } else if isCompressing {
                        Text("\(Int((progress * 100).rounded()))% · Optimizing for \(PackageExportHelper.formattedSizeString(targetSize))")
                            .font(Theme.Typography.bodyRegular)
                            .monospacedDigit()
                            .foregroundStyle(Theme.Colors.textSecondary)
                        ProgressView(value: progress)
                            .tint(Theme.Colors.accent)
                            .padding(.top, 4)
                    } else {
                        Text("Original: \(PackageExportHelper.formattedSizeString(originalSizeMB)) → Target: ~\(PackageExportHelper.formattedSizeString(targetSize))")
                            .font(Theme.Typography.bodyRegular)
                            .monospacedDigit()
                            .foregroundStyle(Theme.Colors.textSecondary)
                        Text("Reduces file size so your \(clipLabel.lowercased()) fits within the \(Int(audition.validationRules.maxPerClipSizeMB)) MB limit.")
                            .font(Theme.Typography.captionBadge)
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .multilineTextAlignment(.center)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(Theme.Typography.captionBadge)
                            .foregroundStyle(Theme.Colors.errorCrimson)
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)
                    }
                }

                Spacer()

                if !isCompressing {
                    Button {
                        if completed {
                            dismiss()
                        } else {
                            compress()
                        }
                    } label: {
                        Text(completed ? "Done" : "Compress \(clipLabel)")
                            .primaryCapsuleButton()
                    }
                    .accessibilityLabel(completed ? "Done" : "Compress \(clipLabel)")
                }
            }
            .padding(20)
            .background(Theme.Colors.canvasBackground.ignoresSafeArea())
            .navigationTitle("Compress your \(clipLabel)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(completed ? "Done" : "Close") {
                        cancelWork()
                        dismiss()
                    }
                }
            }
            .task(id: take.filePath) {
                await loadThumbnailIfAvailable()
            }
            .onDisappear {
                cancelWork()
            }
            .alert("Compression Failed", isPresented: $showingErrorAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Unable to compress this video clip.")
            }
        }
    }

    private func cancelWork() {
        simulation?.invalidate()
        simulation = nil
        compressionTask?.cancel()
        compressionTask = nil
    }

    private func loadThumbnailIfAvailable() async {
        guard let url = MediaStorage.resolveURL(for: take.filePath),
              FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)
        if let cgImage = try? await generator.image(at: .zero).image {
            thumbnailImage = UIImage(cgImage: cgImage)
        }
    }

    private func compress() {
        if completed { dismiss(); return }
        errorMessage = nil

        let sourceURL = MediaStorage.resolveURL(for: take.filePath)
        let sourceExists = sourceURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false

        guard let source = sourceURL, sourceExists else {
            if PackageExportHelper.canSimulateCompression(isDemoMode: isDemoMode) {
                isCompressing = true
                progress = 0
                simulateCompression()
            } else {
                errorMessage = "Source video file could not be found on disk. Please re-record or re-import this take."
                showingErrorAlert = true
            }
            return
        }

        isCompressing = true
        progress = 0

        let relDest = "Takes_\(audition.id)/Compressed_\(isSlate ? "Slate" : "Audition")_\(UUID().uuidString.prefix(6)).mp4"
        let destination = MediaStorage.documentsDirectory.appendingPathComponent(relDest)
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let baselineSizeMB = originalSizeMB
        compressionTask?.cancel()
        compressionTask = Task {
            let progressSyncTask = Task { @MainActor in
                while !Task.isCancelled {
                    progress = max(progress, min(0.99, VideoPostProcessingService.shared.exportProgress))
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            defer { progressSyncTask.cancel() }

            do {
                let outputURL = try await VideoPostProcessingService.shared.compressVideoToTargetSize(
                    sourceURL: source,
                    targetSizeMB: targetSize,
                    destinationURL: destination
                )
                try Task.checkCancellation()

                let candidateSizeMB = MediaStorage.fileSizeMB(at: MediaStorage.storedRelativePath(for: outputURL.path))
                let didProduceSmallerNewFile = outputURL.standardizedFileURL != source.standardizedFileURL
                    && FileManager.default.fileExists(atPath: outputURL.path)
                    && (candidateSizeMB > 0 && (baselineSizeMB <= 0 || candidateSizeMB <= baselineSizeMB))

                let finalPath: String
                let finalSizeMB: Double
                if didProduceSmallerNewFile {
                    finalPath = MediaStorage.storedRelativePath(for: outputURL.path)
                    finalSizeMB = candidateSizeMB
                    MediaStorage.removeFile(at: take.filePath)
                } else {
                    try? FileManager.default.removeItem(at: destination)
                    finalPath = take.filePath
                    finalSizeMB = baselineSizeMB
                }

                await MainActor.run {
                    finishCompression(path: finalPath, sizeMB: finalSizeMB)
                }
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: destination)
                await MainActor.run {
                    isCompressing = false
                    progress = 0
                }
            } catch {
                try? FileManager.default.removeItem(at: destination)
                await MainActor.run {
                    isCompressing = false
                    progress = 0
                    errorMessage = "Compression failed: \(error.localizedDescription)"
                    showingErrorAlert = true
                }
            }
        }
    }

    private func simulateCompression() {
        simulation?.invalidate()
        simulation = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { _ in
            Task { @MainActor in
                progress = min(1, progress + 0.045)
                if progress >= 1 {
                    finishCompression(path: take.filePath, sizeMB: targetSize)
                }
            }
        }
    }

    private func finishCompression(path: String, sizeMB: Double) {
        simulation?.invalidate()
        simulation = nil
        compressionTask = nil
        isCompressing = false
        completed = true
        compressedSizeMB = sizeMB
        progress = 1

        if isSlate {
            if let index = audition.slateTakes.firstIndex(where: { $0.id == take.id }) {
                audition.slateTakes[index].filePath = path
                audition.slateTakes[index].fileSizeMB = sizeMB
            }
        } else {
            if let index = audition.auditionTakes.firstIndex(where: { $0.id == take.id }) {
                audition.auditionTakes[index].filePath = path
                audition.auditionTakes[index].fileSizeMB = sizeMB
            }
        }
        Haptics.success()
        onCompressed(originalSizeMB, sizeMB)
    }
}

@MainActor
enum PackageSharePresenter {
    private static var activeMailCoordinator: MailCoordinator?

    static func topMostViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let keyWindow = scenes
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? scenes.first?.windows.first
        var top = keyWindow?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    @discardableResult
    static func presentActivity(
        items: [URL],
        subject: String,
        from presenterOverride: UIViewController? = nil,
        onCompletion: @escaping (Bool) -> Void
    ) -> UIActivityViewController? {
        guard !items.isEmpty, let presenter = presenterOverride ?? topMostViewController() else { return nil }
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if !subject.isEmpty {
            controller.setValue(subject, forKey: "subject")
        }
        controller.popoverPresentationController?.sourceView = presenter.view
        controller.popoverPresentationController?.sourceRect = CGRect(
            x: presenter.view.bounds.midX,
            y: presenter.view.bounds.midY,
            width: 1,
            height: 1
        )
        controller.popoverPresentationController?.permittedArrowDirections = []
        controller.completionWithItemsHandler = { _, completed, _, _ in
            Task { @MainActor in
                onCompletion(completed)
            }
        }
        presenter.present(controller, animated: true)
        return controller
    }

    static func presentMail(
        recipient: String?,
        subject: String,
        files: [URL],
        onCompletion: @escaping (Bool) -> Void
    ) -> Bool {
        guard MFMailComposeViewController.canSendMail(),
              let presenter = topMostViewController() else { return false }
        let controller = MFMailComposeViewController()
        let coordinator = MailCoordinator { sent in
            activeMailCoordinator = nil
            onCompletion(sent)
        }
        activeMailCoordinator = coordinator
        controller.mailComposeDelegate = coordinator
        controller.setSubject(subject)
        if let recipient { controller.setToRecipients([recipient]) }
        controller.setMessageBody("Sent from OneTake.", isHTML: false)
        if PackageExportHelper.isTotalAttachmentSizeAllowedForMail(files, maxTotalMB: 25.0) {
            for url in files {
                if let data = try? Data(contentsOf: url) {
                    let mime = url.pathExtension.lowercased() == "jpg" ? "image/jpeg" : "video/mp4"
                    controller.addAttachmentData(data, mimeType: mime, fileName: url.lastPathComponent)
                }
            }
        }
        presenter.present(controller, animated: true)
        return true
    }

    private final class MailCoordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: (Bool) -> Void
        init(onFinish: @escaping (Bool) -> Void) { self.onFinish = onFinish }
        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            controller.dismiss(animated: true) {
                self.onFinish(result == .sent)
            }
        }
    }
}

private struct DeliveryCelebrationView: View {
    let audition: Audition
    let done: () -> Void

    private let charcoal = Theme.Colors.textPrimary
    private let forestGreen = Theme.Colors.successGreen

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Theme.Colors.canvasBackground.ignoresSafeArea()

                // Top-right curved filmstrip
                Image("filmstripTopRight")
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width * 0.42)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)

                // Bottom-right curved filmstrip
                Image("filmstripBottomRight")
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width * 0.48)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .ignoresSafeArea(edges: .bottom)
                    .allowsHitTesting(false)

                VStack(alignment: .leading, spacing: 0) {
                    // Top-left circular close button
                    Button(action: done) {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(charcoal)
                            .frame(width: 48, height: 48)
                            .background(Theme.Colors.cardSurface)
                            .clipShape(Circle())
                            .overlay(
                                Circle()
                                    .stroke(Theme.Colors.controlBorder.opacity(0.55), lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                    }
                    .accessibilityLabel("Close")
                    .padding(.top, 4)

                    Spacer()

                    // Clapperboard + sparkles illustration
                    Image("clapperboardCelebration")
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width * 0.78)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 26)

                    // Headline & inline status text
                    VStack(alignment: .leading, spacing: 10) {
                        Text("It’s with casting.")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(charcoal)

                        (
                            Text(earlyLeadText)
                                .font(.system(size: 21, weight: .bold))
                                .foregroundColor(forestGreen)
                            + Text("  Break a leg.")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(charcoal.opacity(0.8))
                        )
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()
                    Spacer()
                }
                .padding(.horizontal, 24)
            }
        }
        .onAppear {
            Haptics.success()
        }
    }

    private var earlyLeadText: String {
        guard audition.hasDeadline else {
            return "Package sent."
        }
        if audition.daysUntilDeadline > 1 {
            return "\(audition.daysUntilDeadline) days early."
        } else if audition.daysUntilDeadline == 1 {
            return "One day early."
        } else if audition.daysUntilDeadline == 0 {
            let hours = Int(audition.deadline.timeIntervalSince(.now) / 3600)
            if hours >= 1 {
                return "Submitted \(hours) \(hours == 1 ? "hour" : "hours") early."
            }
            return "Submitted on deadline day."
        } else {
            return "Package sent."
        }
    }
}

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }

#Preview {
    PackageValidationAndExportView(audition: MockData.heerRanjha)
        .environment(MockData.sampleAppState)
}
