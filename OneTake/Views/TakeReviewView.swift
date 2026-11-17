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
    var initialNoiseCleaned: Bool? = nil
    let onTakeApproved: (VideoTake) -> Void
    let onRetake: () -> Void

    @State private var postProcessor = VideoPostProcessingService.shared
    @State private var player: AVPlayer?
    @State private var observedPlayer: AVPlayer?
    @State private var rawPlayerItem: AVPlayerItem?
    @State private var cleanPlayerItem: AVPlayerItem?
    @State private var timeObserverToken: Any?
    @State private var isPlaying: Bool = false
    @State private var playheadSeconds: Double = 0.0
    @State private var filmstrip: [UIImage] = []
    @State private var cleanedPreviewURL: URL?
    @State private var isPreparingCleanPreview: Bool = false
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
                    VStack(spacing: 18) {
                        // Video Player Preview
                        VStack(spacing: 10) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color.black)
                                    .aspectRatio(16.0 / 9.0, contentMode: .fit)

                                if let player = player {
                                    VideoPlayer(player: player)
                                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                } else {
                                    ProgressView()
                                        .tint(.white)
                                }
                            }

                            HStack(spacing: 12) {
                                Button {
                                    togglePlayPause()
                                } label: {
                                    Label(isPlaying ? "Pause" : "Play Selection", systemImage: isPlaying ? "pause.fill" : "play.fill")
                                        .font(.system(size: 13, weight: .semibold))
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Theme.Colors.accent)
                                .disabled(player == nil || isExporting)

                                Spacer()

                                Text("\(formattedTime(playheadSeconds)) / \(formattedTime(safeDuration))")
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Theme.Colors.textSecondary)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)

                        qualityChecks

                        // Interactive Filmstrip Timeline Trimmer (ported from OneTake-iOS-main VideoTrimmer)
                        timelineCard
                            .padding(.horizontal, Theme.Layout.screenHPadding)

                        // Clean up Room Sound Toggle (Real DSP A/B Audio Toggle)
                        HStack(alignment: .center, spacing: 12) {
                            Image(systemName: "waveform.badge.magnifyingglass")
                                .foregroundStyle(Theme.Colors.accent)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Clean up room sound")
                                    .font(Theme.Typography.cardTitle)
                                    .foregroundStyle(Theme.Colors.textPrimary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                                Text(isNoiseCleaned
                                     ? (isPreparingCleanPreview ? "Cleaning ambient noise & rumble..." : "85 Hz rumble cut, echo trim & noise gate active")
                                     : "Tap to filter room noise & boost voice clarity")
                                    .font(.caption)
                                    .foregroundStyle(Theme.Colors.textSecondary)
                            }

                            Spacer()

                            if isPreparingCleanPreview {
                                ProgressView()
                                    .scaleEffect(0.85)
                            }

                            Toggle("", isOn: $isNoiseCleaned)
                                .labelsHidden()
                                .tint(Theme.Colors.accent)
                                .disabled(isExporting)
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
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        teardownPlayer()
                        cleanupTempRawVideoIfNeeded()
                        dismiss()
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
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button {
                        teardownPlayer()
                        cleanupTempRawVideoIfNeeded()
                        onRetake()
                    } label: {
                        Label("Retake", systemImage: "arrow.counterclockwise")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.Colors.textPrimary)
                    .disabled(isExporting)
                }
                .padding(.horizontal, Theme.Layout.screenHPadding)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
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
                isNoiseCleaned = initialNoiseCleaned ?? appState.settings.noiseReductionDefault
                setupPlayer()
            }
            .task {
                await applyAutoTrimSuggestionIfEnabled()
                filmstrip = await Self.generateFilmstrip(for: rawVideoURL, duration: safeDuration, count: 8)
                if isNoiseCleaned {
                    await switchPlaybackAudio(cleaned: true)
                }
            }
            .onChange(of: isNoiseCleaned) { _, cleaned in
                Task {
                    await switchPlaybackAudio(cleaned: cleaned)
                }
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

    // MARK: - Filmstrip Trimmer Card

    private var timelineCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 4) {
                    Text("START")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Theme.Colors.textSecondary)
                    Text(formattedTime(trimStart))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Theme.Colors.textPrimary)
                }

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: "scissors")
                        .font(.caption2)
                        .foregroundStyle(Theme.Colors.accent)
                    Text(formattedTime(max(0.1, trimEnd - trimStart)))
                        .font(.caption.monospacedDigit().weight(.bold))
                        .foregroundStyle(Theme.Colors.accent)
                }

                Spacer()

                HStack(spacing: 4) {
                    Text("END")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Theme.Colors.textSecondary)
                    Text(formattedTime(trimEnd))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Theme.Colors.textPrimary)
                }
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

            GeometryReader { geo in
                timelineTrack(totalWidth: geo.size.width)
            }
            .frame(height: 58)
        }
        .padding(16)
        .cardStyle()
    }

    private func timelineTrack(totalWidth: CGFloat) -> some View {
        let width = max(120, totalWidth)
        let handleWidth: CGFloat = 18
        let trackHeight: CGFloat = 52
        let duration = safeDuration
        let startX = max(0, min(width - handleWidth * 2, CGFloat(trimStart / duration) * width))
        let endX = max(startX + handleWidth * 2, min(width, CGFloat(trimEnd / duration) * width))
        let playheadX = max(0, min(width, CGFloat(playheadSeconds / duration) * width))

        return ZStack(alignment: .leading) {
            ZStack {
                if !filmstrip.isEmpty {
                    HStack(spacing: 0) {
                        ForEach(filmstrip.indices, id: \.self) { index in
                            Image(uiImage: filmstrip[index])
                                .resizable()
                                .scaledToFill()
                                .frame(width: width / CGFloat(filmstrip.count), height: trackHeight)
                                .clipped()
                        }
                    }
                } else {
                    HStack(spacing: 0) {
                        ForEach(0..<16, id: \.self) { _ in
                            Spacer(minLength: 0)
                            Rectangle()
                                .fill(Theme.Colors.textSecondary.opacity(0.25))
                                .frame(width: 1, height: 24)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(width: width, height: trackHeight)
            .background(Color.black.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            if startX > 0 {
                Rectangle()
                    .fill(Color.black.opacity(0.55))
                    .frame(width: startX, height: trackHeight)
            }
            if endX < width {
                Rectangle()
                    .fill(Color.black.opacity(0.55))
                    .frame(width: width - endX, height: trackHeight)
                    .offset(x: endX)
            }

            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Theme.Colors.accent, lineWidth: 2.5)
                .frame(width: max(handleWidth * 2, endX - startX), height: trackHeight)
                .offset(x: startX)

            Rectangle()
                .fill(Color.white)
                .frame(width: 2.5, height: 58)
                .shadow(color: .black.opacity(0.6), radius: 2)
                .offset(x: max(0, min(width - 2.5, playheadX - 1.25)))

            trimHandle(icon: "chevron.compact.left", width: handleWidth, height: trackHeight)
                .offset(x: startX)
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("takeScrubberTrack"))
                        .onChanged { value in
                            let clampedX = max(0, min(endX - handleWidth * 2, value.location.x))
                            let newSec = Double(clampedX / width) * duration
                            trimStart = max(0, min(trimEnd - minTrimGap, newSec))
                            playheadSeconds = trimStart
                            seekPlayer(to: trimStart)
                        }
                )

            trimHandle(icon: "chevron.compact.right", width: handleWidth, height: trackHeight)
                .offset(x: max(handleWidth, endX - handleWidth))
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("takeScrubberTrack"))
                        .onChanged { value in
                            let clampedX = max(startX + handleWidth * 2, min(width, value.location.x))
                            let newSec = Double(clampedX / width) * duration
                            trimEnd = min(duration, max(trimStart + minTrimGap, newSec))
                            playheadSeconds = trimEnd
                            seekPlayer(to: trimEnd)
                        }
                )
        }
        .frame(width: width, height: 58, alignment: .leading)
        .coordinateSpace(name: "takeScrubberTrack")
        .contentShape(Rectangle())
        .onTapGesture { location in
            let clampedX = max(0, min(width, location.x))
            let tappedSec = Double(clampedX / width) * duration
            playheadSeconds = min(duration, max(0, tappedSec))
            seekPlayer(to: playheadSeconds)
        }
    }

    private func trimHandle(icon: String, width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Theme.Colors.accent)
                .frame(width: width, height: height)
            Image(systemName: icon)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
        }
    }

    private func formattedTime(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    private static func generateFilmstrip(for url: URL, duration: Double, count: Int) async -> [UIImage] {
        guard count > 0, duration > 0.1 else { return [] }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        var images: [UIImage] = []
        for i in 0..<count {
            let t = CMTime(seconds: duration * (Double(i) + 0.5) / Double(count), preferredTimescale: 600)
            if let cg = try? await generator.image(at: t).image {
                images.append(UIImage(cgImage: cg))
            }
        }
        return images
    }

    private func setupPlayer() {
        teardownPlayer()
        trimStart = 0.0
        trimEnd = safeDuration
        playheadSeconds = 0.0

        let item = AVPlayerItem(url: rawVideoURL)
        self.rawPlayerItem = item
        let newPlayer = AVPlayer(playerItem: item)
        self.player = newPlayer
        self.observedPlayer = newPlayer

        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserverToken = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            let seconds = time.seconds
            guard seconds.isFinite else { return }
            self.playheadSeconds = seconds
            let currentlyPlaying = (newPlayer.timeControlStatus == .playing)
            self.isPlaying = currentlyPlaying

            if seconds >= self.trimEnd {
                newPlayer.pause()
                self.isPlaying = false
                self.playheadSeconds = self.trimStart
                newPlayer.seek(
                    to: CMTime(seconds: self.trimStart, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                )
            } else if seconds < self.trimStart - 0.05 {
                self.playheadSeconds = self.trimStart
                newPlayer.seek(
                    to: CMTime(seconds: self.trimStart, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                )
            }
        }
    }

    private func togglePlayPause() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            isPlaying = false
        } else {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try? AVAudioSession.sharedInstance().setActive(true)
            if playheadSeconds >= trimEnd - 0.05 || playheadSeconds < trimStart {
                playheadSeconds = trimStart
                seekPlayer(to: trimStart)
            }
            player.play()
            isPlaying = true
        }
    }

    private func buildCleanComposition(from videoURL: URL, wavURL: URL) async -> AVPlayerItem? {
        let videoAsset = AVURLAsset(url: videoURL)
        let wavAsset = AVURLAsset(url: wavURL)
        guard let sourceVideoTrack = try? await videoAsset.loadTracks(withMediaType: .video).first,
              let cleanAudioTrack = try? await wavAsset.loadTracks(withMediaType: .audio).first else {
            return nil
        }
        let composition = AVMutableComposition()
        guard let compVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let compAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return nil
        }
        let sourceTimeRange = try? await sourceVideoTrack.load(.timeRange)
        let sourceDuration = sourceTimeRange?.duration
        let videoAssetDuration = try? await videoAsset.load(.duration)
        let videoDuration = sourceDuration ?? videoAssetDuration ?? CMTime(seconds: safeDuration, preferredTimescale: 600)

        let cleanTimeRange = try? await cleanAudioTrack.load(.timeRange)
        let cleanDuration = cleanTimeRange?.duration
        let wavAssetDuration = try? await wavAsset.load(.duration)
        let wavDuration = cleanDuration ?? wavAssetDuration ?? videoDuration
        let insertDuration = CMTimeMinimum(videoDuration, wavDuration)
        do {
            try compVideoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: insertDuration), of: sourceVideoTrack, at: .zero)
            if let transform = try? await sourceVideoTrack.load(.preferredTransform) {
                compVideoTrack.preferredTransform = transform
            }
            try compAudioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: insertDuration), of: cleanAudioTrack, at: .zero)
            return AVPlayerItem(asset: composition)
        } catch {
            return nil
        }
    }

    private func switchPlaybackAudio(cleaned: Bool) async {
        guard let player else { return }
        if cleaned {
            if cleanPlayerItem == nil {
                let targetWAV: URL
                if let cached = cleanedPreviewURL, FileManager.default.fileExists(atPath: cached.path) {
                    targetWAV = cached
                } else {
                    isPreparingCleanPreview = true
                    let previewURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("onetake_preview_clean_\(UUID().uuidString).wav")
                    let source = rawVideoURL
                    let processor = postProcessor
                    let generated = try? await Task.detached(priority: .userInitiated) {
                        try await processor.prepareCleanedAudioPreview(
                            sourceURL: source,
                            destinationURL: previewURL
                        )
                    }.value
                    guard let gen = generated else {
                        isPreparingCleanPreview = false
                        return
                    }
                    cleanedPreviewURL = gen
                    targetWAV = gen
                    isPreparingCleanPreview = false
                }
                cleanPlayerItem = await buildCleanComposition(from: rawVideoURL, wavURL: targetWAV)
            }
            guard isNoiseCleaned, let cleanItem = cleanPlayerItem else { return }
            let currentTime = player.currentTime()
            let wasPlaying = (player.timeControlStatus == .playing)
            player.replaceCurrentItem(with: cleanItem)
            await player.seek(to: currentTime, toleranceBefore: .zero, toleranceAfter: .zero)
            if wasPlaying { player.play() }
        } else {
            let currentTime = player.currentTime()
            let wasPlaying = (player.timeControlStatus == .playing)
            player.replaceCurrentItem(with: rawPlayerItem ?? AVPlayerItem(url: rawVideoURL))
            await player.seek(to: currentTime, toleranceBefore: .zero, toleranceAfter: .zero)
            if wasPlaying { player.play() }
        }
    }

    private func teardownPlayer() {
        if let token = timeObserverToken, let observed = observedPlayer {
            observed.removeTimeObserver(token)
        }
        timeObserverToken = nil
        observedPlayer = nil
        player?.pause()
        isPlaying = false
        player?.replaceCurrentItem(with: nil)
        player = nil
        rawPlayerItem = nil
        cleanPlayerItem = nil
    }

    private func seekPlayer(to seconds: Double) {
        let clamped = max(0.0, min(seconds, safeDuration))
        playheadSeconds = clamped
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
        if let cleaned = cleanedPreviewURL {
            try? FileManager.default.removeItem(at: cleaned)
            cleanedPreviewURL = nil
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
                qualityBadge(title: "Light: \(qualityMetrics.lightStatus) (\(qualityMetrics.lightScore)%)", isPassed: qualityMetrics.isLightPassed)
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
