import Foundation
import AVFoundation
import Accelerate

// MARK: - Errors

nonisolated enum VideoPostProcessingError: LocalizedError, Sendable {
    case sourceFileMissing
    case invalidDuration
    case exportSessionCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .sourceFileMissing:
            return "Source video file could not be found on disk."
        case .invalidDuration:
            return "Video has no valid playable duration."
        case .exportSessionCreationFailed(let reason):
            return "Failed to initialize video export: \(reason)"
        }
    }
}

// MARK: - Post Processing Protocol

@MainActor
protocol VideoPostProcessingServiceProtocol: AnyObject {
    var exportProgress: Double { get }
    var isProcessing: Bool { get }

    func trimVideo(
        sourceURL: URL,
        startSeconds: Double,
        endSeconds: Double,
        destinationURL: URL
    ) async throws -> URL

    func exportWithAudioCleanup(
        sourceURL: URL,
        enableNoiseSuppression: Bool,
        destinationURL: URL
    ) async throws -> URL

    func trimAndProcessVideo(
        sourceURL: URL,
        startSeconds: Double,
        endSeconds: Double,
        applyAudioCleanup: Bool,
        quality: VideoQuality,
        destinationURL: URL
    ) async throws -> URL

    func compressVideoToTargetSize(
        sourceURL: URL,
        targetSizeMB: Double,
        destinationURL: URL
    ) async throws -> URL
}

extension VideoPostProcessingServiceProtocol {
    func trimAndProcessVideo(
        sourceURL: URL,
        startSeconds: Double,
        endSeconds: Double,
        applyAudioCleanup: Bool,
        destinationURL: URL
    ) async throws -> URL {
        try await trimAndProcessVideo(
            sourceURL: sourceURL,
            startSeconds: startSeconds,
            endSeconds: endSeconds,
            applyAudioCleanup: applyAudioCleanup,
            quality: .p1080,
            destinationURL: destinationURL
        )
    }
}

// MARK: - VideoPostProcessingService Implementation

@MainActor
@Observable
final class VideoPostProcessingService: NSObject, VideoPostProcessingServiceProtocol {
    static let shared = VideoPostProcessingService()

    var exportProgress: Double = 0.0
    var isProcessing: Bool = false

    nonisolated static func exportPreset(for quality: VideoQuality) -> String {
        switch quality {
        case .p720:
            return AVAssetExportPreset1280x720
        case .p1080:
            return AVAssetExportPresetHighestQuality
        }
    }

    // MARK: - Combined Single-Pass Trim + Audio Cleanup

    func trimAndProcessVideo(
        sourceURL: URL,
        startSeconds: Double,
        endSeconds: Double,
        applyAudioCleanup: Bool,
        quality: VideoQuality = .p1080,
        destinationURL: URL
    ) async throws -> URL {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw VideoPostProcessingError.sourceFileMissing
        }

        isProcessing = true
        exportProgress = 0.0
        defer {
            isProcessing = false
        }

        let asset = AVURLAsset(url: sourceURL)
        let totalDuration = try await asset.load(.duration).seconds
        guard totalDuration.isFinite, totalDuration > 0 else {
            throw VideoPostProcessingError.invalidDuration
        }

        let safeStartInput = startSeconds.isFinite ? startSeconds : 0.0
        let safeEndInput = endSeconds.isFinite ? endSeconds : totalDuration
        let clampedStart = max(0.0, min(safeStartInput, max(0.0, totalDuration - 0.1)))
        let clampedEnd = max(clampedStart + 0.1, min(safeEndInput, totalDuration))
        let timeRange = CMTimeRange(
            start: CMTime(seconds: clampedStart, preferredTimescale: 600),
            duration: CMTime(seconds: clampedEnd - clampedStart, preferredTimescale: 600)
        )

        let preferredPreset = Self.exportPreset(for: quality)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: preferredPreset)
            ?? AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw VideoPostProcessingError.exportSessionCreationFailed("Could not create AVAssetExportSession.")
        }

        exportSession.timeRange = timeRange
        exportSession.shouldOptimizeForNetworkUse = true

        if applyAudioCleanup {
            let trimmedTempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("onetake_trimmed_\(UUID().uuidString).mp4")
            try? FileManager.default.removeItem(at: trimmedTempURL)
            try await exportSessionResult(exportSession, sourceURL: sourceURL, destinationURL: trimmedTempURL)
            exportProgress = 0.75
            do {
                try await Self.remuxWithCleanedAudio(sourceURL: trimmedTempURL, destinationURL: destinationURL)
                try? FileManager.default.removeItem(at: trimmedTempURL)
                exportProgress = 1.0
                return destinationURL
            } catch {
                try? FileManager.default.removeItem(at: trimmedTempURL)
                throw error
            }
        } else {
            try await exportSessionResult(exportSession, sourceURL: sourceURL, destinationURL: destinationURL)
            exportProgress = 1.0
            return destinationURL
        }
    }

    /// Generates a studio-cleaned WAV audio track for instant A/B preview in `TakeReviewView`
    /// without touching or reloading `VideoPlayer`'s video track.
    func prepareCleanedAudioPreview(sourceURL: URL, destinationURL: URL) async throws -> URL {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw VideoPostProcessingError.sourceFileMissing
        }
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let rendered = try await Self.renderCleanedAudioWAV(from: sourceURL, to: destinationURL)
        guard rendered else {
            throw VideoPostProcessingError.exportSessionCreationFailed("No audio track available to clean.")
        }
        return destinationURL
    }

    /// Generates an A/B preview clip with cleaned room audio (without trimming video),
    /// remuxing video passthrough so it completes quickly for in-review toggle auditioning.
    func prepareCleanedPreview(sourceURL: URL, destinationURL: URL) async throws -> URL {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw VideoPostProcessingError.sourceFileMissing
        }
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try await Self.remuxWithCleanedAudio(sourceURL: sourceURL, destinationURL: destinationURL)
        return destinationURL
    }

    // MARK: - Video Trimming (CMTimeRange + AVAssetExportSession)

    func trimVideo(
        sourceURL: URL,
        startSeconds: Double,
        endSeconds: Double,
        destinationURL: URL
    ) async throws -> URL {
        try await trimAndProcessVideo(
            sourceURL: sourceURL,
            startSeconds: startSeconds,
            endSeconds: endSeconds,
            applyAudioCleanup: false,
            destinationURL: destinationURL
        )
    }

    // MARK: - Audio Noise Suppression Export

    func exportWithAudioCleanup(
        sourceURL: URL,
        enableNoiseSuppression: Bool,
        destinationURL: URL
    ) async throws -> URL {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw VideoPostProcessingError.sourceFileMissing
        }

        guard enableNoiseSuppression else {
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if destinationURL.standardizedFileURL != sourceURL.standardizedFileURL {
                try? FileManager.default.removeItem(at: destinationURL)
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            }
            return destinationURL
        }

        let asset = AVURLAsset(url: sourceURL)
        let totalDuration = try await asset.load(.duration).seconds
        guard totalDuration.isFinite, totalDuration > 0 else {
            throw VideoPostProcessingError.invalidDuration
        }

        return try await trimAndProcessVideo(
            sourceURL: sourceURL,
            startSeconds: 0.0,
            endSeconds: totalDuration,
            applyAudioCleanup: true,
            destinationURL: destinationURL
        )
    }

    // MARK: - Bitrate Compression

    nonisolated static func selectCompressionPreset(currentSizeMB: Double, targetSizeMB: Double) -> String {
        if currentSizeMB > targetSizeMB {
            return AVAssetExportPreset1280x720
        }
        return AVAssetExportPresetHighestQuality
    }

    func compressVideoToTargetSize(
        sourceURL: URL,
        targetSizeMB: Double = 85.0,
        destinationURL: URL
    ) async throws -> URL {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw VideoPostProcessingError.sourceFileMissing
        }

        isProcessing = true
        exportProgress = 0.0
        defer {
            isProcessing = false
        }

        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw VideoPostProcessingError.invalidDuration
        }

        let currentSizeMB = MediaStorage.fileSizeMB(at: sourceURL.path)
        let preferredPreset = Self.selectCompressionPreset(currentSizeMB: currentSizeMB, targetSizeMB: targetSizeMB)

        let exportSession: AVAssetExportSession
        if let session = AVAssetExportSession(asset: asset, presetName: preferredPreset) {
            exportSession = session
        } else if let fallback = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetMediumQuality)
            ?? AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) {
            exportSession = fallback
        } else {
            throw VideoPostProcessingError.exportSessionCreationFailed("Compression preset unavailable.")
        }

        exportSession.shouldOptimizeForNetworkUse = true
        try await exportSessionResult(exportSession, sourceURL: sourceURL, destinationURL: destinationURL)
        exportProgress = 1.0
        return destinationURL
    }

    // MARK: - Track Metadata Inspection

    nonisolated static func inspectTrackMetadata(at url: URL) async -> (isPortrait: Bool, aspectRatioString: String, durationSeconds: Double, fileSizeMB: Double) {
        let fileSizeMB = MediaStorage.fileSizeMB(at: url.path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (isPortrait: false, aspectRatioString: "16:9", durationSeconds: 0.0, fileSizeMB: fileSizeMB)
        }

        let asset = AVURLAsset(url: url)
        var durationSeconds = 0.0
        if let loadedDuration = try? await asset.load(.duration).seconds,
           loadedDuration.isFinite,
           loadedDuration > 0 {
            durationSeconds = loadedDuration
        }

        var isPortrait = false
        var aspectRatioString = "16:9"
        if let videoTracks = try? await asset.loadTracks(withMediaType: .video),
           let track = videoTracks.first,
           let (naturalSize, preferredTransform) = try? await track.load(.naturalSize, .preferredTransform) {
            let transformed = naturalSize.applying(preferredTransform)
            let width = abs(transformed.width)
            let height = abs(transformed.height)
            if width > 0, height > 0 {
                isPortrait = height > width
                aspectRatioString = formatAspectRatio(width: width, height: height)
            }
        }

        return (
            isPortrait: isPortrait,
            aspectRatioString: aspectRatioString,
            durationSeconds: durationSeconds,
            fileSizeMB: fileSizeMB
        )
    }

    nonisolated private static func formatAspectRatio(width: CGFloat, height: CGFloat) -> String {
        let ratio = width / height
        let known: [(Double, String)] = [
            (16.0 / 9.0, "16:9"),
            (9.0 / 16.0, "9:16"),
            (4.0 / 3.0, "4:3"),
            (3.0 / 4.0, "3:4"),
            (4.0 / 5.0, "4:5"),
            (5.0 / 4.0, "5:4"),
            (2.0 / 3.0, "2:3"),
            (3.0 / 2.0, "3:2"),
            (1.0, "1:1")
        ]
        for (target, label) in known where abs(ratio - target) < 0.04 {
            return label
        }
        let w = max(1, Int(width.rounded()))
        let h = max(1, Int(height.rounded()))
        let divisor = gcd(w, h)
        return "\(w / divisor):\(h / divisor)"
    }

    nonisolated private static func gcd(_ a: Int, _ b: Int) -> Int {
        var x = abs(a)
        var y = abs(b)
        while y != 0 {
            let r = x % y
            x = y
            y = r
        }
        return max(1, x)
    }

    // MARK: - Export Execution & Progress

    private func exportSessionResult(
        _ exportSession: AVAssetExportSession,
        sourceURL: URL,
        destinationURL: URL
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let sameLocation = destinationURL.standardizedFileURL == sourceURL.standardizedFileURL
        let stagedURL = sameLocation
            ? fm.temporaryDirectory.appendingPathComponent("onetake_export_\(UUID().uuidString).mp4")
            : destinationURL

        try? fm.removeItem(at: stagedURL)

        let tracker = trackProgress(for: exportSession)
        defer { tracker.cancel() }

        do {
            try await exportSession.export(to: stagedURL, as: .mp4)
            if sameLocation {
                try? fm.removeItem(at: destinationURL)
                try fm.moveItem(at: stagedURL, to: destinationURL)
            }
        } catch {
            try? fm.removeItem(at: stagedURL)
            throw error
        }
    }

    private func trackProgress(for exportSession: AVAssetExportSession) -> Task<Void, Never> {
        let box = UncheckedSessionBox(session: exportSession)
        return Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { break }
                self?.exportProgress = Double(box.session.progress)
            }
        }
    }

    private nonisolated struct UncheckedSessionBox: @unchecked Sendable {
        let session: AVAssetExportSession
    }

    private nonisolated struct UncheckedBox<T>: @unchecked Sendable {
        let value: T
    }

    // MARK: - Room Audio Cleanup DSP (85 Hz HPF + De-Mud + Presence + Adaptive Expander)

    /// Applies broadcast-style room cleanup to interleaved or mono Float32 PCM samples:
    /// 1) 85 Hz 2nd-order Butterworth high-pass filter (removes AC rumble & room boom)
    /// 2) -2.2 dB @ 280 Hz peaking cut (reduces boxy room echo)
    /// 3) +2.5 dB @ 2.8 kHz presence bell (improves dialogue clarity)
    /// 4) RMS-tracked adaptive noise-floor downward expander + loudness normalization & soft limiter
    nonisolated static func cleanAudioSamples(
        _ samples: inout [Float],
        sampleRate: Double,
        channels: Int = 1,
        knownNoiseFloor: Float? = nil,
        knownSpeechPeak: Float? = nil
    ) {
        let ch = max(1, channels)
        let frameCount = samples.count / ch
        guard frameCount > 0, sampleRate > 1000 else { return }

        var hpf1 = BiquadFilterState.highPass(cutoffHz: 95.0, q: 0.707, sampleRate: sampleRate, channels: ch)
        var hpf2 = BiquadFilterState.highPass(cutoffHz: 95.0, q: 0.707, sampleRate: sampleRate, channels: ch)
        var deMud = BiquadFilterState.peaking(centerHz: 260.0, q: 1.1, gainDB: -3.2, sampleRate: sampleRate, channels: ch)
        var presence = BiquadFilterState.peaking(centerHz: 2900.0, q: 1.0, gainDB: 3.4, sampleRate: sampleRate, channels: ch)
        var clarity = BiquadFilterState.peaking(centerHz: 5200.0, q: 1.2, gainDB: 1.8, sampleRate: sampleRate, channels: ch)

        hpf1.processInterleaved(&samples, frameCount: frameCount, channels: ch)
        hpf2.processInterleaved(&samples, frameCount: frameCount, channels: ch)
        deMud.processInterleaved(&samples, frameCount: frameCount, channels: ch)
        presence.processInterleaved(&samples, frameCount: frameCount, channels: ch)
        clarity.processInterleaved(&samples, frameCount: frameCount, channels: ch)

        let stats = estimateNoiseAndSpeechStats(samples: samples, frameCount: frameCount, channels: ch, sampleRate: sampleRate)
        let noiseFloor = knownNoiseFloor ?? stats.noiseFloor
        let speechPeak = knownSpeechPeak ?? stats.speechPeak

        let params = ExpanderParameters(noiseFloor: noiseFloor, speechPeak: speechPeak, sampleRate: sampleRate)
        var envSq: Float = noiseFloor * noiseFloor
        var gain: Float = params.floorGain

        applyExpanderAndLimiter(
            &samples,
            frameCount: frameCount,
            channels: ch,
            params: params,
            envSq: &envSq,
            gain: &gain
        )
    }

    private nonisolated struct ExpanderParameters {
        let noiseFloor: Float
        let openThreshold: Float
        let floorGain: Float
        let attackCoeff: Float
        let releaseCoeff: Float
        let envCoeffFast: Float
        let envCoeffSlow: Float
        let normGain: Float

        init(noiseFloor: Float, speechPeak: Float, sampleRate: Double) {
            self.noiseFloor = noiseFloor
            self.openThreshold = max(0.003, noiseFloor * 2.5)
            let rawNorm: Float = (speechPeak > max(0.015, noiseFloor * 2.5))
                ? min(2.8, max(0.95, 0.65 / speechPeak))
                : 1.0
            self.normGain = rawNorm
            // Attenuate room noise floor by ~22 dB during pauses between spoken words.
            self.floorGain = 0.08 / max(1.0, rawNorm)
            self.attackCoeff = Float(1.0 - exp(-1.0 / (0.005 * sampleRate)))
            self.releaseCoeff = Float(1.0 - exp(-1.0 / (0.110 * sampleRate)))
            self.envCoeffFast = Float(1.0 - exp(-1.0 / (0.004 * sampleRate)))
            self.envCoeffSlow = Float(1.0 - exp(-1.0 / (0.040 * sampleRate)))
        }
    }

    nonisolated private static func applyExpanderAndLimiter(
        _ samples: inout [Float],
        frameCount: Int,
        channels: Int,
        params: ExpanderParameters,
        envSq: inout Float,
        gain: inout Float
    ) {
        let lowKnee = max(0.001, params.noiseFloor * 1.45)
        let highKnee = max(lowKnee + 0.001, params.openThreshold)

        for f in 0..<frameCount {
            let base = f * channels
            var energy: Float = 0.0
            for c in 0..<channels {
                let s = samples[base + c]
                energy += s * s
            }
            energy /= Float(channels)

            let eCoeff = energy > envSq ? params.envCoeffFast : params.envCoeffSlow
            envSq += eCoeff * (energy - envSq)
            let rmsEnv = sqrt(max(0.0, envSq))

            let targetGain: Float
            if rmsEnv >= highKnee {
                targetGain = 1.0
            } else if rmsEnv <= lowKnee {
                targetGain = params.floorGain
            } else {
                let t = (rmsEnv - lowKnee) / (highKnee - lowKnee)
                targetGain = params.floorGain + (1.0 - params.floorGain) * (t * t)
            }

            let gainCoeff = targetGain > gain ? params.attackCoeff : params.releaseCoeff
            gain += gainCoeff * (targetGain - gain)

            let totalScale = gain * params.normGain
            for c in 0..<channels {
                let scaled = samples[base + c] * totalScale
                samples[base + c] = 0.94 * tanh(scaled / 0.94)
            }
        }
    }

    nonisolated private static func estimateNoiseAndSpeechStats(
        samples: [Float],
        frameCount: Int,
        channels: Int,
        sampleRate: Double
    ) -> (noiseFloor: Float, speechPeak: Float) {
        let windowFrames = max(64, Int((0.020 * sampleRate).rounded()))
        var frameRMSValues: [Float] = []
        frameRMSValues.reserveCapacity(max(1, frameCount / windowFrames + 1))

        var idx = 0
        while idx < frameCount {
            let end = min(frameCount, idx + windowFrames)
            let spanSamples = (end - idx) * channels
            if spanSamples > 0 {
                var sumSq: Float = 0.0
                samples.withUnsafeBufferPointer { buf in
                    if let ptr = buf.baseAddress?.advanced(by: idx * channels) {
                        vDSP_svesq(ptr, 1, &sumSq, vDSP_Length(spanSamples))
                    }
                }
                frameRMSValues.append(sqrt(sumSq / Float(spanSamples)))
            }
            idx = end
        }

        guard !frameRMSValues.isEmpty else { return (0.002, 0.2) }
        let sorted = frameRMSValues.sorted()
        let lowIdx = min(sorted.count - 1, max(0, Int(Double(sorted.count) * 0.15)))
        let highIdx = min(sorted.count - 1, max(0, Int(Double(sorted.count) * 0.92)))
        return (noiseFloor: max(0.0005, sorted[lowIdx]), speechPeak: max(0.01, sorted[highIdx]))
    }

    /// Decodes any mono, stereo, or Spatial Audio track to canonical 44.1 kHz Float32 PCM,
    /// runs the 5-stage studio room cleanup DSP, and writes a clean WAV file.
    nonisolated static func renderCleanedAudioWAV(
        from sourceURL: URL,
        to wavURL: URL
    ) async throws -> Bool {
        let asset = AVURLAsset(url: sourceURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { return false }

        let targetSampleRate: Double = 44_100.0
        let reader = try AVAssetReader(asset: asset)
        let pcmSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: pcmSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return false }
        reader.add(output)
        guard reader.startReading() else { return false }

        var allSamples: [Float] = []
        allSamples.reserveCapacity(Int(targetSampleRate * 15))
        while let sampleBuffer = output.copyNextSampleBuffer() {
            if let chunk = extractFloatSamples(from: sampleBuffer) {
                allSamples.append(contentsOf: chunk)
            }
        }
        guard !allSamples.isEmpty else { return false }

        cleanAudioSamples(&allSamples, sampleRate: targetSampleRate, channels: 1)

        try? FileManager.default.removeItem(at: wavURL)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: targetSampleRate, channels: 1),
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(allSamples.count)),
              let channelPtr = pcmBuffer.floatChannelData?[0] else {
            return false
        }
        pcmBuffer.frameLength = AVAudioFrameCount(allSamples.count)
        allSamples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress {
                channelPtr.update(from: base, count: allSamples.count)
            }
        }

        let outFile = try AVAudioFile(forWriting: wavURL, settings: format.settings)
        try outFile.write(from: pcmBuffer)
        return true
    }

    nonisolated private static func remuxWithCleanedAudio(
        sourceURL: URL,
        destinationURL: URL
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let asset = AVURLAsset(url: sourceURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        let sameLocation = destinationURL.standardizedFileURL == sourceURL.standardizedFileURL
        guard !audioTracks.isEmpty else {
            if !sameLocation {
                try? fm.removeItem(at: destinationURL)
                try fm.copyItem(at: sourceURL, to: destinationURL)
            }
            return
        }

        let tempWAVURL = fm.temporaryDirectory
            .appendingPathComponent("onetake_clean_pcm_\(UUID().uuidString).wav")
        defer { try? fm.removeItem(at: tempWAVURL) }

        let didRenderAudio = try await renderCleanedAudioWAV(from: sourceURL, to: tempWAVURL)
        guard didRenderAudio else {
            if !sameLocation {
                try? fm.removeItem(at: destinationURL)
                try fm.copyItem(at: sourceURL, to: destinationURL)
            }
            return
        }

        let stagedURL = sameLocation
            ? fm.temporaryDirectory.appendingPathComponent("onetake_clean_\(UUID().uuidString).\(destinationURL.pathExtension.isEmpty ? "mp4" : destinationURL.pathExtension)")
            : destinationURL
        try? fm.removeItem(at: stagedURL)

        let composition = AVMutableComposition()
        let totalDuration = try await asset.load(.duration)

        if let sourceVideoTrack = videoTracks.first,
           let compVideoTrack = composition.addMutableTrack(
               withMediaType: .video,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            let videoDuration = (try? await sourceVideoTrack.load(.timeRange).duration) ?? totalDuration
            try compVideoTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: videoDuration),
                of: sourceVideoTrack,
                at: .zero
            )
            if let preferredTransform = try? await sourceVideoTrack.load(.preferredTransform) {
                compVideoTrack.preferredTransform = preferredTransform
            }
        }

        let wavAsset = AVURLAsset(url: tempWAVURL)
        if let cleanedAudioTrack = try? await wavAsset.loadTracks(withMediaType: .audio).first,
           let compAudioTrack = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            let wavDuration = (try? await wavAsset.load(.duration)) ?? totalDuration
            let insertDuration = CMTimeMinimum(totalDuration, wavDuration)
            try? compAudioTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: insertDuration),
                of: cleanedAudioTrack,
                at: .zero
            )
        }

        let hasVideo = !composition.tracks(withMediaType: .video).isEmpty
        let preset = hasVideo ? AVAssetExportPresetHighestQuality : AVAssetExportPresetAppleM4A
        let outFileType: AVFileType = hasVideo ? .mp4 : .m4a

        guard let exportSession = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw VideoPostProcessingError.exportSessionCreationFailed("Could not initialize AVAssetExportSession for cleaned audio.")
        }
        exportSession.shouldOptimizeForNetworkUse = true
        try await exportSession.export(to: stagedURL, as: outFileType)

        if sameLocation {
            try? fm.removeItem(at: destinationURL)
            try fm.moveItem(at: stagedURL, to: destinationURL)
        }
    }

    nonisolated private static func scanAudioStats(
        asset: AVAsset,
        audioTracks: [AVAssetTrack]
    ) async throws -> (noiseFloor: Float, speechPeak: Float, sampleRate: Double, channels: Int) {
        let reader = try AVAssetReader(asset: asset)
        let pcmSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: pcmSettings)
        reader.add(output)
        guard reader.startReading() else {
            return (0.002, 0.25, 44100.0, 1)
        }

        var sampleRate: Double = 44100.0
        var channels: Int = 1
        var frameRMSValues: [Float] = []

        while let sample = output.copyNextSampleBuffer() {
            if let desc = CMSampleBufferGetFormatDescription(sample),
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
                if asbd.mSampleRate > 1000 { sampleRate = asbd.mSampleRate }
                if asbd.mChannelsPerFrame > 0 { channels = Int(asbd.mChannelsPerFrame) }
            }
            if let data = extractFloatSamples(from: sample) {
                let frameCount = data.count / max(1, channels)
                let statsWindow = max(64, Int((0.020 * sampleRate).rounded()))
                var idx = 0
                while idx < frameCount {
                    let end = min(frameCount, idx + statsWindow)
                    let span = (end - idx) * max(1, channels)
                    if span > 0 {
                        var sumSq: Float = 0
                        data.withUnsafeBufferPointer { buf in
                            if let ptr = buf.baseAddress?.advanced(by: idx * max(1, channels)) {
                                vDSP_svesq(ptr, 1, &sumSq, vDSP_Length(span))
                            }
                        }
                        frameRMSValues.append(sqrt(sumSq / Float(span)))
                    }
                    idx = end
                }
            }
        }

        guard !frameRMSValues.isEmpty else { return (0.002, 0.25, sampleRate, channels) }
        let sorted = frameRMSValues.sorted()
        let lowIdx = min(sorted.count - 1, max(0, Int(Double(sorted.count) * 0.15)))
        let highIdx = min(sorted.count - 1, max(0, Int(Double(sorted.count) * 0.92)))
        return (max(0.0005, sorted[lowIdx]), max(0.01, sorted[highIdx]), sampleRate, channels)
    }

    nonisolated private static func extractFloatSamples(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &pointer
        )
        guard status == kCMBlockBufferNoErr, let pointer, length >= MemoryLayout<Float>.size else { return nil }
        let count = length / MemoryLayout<Float>.size
        return pointer.withMemoryRebound(to: Float.self, capacity: count) { floatPtr in
            Array(UnsafeBufferPointer(start: floatPtr, count: count))
        }
    }

    nonisolated private static func processPCMBuffer(
        _ sampleBuffer: CMSampleBuffer,
        channels: Int,
        pts: CMTime,
        hpf: inout BiquadFilterState,
        deMud: inout BiquadFilterState,
        presence: inout BiquadFilterState,
        params: ExpanderParameters,
        envSq: inout Float,
        gain: inout Float
    ) -> CMSampleBuffer? {
        guard var samples = extractFloatSamples(from: sampleBuffer) else { return nil }
        let ch = max(1, channels)
        let frameCount = samples.count / ch
        guard frameCount > 0 else { return nil }

        let sampleRate = CMSampleBufferGetFormatDescription(sampleBuffer)
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate }
            .flatMap { $0 > 1000 ? $0 : nil } ?? 44100.0

        hpf.processInterleaved(&samples, frameCount: frameCount, channels: ch)
        deMud.processInterleaved(&samples, frameCount: frameCount, channels: ch)
        presence.processInterleaved(&samples, frameCount: frameCount, channels: ch)
        applyExpanderAndLimiter(&samples, frameCount: frameCount, channels: ch, params: params, envSq: &envSq, gain: &gain)

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(ch * MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(ch * MemoryLayout<Float>.size),
            mChannelsPerFrame: UInt32(ch),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var formatDesc: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        ) == noErr, let formatDesc else { return nil }

        let byteCount = samples.count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        guard CMBlockBufferAssureBlockMemory(blockBuffer) == kCMBlockBufferNoErr else { return nil }
        let replaceStatus = samples.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard replaceStatus == kCMBlockBufferNoErr else { return nil }

        var outBuffer: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDesc,
            sampleCount: CMItemCount(frameCount),
            presentationTimeStamp: pts,
            packetDescriptions: nil,
            sampleBufferOut: &outBuffer
        ) == noErr else { return nil }

        return outBuffer
    }

    private nonisolated struct BiquadFilterState {
        let b0: Double
        let b1: Double
        let b2: Double
        let a1: Double
        let a2: Double
        var x1: [Double]
        var x2: [Double]
        var y1: [Double]
        var y2: [Double]

        static func highPass(cutoffHz: Double, q: Double, sampleRate: Double, channels: Int) -> BiquadFilterState {
            let w0 = 2.0 * Double.pi * min(cutoffHz, sampleRate * 0.45) / sampleRate
            let cosW0 = cos(w0)
            let alpha = sin(w0) / (2.0 * q)
            let a0 = 1.0 + alpha
            return BiquadFilterState(
                b0: ((1.0 + cosW0) / 2.0) / a0,
                b1: (-(1.0 + cosW0)) / a0,
                b2: ((1.0 + cosW0) / 2.0) / a0,
                a1: (-2.0 * cosW0) / a0,
                a2: (1.0 - alpha) / a0,
                x1: Array(repeating: 0, count: channels),
                x2: Array(repeating: 0, count: channels),
                y1: Array(repeating: 0, count: channels),
                y2: Array(repeating: 0, count: channels)
            )
        }

        static func peaking(centerHz: Double, q: Double, gainDB: Double, sampleRate: Double, channels: Int) -> BiquadFilterState {
            let amp = pow(10.0, gainDB / 40.0)
            let w0 = 2.0 * Double.pi * min(centerHz, sampleRate * 0.45) / sampleRate
            let cosW0 = cos(w0)
            let alpha = sin(w0) / (2.0 * q)
            let a0 = 1.0 + alpha / amp
            return BiquadFilterState(
                b0: (1.0 + alpha * amp) / a0,
                b1: (-2.0 * cosW0) / a0,
                b2: (1.0 - alpha * amp) / a0,
                a1: (-2.0 * cosW0) / a0,
                a2: (1.0 - alpha / amp) / a0,
                x1: Array(repeating: 0, count: channels),
                x2: Array(repeating: 0, count: channels),
                y1: Array(repeating: 0, count: channels),
                y2: Array(repeating: 0, count: channels)
            )
        }

        mutating func processInterleaved(_ samples: inout [Float], frameCount: Int, channels: Int) {
            for f in 0..<frameCount {
                let base = f * channels
                for c in 0..<channels {
                    let x0 = Double(samples[base + c])
                    let y0 = b0 * x0 + b1 * x1[c] + b2 * x2[c] - a1 * y1[c] - a2 * y2[c]
                    x2[c] = x1[c]
                    x1[c] = x0
                    y2[c] = y1[c]
                    y1[c] = y0
                    samples[base + c] = Float(y0)
                }
            }
        }
    }
}
