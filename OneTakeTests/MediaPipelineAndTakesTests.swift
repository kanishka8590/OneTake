import XCTest
import AVFoundation
@testable import OneTake

@MainActor
final class MediaPipelineAndTakesTests: XCTestCase {

    private func makeTempDirectory(prefix: String = "OneTakeMediaPipelineTests") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - VideoPostProcessingService Tests

    func testCompressVideoBytesVsMBClassificationAndPlayableOutput() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sourceURL = dir.appendingPathComponent("small_clip.mp4")
        let ok = await DemoMediaGenerator.writeQuickSimulatedClip(
            to: sourceURL,
            title: "Compression Check",
            subtitle: "Bytes vs MB",
            durationSeconds: 1.5
        )
        XCTAssertTrue(ok)

        let sourceMeta = await VideoPostProcessingService.inspectTrackMetadata(at: sourceURL)
        XCTAssertGreaterThan(sourceMeta.fileSizeMB, 0.0)
        XCTAssertLessThan(sourceMeta.fileSizeMB, 5.0, "Demo clip should be well under 5 MB (~50-150 KB).")

        // Verify bytes-vs-MB bug is fixed: ~0.05 MB must NOT be misclassified as > 50.0 MB.
        let selectedPreset = VideoPostProcessingService.selectCompressionPreset(
            currentSizeMB: sourceMeta.fileSizeMB,
            targetSizeMB: 50.0
        )
        XCTAssertEqual(selectedPreset, AVAssetExportPresetHighestQuality)

        let oversizedPreset = VideoPostProcessingService.selectCompressionPreset(
            currentSizeMB: 120.0,
            targetSizeMB: 85.0
        )
        XCTAssertEqual(oversizedPreset, AVAssetExportPreset1280x720)

        let destURL = dir.appendingPathComponent("compressed_output.mp4")
        let exportedURL = try await VideoPostProcessingService.shared.compressVideoToTargetSize(
            sourceURL: sourceURL,
            targetSizeMB: 50.0,
            destinationURL: destURL
        )
        XCTAssertEqual(exportedURL.standardizedFileURL, destURL.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path))

        let destMeta = await VideoPostProcessingService.inspectTrackMetadata(at: destURL)
        XCTAssertFalse(destMeta.isPortrait)
        XCTAssertEqual(destMeta.aspectRatioString, "16:9")
        XCTAssertGreaterThan(destMeta.durationSeconds, 1.0)
        XCTAssertGreaterThan(destMeta.fileSizeMB, 0.0)
    }

    func testTrimAndProcessVideoProducesTrimmedPlayableMP4AndInspectsMetadata() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sourceURL = dir.appendingPathComponent("full_clip.mp4")
        let ok = await DemoMediaGenerator.writeQuickSimulatedClip(
            to: sourceURL,
            title: "Trim Source",
            subtitle: "3s Clip",
            durationSeconds: 3.0
        )
        XCTAssertTrue(ok)

        let trimmedURL = dir.appendingPathComponent("trimmed_cleaned.mp4")
        let resultURL = try await VideoPostProcessingService.shared.trimAndProcessVideo(
            sourceURL: sourceURL,
            startSeconds: 0.5,
            endSeconds: 2.0,
            applyAudioCleanup: true,
            destinationURL: trimmedURL
        )

        XCTAssertEqual(resultURL.standardizedFileURL, trimmedURL.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trimmedURL.path))

        let meta = await VideoPostProcessingService.inspectTrackMetadata(at: trimmedURL)
        XCTAssertFalse(meta.isPortrait)
        XCTAssertEqual(meta.aspectRatioString, "16:9")
        XCTAssertEqual(meta.durationSeconds, 1.5, accuracy: 0.25)
        XCTAssertGreaterThan(meta.fileSizeMB, 0.0)
        XCTAssertFalse(VideoPostProcessingService.shared.isProcessing)
    }

    func testPostProcessingHandlesInvalidAndMissingURLsAndNaNSafely() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let missingURL = dir.appendingPathComponent("does_not_exist.mp4")
        let missingMeta = await VideoPostProcessingService.inspectTrackMetadata(at: missingURL)
        XCTAssertEqual(missingMeta.durationSeconds, 0.0)
        XCTAssertEqual(missingMeta.fileSizeMB, 0.0)
        XCTAssertFalse(missingMeta.durationSeconds.isNaN)

        let invalidFileURL = dir.appendingPathComponent("corrupt.mp4")
        try Data("not a valid mp4".utf8).write(to: invalidFileURL)
        let invalidMeta = await VideoPostProcessingService.inspectTrackMetadata(at: invalidFileURL)
        XCTAssertEqual(invalidMeta.durationSeconds, 0.0)
        XCTAssertFalse(invalidMeta.durationSeconds.isNaN)

        let destURL = dir.appendingPathComponent("out.mp4")
        do {
            _ = try await VideoPostProcessingService.shared.compressVideoToTargetSize(
                sourceURL: missingURL,
                targetSizeMB: 50.0,
                destinationURL: destURL
            )
            XCTFail("Expected missing source URL to throw an error.")
        } catch {
            // Expected
        }

        do {
            _ = try await VideoPostProcessingService.shared.trimAndProcessVideo(
                sourceURL: invalidFileURL,
                startSeconds: .nan,
                endSeconds: .nan,
                applyAudioCleanup: false,
                destinationURL: destURL
            )
            XCTFail("Expected invalid video duration to throw an error.")
        } catch {
            // Expected
        }
        XCTAssertFalse(VideoPostProcessingService.shared.isProcessing)
    }

    // MARK: - CuePartnerAudioEngine Tests

    func testPlayNextCueWithEmptyPrecedingActorLineDoesNotDeadlock() async throws {
        let engine = CuePartnerAudioEngine.shared
        defer { engine.stopListening() }

        let cues = [
            CueLine(orderIndex: 0, speaker: "READER", cueText: "First cue line.", precedingActorLine: ""),
            CueLine(orderIndex: 1, speaker: "READER", cueText: "Second cue line.", precedingActorLine: "Actor line two.")
        ]

        var triggeredIndices: [Int] = []
        engine.startAuditionScenePartner(cues: cues, mode: .afterMyLine, responseDelay: 0.0) { index in
            triggeredIndices.append(index)
        }

        engine.playNextCue()
        // Allow Coordinator's DispatchQueue.main.asyncAfter(0) to execute.
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(triggeredIndices, [0], "Manual playNextCue() must force-trigger even when precedingActorLine is empty.")

        // Cancelling/stopping playback must release both engine and coordinator locks.
        engine.stopPlayback()
        XCTAssertFalse(engine.isCuePlaying)
        XCTAssertFalse(engine.isCoordinatorPlayingCue)
        XCTAssertEqual(engine.currentCueIndex, 1)
    }

    func testStopPlaybackCancelsPendingAsyncLoadAndResetsState() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cueURL = dir.appendingPathComponent("cue.m4a")
        let created = await DemoMediaGenerator.writeAudioCue(
            DemoMediaGenerator.AudioCueSpec(destinationURL: cueURL, frequencyHz: 440, durationSeconds: 1.5)
        )
        XCTAssertTrue(created)

        let engine = CuePartnerAudioEngine.shared
        defer { engine.stopListening() }

        var completionCalled = false
        engine.playCue(at: cueURL) {
            completionCalled = true
        }
        XCTAssertTrue(engine.isCuePlaying)

        // Cancel immediately before the background AVAudioPlayer initialization finishes on main.
        engine.stopPlayback()
        XCTAssertFalse(engine.isCuePlaying)

        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(engine.isCuePlaying, "Stale async audio load must not start playing after stopPlayback().")
        XCTAssertFalse(completionCalled)
    }

    func testSpeechSynthesizerDidCancelReleasesScriptCueCoordinatorLock() async throws {
        let engine = CuePartnerAudioEngine.shared
        defer { engine.stopListening() }

        let cues = [
            CueLine(orderIndex: 0, speaker: "READER", cueText: "Are you coming tonight?", precedingActorLine: "I need to tell you something.")
        ]
        engine.startListening(cues: cues, mode: .afterMyLine, responseDelay: 0.0)

        engine.ingestLiveMicInput(rms: 0.1, transcript: "I need to tell you something.", isFinal: true)
        XCTAssertTrue(engine.isCuePlaying)
        XCTAssertTrue(engine.isCoordinatorPlayingCue)

        // Wait for coordinator's schedule(0) to start TTS fallback, then simulate AVSpeechSynthesizer didCancel.
        try await Task.sleep(for: .milliseconds(80))
        let activeUtterance = try XCTUnwrap(engine.activeUtterance)

        // A stale/unrelated utterance must NOT clear the active cue lock.
        let staleUtterance = AVSpeechUtterance(string: "Stale utterance")
        engine.speechSynthesizer(engine.fallbackSynthesizer, didCancel: staleUtterance)
        XCTAssertTrue(engine.isCuePlaying)
        XCTAssertTrue(engine.isCoordinatorPlayingCue)

        // Cancelling the active utterance MUST release both engine and coordinator locks.
        engine.speechSynthesizer(engine.fallbackSynthesizer, didCancel: activeUtterance)

        XCTAssertFalse(engine.isCuePlaying)
        XCTAssertFalse(engine.isCoordinatorPlayingCue)
    }

    // MARK: - TeleprompterRecorderService Tests

    func testCameraPermissionDeniedDoesNotCorruptServiceInvariants() {
        let service = TeleprompterRecorderService.shared
        defer {
            service.stopSession()
            service.cameraPermissionDenied = false
            service.cameraErrorMessage = nil
        }

        service.cameraPermissionDenied = true
        service.voiceGuidanceEnabled = false
        service.mirrorFrontCamera = false
        service.applySimulatorMetrics()

        XCTAssertTrue(service.cameraPermissionDenied)
        XCTAssertFalse(service.voiceGuidanceEnabled)
        XCTAssertFalse(service.mirrorFrontCamera)
        XCTAssertTrue(service.qualityMetrics.isLightingEvaluated)
        XCTAssertTrue(service.qualityMetrics.isFramingEvaluated)
    }

    func testSimulatorNonDemoRecordingDoesNotWriteDummyTextFile() async throws {
        let service = TeleprompterRecorderService.shared
        defer {
            service.stopSession()
            service.isDemoMode = false
            service.cameraErrorMessage = nil
        }

        let tempFilesBefore = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
        )

        var receivedURL: URL? = URL(fileURLWithPath: "/sentinel")
        let completionExpectation = expectation(description: "Recording callback fires")

        service.isDemoMode = false
        service.startCountdownAndRecord(countdownSeconds: 0, isDemoMode: false) { url, _ in
            receivedURL = url
            completionExpectation.fulfill()
        }

        await fulfillment(of: [completionExpectation], timeout: 2.0)

        XCTAssertNil(receivedURL)
        XCTAssertFalse(service.isRecording)
        XCTAssertNotNil(service.cameraErrorMessage)

        let tempFilesAfter = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
        )
        let newFiles = tempFilesAfter.subtracting(tempFilesBefore)
        for name in newFiles where name.hasPrefix("onetake_take_") {
            XCTFail("Non-demo simulator recording must not write dummy file \(name)")
        }
    }

    func testSimulatorDemoRecordingGeneratesPlayableMP4() async throws {
        let service = TeleprompterRecorderService.shared
        defer {
            service.stopSession()
            service.isDemoMode = false
            service.cameraErrorMessage = nil
        }

        var recordedURL: URL?
        let finishedExpectation = expectation(description: "Demo recording produces MP4")

        service.startCountdownAndRecord(countdownSeconds: 0, isDemoMode: true) { url, _ in
            recordedURL = url
            finishedExpectation.fulfill()
        }

        XCTAssertTrue(service.isRecording)
        try await Task.sleep(for: .milliseconds(250))
        service.stopRecording()

        await fulfillment(of: [finishedExpectation], timeout: 10.0)

        let url = try XCTUnwrap(recordedURL)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let meta = await VideoPostProcessingService.inspectTrackMetadata(at: url)
        XCTAssertGreaterThan(meta.durationSeconds, 0.5)
        XCTAssertGreaterThan(meta.fileSizeMB, 0.0)
        XCTAssertEqual(meta.aspectRatioString, "16:9")
    }
}
