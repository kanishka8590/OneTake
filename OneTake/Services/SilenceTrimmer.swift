import AVFoundation
import CoreMedia

/// Finds long silent edges and exports a padded suggestion. It never changes the source recording.
nonisolated enum SilenceTrimmer {
    struct Suggestion: Equatable, Sendable {
        let start: Double
        let end: Double
        let removedLeading: Double
        let removedTrailing: Double
    }

    private struct EnergyAccumulator {
        let sampleRate: Double
        let windowFrames: Int
        private(set) var energies: [Double] = []
        private(set) var totalFrames: Int = 0
        private var sum: Double = 0
        private var count: Int = 0

        init(sampleRate: Double) {
            self.sampleRate = sampleRate
            self.windowFrames = max(1, Int(sampleRate * 0.05))
        }

        mutating func appendSampleEnergy(_ energy: Double) {
            sum += energy
            count += 1
            totalFrames += 1
            if count == windowFrames {
                energies.append(sqrt(sum / Double(count)))
                sum = 0
                count = 0
            }
        }

        mutating func finalize() -> (energies: [Double], duration: Double)? {
            if count > 0 {
                energies.append(sqrt(sum / Double(count)))
                sum = 0
                count = 0
            }
            guard energies.count >= 10, sampleRate > 0 else { return nil }
            return (energies, Double(totalFrames) / sampleRate)
        }
    }

    static func suggest(for url: URL) -> Suggestion? {
        guard let analyzed = readWindowEnergiesFromAudioFile(url: url)
            ?? readWindowEnergiesFromAsset(url: url) else {
            return nil
        }

        let energies = analyzed.energies
        let duration = analyzed.duration
        let peak = energies.max() ?? 0
        let threshold = max(0.003, peak * 0.035)
        let active = energies.map { $0 >= threshold }
        guard let firstActive = active.indices.dropLast().first(where: { active[$0] && active[$0 + 1] }),
              let lastActive = active.indices.dropLast().reversed().first(where: { active[$0] && active[$0 + 1] }) else {
            return nil
        }
        let leadingSilence = Double(firstActive) * 0.05
        let trailingSilence = duration - Double(lastActive + 2) * 0.05
        guard leadingSilence >= 0.25 || trailingSilence >= 0.35 else { return nil }

        let padding = 0.15
        let start = max(0, leadingSilence - padding)
        let end = min(duration, duration - trailingSilence + padding)
        guard end - start >= 0.8, end - start < duration - 0.2 else { return nil }
        return Suggestion(start: start, end: end, removedLeading: start, removedTrailing: duration - end)
    }

    private static func readWindowEnergiesFromAudioFile(url: URL) -> (energies: [Double], duration: Double)? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        guard sampleRate > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384),
              let channels = buffer.floatChannelData else {
            return nil
        }

        var accumulator = EnergyAccumulator(sampleRate: sampleRate)
        let channelCount = max(1, Int(format.channelCount))

        while file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            let toRead = AVAudioFrameCount(min(Int64(buffer.frameCapacity), remaining))
            guard toRead > 0 else { break }
            do {
                try file.read(into: buffer, frameCount: toRead)
            } catch {
                return nil
            }
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            for frame in 0..<frames {
                var sampleEnergy: Double = 0
                for channel in 0..<channelCount {
                    let value = Double(channels[channel][frame])
                    sampleEnergy += value * value
                }
                accumulator.appendSampleEnergy(sampleEnergy / Double(channelCount))
            }
        }
        return accumulator.finalize()
    }

    private static func readWindowEnergiesFromAsset(url: URL) -> (energies: [Double], duration: Double)? {
        let asset = AVURLAsset(url: url)
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var audioTrack: AVAssetTrack?
        Task.detached {
            audioTrack = try? await asset.loadTracks(withMediaType: .audio).first
            sem.signal()
        }
        sem.wait()

        guard let track = audioTrack,
              let reader = try? AVAssetReader(asset: asset) else {
            return nil
        }

        let targetSampleRate = 16_000.0
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        var accumulator = EnergyAccumulator(sampleRate: targetSampleRate)
        while reader.status == .reading, let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            var lengthAtOffset = 0
            var totalLength = 0
            var dataPointer: UnsafeMutablePointer<CChar>?
            let status = CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: &lengthAtOffset,
                totalLengthOut: &totalLength,
                dataPointerOut: &dataPointer
            )
            guard status == kCMBlockBufferNoErr, let dataPointer, totalLength >= MemoryLayout<Float>.size else {
                continue
            }
            let sampleCount = totalLength / MemoryLayout<Float>.size
            dataPointer.withMemoryRebound(to: Float.self, capacity: sampleCount) { floatPtr in
                for idx in 0..<sampleCount {
                    let value = Double(floatPtr[idx])
                    accumulator.appendSampleEnergy(value * value)
                }
            }
        }
        return accumulator.finalize()
    }

    static func export(_ suggestion: Suggestion, from source: URL) async -> URL? {
        let asset = AVURLAsset(url: source)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            return nil
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("slate-trim-\(UUID().uuidString).mov")
        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: suggestion.start, preferredTimescale: 600),
            duration: CMTime(seconds: suggestion.end - suggestion.start, preferredTimescale: 600)
        )
        do {
            try await exporter.export(to: output, as: .mov)
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            return nil
        }
    }
}
