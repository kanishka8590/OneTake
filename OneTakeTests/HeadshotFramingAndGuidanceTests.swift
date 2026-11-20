import AVFoundation
import CoreGraphics
import CoreVideo
import UIKit
import XCTest
@testable import OneTake

final class HeadshotFramingAndGuidanceTests: XCTestCase {

    // MARK: - Helpers

    private func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let pb = buffer else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        if let base = CVPixelBufferGetBaseAddress(pb) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
            memset(base, 128, bytesPerRow * height)
        }
        return pb
    }

    /// Creates a `UIImage` whose raw backing `CGImage` has `rawSize` pixels and carries `orientation`.
    private func makeImage(rawWidth: Int, rawHeight: Int, orientation: UIImage.Orientation) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let base = UIGraphicsImageRenderer(
            size: CGSize(width: rawWidth, height: rawHeight),
            format: format
        ).image { ctx in
            UIColor(red: 0.25, green: 0.30, blue: 0.45, alpha: 1.0).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: rawWidth, height: rawHeight))
            UIColor.white.withAlphaComponent(0.75).setFill()
            ctx.fill(CGRect(x: rawWidth / 4, y: rawHeight / 5, width: rawWidth / 2, height: rawHeight / 2))
        }
        guard let cg = base.cgImage else { return base }
        return UIImage(cgImage: cg, scale: 1, orientation: orientation)
    }

    private func pixelSize(of image: UIImage) -> CGSize {
        if let cg = image.cgImage {
            return CGSize(width: cg.width, height: cg.height)
        }
        return CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }

    // MARK: - HeadshotPosePredictor

    func testHeadshotPosePredictorLoadsAndPredictsOn224BufferAndDemoImage() throws {
        let predictor = HeadshotPosePredictor(bundle: .main)
        XCTAssertTrue(predictor.isAvailable, "HeadshotPoseClassifier should load from Bundle.main")

        let buffer224 = try XCTUnwrap(makePixelBuffer(width: 224, height: 224))
        let bufferPrediction = try XCTUnwrap(predictor.predict(resized224Buffer: buffer224))

        XCTAssertEqual(bufferPrediction.probabilities.count, 3)
        let probSum = bufferPrediction.probabilities.values.reduce(0, +)
        XCTAssertGreaterThan(probSum, 0.95)
        XCTAssertLessThan(probSum, 1.05)
        for p in bufferPrediction.probabilities.values {
            XCTAssertTrue(p.isFinite)
            XCTAssertGreaterThanOrEqual(p, 0)
            XCTAssertLessThanOrEqual(p, 1)
        }
        XCTAssertTrue(bufferPrediction.yawDegrees.isFinite)
        XCTAssertTrue(bufferPrediction.yawRadians.isFinite)

        let demoImage = DemoMediaGenerator.renderHeadshotImage(angle: "front")
        let demoCG = try XCTUnwrap(demoImage.cgImage)
        let demoPrediction = try XCTUnwrap(predictor.predict(cgImage: demoCG, orientation: .up))
        XCTAssertGreaterThan(demoPrediction.confidence, 0)
        XCTAssertTrue(HeadshotPoseLabel.allCases.contains(demoPrediction.pose))
    }

    // MARK: - ImageFramer.autoCrop & Orientations

    func testImageFramerAutoCropHonorsRatiosAcrossOrientations() async {
        // Landscape raw backing (1600x1200) rotated .right/.left becomes portrait 1200x1600 upright.
        let cases: [(UIImage.Orientation, Int, Int)] = [
            (.up, 1200, 1600),
            (.down, 1200, 1600),
            (.right, 1600, 1200),
            (.left, 1600, 1200)
        ]

        let ratios: [(HeadshotAspectRatio, HeadshotCropPreset, CGFloat)] = [
            (.ratio4x5, .theatrical, 4.0 / 5.0),
            (.ratio2x3, .theatrical, 2.0 / 3.0),
            (.ratio1x1, .theatrical, 1.0),
            (.free, .commercial, 3.0 / 4.0),
            (.free, .cardSlotFit, 1200.0 / 1600.0)
        ]

        for (orientation, rawW, rawH) in cases {
            let source = makeImage(rawWidth: rawW, rawHeight: rawH, orientation: orientation)

            for (ratio, preset, expectedAspect) in ratios {
                let cropped = await ImageFramer.autoCrop(
                    image: source,
                    aspectRatio: ratio,
                    preset: preset
                )
                XCTAssertEqual(cropped.imageOrientation, .up, "Cropped image must always be normalized to .up")
                let px = pixelSize(of: cropped)
                let actualAspect = px.width / px.height
                XCTAssertEqual(
                    actualAspect,
                    expectedAspect,
                    accuracy: 0.015,
                    "Ratio \(ratio.rawValue) with preset \(preset.rawValue) and orientation \(orientation.rawValue) produced \(px.width)x\(px.height)"
                )
            }
        }
    }

    // MARK: - HeadshotCropMath

    func testHeadshotCropMathPortraitAndLandscapeScaledToFillAndClampedPan() {
        let containerSize = CGSize(width: 320, height: 400) // Exact 4:5 frame
        let targetAspect: CGFloat = 4.0 / 5.0

        // Portrait 800x1200 at zoom 1.0, zero offset
        let portraitSize = CGSize(width: 800, height: 1200)
        let portraitBase = HeadshotCropMath.cropRect(
            imageSize: portraitSize,
            containerSize: containerSize,
            targetAspect: targetAspect,
            scale: 1.0,
            offset: .zero
        )
        XCTAssertEqual(portraitBase.width, 800, accuracy: 0.5)
        XCTAssertEqual(portraitBase.height, 1000, accuracy: 0.5)
        XCTAssertEqual(portraitBase.origin.x, 0, accuracy: 0.5)
        XCTAssertEqual(portraitBase.origin.y, 100, accuracy: 0.5)
        XCTAssertEqual(portraitBase.width / portraitBase.height, targetAspect, accuracy: 0.001)

        // Landscape 1600x1000 at zoom 1.0, zero offset
        let landscapeSize = CGSize(width: 1600, height: 1000)
        let landscapeBase = HeadshotCropMath.cropRect(
            imageSize: landscapeSize,
            containerSize: containerSize,
            targetAspect: targetAspect,
            scale: 1.0,
            offset: .zero
        )
        XCTAssertEqual(landscapeBase.width, 800, accuracy: 0.5)
        XCTAssertEqual(landscapeBase.height, 1000, accuracy: 0.5)
        XCTAssertEqual(landscapeBase.origin.x, 400, accuracy: 0.5)
        XCTAssertEqual(landscapeBase.origin.y, 0, accuracy: 0.5)
        XCTAssertEqual(landscapeBase.width / landscapeBase.height, targetAspect, accuracy: 0.001)

        // Zoom 2.0 with extreme positive/negative pan offsets must clamp cleanly inside bounds
        let extremeOffsets = [
            CGSize(width: 50_000, height: -50_000),
            CGSize(width: -50_000, height: 50_000)
        ]

        for imgSize in [portraitSize, landscapeSize] {
            for offset in extremeOffsets {
                let zoomed = HeadshotCropMath.cropRect(
                    imageSize: imgSize,
                    containerSize: containerSize,
                    targetAspect: targetAspect,
                    scale: 2.0,
                    offset: offset
                )
                XCTAssertGreaterThanOrEqual(zoomed.minX, 0)
                XCTAssertGreaterThanOrEqual(zoomed.minY, 0)
                XCTAssertLessThanOrEqual(zoomed.maxX, imgSize.width + 0.001)
                XCTAssertLessThanOrEqual(zoomed.maxY, imgSize.height + 0.001)
                XCTAssertEqual(zoomed.width / zoomed.height, targetAspect, accuracy: 0.001)
            }
        }

        // End-to-end render verification with rotated input image
        let rotatedPortrait = makeImage(rawWidth: 1200, rawHeight: 800, orientation: .right)
        let rendered = HeadshotCropMath.renderCroppedImage(
            rotatedPortrait,
            containerSize: containerSize,
            targetAspect: targetAspect,
            scale: 2.0,
            offset: CGSize(width: 5_000, height: -5_000)
        )
        let renderedPx = pixelSize(of: rendered)
        XCTAssertEqual(rendered.imageOrientation, .up)
        XCTAssertEqual(renderedPx.width / renderedPx.height, targetAspect, accuracy: 0.01)
    }

    func testHeadshotCropMathDownsamplesLargeImagesWithOrientation() throws {
        let large = makeImage(rawWidth: 3200, rawHeight: 2400, orientation: .right)
        let data = try XCTUnwrap(large.jpegData(compressionQuality: 0.85))
        let downsampled = try XCTUnwrap(HeadshotCropMath.downsampledImage(from: data, maxPixelDimension: 2400))
        let px = pixelSize(of: downsampled)
        XCTAssertLessThanOrEqual(max(px.width, px.height), 2400)
        XCTAssertEqual(downsampled.imageOrientation, .up)
    }

    func testAdjustedOffsetClampsBaseAcrossAspectSwitchWithoutDragDeadZone() {
        let imgSize = CGSize(width: 1200, height: 1600) // 3:4 portrait image
        // Panned horizontally in a narrower 2:3 container at 1.2x zoom
        let narrowContainer = CGSize(width: 260, height: 390)
        let wideContainer = CGSize(width: 390, height: 390) // 1:1 container
        let baseRatio = CGSize(width: 0.25, height: 0.0)

        let narrowLimit = HeadshotCropMath.maxOffset(imageSize: imgSize, containerSize: narrowContainer, scale: 1.2)
        let wideLimit = HeadshotCropMath.maxOffset(imageSize: imgSize, containerSize: wideContainer, scale: 1.2)
        XCTAssertGreaterThan(narrowLimit.width, wideLimit.width)

        // Switching directly to 1:1 clamps cleanly within 1:1 bounds
        let switchedOffset = HeadshotCropMath.adjustedOffset(
            baseRatio: baseRatio,
            imageSize: imgSize,
            containerSize: wideContainer,
            scale: 1.2
        )
        XCTAssertLessThanOrEqual(abs(switchedOffset.width), wideLimit.width + 0.01)

        // Dragging back by -20pt immediately moves inward from the clamped edge (no dead-zone)
        let draggedBack = HeadshotCropMath.adjustedOffset(
            baseRatio: baseRatio,
            translation: CGSize(width: -20, height: 0),
            imageSize: imgSize,
            containerSize: wideContainer,
            scale: 1.2
        )
        XCTAssertEqual(draggedBack.width, switchedOffset.width - 20, accuracy: 0.01)
    }

    // MARK: - HeadshotGuidanceService Pure Evaluators & Demo Gating

    func testIsEyeLevelPitchRejectsFlatPhoneAndAcceptsUprightPhone() {
        XCTAssertFalse(HeadshotGuidanceService.isEyeLevelPitch(degrees: 0.0))
        XCTAssertFalse(HeadshotGuidanceService.isEyeLevelPitch(degrees: 10.0))
        XCTAssertFalse(HeadshotGuidanceService.isEyeLevelPitch(degrees: -12.0))
        XCTAssertFalse(HeadshotGuidanceService.isEyeLevelPitch(degrees: 45.0))
        XCTAssertTrue(HeadshotGuidanceService.isEyeLevelPitch(degrees: 88.0))
        XCTAssertTrue(HeadshotGuidanceService.isEyeLevelPitch(degrees: 90.0))
        XCTAssertTrue(HeadshotGuidanceService.isEyeLevelPitch(degrees: -86.0))
    }

    func testEvaluateAngleDoesNotFalselyPassFrontWhenYawIsNilWithoutPoseConfirmation() {
        // Nil Vision yaw and nil pose predictor must NOT pass .front
        let noSignal = HeadshotGuidanceService.evaluateAngle(
            .front,
            visionYawDegrees: nil,
            posePrediction: nil
        )
        XCTAssertFalse(noSignal.isCorrect)

        // Nil Vision yaw with profile pose prediction must NOT pass .front
        let profilePred = HeadshotPosePrediction(
            pose: .leftProfile,
            probabilities: [.front: 0.1, .leftProfile: 0.85, .rightProfile: 0.05],
            yawRadians: 0.9,
            yawDegrees: 52.0
        )
        let mismatch = HeadshotGuidanceService.evaluateAngle(
            .front,
            visionYawDegrees: nil,
            posePrediction: profilePred
        )
        XCTAssertFalse(mismatch.isCorrect)

        // Nil Vision yaw with confident .front pose prediction DOES pass .front
        let frontPred = HeadshotPosePrediction(
            pose: .front,
            probabilities: [.front: 0.88, .leftProfile: 0.06, .rightProfile: 0.06],
            yawRadians: 0.03,
            yawDegrees: 1.7
        )
        let confirmedFront = HeadshotGuidanceService.evaluateAngle(
            .front,
            visionYawDegrees: nil,
            posePrediction: frontPred
        )
        XCTAssertTrue(confirmedFront.isCorrect)
        XCTAssertEqual(confirmedFront.resolvedYawDegrees, 1.7, accuracy: 0.01)

        // Nil Vision yaw with confident .leftProfile prediction passes .left
        let confirmedLeft = HeadshotGuidanceService.evaluateAngle(
            .left,
            visionYawDegrees: nil,
            posePrediction: profilePred
        )
        XCTAssertTrue(confirmedLeft.isCorrect)

        // Vision yaw checks
        XCTAssertTrue(HeadshotGuidanceService.evaluateAngle(.front, visionYawDegrees: 5.0).isCorrect)
        XCTAssertFalse(HeadshotGuidanceService.evaluateAngle(.front, visionYawDegrees: 35.0).isCorrect)
        XCTAssertTrue(HeadshotGuidanceService.evaluateAngle(.left, visionYawDegrees: 45.0).isCorrect)
        XCTAssertTrue(HeadshotGuidanceService.evaluateAngle(.right, visionYawDegrees: -45.0).isCorrect)
    }

    @MainActor
    func testHeadshotGuidanceSessionDemoModeGating() {
        let service = HeadshotGuidanceService.shared
        defer { service.stopSession() }

        service.startSession(for: .front, isDemoMode: false)
        XCTAssertFalse(service.feedback.allChecksPassed, "Non-demo session must not fake passing checks at startup")
        #if targetEnvironment(simulator)
        XCTAssertNotNil(service.cameraErrorMessage)
        #endif

        service.startSession(for: .front, isDemoMode: true)
        #if targetEnvironment(simulator)
        XCTAssertTrue(service.feedback.allChecksPassed, "Demo Simulator session should populate simulated passing checks")
        XCTAssertNil(service.cameraErrorMessage)
        #else
        XCTAssertTrue(service.isSessionRunning)
        #endif
    }

    @MainActor
    func testDisableVoiceTriggersResetsListeningAndStatus() {
        let service = HeadshotGuidanceService.shared
        defer { service.stopSession() }

        service.voiceStatus = .starting
        service.disableVoiceTriggers()
        XCTAssertFalse(service.isVoiceListening)
        XCTAssertEqual(service.voiceStatus, .idle)
    }

    func testAlignedGuidanceSpeechAvoidsTriggerWordSelfCapture() {
        let eval = HeadshotGuidanceService.evaluatePoseGuide(
            hasFace: true,
            centerX: 0.5,
            centerYTopDown: 0.42,
            faceHeight: 0.34,
            visionYawDegrees: 0.0,
            posePrediction: nil,
            lighting: .good,
            isEyeLevel: true,
            background: .clean,
            targetAngle: .front,
            autoCaptureEnabled: false
        )
        XCTAssertTrue(eval.isAligned)
        XCTAssertFalse(eval.spoken.lowercased().contains("now"))
        XCTAssertFalse(eval.spoken.lowercased().contains("action"))
        XCTAssertFalse(eval.spoken.lowercased().contains("shoot"))
    }

    @MainActor
    func testHeadshotVoiceCommandTriggersCaptureDuringActiveSession() {
        let service = HeadshotGuidanceService.shared
        let prevCallback = service.onShutterTriggered
        defer {
            service.onShutterTriggered = prevCallback
            service.stopSession()
        }

        var didTrigger = false
        service.startSession(for: .front, isDemoMode: true)
        service.onShutterTriggered = {
            didTrigger = true
        }

        service.handleRecognizedTranscript("shoot", isFinal: false)
        XCTAssertTrue(didTrigger, "Headshot voice trigger 'shoot' must fire capture callback immediately")
    }

    @MainActor
    func testVoiceGuidanceDefaultsDisabledAndStartSessionDoesNotAutoEnableVoice() {
        let service = HeadshotGuidanceService.shared
        defer {
            service.voiceGuidanceEnabled = false
            service.stopSession()
        }

        XCTAssertFalse(service.voiceGuidanceEnabled)
        service.startSession(for: .front, isDemoMode: true)
        XCTAssertFalse(service.voiceGuidanceEnabled)
        XCTAssertFalse(service.isVoiceListening)
        XCTAssertEqual(service.voiceStatus, .idle)
    }
}
