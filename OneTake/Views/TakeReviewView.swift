import SwiftUI
import AVKit

struct TakeReviewView: View {
    @Environment(\.dismiss) private var dismiss

    let audition: Audition
    let rawVideoURL: URL
    let totalDurationSeconds: Double
    let isSlate: Bool
    /// Imported and older takes may not have live-analysis metadata; in that
    /// case the review deliberately shows only validations we can verify.
    let qualityMetrics: PreTakeQualityMetrics
    let onTakeApproved: (VideoTake) -> Void
    let onRetake: () -> Void

    @State private var player: AVPlayer?
    @State private var trimStart: Double = 0.0
    @State private var trimEnd: Double = 0.0
    @State private var isNoiseCleaned: Bool = false
    @State private var isExporting: Bool = false
    @State private var exportProgress: Double = 0.0
    @State private var isPlaying: Bool = false

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

                            // Range Slider Simulation
                            VStack(spacing: 8) {
                                HStack {
                                    Text("Start:")
                                        .font(Theme.Typography.captionBadge)
                                        .frame(width: 44, alignment: .leading)
                                    Slider(value: $trimStart, in: 0...max(0.1, trimEnd - 0.5))
                                        .tint(Theme.Colors.accent)
                                        .onChange(of: trimStart) { _, newVal in
                                            seekPlayer(to: newVal)
                                        }
                                }

                                HStack {
                                    Text("End:")
                                        .font(Theme.Typography.captionBadge)
                                        .frame(width: 44, alignment: .leading)
                                    Slider(value: $trimEnd, in: min(totalDurationSeconds, trimStart + 0.5)...max(1.0, totalDurationSeconds))
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
                                .overlay(
                                    Capsule()
                                        .stroke(Theme.Colors.controlBorder.opacity(0.7), lineWidth: 1)
                                )
                        }
                        .padding(16)
                        .cardStyle()
                        .padding(.horizontal, Theme.Layout.screenHPadding)

                        // File Size & Compression Info

                        // Export Progress Indicator
                        if isExporting {
                            VStack(spacing: 6) {
                                ProgressView(value: exportProgress, total: 1.0)
                                    .tint(Theme.Colors.accent)
                                Text("Processing Take (\(Int(exportProgress * 100))%)...")
                                    .font(Theme.Typography.captionBadge)
                                    .foregroundStyle(Theme.Colors.textSecondary)
                            }
                            .padding(.horizontal, 24)
                        }
                    }
                    .padding(.bottom, 16)
                }
                .safeAreaInset(edge: .bottom) {
                    // Action Buttons: Retake vs Use Take
                    HStack(spacing: 14) {
                        Button {
                            player?.pause()
                            onRetake()
                        } label: {
                            Text("Retake")
                                .secondaryLavenderButton()
                        }

                        Button {
                            finalizeAndSaveTake()
                        } label: {
                            if isExporting {
                                ProgressView().tint(.white)
                            } else {
                                Text("Use This Take")
                            }
                        }
                        .primaryCapsuleButton()
                        .disabled(isExporting)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .padding(.bottom, 16)
                    .background(Theme.Colors.canvasBackground)
                }
            }
            .navigationTitle("Review Take")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        player?.pause()
                        dismiss()
                    }
                }
            }
            .onAppear {
                setupPlayer()
            }
            .onDisappear {
                player?.pause()
            }
        }
    }

    private var maxAllowedSeconds: Double {
        isSlate ? audition.validationRules.maxSlateSeconds : audition.validationRules.maxClipSeconds
    }

    private var estimatedSizeMB: Int {
        let dur = max(1.0, trimEnd - trimStart)
        // ~1.2 MB per second for 1080p
        return min(Int(audition.validationRules.maxPerClipSizeMB), max(4, Int(dur * 1.1)))
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
        let playerItem = AVPlayerItem(url: rawVideoURL)
        self.player = AVPlayer(playerItem: playerItem)
        self.trimStart = 0.0
        self.trimEnd = max(1.0, totalDurationSeconds)
    }

    private func seekPlayer(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func finalizeAndSaveTake() {
        isExporting = true
        player?.pause()

        Task {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let outputDir = docs.appendingPathComponent("Takes_\(audition.id)", isDirectory: true)
            try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

            let filename = "\(isSlate ? "Slate" : "Audition")_Take_\(UUID().uuidString.prefix(6)).mp4"
            let destinationURL = outputDir.appendingPathComponent(filename)

            do {
                // Apply trimming
                let trimmedURL = try await VideoPostProcessingService.shared.trimVideo(
                    sourceURL: rawVideoURL,
                    startSeconds: trimStart,
                    endSeconds: trimEnd,
                    destinationURL: destinationURL
                )

                // Apply audio cleanup if enabled
                let finalURL: URL
                if isNoiseCleaned {
                    let cleanedDest = outputDir.appendingPathComponent("Cleaned_\(filename)")
                    finalURL = try await VideoPostProcessingService.shared.exportWithAudioCleanup(
                        sourceURL: trimmedURL,
                        enableNoiseSuppression: true,
                        destinationURL: cleanedDest
                    )
                } else {
                    finalURL = trimmedURL
                }

                let finalDuration = max(0.5, trimEnd - trimStart)
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: finalURL.path)[.size] as? Double) ?? 15_000_000.0
                let sizeMB = fileSize / (1024.0 * 1024.0)

                let takeCount = isSlate ? audition.slateTakes.count + 1 : audition.auditionTakes.count + 1
                let takeTitle = "Take \(takeCount)"

                let videoTake = VideoTake(
                    id: UUID(),
                    title: takeTitle,
                    filePath: finalURL.path,
                    durationSeconds: finalDuration,
                    fileSizeMB: sizeMB,
                    aspectRatioString: "16:9",
                    isPortrait: false,
                    isMirrored: true,
                    noiseCleaned: isNoiseCleaned,
                    trimStartSeconds: trimStart,
                    trimEndSeconds: trimEnd,
                    lightingPassed: qualityMetrics.isLightingEvaluated && qualityMetrics.isLightPassed,
                    framingPassed: qualityMetrics.isFramingEvaluated && qualityMetrics.isAlignmentPassed,
                    soundPassed: false,
                    createdAt: Date()
                )

                await MainActor.run {
                    self.isExporting = false
                    self.onTakeApproved(videoTake)
                }
            } catch {
                print("Export take error: \(error)")
                await MainActor.run {
                    self.isExporting = false
                    // Fallback to saving take directly
                    let videoTake = VideoTake(
                        title: "Take 1",
                        filePath: rawVideoURL.path,
                        durationSeconds: totalDurationSeconds,
                        fileSizeMB: 12.0,
                        noiseCleaned: isNoiseCleaned,
                        trimStartSeconds: trimStart,
                        trimEndSeconds: trimEnd
                    )
                    self.onTakeApproved(videoTake)
                }
            }
        }
    }

    @ViewBuilder
    private var qualityChecks: some View {
        let duration = trimEnd - trimStart
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
