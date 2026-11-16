import SwiftUI
import AVKit

struct TakeReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    let audition: Audition
    let rawVideoURL: URL
    let totalDurationSeconds: Double
    let isSlate: Bool
    /// Imported and older takes may not have live-analysis metadata; in that
    /// case the review deliberately shows only validations we can verify.
    let qualityMetrics: PreTakeQualityMetrics
    var usedFrontCamera: Bool = true
    var autoTrimSilence: Bool = false
    let onTakeApproved: (VideoTake) -> Void
    let onRetake: () -> Void

    @State private var postProcessor = VideoPostProcessingService.shared
    @State private var player: AVPlayer?
    @State private var observedPlayer: AVPlayer?
    @State private var timeObserverToken: Any?
    @State private var trimStart: Double = 0.0
    @State private var trimEnd: Double = 0.0
    @State private var didAutoTrimSilence: Bool = false
    @State private var hasAppliedInitialAutoTrim: Bool = false
    @State private var isNoiseCleaned: Bool = false
    @State private var isExporting: Bool = false
    @State private var exportErrorMessage: String?
    @State private var showingExportError: Bool = false
    @State private var didApproveTake: Bool = false

    private var safeDuration: Double {
        guard totalDurationSeconds.isFinite, totalDurationSeconds > 0 else { return 1.0 }
        return max(0.5, totalDurationSeconds)
    }

    private var minTrimGap: Double {
        min(0.5, safeDuration * 0.25)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.canvasBackground
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        // Video Player Preview
                        ZStack {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.black)
                                .aspectRatio(16.0 / 9.0, contentMode: .fit)

                            if let player = player {
                                VideoPlayer(player: player)
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                            } else {
                                ProgressView()
                                    .tint(.white)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)

                        qualityChecks

                        // Interactive Video Trimmer
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Trim Start & End")
                                    .font(Theme.Typography.sectionHeader)
                                    .foregroundStyle(Theme.Colors.textPrimary)

                                Spacer()

                                Text(String(format: "%.1fs - %.1fs (Duration: %.1fs)", trimStart, trimEnd, max(0.1, trimEnd - trimStart)))
                                    .font(Theme.Typography.captionBadge)
                                    .foregroundStyle(Theme.Colors.accent)
                            }

                            if didAutoTrimSilence {
                                HStack(spacing: 5) {
                                    Image(systemName: "waveform.path")
                                        .font(.system(size: 11, weight: .semibold))
                                    Text("Auto-trimmed silence")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .foregroundStyle(Theme.Colors.accent)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(Theme.Colors.lavenderSurface)
                                .clipShape(Capsule())
                            }

                            VStack(spacing: 8) {
                                HStack {
                                    Text("Start:")
                                        .font(Theme.Typography.captionBadge)
                                        .frame(width: 44, alignment: .leading)
                                    let startUpper = max(0.05, trimEnd - minTrimGap)
                                    Slider(value: $trimStart, in: 0...startUpper)
                                        .tint(Theme.Colors.accent)
                                        .onChange(of: trimStart) { _, newVal in
                                            seekPlayer(to: newVal)
                                        }
                                }

                                HStack {
                                    Text("End:")
                                        .font(Theme.Typography.captionBadge)
                                        .frame(width: 44, alignment: .leading)
                                    let endLower = min(safeDuration - 0.05, trimStart + minTrimGap)
                                    Slider(value: $trimEnd, in: endLower...safeDuration)
                                        .tint(Theme.Colors.accent)
                                        .onChange(of: trimEnd) { _, newVal in
                                            seekPlayer(to: newVal)
                                        }
                                }
                            }
                        }
                        .padding(16)
                        .cardStyle()
                        .padding(.horizontal, Theme.Layout.screenHPadding)

                        // Clean up Room Sound Toggle (A/B Audio Toggle)
                        HStack(alignment: .center, spacing: 12) {
                            Image(systemName: "waveform.badge.magnifyingglass")
                                .foregroundStyle(Theme.Colors.accent)

                            Text("Clean up room sound")
                                .font(Theme.Typography.cardTitle)
                                .foregroundStyle(Theme.Colors.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)

                            Spacer()

                            Toggle("", isOn: $isNoiseCleaned)
                                .labelsHidden()
                                .tint(Theme.Colors.accent)
                        }
                        .padding(16)
                        .cardStyle()
                        .padding(.horizontal, Theme.Layout.screenHPadding)

                        // Export Progress Indicator
                        if isExporting {
                            VStack(spacing: 6) {
                                ProgressView(value: postProcessor.exportProgress, total: 1.0)
                                    .tint(Theme.Colors.accent)
                                Text("Processing Take (\(Int(postProcessor.exportProgress * 100))%)...")
                                    .font(Theme.Typography.captionBadge)
                                    .foregroundStyle(Theme.Colors.textSecondary)
                            }
                            .padding(.horizontal, 24)
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Review Take")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button("Close") {
                        teardownPlayer()
                        cleanupTempRawVideoIfNeeded()
                        dismiss()
                    }
                    .disabled(isExporting)

                    Button("Retake") {
                        teardownPlayer()
                        cleanupTempRawVideoIfNeeded()
                        onRetake()
                    }
                    .disabled(isExporting)
                }

                ToolbarItem(placement: .confirmationAction) {
                    if isExporting {
                        ProgressView()
                    } else {
                        Button("Use Take") {
                            finalizeAndSaveTake()
                        }
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.Colors.accent)
                        .accessibilityLabel("Use This Take")
                    }
                }
            }
            .alert("Export Failed", isPresented: $showingExportError) {
                Button("Retry") {
                    finalizeAndSaveTake()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(exportErrorMessage ?? "Could not export this take. Please try again.")
            }
            .onAppear {
                isNoiseCleaned = appState.settings.noiseReductionDefault
                setupPlayer()
            }
            .task {
                await applyAutoTrimSuggestionIfEnabled()
            }
            .onDisappear {
                teardownPlayer()
                if !didApproveTake {
                    cleanupTempRawVideoIfNeeded()
                }
            }
        }
    }

    private var maxAllowedSeconds: Double {
        isSlate ? audition.validationRules.maxSlateSeconds : audition.validationRules.maxClipSeconds
    }

    private func qualityBadge(title: String, isPassed: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isPassed ? Theme.Colors.successGreen : Theme.Colors.errorCrimson)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Colors.textPrimary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isPassed ? Theme.Colors.successGreen.opacity(0.12) : Theme.Colors.errorCrimson.opacity(0.12))
        .clipShape(Capsule())
    }

    private func setupPlayer() {
        teardownPlayer()
        trimStart = 0.0
        trimEnd = safeDuration

        let playerItem = AVPlayerItem(url: rawVideoURL)
        let newPlayer = AVPlayer(playerItem: playerItem)
        self.player = newPlayer
        self.observedPlayer = newPlayer

        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserverToken = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak newPlayer] time in
            guard let newPlayer else { return }
            let seconds = time.seconds
            guard seconds.isFinite else { return }

            if seconds >= trimEnd {
                newPlayer.pause()
                newPlayer.seek(
                    to: CMTime(seconds: trimStart, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                )
            } else if seconds < trimStart - 0.05 {
                newPlayer.seek(
                    to: CMTime(seconds: trimStart, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                )
            }
        }
    }

    private func teardownPlayer() {
        if let token = timeObserverToken, let observed = observedPlayer {
            observed.removeTimeObserver(token)
        }
        timeObserverToken = nil
        observedPlayer = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    private func seekPlayer(to seconds: Double) {
        let clamped = max(0.0, min(seconds, safeDuration))
        player?.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private func cleanupTempRawVideoIfNeeded() {
        let tempRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let rawPath = rawVideoURL.standardizedFileURL.path
        if rawPath.hasPrefix(tempRoot), FileManager.default.fileExists(atPath: rawPath) {
            try? FileManager.default.removeItem(at: rawVideoURL)
        }
    }

    private func applyAutoTrimSuggestionIfEnabled() async {
        guard autoTrimSilence, !hasAppliedInitialAutoTrim else { return }
        hasAppliedInitialAutoTrim = true

        let url = rawVideoURL
        let suggestion = await Task.detached(priority: .userInitiated) {
            SilenceTrimmer.suggest(for: url)
        }.value

        guard let suggestion, !Task.isCancelled else { return }
        let maxDuration = safeDuration
        let minGap = minTrimGap
        let clampedStart = max(0.0, min(suggestion.start, max(0.0, maxDuration - minGap)))
        let clampedEnd = max(clampedStart + minGap, min(suggestion.end, maxDuration))
        guard clampedEnd <= maxDuration, clampedEnd - clampedStart >= minGap else { return }

        if trimStart == 0.0 && abs(trimEnd - maxDuration) < 0.001 {
            trimStart = clampedStart
            trimEnd = clampedEnd
            didAutoTrimSilence = true
            seekPlayer(to: clampedStart)
        }
    }

    private func finalizeAndSaveTake() {
        isExporting = true
        exportErrorMessage = nil
        player?.pause()

        let mirrorSetting = appState.settings.mirrorFrontCamera
        let exportQuality = appState.settings.videoQuality
        let frontUsed = usedFrontCamera
        let start = trimStart
        let end = trimEnd
        let cleanupAudio = isNoiseCleaned

        Task {
            let outputDir = MediaStorage.documentsDirectory
                .appendingPathComponent("Takes_\(audition.id)", isDirectory: true)
            let filename = "\(isSlate ? "Slate" : "Audition")_Take_\(UUID().uuidString.prefix(6)).mp4"
            let destinationURL = outputDir.appendingPathComponent(filename)

            do {
                try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

                let finalURL = try await postProcessor.trimAndProcessVideo(
                    sourceURL: rawVideoURL,
                    startSeconds: start,
                    endSeconds: end,
                    applyAudioCleanup: cleanupAudio,
                    quality: exportQuality,
                    destinationURL: destinationURL
                )

                let metadata = await VideoPostProcessingService.inspectTrackMetadata(at: finalURL)
                let finalDuration = metadata.durationSeconds > 0
                    ? metadata.durationSeconds
                    : max(0.1, end - start)
                let storedPath = MediaStorage.storedRelativePath(for: finalURL.path)

                let takeCount = isSlate ? audition.slateTakes.count + 1 : audition.auditionTakes.count + 1
                let takeTitle = "Take \(takeCount)"

                let videoTake = VideoTake(
                    id: UUID(),
                    title: takeTitle,
                    filePath: storedPath,
                    durationSeconds: finalDuration,
                    fileSizeMB: metadata.fileSizeMB,
                    aspectRatioString: metadata.aspectRatioString,
                    isPortrait: metadata.isPortrait,
                    isMirrored: frontUsed && mirrorSetting,
                    noiseCleaned: cleanupAudio,
                    trimStartSeconds: start,
                    trimEndSeconds: end,
                    lightingPassed: qualityMetrics.isLightingEvaluated && qualityMetrics.isLightPassed,
                    framingPassed: qualityMetrics.isFramingEvaluated && qualityMetrics.isAlignmentPassed,
                    soundPassed: false,
                    createdAt: Date()
                )

                await MainActor.run {
                    self.didApproveTake = true
                    self.isExporting = false
                    self.teardownPlayer()
                    self.cleanupTempRawVideoIfNeeded()
                    self.onTakeApproved(videoTake)
                }
            } catch {
                try? FileManager.default.removeItem(at: destinationURL)
                await MainActor.run {
                    self.isExporting = false
                    self.exportErrorMessage = error.localizedDescription
                    self.showingExportError = true
                }
            }
        }
    }

    @ViewBuilder
    private var qualityChecks: some View {
        let duration = max(0.0, trimEnd - trimStart)
        HStack(spacing: 8) {
            if qualityMetrics.isLightingEvaluated {
                qualityBadge(title: "Light: \(qualityMetrics.lightStatus)", isPassed: qualityMetrics.isLightPassed)
            }
            if qualityMetrics.isFramingEvaluated {
                qualityBadge(title: qualityMetrics.isAlignmentPassed ? "Framing: Centered" : "Framing: Adjust", isPassed: qualityMetrics.isAlignmentPassed)
            }
            if qualityMetrics.isBackgroundEvaluated {
                qualityBadge(title: "Background: \(qualityMetrics.backgroundStatus)", isPassed: qualityMetrics.isBackgroundPassed)
            }
            if qualityMetrics.isPhoneHeightEvaluated {
                qualityBadge(title: "Camera: \(qualityMetrics.phoneHeightStatus)", isPassed: qualityMetrics.isPhoneHeightPassed)
            }
            qualityBadge(title: "\(Int(duration))s", isPassed: duration <= maxAllowedSeconds)
        }
        .padding(.horizontal, 16)
    }
}
