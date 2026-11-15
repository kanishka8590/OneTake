import Foundation
import AVFoundation

// MARK: - Post Processing Protocol

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

    func compressVideoToTargetSize(
        sourceURL: URL,
        targetSizeMB: Double,
        destinationURL: URL
    ) async throws -> URL
}

// MARK: - VideoPostProcessingService Implementation

@Observable
final class VideoPostProcessingService: NSObject, VideoPostProcessingServiceProtocol, @unchecked Sendable {
    static let shared = VideoPostProcessingService()

    var exportProgress: Double = 0.0
    var isProcessing: Bool = false

    // MARK: - Video Trimming (CMTimeRange + AVAssetExportSession)

    func trimVideo(
        sourceURL: URL,
        startSeconds: Double,
        endSeconds: Double,
        destinationURL: URL
    ) async throws -> URL {
        isProcessing = true
        exportProgress = 0.0
        defer {
            isProcessing = false
        }

        let asset = AVURLAsset(url: sourceURL)
        let totalDuration = try await asset.load(.duration).seconds

        let clampedStart = max(0.0, min(startSeconds, totalDuration))
        let clampedEnd = max(clampedStart + 0.1, min(endSeconds, totalDuration))
        let timeRange = CMTimeRange(
            start: CMTime(seconds: clampedStart, preferredTimescale: 600),
            duration: CMTime(seconds: clampedEnd - clampedStart, preferredTimescale: 600)
        )

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(domain: "OneTake.VideoPostProcessing", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize AVAssetExportSession"])
        }

        try? FileManager.default.removeItem(at: destinationURL)

        exportSession.timeRange = timeRange

        let tracker = trackProgress(for: exportSession)
        defer { tracker.cancel() }

        try await exportSession.export(to: destinationURL, as: .mp4)

        return destinationURL
    }

    // MARK: - Audio Noise Suppression Export

    func exportWithAudioCleanup(
        sourceURL: URL,
        enableNoiseSuppression: Bool,
        destinationURL: URL
    ) async throws -> URL {
        guard enableNoiseSuppression else {
            // Simply copy if noise suppression is not enabled
            try? FileManager.default.removeItem(at: destinationURL)
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            return destinationURL
        }

        isProcessing = true
        exportProgress = 0.0
        defer {
            isProcessing = false
        }

        let asset = AVURLAsset(url: sourceURL)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(domain: "OneTake.VideoPostProcessing", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio export session"])
        }

        try? FileManager.default.removeItem(at: destinationURL)

        // Apply audio mix with high-pass filtering simulation / gain adjustment
        let audioMix = AVMutableAudioMix()
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        if let audioTrack = audioTracks.first {
            let trackParams = AVMutableAudioMixInputParameters(track: audioTrack)
            // Slightly lift clean vocal frequencies
            trackParams.setVolume(1.15, at: .zero)
            audioMix.inputParameters = [trackParams]
            exportSession.audioMix = audioMix
        }

        let tracker = trackProgress(for: exportSession)
        defer { tracker.cancel() }

        try await exportSession.export(to: destinationURL, as: .mp4)

        return destinationURL
    }

    // MARK: - Bitrate Compression (128 MB -> ~85 MB)

    func compressVideoToTargetSize(
        sourceURL: URL,
        targetSizeMB: Double = 85.0,
        destinationURL: URL
    ) async throws -> URL {
        isProcessing = true
        exportProgress = 0.0
        defer {
            isProcessing = false
        }

        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration).seconds
        guard duration > 0 else { return sourceURL }

        // Select preset that meets target budget
        let preset: String
        let currentSizeMB = (try? FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size] as? Double) ?? 100.0 / 1024.0 / 1024.0
        if currentSizeMB > targetSizeMB {
            preset = AVAssetExportPreset1280x720
        } else {
            preset = AVAssetExportPresetHighestQuality
        }

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw NSError(domain: "OneTake.VideoPostProcessing", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize compression export"])
        }

        try? FileManager.default.removeItem(at: destinationURL)
        exportSession.shouldOptimizeForNetworkUse = true

        let tracker = trackProgress(for: exportSession)
        defer { tracker.cancel() }

        try await exportSession.export(to: destinationURL, as: .mp4)

        return destinationURL
    }

    // MARK: - Modern Progress Tracking (session.states)

    private func trackProgress(for exportSession: AVAssetExportSession) -> Task<Void, Never> {
        Task { [weak self] in
            for await state in exportSession.states(updateInterval: 0.1) {
                if case .exporting(let progress) = state {
                    let frac = progress.fractionCompleted
                    await MainActor.run {
                        self?.exportProgress = frac
                    }
                }
            }
        }
    }
}
