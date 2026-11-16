import Foundation
import AVFoundation

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
        destinationURL: URL
    ) async throws -> URL

    func compressVideoToTargetSize(
        sourceURL: URL,
        targetSizeMB: Double,
        destinationURL: URL
    ) async throws -> URL
}

// MARK: - VideoPostProcessingService Implementation

@MainActor
@Observable
final class VideoPostProcessingService: NSObject, VideoPostProcessingServiceProtocol {
    static let shared = VideoPostProcessingService()

    var exportProgress: Double = 0.0
    var isProcessing: Bool = false

    // MARK: - Combined Single-Pass Trim + Audio Cleanup

    func trimAndProcessVideo(
        sourceURL: URL,
        startSeconds: Double,
        endSeconds: Double,
        applyAudioCleanup: Bool,
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

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw VideoPostProcessingError.exportSessionCreationFailed("Could not create AVAssetExportSession.")
        }

        exportSession.timeRange = timeRange
        exportSession.shouldOptimizeForNetworkUse = true

        if applyAudioCleanup {
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            if let audioTrack = audioTracks.first {
                let audioMix = AVMutableAudioMix()
                let trackParams = AVMutableAudioMixInputParameters(track: audioTrack)
                // Gently lift vocal presence while keeping headroom.
                trackParams.setVolume(1.15, at: .zero)
                audioMix.inputParameters = [trackParams]
                exportSession.audioMix = audioMix
            }
        }

        try await exportSessionResult(exportSession, sourceURL: sourceURL, destinationURL: destinationURL)
        exportProgress = 1.0
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
        Task { @MainActor [weak self] in
            for await state in exportSession.states(updateInterval: 0.1) {
                guard !Task.isCancelled else { break }
                if case .exporting(let progress) = state {
                    self?.exportProgress = progress.fractionCompleted
                }
            }
        }
    }
}
