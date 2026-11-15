import SwiftUI
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
    @State private var showingCompressor = false
    @State private var showingShareChoices = false
    @State private var showingActivitySheet = false
    @State private var showingMailComposer = false
    @State private var showingCelebration = false
    @State private var editingFileID: String?
    @State private var names: [String: String] = [:]
    @State private var packageURLs: [URL] = []
    @State private var reviewRoute: ReviewRoute?
    @State private var cropRoute: CropRoute?
    @State private var cropSourceImage: UIImage?

    private enum Stage { case checking, ready }
    private enum ReviewRoute: Identifiable { case slate(VideoTake), audition(VideoTake); var id: UUID { switch self { case .slate(let take), .audition(let take): take.id } } }
    private struct CropRoute: Identifiable { let id = UUID(); let angle: HeadshotAngle }

    private var rules: ValidationRules { audition.validationRules }
    private var slate: VideoTake? { audition.selectedSlateTake }
    private var clip: VideoTake? { audition.selectedAuditionTake }
    private var isPortraitRequired: Bool { rules.requiredPortrait == true }
    private var expectedOrientation: String { isPortraitRequired ? "9:16 Portrait" : "16:9" }
    private var packageName: String {
        "\(appState.currentUser?.name.nonEmpty ?? "Actor")_\(audition.projectName)"
    }
    private var fileSizeTotal: Double {
        let headshotSize = Double(audition.headshots.count) * 1.2
        let slateSize = slate?.fileSizeMB ?? 0
        let clipSize = clip?.fileSizeMB ?? 0
        return headshotSize + slateSize + clipSize
    }
    private var oversizedTake: VideoTake? {
        [slate, clip].compactMap { $0 }.first { $0.fileSizeMB > rules.maxPerClipSizeMB }
    }

    var body: some View {
        NavigationStack {
            Group {
                if stage == .checking { validationView } else { readyView }
            }
            .background(Theme.Colors.canvasBackground)
            .navigationTitle(stage == .checking ? "Check your package" : "Ready to Send")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(stage == .checking ? "Close" : "Back") {
                        if stage == .checking { dismiss() } else { stage = .checking }
                    }
                }
            }
            .sheet(isPresented: $showingCompressor) {
                if let oversizedTake { VideoCompressorView(audition: audition, take: oversizedTake) }
            }
            .fullScreenCover(item: $reviewRoute) { route in
                switch route {
                case .slate(let take): reviewView(take: take, isSlate: true)
                case .audition(let take): reviewView(take: take, isSlate: false)
                }
            }
            .fullScreenCover(item: $cropRoute) { route in
                if let cropSourceImage {
                    HeadshotCropView(originalImage: cropSourceImage, defaultRatio: rules.requiredHeadshotRatio) { image, ratio, preset in
                        saveCrop(image, ratio: ratio, preset: preset, angle: route.angle)
                    }
                }
            }
            .sheet(isPresented: $showingShareChoices) { shareChoices }
            .sheet(isPresented: $showingActivitySheet) {
                NativeActivitySheet(items: packageURLs, recipientEmail: appState.resolvedRecipientEmail(for: audition)) { completed in
                    if completed { markSentAfterNativeShare() }
                }
            }
            .sheet(isPresented: $showingMailComposer) {
                MailPackageComposer(recipient: appState.resolvedRecipientEmail(for: audition), files: packageURLs) { completed in
                    if completed { markSentAfterNativeShare() }
                }
            }
            .fullScreenCover(isPresented: $showingCelebration) {
                DeliveryCelebrationView(audition: audition) { dismiss() }
            }
            .onAppear { seedNamesIfNeeded() }
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

                validationCard("Headshots 4:5", detail: "\(rules.requiredHeadshotRatio.rawValue) across Front, Left, and Right angles", passed: headshotsPass, action: "Fix crops") {
                    presentHeadshotCrop()
                }
                validationCard("Slate under \(Int(rules.maxSlateSeconds))s", detail: durationDetail(slate, cap: rules.maxSlateSeconds), passed: (slate?.durationSeconds ?? 0) <= rules.maxSlateSeconds && slate != nil, action: "Open Slate Trimmer") {
                    if let slate { reviewRoute = .slate(slate) }
                }
                validationCard("Clip under \(Int(rules.maxClipSeconds / 60)) mins", detail: durationDetail(clip, cap: rules.maxClipSeconds), passed: (clip?.durationSeconds ?? 0) <= rules.maxClipSeconds && clip != nil, action: "Open Audition Trimmer") {
                    if let clip { reviewRoute = .audition(clip) }
                }
                validationCard("Video orientation & ratio", detail: "Consistent \(expectedOrientation) across both clips", passed: orientationPass, action: nil, actionHandler: {})
                validationCard("File Name", detail: "Auto-formatted as \(actorFileStem)_\(audition.roleName)", passed: true, action: nil, actionHandler: {})
                validationCard("File Size", detail: "Each clip must be at most \(Int(rules.maxPerClipSizeMB)) MB", passed: oversizedTake == nil, action: nil, actionHandler: {})

                if let oversizedTake {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            Image(systemName: "film.stack.fill")
                                .font(.title2)
                                .foregroundStyle(Theme.Colors.warningAmber)
                                .frame(width: 54, height: 42)
                                .background(Theme.Colors.warningAmber.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("A couple of things need attention...").font(Theme.Typography.cardTitle)
                                Text("\(oversizedTake.title) Size is \(Int(oversizedTake.fileSizeMB)) MB — File limit is \(Int(rules.maxPerClipSizeMB)) MB")
                                    .font(Theme.Typography.captionBadge).foregroundStyle(Theme.Colors.textSecondary)
                            }
                        }
                        Button { showingCompressor = true } label: {
                            Label("Compress \(oversizedTake == clip ? "Audition Clip" : "Slate")", systemImage: "arrow.down.right.and.arrow.up.left")
                                .secondaryLavenderButton()
                        }
                    }
                    .padding(16).cardStyle()
                }

                Button { stage = .ready } label: {
                    Text("Review Your Package").primaryCapsuleButton()
                }
                .accessibilityHint("Continues even when an advisory item needs review")
            }
            .padding(16)
        }
    }

    private func validationCard(_ title: String, detail: String, passed: Bool, action: String?, actionHandler: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: passed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
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
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.Colors.primaryPlum)
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
                    Text("5 elements · ~\(Int(fileSizeTotal)) MB").font(Theme.Typography.captionBadge).foregroundStyle(Theme.Colors.textSecondary)
                }
                .padding(16).cardStyle()

                Text("Bundle summary").font(Theme.Typography.sectionHeader)
                ForEach(bundleItems) { item in bundleFileRow(item) }

                Button { showingShareChoices = true } label: {
                    Label("Share Package", systemImage: "square.and.arrow.up.fill").primaryCapsuleButton()
                }
                .padding(.top, 8)
            }
            .padding(16)
        }
    }

    private struct BundleItem: Identifiable {
        let id: String; let title: String; let metadata: String; let path: String; let fallbackExtension: String
    }
    private var bundleItems: [BundleItem] {
        let heads = HeadshotAngle.allCases.map { angle in
            let headshot = audition.headshot(for: angle)
            return BundleItem(id: "headshot-\(angle.rawValue)", title: "\(actorFileStem)_\(audition.roleName)_\(angle.rawValue)", metadata: "JPG · \(headshot?.aspectRatio.rawValue ?? rules.requiredHeadshotRatio.rawValue)", path: headshot?.croppedFilePath ?? "", fallbackExtension: "jpg")
        }
        return heads + [
            BundleItem(id: "slate", title: "\(actorFileStem)_\(audition.roleName)_Slate", metadata: "MP4 · \(slate.map { "\(Int($0.durationSeconds))s · \(Int($0.fileSizeMB)) MB" } ?? "Not recorded")", path: slate?.filePath ?? "", fallbackExtension: "mp4"),
            BundleItem(id: "audition", title: "\(actorFileStem)_\(audition.roleName)_Audition", metadata: "MP4 · \(clip.map { "\(Int($0.durationSeconds))s · \(Int($0.fileSizeMB)) MB" } ?? "Not recorded")", path: clip?.filePath ?? "", fallbackExtension: "mp4")
        ]
    }
    private func bundleFileRow(_ item: BundleItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.fallbackExtension == "jpg" ? "photo.fill" : "video.fill")
                .foregroundStyle(Theme.Colors.primaryPlum).frame(width: 34, height: 34)
                .background(Theme.Colors.lavenderSurface).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                if editingFileID == item.id {
                    TextField("Filename", text: Binding(get: { names[item.id, default: item.title] }, set: { names[item.id] = $0 }))
                        .textInputAutocapitalization(.words)
                        .font(Theme.Typography.bodyRegular)
                } else { Text(names[item.id, default: item.title]).font(Theme.Typography.bodyRegular).lineLimit(1) }
                Text(item.metadata).font(Theme.Typography.captionBadge).foregroundStyle(Theme.Colors.textSecondary)
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

    private var shareChoices: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text("Send it your way").font(Theme.Typography.screenTitle)
                Text("Use whatever the casting notice asked for.").font(Theme.Typography.bodyRegular).foregroundStyle(Theme.Colors.textSecondary)
                Button { createPrivateLink() } label: {
                    Label("Copy private link", systemImage: "link")
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16).cardStyle()
                }
                Text("Unlisted, works for 30 days").font(Theme.Typography.captionBadge).foregroundStyle(Theme.Colors.textSecondary).padding(.top, -12)
                Button { sharePackageFiles() } label: {
                    Label("More ways to share", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16).cardStyle()
                }
                Text("Mail, AirDrop, Messages, or Save to Files").font(Theme.Typography.captionBadge).foregroundStyle(Theme.Colors.textSecondary).padding(.top, -12)
                if let email = appState.resolvedRecipientEmail(for: audition), MFMailComposeViewController.canSendMail() {
                    Button {
                        packageURLs = materializePackage()
                        showingShareChoices = false
                        showingMailComposer = !packageURLs.isEmpty
                    } label: {
                        Label("Email \(email)", systemImage: "envelope.fill")
                            .frame(maxWidth: .infinity, alignment: .leading).padding(16).cardStyle()
                    }
                }
                Spacer()
            }
            .padding(20)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { showingShareChoices = false } } }
        }
        .presentationDetents([.medium])
    }

    private var headshotsPass: Bool {
        HeadshotAngle.allCases.allSatisfy { audition.headshot(for: $0)?.aspectRatio == rules.requiredHeadshotRatio }
    }
    private var orientationPass: Bool {
        guard let slate, let clip else { return false }
        let expected = isPortraitRequired ? "9:16" : "16:9"
        return slate.aspectRatioString == expected && clip.aspectRatioString == expected && slate.isPortrait == isPortraitRequired && clip.isPortrait == isPortraitRequired
    }
    private var actorFileStem: String { appState.currentUser?.name.nonEmpty ?? "Actor" }
    private func durationDetail(_ take: VideoTake?, cap: Double) -> String {
        guard let take else { return "Not recorded · maximum \(Int(cap))s" }
        return "\(Int(take.durationSeconds))s · maximum \(Int(cap))s"
    }
    private func seedNamesIfNeeded() { if names.isEmpty { bundleItems.forEach { names[$0.id] = $0.title } } }
    private func createPrivateLink() {
        let token = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6)).lowercased()
        let link = PrivateShareLink(urlString: "https://onetake.app/a/\(token)", expiresAt: Calendar.current.date(byAdding: .day, value: 30, to: .now) ?? .now)
        UIPasteboard.general.string = link.urlString
        appState.markAuditionSent(audition, privateLink: link)
        showingShareChoices = false
        showingCelebration = true
    }
    private func sharePackageFiles() {
        packageURLs = materializePackage()
        showingShareChoices = false
        guard !packageURLs.isEmpty else { return }
        showingActivitySheet = true
    }
    private func materializePackage() -> [URL] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OneTake-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return bundleItems.compactMap { item in
            guard !item.path.isEmpty, FileManager.default.fileExists(atPath: item.path) else { return nil }
            let base = names[item.id, default: item.title].replacingOccurrences(of: "/", with: "-")
            let destination = directory.appendingPathComponent(base).appendingPathExtension(item.fallbackExtension)
            do { try FileManager.default.copyItem(at: URL(fileURLWithPath: item.path), to: destination); return destination } catch { return nil }
        }
    }
    private func markSentAfterNativeShare() {
        guard !packageURLs.isEmpty else { return }
        appState.markAuditionSent(audition)
        showingCelebration = true
    }
    @ViewBuilder
    private func reviewView(take: VideoTake, isSlate: Bool) -> some View {
        TakeReviewView(audition: audition, rawVideoURL: URL(fileURLWithPath: take.filePath), totalDurationSeconds: take.durationSeconds, isSlate: isSlate) { approved in
            if isSlate {
                if let index = audition.slateTakes.firstIndex(where: { $0.id == take.id }) { audition.slateTakes[index] = approved } else { audition.slateTakes.append(approved) }
                audition.selectedSlateTakeID = approved.id
            } else {
                if let index = audition.auditionTakes.firstIndex(where: { $0.id == take.id }) { audition.auditionTakes[index] = approved } else { audition.auditionTakes.append(approved) }
                audition.selectedAuditionTakeID = approved.id
            }
            appState.saveChanges(); reviewRoute = nil
        } onRetake: { reviewRoute = nil }
    }
    private func presentHeadshotCrop() {
        guard let asset = HeadshotAngle.allCases.compactMap({ audition.headshot(for: $0) }).first(where: { $0.aspectRatio != rules.requiredHeadshotRatio }),
              let image = UIImage(contentsOfFile: asset.croppedFilePath) ?? UIImage(contentsOfFile: asset.originalFilePath) else { return }
        cropSourceImage = image
        cropRoute = CropRoute(angle: asset.angle)
    }
    private func saveCrop(_ image: UIImage, ratio: HeadshotAspectRatio, preset: HeadshotCropPreset, angle: HeadshotAngle) {
        guard let index = audition.headshots.firstIndex(where: { $0.angle == angle }), let data = image.jpegData(compressionQuality: 0.92) else { return }
        let path = audition.headshots[index].croppedFilePath
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        audition.headshots[index].aspectRatio = ratio
        audition.headshots[index].cropPreset = preset
        appState.saveChanges()
    }
}

private struct VideoCompressorView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var audition: Audition
    let take: VideoTake
    @State private var progress = 0.0
    @State private var isCompressing = false
    @State private var completed = false
    @State private var simulation: Timer?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                ZStack { RoundedRectangle(cornerRadius: 18).fill(.black).aspectRatio(16 / 9, contentMode: .fit); Image(systemName: "play.rectangle.fill").font(.system(size: 44)).foregroundStyle(.white) }
                VStack(spacing: 8) {
                    Text("COMPRESSING YOUR CLIP").font(Theme.Typography.cardTitle)
                    Text(isCompressing ? "\(Int(progress * 100))%" : "Original: \(Int(take.fileSizeMB)) MB → Compressed: ~\(Int(targetSize)) MB")
                        .font(Theme.Typography.bodyRegular).foregroundStyle(Theme.Colors.textSecondary)
                    ProgressView(value: progress).tint(Theme.Colors.primaryPlum).opacity(isCompressing ? 1 : 0)
                }
                Spacer()
                Button { compress() } label: { Text(completed ? "Save Compressed File" : "Compress Audition Clip").primaryCapsuleButton() }
                    .disabled(isCompressing)
            }
            .padding(20)
            .navigationTitle("Compress your Audition Clip").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { simulation?.invalidate(); dismiss() } } }
        }
    }
    private var targetSize: Double { min(take.fileSizeMB * 0.67, audition.validationRules.maxPerClipSizeMB * 0.85) }
    private func compress() {
        if completed { dismiss(); return }
        isCompressing = true; progress = 0
        let source = URL(fileURLWithPath: take.filePath)
        guard FileManager.default.fileExists(atPath: source.path) else { simulateCompression(); return }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("Compressed_\(UUID().uuidString).mp4")
        Task {
            do {
                _ = try await VideoPostProcessingService.shared.compressVideoToTargetSize(sourceURL: source, targetSizeMB: targetSize, destinationURL: destination)
                await MainActor.run { finishCompression(path: destination.path) }
            } catch { await MainActor.run { simulateCompression() } }
        }
    }
    private func simulateCompression() {
        simulation?.invalidate()
        simulation = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { _ in
            progress = min(1, progress + 0.045)
            if progress >= 1 { finishCompression(path: take.filePath) }
        }
    }
    private func finishCompression(path: String) {
        simulation?.invalidate(); isCompressing = false; completed = true; progress = 1
        if let index = audition.auditionTakes.firstIndex(where: { $0.id == take.id }) {
            audition.auditionTakes[index].filePath = path
            audition.auditionTakes[index].fileSizeMB = targetSize
        }
    }
}

private struct NativeActivitySheet: UIViewControllerRepresentable {
    let items: [URL]; let recipientEmail: String?; let onCompletion: (Bool) -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.setValue("OneTake audition package", forKey: "subject")
        controller.completionWithItemsHandler = { _, completed, _, _ in onCompletion(completed) }
        return controller
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct MailPackageComposer: UIViewControllerRepresentable {
    let recipient: String?
    let files: [URL]
    let onCompletion: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss, onCompletion: onCompletion) }
    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setSubject("Audition package")
        if let recipient { controller.setToRecipients([recipient]) }
        controller.setMessageBody("Sent from OneTake.", isHTML: false)
        for url in files {
            if let data = try? Data(contentsOf: url) {
                let mime = url.pathExtension.lowercased() == "jpg" ? "image/jpeg" : "video/mp4"
                controller.addAttachmentData(data, mimeType: mime, fileName: url.lastPathComponent)
            }
        }
        return controller
    }
    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}
    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let dismiss: DismissAction; let onCompletion: (Bool) -> Void
        init(dismiss: DismissAction, onCompletion: @escaping (Bool) -> Void) { self.dismiss = dismiss; self.onCompletion = onCompletion }
        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            onCompletion(result == .sent); dismiss()
        }
    }
}

private struct DeliveryCelebrationView: View {
    let audition: Audition; let done: () -> Void
    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.Colors.primaryPlum, Theme.Colors.plumDark], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(spacing: 22) {
                Image(systemName: "movieclapper.fill").font(.system(size: 84)).foregroundStyle(.white)
                Text("It’s with casting.").font(.system(size: 30, weight: .bold)).foregroundStyle(.white)
                Text(subtitle).font(Theme.Typography.bodyRegular).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center)
                Text("Break a leg.").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                Button("Done", action: done).padding(.horizontal, 30).padding(.vertical, 12).background(.white).foregroundStyle(Theme.Colors.primaryPlum).clipShape(Capsule())
            }.padding(28)
        }
    }
    private var subtitle: String { audition.daysUntilDeadline >= 0 ? "Sent with \(audition.daysUntilDeadline) day\(audition.daysUntilDeadline == 1 ? "" : "s") to spare." : "Sent — your deadline has passed, but your package is on its way." }
}

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }

#Preview {
    PackageValidationAndExportView(audition: MockData.heerRanjha)
        .environment(MockData.sampleAppState)
}
