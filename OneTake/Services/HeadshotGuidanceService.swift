import AVFoundation
import CoreImage
import CoreMotion
import Foundation
import ImageIO
import Speech
import UIKit
import Vision

// MARK: - Orientation Helper

nonisolated private func cgImagePropertyOrientation(for uiOrientation: UIImage.Orientation) -> CGImagePropertyOrientation {
    switch uiOrientation {
    case .up: return .up
    case .down: return .down
    case .left: return .left
    case .right: return .right
    case .upMirrored: return .upMirrored
    case .downMirrored: return .downMirrored
    case .leftMirrored: return .leftMirrored
    case .rightMirrored: return .rightMirrored
    @unknown default: return .up
    }
}

// MARK: - Enums & Status Models

nonisolated enum LightingStatus: String, CaseIterable, Sendable {
    case good = "Good"
    case tooDark = "Too Dark"
    case uneven = "Uneven"
    case tooBright = "Too Bright"

    var badgeColorName: String {
        switch self {
        case .good: return "success"
        case .tooDark, .tooBright: return "error"
        case .uneven: return "warning"
        }
    }
}

nonisolated enum BackgroundStatus: String, CaseIterable, Sendable {
    case clean = "Clean Background"
    case cluttered = "Cluttered"
}

nonisolated struct GuidanceFeedback: Sendable {
    var hasFace: Bool = false
    var isFaceCentered: Bool = false
    var isAngleCorrect: Bool = false
    var currentYawDegrees: Double = 0.0
    var lighting: LightingStatus = .good
    var background: BackgroundStatus = .clean
    var isEyeLevel: Bool = true
    var pitchDegrees: Double = 90.0
    var guidanceHeadline: String? = nil
    var spokenAdvice: String? = nil
    var posePrediction: HeadshotPosePrediction? = nil

    var allChecksPassed: Bool {
        hasFace && isFaceCentered && isAngleCorrect && (lighting == .good)
    }
}

nonisolated struct PoseGuideEvaluation: Sendable {
    let isFaceCentered: Bool
    let isAngleCorrect: Bool
    let resolvedYawDegrees: Double
    let headline: String
    let spoken: String
    let isAligned: Bool
}

nonisolated struct AngleEvaluationResult: Equatable, Sendable {
    let isCorrect: Bool
    let resolvedYawDegrees: Double
}

// MARK: - Protocol

protocol HeadshotGuidanceServiceProtocol: AnyObject {
    var feedback: GuidanceFeedback { get }
    var isCapturing: Bool { get }
    var countdownRemaining: Int { get }
    var voiceGuidanceEnabled: Bool { get set }
    var isVoiceListening: Bool { get }
    var voiceStatus: LiveSpeechStatus { get }
    var cameraPermissionDenied: Bool { get }
    var cameraErrorMessage: String? { get }
    var shutterStatusMessage: String? { get }
    var isFrontCamera: Bool { get }

    func startSession(for angle: HeadshotAngle, isDemoMode: Bool)
    func stopSession()
    func flipCamera()
    func startCountdown(seconds: Int, completion: @escaping (UIImage?) -> Void)
    func evaluateImage(_ image: UIImage, for angle: HeadshotAngle) async -> GuidanceFeedback
    func triggerFramingFeedbackVoice()
    @MainActor func handleRecognizedTranscript(_ transcript: String, isFinal: Bool)
}

extension HeadshotGuidanceServiceProtocol {
    func startSession(for angle: HeadshotAngle) {
        startSession(for: angle, isDemoMode: false)
    }
}

// MARK: - Thread-Safe Cross-Queue State Box

nonisolated private final class GuidanceStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _isCapturing = false
    private var _isCountdownInProgress = false
    private var _isSessionRunning = false
    private var _targetAngle: HeadshotAngle = .front
    private var _isFrontCamera = true
    private var _cameraPosition: AVCaptureDevice.Position = .front
    private var _isDemoMode = false
    private var _wantsHandGesture = true
    private var _activeRecognitionTaskID: UUID?
    private var _isRestartingRecognition = false
    private var _isAudioTapInstalled = false
    private var _recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var _lastFrameAnalyzedAt: Date = .distantPast
    private var _isAnalyzingFrame = false
    private var _visionFrameCounter: Int = 0
    private var _cachedBackgroundIsPlain: Bool = true
    private var _recentYaws: [Double] = []
    private var _recentPoses: [HeadshotPosePrediction] = []
    private var _smoothedCenterX: CGFloat?
    private var _smoothedCenterY: CGFloat?
    private var _smoothedFaceHeight: CGFloat?

    func withLock<T>(_ body: (GuidanceStateBox) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(self)
    }

    var isCapturing: Bool {
        get { withLock { $0._isCapturing } }
        set { withLock { $0._isCapturing = newValue } }
    }

    var isCountdownInProgress: Bool {
        get { withLock { $0._isCountdownInProgress } }
        set { withLock { $0._isCountdownInProgress = newValue } }
    }

    var isSessionRunning: Bool {
        get { withLock { $0._isSessionRunning } }
        set { withLock { $0._isSessionRunning = newValue } }
    }

    var targetAngle: HeadshotAngle {
        get { withLock { $0._targetAngle } }
        set { withLock { $0._targetAngle = newValue } }
    }

    var isFrontCamera: Bool {
        get { withLock { $0._isFrontCamera } }
        set { withLock { $0._isFrontCamera = newValue } }
    }

    var cameraPosition: AVCaptureDevice.Position {
        get { withLock { $0._cameraPosition } }
        set { withLock { $0._cameraPosition = newValue } }
    }

    var isDemoMode: Bool {
        get { withLock { $0._isDemoMode } }
        set { withLock { $0._isDemoMode = newValue } }
    }

    var wantsHandGesture: Bool {
        get { withLock { $0._wantsHandGesture } }
        set { withLock { $0._wantsHandGesture = newValue } }
    }

    var activeRecognitionTaskID: UUID? {
        get { withLock { $0._activeRecognitionTaskID } }
        set { withLock { $0._activeRecognitionTaskID = newValue } }
    }

    var isRestartingRecognition: Bool {
        get { withLock { $0._isRestartingRecognition } }
        set { withLock { $0._isRestartingRecognition = newValue } }
    }

    var isAudioTapInstalled: Bool {
        get { withLock { $0._isAudioTapInstalled } }
        set { withLock { $0._isAudioTapInstalled = newValue } }
    }

    var recognitionRequest: SFSpeechAudioBufferRecognitionRequest? {
        get { withLock { $0._recognitionRequest } }
        set { withLock { $0._recognitionRequest = newValue } }
    }

    func tryBeginFrameAnalysis(minInterval: TimeInterval = 0.16) -> Bool {
        withLock { box in
            guard box._isSessionRunning else { return false }
            guard !box._isAnalyzingFrame else { return false }
            guard !box._isCapturing || box._isCountdownInProgress else { return false }
            let now = Date()
            guard now.timeIntervalSince(box._lastFrameAnalyzedAt) >= minInterval else { return false }
            box._isAnalyzingFrame = true
            box._lastFrameAnalyzedAt = now
            return true
        }
    }

    func endFrameAnalysis() {
        withLock { box in
            box._isAnalyzingFrame = false
        }
    }

    func shouldRunSegmentationThisFrame() -> Bool {
        withLock { box in
            let shouldRun = (box._visionFrameCounter % 4) == 0
            box._visionFrameCounter += 1
            return shouldRun
        }
    }

    var cachedBackgroundIsPlain: Bool {
        get { withLock { $0._cachedBackgroundIsPlain } }
        set { withLock { $0._cachedBackgroundIsPlain = newValue } }
    }

    func resetSmoothing() {
        withLock { box in
            box._recentYaws.removeAll()
            box._recentPoses.removeAll()
            box._smoothedCenterX = nil
            box._smoothedCenterY = nil
            box._smoothedFaceHeight = nil
            box._cachedBackgroundIsPlain = true
            box._visionFrameCounter = 0
        }
    }

    func smoothVisionSignals(
        hasFace: Bool,
        centerX: CGFloat,
        centerYTopDown: CGFloat,
        faceHeight: CGFloat,
        rawYaw: Double?,
        posePrediction: HeadshotPosePrediction?
    ) -> (centerX: CGFloat, centerYTopDown: CGFloat, faceHeight: CGFloat, yaw: Double?, pose: HeadshotPosePrediction?) {
        withLock { box in
            let sX: CGFloat
            let sY: CGFloat
            let sH: CGFloat
            if hasFace {
                if let px = box._smoothedCenterX, let py = box._smoothedCenterY, let ph = box._smoothedFaceHeight {
                    sX = px * 0.4 + centerX * 0.6
                    sY = py * 0.4 + centerYTopDown * 0.6
                    sH = ph * 0.4 + faceHeight * 0.6
                } else {
                    sX = centerX
                    sY = centerYTopDown
                    sH = faceHeight
                }
                box._smoothedCenterX = sX
                box._smoothedCenterY = sY
                box._smoothedFaceHeight = sH
            } else {
                box._smoothedCenterX = nil
                box._smoothedCenterY = nil
                box._smoothedFaceHeight = nil
                box._recentYaws.removeAll()
                sX = centerX
                sY = centerYTopDown
                sH = faceHeight
            }

            if let rawYaw {
                box._recentYaws.append(rawYaw)
                if box._recentYaws.count > 3 { box._recentYaws.removeFirst() }
            } else if !hasFace {
                box._recentYaws.removeAll()
            }

            let smoothedYaw: Double? = box._recentYaws.isEmpty ? rawYaw : {
                let sorted = box._recentYaws.sorted()
                return sorted[sorted.count / 2]
            }()

            if let posePrediction {
                box._recentPoses.append(posePrediction)
                if box._recentPoses.count > 3 { box._recentPoses.removeFirst() }
            }
            let smoothedPose: HeadshotPosePrediction? = box._recentPoses.last

            return (sX, sY, sH, smoothedYaw, smoothedPose)
        }
    }
}

// MARK: - HeadshotGuidanceService Implementation

@Observable
final class HeadshotGuidanceService: NSObject, HeadshotGuidanceServiceProtocol, SFSpeechRecognizerDelegate, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    static let shared = HeadshotGuidanceService()

    nonisolated static let unevenLightingThreshold: Double = 0.30
    nonisolated static let frameAnalysisInterval: TimeInterval = 0.16

    var feedback: GuidanceFeedback = GuidanceFeedback()
    var isCapturing: Bool = false
    var countdownRemaining: Int = 0
    var voiceGuidanceEnabled: Bool = true
    var gesturesEnabled: Bool = true {
        didSet {
            stateBox.wantsHandGesture = gesturesEnabled
            if !gesturesEnabled {
                openPalmDetected = false
            }
        }
    }
    var autoCaptureEnabled: Bool = false
    var openPalmDetected: Bool = false
    var isVoiceListening: Bool = false
    var voiceStatus: LiveSpeechStatus = .idle
    var cameraPermissionDenied: Bool = false
    var cameraErrorMessage: String? = nil
    var shutterStatusMessage: String? = nil
    var isFrontCamera: Bool = true

    @ObservationIgnored var onShutterTriggered: (() -> Void)?

    // State tracking
    private(set) var isSessionRunning: Bool = false
    private(set) var captureSession: AVCaptureSession?
    @ObservationIgnored private let stateBox = GuidanceStateBox()
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "com.onetake.headshot.session")
    @ObservationIgnored private let visionQueue = DispatchQueue(label: "com.onetake.headshot.vision")
    @ObservationIgnored private let voiceAudioSessionQueue = DispatchQueue(label: "com.onetake.headshot.voice.audiosession", qos: .userInitiated)
    @ObservationIgnored private var taskRestartTimer: Timer?
    @ObservationIgnored private var recognitionRestartWorkItem: DispatchWorkItem?
    @ObservationIgnored private var audioSessionObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var engineConfigurationObserver: NSObjectProtocol?
    @ObservationIgnored private var requireAlignmentForActiveCountdown: Bool = false

    // Capture Session (sessionQueue-owned references)
    @ObservationIgnored nonisolated(unsafe) private var sessionCaptureSession: AVCaptureSession?
    @ObservationIgnored nonisolated(unsafe) private var sessionVideoDevice: AVCaptureDevice?
    @ObservationIgnored nonisolated(unsafe) private var sessionPhotoOutput: AVCapturePhotoOutput?
    @ObservationIgnored nonisolated(unsafe) private var sessionVideoDataOutput: AVCaptureVideoDataOutput?
    @ObservationIgnored private weak var previewLayer: AVCaptureVideoPreviewLayer?

    // Subsystems
    @ObservationIgnored private let motionManager = CMMotionManager()
    @ObservationIgnored private let speechSynthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var speechRecognizer: SFSpeechRecognizer?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
    @ObservationIgnored private let audioEngine = AVAudioEngine()

    // State & Debouncing
    @ObservationIgnored private var targetAngle: HeadshotAngle = .front
    @ObservationIgnored private var isDemoMode: Bool = false
    @ObservationIgnored private var lastSpokenTime: Date = .distantPast
    @ObservationIgnored private var lastSpokenMessage: String = ""
    @ObservationIgnored private let speechMinInterval: TimeInterval = 2.0
    @ObservationIgnored private let speechRepeatInterval: TimeInterval = 4.5
    @ObservationIgnored private var pendingPhotoCompletion: ((UIImage?) -> Void)?
    @ObservationIgnored private var countdownToken: UUID?
    @ObservationIgnored private var isCountdownInProgress = false
    @ObservationIgnored private var isCountdownSpeechActive = false
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var shutterStatusClearTask: Task<Void, Never>?
    @ObservationIgnored private var isTTSSpeaking = false
    @ObservationIgnored private var lastTTSEndedAt: Date = .distantPast
    @ObservationIgnored private var lastAlignedAt: Date?
    @ObservationIgnored private var alignmentLossGraceInterval: TimeInterval = 0.50
    @ObservationIgnored private var poseAnnouncementToken: UUID?
    @ObservationIgnored private lazy var voiceCommandController: LiveVoiceCommandController = { [weak self] in
        LiveVoiceCommandController(
            mode: .headshots,
            state: { [weak self] in
                LiveVoiceCommandState(
                    isRecording: false,
                    isCountingDown: false,
                    isCapturingPhoto: self?.isCapturing ?? false
                )
            },
            capturePhoto: { [weak self] in self?.triggerShutterCapture() },
            speakFramingFeedback: { [weak self] in self?.triggerFramingFeedbackVoice() }
        )
    }()

    // Simulator test controls (used only in Demo Mode)
    var simulatedCentered: Bool = true
    var simulatedLighting: LightingStatus = .good
    var simulatedYaw: Double = 0.0
    var simulatedEyeLevel: Bool = true
    var simulatedPlainBackground: Bool = true

    override init() {
        super.init()
        speechSynthesizer.delegate = self
        observeAudioSessionChanges()
    }

    deinit {
        for observer in audioSessionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Pure Testable Guidance Evaluators

    nonisolated static func isEyeLevelPitch(degrees: Double) -> Bool {
        abs(abs(degrees) - 90.0) < 22.0
    }

    nonisolated static func evaluateYawAngle(
        targetAngle: HeadshotAngle,
        visionYawDegrees: Double?,
        posePrediction: HeadshotPosePrediction?
    ) -> AngleEvaluationResult {
        switch targetAngle {
        case .front:
            if let yaw = visionYawDegrees {
                return AngleEvaluationResult(isCorrect: abs(yaw) <= 22.0, resolvedYawDegrees: yaw)
            }
            if let prediction = posePrediction, prediction.pose == .front, prediction.confidence >= 0.45 {
                return AngleEvaluationResult(isCorrect: true, resolvedYawDegrees: prediction.yawDegrees)
            }
            return AngleEvaluationResult(isCorrect: false, resolvedYawDegrees: posePrediction?.yawDegrees ?? 0.0)

        case .left:
            if let yaw = visionYawDegrees, yaw >= 20.0 && yaw <= 88.0 {
                return AngleEvaluationResult(isCorrect: true, resolvedYawDegrees: yaw)
            }
            if let prediction = posePrediction, prediction.pose == .leftProfile, prediction.confidence >= 0.45 {
                return AngleEvaluationResult(isCorrect: true, resolvedYawDegrees: prediction.yawDegrees)
            }
            return AngleEvaluationResult(
                isCorrect: false,
                resolvedYawDegrees: visionYawDegrees ?? posePrediction?.yawDegrees ?? 0.0
            )

        case .right:
            if let yaw = visionYawDegrees, yaw <= -20.0 && yaw >= -88.0 {
                return AngleEvaluationResult(isCorrect: true, resolvedYawDegrees: yaw)
            }
            if let prediction = posePrediction, prediction.pose == .rightProfile, prediction.confidence >= 0.45 {
                return AngleEvaluationResult(isCorrect: true, resolvedYawDegrees: prediction.yawDegrees)
            }
            return AngleEvaluationResult(
                isCorrect: false,
                resolvedYawDegrees: visionYawDegrees ?? posePrediction?.yawDegrees ?? 0.0
            )
        }
    }

    nonisolated static func evaluateAngle(
        _ targetAngle: HeadshotAngle,
        visionYawDegrees: Double?,
        posePrediction: HeadshotPosePrediction? = nil
    ) -> AngleEvaluationResult {
        evaluateYawAngle(
            targetAngle: targetAngle,
            visionYawDegrees: visionYawDegrees,
            posePrediction: posePrediction
        )
    }

    /// Combines CoreML `HeadshotPosePredictor` + Vision face framing + lighting/pitch/background
    /// into exact directional coaching text & TTS phrasing (ported from `OneTake-iOS-main`).
    nonisolated static func evaluatePoseGuide(
        hasFace: Bool,
        centerX: CGFloat,
        centerYTopDown: CGFloat,
        faceHeight: CGFloat,
        visionYawDegrees: Double?,
        posePrediction: HeadshotPosePrediction?,
        lighting: LightingStatus,
        isEyeLevel: Bool,
        background: BackgroundStatus,
        targetAngle: HeadshotAngle,
        autoCaptureEnabled: Bool
    ) -> PoseGuideEvaluation {
        let angleEval = evaluateYawAngle(
            targetAngle: targetAngle,
            visionYawDegrees: visionYawDegrees,
            posePrediction: posePrediction
        )

        guard hasFace else {
            return PoseGuideEvaluation(
                isFaceCentered: false,
                isAngleCorrect: false,
                resolvedYawDegrees: angleEval.resolvedYawDegrees,
                headline: "Show your face to the camera",
                spoken: "Step into the frame so your face is visible.",
                isAligned: false
            )
        }

        if faceHeight < 0.17 {
            return PoseGuideEvaluation(
                isFaceCentered: false,
                isAngleCorrect: angleEval.isCorrect,
                resolvedYawDegrees: angleEval.resolvedYawDegrees,
                headline: "Move closer",
                spoken: "Move closer to the camera.",
                isAligned: false
            )
        }
        if faceHeight > 0.56 {
            return PoseGuideEvaluation(
                isFaceCentered: false,
                isAngleCorrect: angleEval.isCorrect,
                resolvedYawDegrees: angleEval.resolvedYawDegrees,
                headline: "Move back a little",
                spoken: "Move back a little.",
                isAligned: false
            )
        }
        if centerX < 0.33 {
            return PoseGuideEvaluation(
                isFaceCentered: false,
                isAngleCorrect: angleEval.isCorrect,
                resolvedYawDegrees: angleEval.resolvedYawDegrees,
                headline: "Too far left — move right",
                spoken: "Move to your right.",
                isAligned: false
            )
        }
        if centerX > 0.67 {
            return PoseGuideEvaluation(
                isFaceCentered: false,
                isAngleCorrect: angleEval.isCorrect,
                resolvedYawDegrees: angleEval.resolvedYawDegrees,
                headline: "Too far right — move left",
                spoken: "Move to your left.",
                isAligned: false
            )
        }
        if centerYTopDown < 0.24 {
            return PoseGuideEvaluation(
                isFaceCentered: false,
                isAngleCorrect: angleEval.isCorrect,
                resolvedYawDegrees: angleEval.resolvedYawDegrees,
                headline: "Tilt the phone up a little",
                spoken: "Tilt the phone up a little.",
                isAligned: false
            )
        }
        if centerYTopDown > 0.62 {
            return PoseGuideEvaluation(
                isFaceCentered: false,
                isAngleCorrect: angleEval.isCorrect,
                resolvedYawDegrees: angleEval.resolvedYawDegrees,
                headline: "Tilt the phone down a little",
                spoken: "Tilt the phone down a little.",
                isAligned: false
            )
        }

        let yawDegrees = angleEval.resolvedYawDegrees
        switch targetAngle {
        case .front:
            if !angleEval.isCorrect {
                return PoseGuideEvaluation(
                    isFaceCentered: true,
                    isAngleCorrect: false,
                    resolvedYawDegrees: yawDegrees,
                    headline: "Look straight at the camera",
                    spoken: "Look straight at the camera.",
                    isAligned: false
                )
            }
        case .left:
            if (posePrediction?.pose == .rightProfile && (posePrediction?.confidence ?? 0) >= 0.55) || yawDegrees < -15 {
                return PoseGuideEvaluation(
                    isFaceCentered: true,
                    isAngleCorrect: false,
                    resolvedYawDegrees: yawDegrees,
                    headline: "Wrong side — turn your head left",
                    spoken: "Wrong side, turn your head to your left.",
                    isAligned: false
                )
            }
            if abs(yawDegrees) > 105 {
                return PoseGuideEvaluation(
                    isFaceCentered: true,
                    isAngleCorrect: false,
                    resolvedYawDegrees: yawDegrees,
                    headline: "Turn back a little",
                    spoken: "Turn back slightly toward the camera.",
                    isAligned: false
                )
            }
            if !angleEval.isCorrect {
                return PoseGuideEvaluation(
                    isFaceCentered: true,
                    isAngleCorrect: false,
                    resolvedYawDegrees: yawDegrees,
                    headline: "Turn your head to your left",
                    spoken: "Turn your head to your left.",
                    isAligned: false
                )
            }
        case .right:
            if (posePrediction?.pose == .leftProfile && (posePrediction?.confidence ?? 0) >= 0.55) || yawDegrees > 15 {
                return PoseGuideEvaluation(
                    isFaceCentered: true,
                    isAngleCorrect: false,
                    resolvedYawDegrees: yawDegrees,
                    headline: "Wrong side — turn your head right",
                    spoken: "Wrong side, turn your head to your right.",
                    isAligned: false
                )
            }
            if abs(yawDegrees) > 105 {
                return PoseGuideEvaluation(
                    isFaceCentered: true,
                    isAngleCorrect: false,
                    resolvedYawDegrees: yawDegrees,
                    headline: "Turn back a little",
                    spoken: "Turn back slightly toward the camera.",
                    isAligned: false
                )
            }
            if !angleEval.isCorrect {
                return PoseGuideEvaluation(
                    isFaceCentered: true,
                    isAngleCorrect: false,
                    resolvedYawDegrees: yawDegrees,
                    headline: "Turn your head to your right",
                    spoken: "Turn your head to your right.",
                    isAligned: false
                )
            }
        }

        switch lighting {
        case .tooDark:
            return PoseGuideEvaluation(
                isFaceCentered: true,
                isAngleCorrect: true,
                resolvedYawDegrees: yawDegrees,
                headline: "Lighting is too dark — add front light",
                spoken: "Lighting is too dark. Add light in front of you.",
                isAligned: false
            )
        case .uneven:
            return PoseGuideEvaluation(
                isFaceCentered: true,
                isAngleCorrect: true,
                resolvedYawDegrees: yawDegrees,
                headline: "Balance light evenly across your face",
                spoken: "Balance light evenly across your face.",
                isAligned: false
            )
        case .tooBright:
            return PoseGuideEvaluation(
                isFaceCentered: true,
                isAngleCorrect: true,
                resolvedYawDegrees: yawDegrees,
                headline: "Lighting is too bright — reduce glare",
                spoken: "Lighting is too bright. Reduce glare.",
                isAligned: false
            )
        case .good:
            break
        }

        return PoseGuideEvaluation(
            isFaceCentered: true,
            isAngleCorrect: true,
            resolvedYawDegrees: yawDegrees,
            headline: autoCaptureEnabled ? "Perfect — holding steady to auto-shoot" : "Hold still — ready",
            spoken: autoCaptureEnabled ? "Hold still." : "Framing and lighting look great. Ready!",
            isAligned: true
        )
    }

    // MARK: - Motion Setup

    private func startMotionUpdates() {
        guard motionManager.isDeviceMotionAvailable, !motionManager.isDeviceMotionActive else { return }
        motionManager.deviceMotionUpdateInterval = 0.2
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let pitchDeg = motion.attitude.pitch * 180.0 / .pi
            let isVertical = Self.isEyeLevelPitch(degrees: pitchDeg)
            self.feedback.pitchDegrees = pitchDeg
            self.feedback.isEyeLevel = isVertical
            self.cancelCountdownIfAlignmentLost()
        }
    }

    private func stopMotionUpdates() {
        if motionManager.isDeviceMotionActive {
            motionManager.stopDeviceMotionUpdates()
        }
    }

    // MARK: - Session Lifecycle

    func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = layer
        applyPreviewLayerConfiguration(for: stateBox.cameraPosition)
    }

    private func applyPreviewLayerConfiguration(for position: AVCaptureDevice.Position) {
        guard let conn = previewLayer?.connection else { return }
        if conn.isVideoRotationAngleSupported(90) {
            conn.videoRotationAngle = 90
        }
        if conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = (position == .front)
        }
    }

    func startSession(for angle: HeadshotAngle, isDemoMode: Bool = false) {
        let needsInitialVoiceSetup = !isSessionRunning
        self.targetAngle = angle
        self.isDemoMode = isDemoMode
        self.stateBox.targetAngle = angle
        self.stateBox.isDemoMode = isDemoMode
        self.stateBox.resetSmoothing()
        self.lastAlignedAt = nil

        self.poseAnnouncementToken = nil
        self.countdownTask?.cancel()
        self.countdownTask = nil
        self.shutterStatusClearTask?.cancel()
        self.shutterStatusClearTask = nil
        self.shutterStatusMessage = nil
        self.cameraErrorMessage = nil

        self.setCapturingState(false)
        self.countdownRemaining = 0
        self.countdownToken = nil
        self.setCountdownInProgressState(false)
        self.isCountdownSpeechActive = false
        self.pendingPhotoCompletion = nil
        self.feedback = GuidanceFeedback()

        self.isSessionRunning = true
        self.stateBox.isSessionRunning = true
        self.stateBox.wantsHandGesture = self.gesturesEnabled
        self.openPalmDetected = false
        self.lastSpokenTime = .distantPast
        self.lastSpokenMessage = ""
        self.startMotionUpdates()

        #if targetEnvironment(simulator)
        if isDemoMode {
            configureSimulatorDefaults(for: angle)
        } else {
            feedback.isFaceCentered = false
            feedback.isAngleCorrect = false
            cameraErrorMessage = "Live camera is unavailable in the iOS Simulator. Enable Demo Mode in Profile or test on a physical device."
        }
        if needsInitialVoiceSetup, isVoiceAuthorizedInSystem {
            setupVoiceTriggerIfAuthorized()
        }
        #else
        prepareCameraSession()
        if needsInitialVoiceSetup, isVoiceAuthorizedInSystem {
            setupVoiceTriggerIfAuthorized()
        }
        #endif
    }

    func stopSession() {
        isSessionRunning = false
        stateBox.isSessionRunning = false
        openPalmDetected = false
        requireAlignmentForActiveCountdown = false
        stopMotionUpdates()

        #if !targetEnvironment(simulator)
        sessionQueue.async { [weak self] in
            self?.sessionCaptureSession?.stopRunning()
        }
        #endif

        stopVoiceTrigger()
        poseAnnouncementToken = nil
        countdownTask?.cancel()
        countdownTask = nil
        shutterStatusClearTask?.cancel()
        shutterStatusClearTask = nil
        shutterStatusMessage = nil
        countdownToken = nil
        setCountdownInProgressState(false)
        isCountdownSpeechActive = false
        pendingPhotoCompletion = nil
        setCapturingState(false)
        countdownRemaining = 0
    }

    private func configureSimulatorDefaults(for angle: HeadshotAngle) {
        switch angle {
        case .front: simulatedYaw = 0.0
        case .left: simulatedYaw = 50.0
        case .right: simulatedYaw = -50.0
        }
        feedback.hasFace = simulatedCentered
        feedback.isAngleCorrect = true
        feedback.isFaceCentered = simulatedCentered
        feedback.lighting = simulatedLighting
        feedback.isEyeLevel = simulatedEyeLevel
        feedback.background = simulatedPlainBackground ? .clean : .cluttered
        feedback.currentYawDegrees = simulatedYaw
        let eval = Self.evaluatePoseGuide(
            hasFace: feedback.hasFace,
            centerX: 0.5,
            centerYTopDown: 0.42,
            faceHeight: 0.34,
            visionYawDegrees: simulatedYaw,
            posePrediction: nil,
            lighting: feedback.lighting,
            isEyeLevel: feedback.isEyeLevel,
            background: feedback.background,
            targetAngle: angle,
            autoCaptureEnabled: autoCaptureEnabled
        )
        feedback.guidanceHeadline = eval.headline
        feedback.spokenAdvice = eval.spoken
    }

    private func setCapturingState(_ capturing: Bool) {
        isCapturing = capturing
        stateBox.isCapturing = capturing
    }

    private func setCountdownInProgressState(_ inProgress: Bool) {
        isCountdownInProgress = inProgress
        stateBox.isCountdownInProgress = inProgress
    }

    // MARK: - Camera Flip

    func flipCamera() {
        guard !isCapturing else { return }
        sessionQueue.async { [weak self] in
            guard let self, let session = self.sessionCaptureSession else { return }
            session.beginConfiguration()
            guard let currentInput = session.inputs.first(where: {
                ($0 as? AVCaptureDeviceInput)?.device.hasMediaType(.video) == true
            }) as? AVCaptureDeviceInput else {
                session.commitConfiguration()
                return
            }

            session.removeInput(currentInput)
            let newPosition: AVCaptureDevice.Position = (currentInput.device.position == .front) ? .back : .front
            var activePosition = currentInput.device.position

            if let newDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPosition),
               let newInput = try? AVCaptureDeviceInput(device: newDevice),
               session.canAddInput(newInput) {
                session.addInput(newInput)
                self.sessionVideoDevice = newDevice
                activePosition = newPosition
            } else {
                session.addInput(currentInput)
            }

            self.stateBox.cameraPosition = activePosition
            self.stateBox.isFrontCamera = (activePosition == .front)
            self.configureVideoConnection(self.sessionVideoDataOutput?.connection(with: .video), position: activePosition)
            self.configureVideoConnection(self.sessionPhotoOutput?.connection(with: .video), position: activePosition)
            session.commitConfiguration()

            let resolvedPosition = activePosition
            let isFront = (resolvedPosition == .front)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isFrontCamera = isFront
                self.applyPreviewLayerConfiguration(for: resolvedPosition)
            }
        }
    }

    // MARK: - Countdown & Capture Flow

    func startCountdown(seconds: Int = 3, completion: @escaping (UIImage?) -> Void) {
        startCountdown(seconds: seconds, requireAlignment: false, completion: completion)
    }

    func startCountdown(seconds: Int = 3, requireAlignment: Bool, completion: @escaping (UIImage?) -> Void) {
        guard !isCapturing else { return }

        if requireAlignment {
            guard feedback.allChecksPassed else {
                let reason = currentBlockingReason()
                surfaceShutterStatus(reason)
                speakCurrentPoseGuidanceIfNeeded()
                return
            }
        }

        shutterStatusClearTask?.cancel()
        shutterStatusClearTask = nil
        shutterStatusMessage = nil

        requireAlignmentForActiveCountdown = requireAlignment
        setCapturingState(true)
        countdownRemaining = 0
        pendingPhotoCompletion = completion
        setCountdownInProgressState(true)
        isCountdownSpeechActive = false

        let token = UUID()
        countdownToken = token

        countdownTask?.cancel()
        countdownTask = Task { @MainActor [weak self] in
            await self?.runCountdown(seconds: seconds, token: token)
        }
    }

    private func currentBlockingReason() -> String {
        if let cameraErrorMessage, !cameraErrorMessage.isEmpty {
            return cameraErrorMessage
        }
        if !feedback.isFaceCentered {
            return "Center your face in the guide oval first"
        }
        if !feedback.isAngleCorrect {
            switch targetAngle {
            case .front: return "Face the camera directly"
            case .left: return "Turn slightly to your left"
            case .right: return "Turn slightly to your right"
            }
        }
        if feedback.lighting != .good {
            switch feedback.lighting {
            case .tooDark: return "Lighting is too dark — add front light"
            case .uneven: return "Balance lighting across your face"
            case .tooBright: return "Lighting is too bright — reduce glare"
            case .good: break
            }
        }
        if !feedback.isEyeLevel {
            return "Hold phone upright at eye level"
        }
        if feedback.background != .clean {
            return "Use a plain, uncluttered background"
        }
        return "Align inside the guide oval"
    }

    private func surfaceShutterStatus(_ message: String) {
        shutterStatusClearTask?.cancel()
        shutterStatusMessage = message
        shutterStatusClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self else { return }
            if self.shutterStatusMessage == message {
                self.shutterStatusMessage = nil
            }
        }
    }

    private func runCountdown(seconds: Int, token: UUID) async {
        // Wait briefly if a coaching phrase is already speaking, without stalling forever.
        var waitedSteps = 0
        while speechSynthesizer.isSpeaking && waitedSteps < 15 {
            guard !Task.isCancelled, isCapturing, isCountdownInProgress, countdownToken == token else { return }
            if requireAlignmentForActiveCountdown && !feedback.allChecksPassed {
                cancelCountdownAndResumePoseGuidance()
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
            waitedSteps += 1
        }

        if isCountdownInProgress, !isCountdownSpeechActive, requireAlignmentForActiveCountdown {
            // Reset grace baseline when starting countdown
        }
        lastAlignedAt = feedback.allChecksPassed ? Date() : lastAlignedAt
        if seconds > 0 {
            for tick in stride(from: seconds, through: 1, by: -1) {
                guard !Task.isCancelled, isCapturing, isCountdownInProgress, countdownToken == token else { return }
                if feedback.allChecksPassed {
                    lastAlignedAt = Date()
                } else if requireAlignmentForActiveCountdown,
                          (lastAlignedAt.map { Date().timeIntervalSince($0) >= alignmentLossGraceInterval } ?? true) {
                    cancelCountdownAndResumePoseGuidance()
                    return
                }

                countdownRemaining = tick
                isCountdownSpeechActive = true
                speak("\(tick)", forceSpeak: true)

                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        guard !Task.isCancelled, isCapturing, isCountdownInProgress, countdownToken == token else { return }
        capturePhotoNow(token: token)
    }

    private func capturePhotoNow(token: UUID) {
        guard isCapturing, countdownToken == token else { return }
        if requireAlignmentForActiveCountdown && !feedback.allChecksPassed,
           (lastAlignedAt.map { Date().timeIntervalSince($0) >= alignmentLossGraceInterval } ?? true) {
            cancelCountdownAndResumePoseGuidance()
            return
        }

        setCountdownInProgressState(false)
        isCountdownSpeechActive = false
        countdownRemaining = 0
        countdownToken = nil

        #if targetEnvironment(simulator)
        guard isDemoMode else {
            cameraErrorMessage = "Camera capture is unavailable in Simulator without Demo Mode."
            completePhotoCapture(with: nil)
            return
        }
        let angle = targetAngle
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, self.isCapturing else { return }
            let simulatedPhoto = DemoMediaGenerator.renderHeadshotImage(angle: angle.rawValue)
            self.completePhotoCapture(with: simulatedPhoto)
        }
        #else
        let angle = targetAngle
        let demoMode = isDemoMode
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard let photoOutput = self.sessionPhotoOutput else {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if demoMode {
                        let fallback = DemoMediaGenerator.renderHeadshotImage(angle: angle.rawValue)
                        self.completePhotoCapture(with: fallback)
                    } else {
                        self.cameraErrorMessage = "Camera is unavailable. Please check permissions or use Photo Import."
                        self.completePhotoCapture(with: nil)
                    }
                }
                return
            }

            let settings = AVCapturePhotoSettings()
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
        #endif
    }

    private func completePhotoCapture(with image: UIImage?) {
        setCapturingState(false)
        requireAlignmentForActiveCountdown = false
        countdownRemaining = 0
        countdownToken = nil
        countdownTask?.cancel()
        countdownTask = nil
        setCountdownInProgressState(false)
        isCountdownSpeechActive = false

        let completion = pendingPhotoCompletion
        pendingPhotoCompletion = nil
        completion?(image)
    }

    // MARK: - Camera Session Configuration (Device)

    /// Camera preview must not depend on microphone/speech authorization. A user
    /// can still take a headshot when hands-free commands are unavailable.
    private func prepareCameraSession() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraPermissionDenied = false
            setupCameraSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.cameraPermissionDenied = !granted
                    if granted {
                        self.cameraErrorMessage = nil
                        if self.isSessionRunning {
                            self.setupCameraSession()
                        }
                    } else {
                        self.cameraErrorMessage = "Camera access is denied. Enable camera access in Settings to capture headshots."
                    }
                }
            }
        case .denied, .restricted:
            cameraPermissionDenied = true
            cameraErrorMessage = "Camera access is denied. Enable camera access in Settings to capture headshots."
        @unknown default:
            cameraPermissionDenied = true
            cameraErrorMessage = "Camera access is unavailable."
        }
    }

    private func setupCameraSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            if let existing = self.sessionCaptureSession {
                if !existing.isRunning, self.stateBox.isSessionRunning {
                    existing.startRunning()
                }
                let position = self.stateBox.cameraPosition
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.captureSession !== existing {
                        self.captureSession = existing
                    }
                    self.isFrontCamera = (position == .front)
                    self.applyPreviewLayerConfiguration(for: position)
                }
                return
            }

            let session = AVCaptureSession()
            session.beginConfiguration()
            session.sessionPreset = .photo
            session.automaticallyConfiguresApplicationAudioSession = false

            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(for: .video) else {
                session.commitConfiguration()
                Task { @MainActor [weak self] in
                    self?.cameraErrorMessage = "No camera device available."
                }
                return
            }

            let initialPosition: AVCaptureDevice.Position = (camera.position == .back) ? .back : .front
            self.sessionVideoDevice = camera
            self.stateBox.cameraPosition = initialPosition
            self.stateBox.isFrontCamera = (initialPosition == .front)

            do {
                let input = try AVCaptureDeviceInput(device: camera)
                if session.canAddInput(input) {
                    session.addInput(input)
                }

                let photo = AVCapturePhotoOutput()
                if session.canAddOutput(photo) {
                    session.addOutput(photo)
                    self.sessionPhotoOutput = photo
                    self.configureVideoConnection(photo.connection(with: .video), position: initialPosition)
                }

                let videoOutput = AVCaptureVideoDataOutput()
                videoOutput.alwaysDiscardsLateVideoFrames = true
                videoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
                ]
                videoOutput.setSampleBufferDelegate(self, queue: self.visionQueue)
                if session.canAddOutput(videoOutput) {
                    session.addOutput(videoOutput)
                    self.sessionVideoDataOutput = videoOutput
                    self.configureVideoConnection(videoOutput.connection(with: .video), position: initialPosition)
                }

                session.commitConfiguration()
                self.configureCameraOptics(camera)
                self.sessionCaptureSession = session

                if self.stateBox.isSessionRunning {
                    session.startRunning()
                }

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.captureSession = session
                    self.isFrontCamera = (initialPosition == .front)
                    self.applyPreviewLayerConfiguration(for: initialPosition)
                }
            } catch {
                session.commitConfiguration()
                Task { @MainActor [weak self] in
                    self?.cameraErrorMessage = "Camera setup failed: \(error.localizedDescription)"
                }
            }
        }
    }

    nonisolated private func configureCameraOptics(_ device: AVCaptureDevice) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isSmoothAutoFocusSupported {
            device.isSmoothAutoFocusEnabled = true
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
        if !device.isSubjectAreaChangeMonitoringEnabled {
            device.isSubjectAreaChangeMonitoringEnabled = true
        }
        device.unlockForConfiguration()
    }

    nonisolated private func configureVideoConnection(_ connection: AVCaptureConnection?, position: AVCaptureDevice.Position) {
        guard let connection else { return }
        if connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = (position == .front)
        }
    }

    // MARK: - Permission-Gated Voice Trigger Setup (SFSpeechRecognizer)

    private var isVoiceAuthorizedInSystem: Bool {
        AVAudioApplication.shared.recordPermission == .granted &&
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    private static func makeSpeechRecognizer() -> SFSpeechRecognizer? {
        let preferred = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        if preferred.lowercased().hasPrefix("en"),
           let current = SFSpeechRecognizer(locale: Locale(identifier: preferred)),
           current.isAvailable {
            return current
        }
        return SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
            ?? SFSpeechRecognizer(locale: Locale.current)
    }

    /// Explicit opt-in entry point when the user chooses to enable voice commands.
    func enableVoiceTriggers() {
        voiceStatus = .starting
        VoiceAuthorizationService.shared.requestAccess { [weak self] authorized in
            guard let self else { return }
            guard authorized else {
                self.isVoiceListening = false
                self.voiceStatus = .failed
                self.surfaceShutterStatus("Allow Microphone & Speech access in Settings for voice commands")
                return
            }
            guard self.isSessionRunning else {
                self.voiceStatus = .idle
                return
            }
            self.voiceAudioSessionQueue.async { [weak self] in
                let ok = VoiceAudioSessionCoordinator.shared.activate()
                Task { @MainActor [weak self] in
                    guard let self, self.isSessionRunning else { return }
                    guard ok else { self.voiceStatus = .failed; return }
                    self.startVoiceListening(audioAlreadyActivated: true)
                }
            }
        }
    }

    func disableVoiceTriggers() {
        stopVoiceTrigger()
    }

    private func configureGuidanceAudioSession() -> Bool {
        VoiceAudioSessionCoordinator.shared.activate()
    }

    private func setupVoiceTriggerIfAuthorized() {
        guard isVoiceAuthorizedInSystem else { return }
        enableVoiceTriggers()
    }

    private func startVoiceListening(audioAlreadyActivated: Bool = false) {
        guard isSessionRunning, isVoiceAuthorizedInSystem else { voiceStatus = .failed; return }
        if isVoiceListening, recognitionTask != nil { return }
        if isVoiceListening && recognitionTask == nil {
            stopVoiceTrigger()
        }
        speechRecognizer = Self.makeSpeechRecognizer()
        speechRecognizer?.delegate = self
        guard let speechRecognizer, speechRecognizer.isAvailable else { voiceStatus = .unavailable; return }

        if !audioAlreadyActivated {
            guard configureGuidanceAudioSession() else { voiceStatus = .failed; return }
        }
        let installed = installAudioTapAndStartEngine()
        guard installed else {
            voiceStatus = .failed
            return
        }

        if let existing = engineConfigurationObserver {
            NotificationCenter.default.removeObserver(existing)
        }
        engineConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isSessionRunning, self.isVoiceListening else { return }
            self.stateBox.isAudioTapInstalled = false
            if self.installAudioTapAndStartEngine() {
                self.restartRecognitionTaskSeamlessly()
            }
        }

        guard isSessionRunning else { return }
        voiceCommandController.resetTranscriptCursor()
        startRecognitionTask()
    }

    private func installAudioTapAndStartEngine() -> Bool {
        let inputNode = audioEngine.inputNode
        let outputFormat = inputNode.outputFormat(forBus: 0)
        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard let tapFormat = [outputFormat, inputFormat].first(where: { $0.sampleRate > 0 && $0.channelCount > 0 }) else {
            return false
        }

        inputNode.removeTap(onBus: 0)
        let box = stateBox
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { readOnlyBuffer, _ in
            box.recognitionRequest?.append(readOnlyBuffer)
        }
        stateBox.isAudioTapInstalled = true

        audioEngine.prepare()
        if !audioEngine.isRunning {
            do {
                try audioEngine.start()
            } catch {
                inputNode.removeTap(onBus: 0)
                stateBox.isAudioTapInstalled = false
                return false
            }
        }
        return true
    }

    private func startRecognitionTask() {
        guard isSessionRunning else { return }
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            isVoiceListening = false
            voiceStatus = .unavailable
            return
        }

        taskRestartTimer?.invalidate()
        taskRestartTimer = nil

        stateBox.activeRecognitionTaskID = nil
        stateBox.recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = false
        request.contextualStrings = [
            "Now", "Action", "Capture", "Shoot", "Snap", "Click", "Photo", "How do I look", "Check framing"
        ]
        request.requiresOnDeviceRecognition = false
        stateBox.recognitionRequest = request
        let taskID = UUID()
        stateBox.activeRecognitionTaskID = taskID

        self.recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            let resultTranscript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let hasError = (error != nil)

            Task { @MainActor [weak self] in
                guard let self,
                      self.isSessionRunning,
                      self.stateBox.activeRecognitionTaskID == taskID else { return }

                if let transcript = resultTranscript {
                    self.handleRecognizedTranscript(transcript, isFinal: isFinal)
                    if isFinal {
                        self.restartRecognitionTaskSeamlessly()
                    }
                }
                if hasError {
                    self.restartRecognitionTaskSeamlessly()
                }
            }
        }

        isVoiceListening = true
        voiceStatus = .listening

        taskRestartTimer = Timer.scheduledTimer(withTimeInterval: 50.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isSessionRunning else { return }
                self.restartRecognitionTaskSeamlessly()
            }
        }
    }

    private func restartRecognitionTaskSeamlessly() {
        guard isSessionRunning, !stateBox.isRestartingRecognition else { return }
        stateBox.isRestartingRecognition = true

        taskRestartTimer?.invalidate()
        taskRestartTimer = nil
        recognitionRestartWorkItem?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stateBox.isRestartingRecognition = false
            guard self.isSessionRunning else { return }
            guard self.configureGuidanceAudioSession() else { self.voiceStatus = .failed; return }
            if !self.audioEngine.isRunning {
                do { try self.audioEngine.start() }
                catch { self.voiceStatus = .failed; return }
            }
            self.startRecognitionTask()
        }
        recognitionRestartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: - Single Transcript Entry Point

    /// Device recognizer results and injectable Simulator/XCTest transcripts use
    /// the same command parser. Headshots intentionally has no Cut behavior.
    /// When synthesized guidance or countdown speech is actively playing (or just
    /// finished within the echo window), transcripts are ignored to prevent speaker
    /// bleed from triggering the shutter.
    @MainActor
    func handleRecognizedTranscript(_ transcript: String, isFinal: Bool) {
        // Avoid dropping real voice commands while guidance TTS is speaking;
        // TTS strings omit trigger words ("shoot", "capture", "retake", "next", "cancel")
        // and countdown digits only trigger nothing on VoiceCommandController.
        voiceCommandController.handleRecognizedTranscript(transcript, isFinal: isFinal)
    }

    // MARK: - AVSpeechSynthesizerDelegate (Speaker-Bleed Guard)

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.isTTSSpeaking = true
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.isTTSSpeaking = false
            self?.lastTTSEndedAt = Date()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.isTTSSpeaking = false
            self?.lastTTSEndedAt = Date()
        }
    }

    @MainActor
    private func triggerShutterCapture() {
        guard !isCapturing else { return }
        if let onShutterTriggered = onShutterTriggered {
            onShutterTriggered()
        } else if let completion = pendingPhotoCompletion {
            startCountdown(seconds: 3, completion: completion)
        }
    }

    func triggerFramingFeedbackVoice() {
        guard !isCapturing else { return }
        let advice = feedback.spokenAdvice ?? (feedback.allChecksPassed ? "Framing and lighting look great." : currentBlockingReason())
        lastSpokenTime = Date()
        lastSpokenMessage = advice
        speak(advice, forceSpeak: true)
    }

    /// Resets completed capture state, then announces the next pose without
    /// interrupting the last countdown utterance.
    func transitionToNextPose(_ angle: HeadshotAngle, isDemoMode: Bool? = nil) {
        voiceCommandController.resetTranscriptCursor()
        startSession(for: angle, isDemoMode: isDemoMode ?? self.isDemoMode)
        announceAngle(angle, notBefore: Date().addingTimeInterval(0.4))
    }

    func announceAngle(_ angle: HeadshotAngle) {
        announceAngle(angle, notBefore: .distantPast)
    }

    private func announceAngle(_ angle: HeadshotAngle, notBefore: Date) {
        guard !isCapturing else { return }
        let prompt: String
        switch angle {
        case .front: prompt = "Front headshot. Look straight at the camera."
        case .left: prompt = "Left profile. Turn your head slightly to your left."
        case .right: prompt = "Right profile. Turn your head slightly to your right."
        }

        let token = UUID()
        poseAnnouncementToken = token
        speakPoseAnnouncementWhenReady(prompt, token: token, notBefore: notBefore)
    }

    private func speakPoseAnnouncementWhenReady(_ prompt: String, token: UUID, notBefore: Date) {
        guard poseAnnouncementToken == token, !isCapturing else { return }
        guard Date() >= notBefore, !speechSynthesizer.isSpeaking else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.speakPoseAnnouncementWhenReady(prompt, token: token, notBefore: notBefore)
            }
            return
        }

        poseAnnouncementToken = nil
        speak(prompt, forceSpeak: false)
    }

    private func stopVoiceTrigger() {
        isVoiceListening = false
        voiceStatus = .idle
        taskRestartTimer?.invalidate()
        taskRestartTimer = nil
        recognitionRestartWorkItem?.cancel()
        recognitionRestartWorkItem = nil
        stateBox.isRestartingRecognition = false

        if let existing = engineConfigurationObserver {
            NotificationCenter.default.removeObserver(existing)
            engineConfigurationObserver = nil
        }

        stateBox.recognitionRequest?.endAudio()
        stateBox.activeRecognitionTaskID = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        stateBox.recognitionRequest = nil

        if stateBox.isAudioTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            stateBox.isAudioTapInstalled = false
        }
        if audioEngine.isRunning {
            audioEngine.stop()
        }
    }

    private func observeAudioSessionChanges() {
        let center = NotificationCenter.default
        audioSessionObservers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor [weak self] in
                guard let self, self.isSessionRunning else { return }
                let type = typeRaw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
                if type == .began {
                    self.isVoiceListening = false
                    self.voiceStatus = .interrupted
                } else if self.isVoiceAuthorizedInSystem {
                    self.restartRecognitionTaskSeamlessly()
                }
            }
        })
        audioSessionObservers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isSessionRunning, self.isVoiceAuthorizedInSystem else { return }
                self.restartRecognitionTaskSeamlessly()
            }
        })
        audioSessionObservers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.stateBox.isAudioTapInstalled = false
                self.audioEngine.reset()
                self.isVoiceListening = false
                self.restartVoicePipeline()
            }
        })
    }

    private func restartVoicePipeline() {
        guard isSessionRunning else { return }
        stateBox.isRestartingRecognition = false
        stopVoiceTrigger()
        if isSessionRunning, isVoiceAuthorizedInSystem {
            voiceStatus = .starting
            startVoiceListening()
        }
    }

    nonisolated func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.isSessionRunning else { return }
            if available {
                if !self.isVoiceListening, self.isVoiceAuthorizedInSystem {
                    self.restartRecognitionTaskSeamlessly()
                }
            } else {
                self.isVoiceListening = false
                self.voiceStatus = .unavailable
            }
        }
    }

    // MARK: - Real-Time Guidance & Spoken Warnings

    func speakDebouncedWarning(_ message: String) {
        guard voiceGuidanceEnabled, !message.isEmpty, !isCapturing else { return }
        guard !speechSynthesizer.isSpeaking else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(lastSpokenTime)
        if message == lastSpokenMessage {
            guard elapsed >= speechRepeatInterval else { return }
        } else {
            guard elapsed >= speechMinInterval else { return }
        }
        lastSpokenMessage = message
        lastSpokenTime = now
        speak(message, forceSpeak: false)
    }

    private func speak(_ text: String, forceSpeak: Bool) {
        guard forceSpeak || voiceGuidanceEnabled else { return }
        if forceSpeak && speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        } else if !forceSpeak && speechSynthesizer.isSpeaking {
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.volume = forceSpeak ? 0.6 : 0.4
        speechSynthesizer.speak(utterance)
    }

    /// Called from live analysis and the view so alignment-gated countdowns (like Auto-Capture)
    /// cannot produce a photo after the subject has moved out of framing, while tolerating single-frame jitter.
    func cancelCountdownIfAlignmentLost() {
        guard requireAlignmentForActiveCountdown, isCountdownInProgress else { return }
        if feedback.allChecksPassed {
            lastAlignedAt = Date()
            return
        }
        if let lastAligned = lastAlignedAt,
           Date().timeIntervalSince(lastAligned) < alignmentLossGraceInterval {
            return
        }
        cancelCountdownAndResumePoseGuidance()
    }

    private func cancelCountdownAndResumePoseGuidance() {
        guard isCountdownInProgress else { return }

        let wasSpeakingCountdown = isCountdownSpeechActive
        countdownTask?.cancel()
        countdownTask = nil
        countdownToken = nil
        requireAlignmentForActiveCountdown = false
        setCountdownInProgressState(false)
        isCountdownSpeechActive = false
        setCapturingState(false)
        countdownRemaining = 0
        pendingPhotoCompletion = nil
        lastSpokenTime = .distantPast
        lastSpokenMessage = ""

        if wasSpeakingCountdown {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        speakCurrentPoseGuidanceIfNeeded()
    }

    private func speakCurrentPoseGuidanceIfNeeded() {
        guard voiceGuidanceEnabled, !isCapturing, !isCountdownInProgress else { return }
        guard !speechSynthesizer.isSpeaking else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.speakCurrentPoseGuidanceIfNeeded()
            }
            return
        }

        if let spoken = feedback.spokenAdvice, !spoken.isEmpty {
            speakDebouncedWarning(spoken)
        }
    }

    // MARK: - Single Image Evaluation (Off Main Thread)

    func evaluateImage(_ image: UIImage, for angle: HeadshotAngle) async -> GuidanceFeedback {
        guard let cgImage = image.cgImage else { return GuidanceFeedback() }
        let orientation = cgImagePropertyOrientation(for: image.imageOrientation)

        return await Task.detached(priority: .userInitiated) {
            let faceRequest = VNDetectFaceRectanglesRequest()
            let segRequest = VNGeneratePersonSegmentationRequest()
            segRequest.qualityLevel = .fast

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
            try? handler.perform([faceRequest, segRequest])

            let face = (faceRequest.results ?? []).max(by: {
                ($0.boundingBox.width * $0.boundingBox.height) < ($1.boundingBox.width * $1.boundingBox.height)
            })
            let posePrediction = HeadshotPosePredictor.shared.predict(cgImage: cgImage, orientation: orientation)

            var fb = GuidanceFeedback()

            if let face {
                let box = face.boundingBox
                fb.isFaceCentered = (box.midX >= 0.35 && box.midX <= 0.65) && (box.midY >= 0.30 && box.midY <= 0.70)
            } else {
                fb.isFaceCentered = false
            }

            let visionYawDeg = face?.yaw.map { $0.doubleValue * 180.0 / .pi }
            let angleEval = Self.evaluateYawAngle(
                targetAngle: angle,
                visionYawDegrees: visionYawDeg,
                posePrediction: posePrediction
            )
            fb.isAngleCorrect = angleEval.isCorrect
            fb.currentYawDegrees = angleEval.resolvedYawDegrees

            fb.lighting = Self.evaluateCGImageLuminance(
                cgImage,
                orientation: orientation,
                faceBoundingBox: face?.boundingBox
            )

            if let segObs = segRequest.results?.first as? VNPixelBufferObservation {
                fb.background = Self.evaluateBackgroundClutter(
                    maskBuffer: segObs.pixelBuffer,
                    cgImage: cgImage,
                    orientation: orientation
                ) ? .clean : .cluttered
            } else {
                fb.background = .clean
            }

            if !fb.isFaceCentered {
                fb.spokenAdvice = "Face not detected or off-center. Center yourself in the frame."
            } else if !fb.isAngleCorrect {
                switch angle {
                case .front: fb.spokenAdvice = "Look directly at the camera."
                case .left: fb.spokenAdvice = "Turn your face to the left."
                case .right: fb.spokenAdvice = "Turn your face to the right."
                }
            } else if fb.lighting == .tooDark {
                fb.spokenAdvice = "Face is too dark. Add key light in front of you."
            } else if fb.lighting == .uneven {
                fb.spokenAdvice = "Lighting is uneven. Balance the light across your face."
            } else if fb.lighting == .tooBright {
                fb.spokenAdvice = "Lighting is too bright. Reduce glare."
            } else if fb.background == .cluttered {
                fb.spokenAdvice = "Background looks busy. Try a plain wall behind you."
            }

            return fb
        }.value
    }

    // MARK: - Safe Luminance & Background Evaluators

    nonisolated static func evaluateCGImageLuminance(
        _ cgImage: CGImage,
        orientation: CGImagePropertyOrientation = .up,
        faceBoundingBox: CGRect? = nil
    ) -> LightingStatus {
        let sampleSize = 120
        let ciImage = CIImage(cgImage: cgImage).oriented(orientation)
        let extent = ciImage.extent
        guard extent.width > 0, extent.height > 0 else { return .good }

        let bytesPerRow = sampleSize * 4
        var rgba = [UInt8](repeating: 0, count: sampleSize * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let ctx = CGContext(
            data: &rgba,
            width: sampleSize,
            height: sampleSize,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            return .good
        }

        let ciContext = CIContext(options: [.useSoftwareRenderer: true])
        guard let rendered = ciContext.createCGImage(ciImage, from: extent) else { return .good }
        ctx.draw(rendered, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))

        let region = clampedPixelRegion(for: faceBoundingBox, width: sampleSize, height: sampleSize)
        return computeLightingStatus(
            width: sampleSize,
            height: sampleSize,
            region: region
        ) { x, y in
            let offset = y * bytesPerRow + x * 4
            let r = Double(rgba[offset]) / 255.0
            let g = Double(rgba[offset + 1]) / 255.0
            let b = Double(rgba[offset + 2]) / 255.0
            return 0.299 * r + 0.587 * g + 0.114 * b
        }
    }

    nonisolated static func evaluatePixelBufferLuminance(
        _ pixelBuffer: CVPixelBuffer,
        faceBoundingBox: CGRect? = nil,
        allowUnevenShadow: Bool = false
    ) -> LightingStatus {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        if planeCount > 0 {
            guard pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                  pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
                  pixelFormat == kCVPixelFormatType_420YpCbCr8Planar,
                  let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
                return .good
            }
            let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            guard width > 0, height > 0, bytesPerRow >= width else { return .good }

            let ptr = yBase.assumingMemoryBound(to: UInt8.self)
            let region = clampedPixelRegion(for: faceBoundingBox, width: width, height: height)
            return computeLightingStatus(width: width, height: height, region: region, allowUnevenShadow: allowUnevenShadow) { x, y in
                Double(ptr[y * bytesPerRow + x]) / 255.0
            }
        } else {
            guard pixelFormat == kCVPixelFormatType_32BGRA,
                  let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
                return .good
            }
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            guard width > 0, height > 0, bytesPerRow >= width * 4 else { return .good }

            let ptr = base.assumingMemoryBound(to: UInt8.self)
            let region = clampedPixelRegion(for: faceBoundingBox, width: width, height: height)
            return computeLightingStatus(width: width, height: height, region: region, allowUnevenShadow: allowUnevenShadow) { x, y in
                let offset = y * bytesPerRow + x * 4
                let b = Double(ptr[offset]) / 255.0
                let g = Double(ptr[offset + 1]) / 255.0
                let r = Double(ptr[offset + 2]) / 255.0
                return 0.299 * r + 0.587 * g + 0.114 * b
            }
        }
    }

    nonisolated private static func clampedPixelRegion(
        for faceBoundingBox: CGRect?,
        width: Int,
        height: Int
    ) -> (minX: Int, maxX: Int, minY: Int, maxY: Int) {
        guard let box = faceBoundingBox, box.width > 0.05, box.height > 0.05 else {
            return (0, width, 0, height)
        }
        // Vision boundingBox uses normalized bottom-left origin; pixel buffers use top-left origin.
        let rawMinX = Int(floor(box.minX * CGFloat(width)))
        let rawMaxX = Int(ceil(box.maxX * CGFloat(width)))
        let rawMinY = Int(floor((1.0 - box.maxY) * CGFloat(height)))
        let rawMaxY = Int(ceil((1.0 - box.minY) * CGFloat(height)))

        let minX = max(0, min(width - 1, rawMinX))
        let maxX = max(minX + 1, min(width, rawMaxX))
        let minY = max(0, min(height - 1, rawMinY))
        let maxY = max(minY + 1, min(height, rawMaxY))

        if (maxX - minX) < 12 || (maxY - minY) < 12 {
            return (0, width, 0, height)
        }
        return (minX, maxX, minY, maxY)
    }

    nonisolated private static func computeLightingStatus(
        width: Int,
        height: Int,
        region: (minX: Int, maxX: Int, minY: Int, maxY: Int),
        allowUnevenShadow: Bool = false,
        luminanceAt: (_ x: Int, _ y: Int) -> Double
    ) -> LightingStatus {
        let regionWidth = region.maxX - region.minX
        let step = max(1, regionWidth / 24)
        let midX = (region.minX + region.maxX) / 2

        var totalLum: Double = 0
        var leftLum: Double = 0
        var rightLum: Double = 0
        var sampled = 0
        var leftSampled = 0
        var rightSampled = 0

        for y in stride(from: region.minY, to: region.maxY, by: step) {
            for x in stride(from: region.minX, to: region.maxX, by: step) {
                let lum = luminanceAt(x, y)
                totalLum += lum
                sampled += 1
                if x < midX {
                    leftLum += lum
                    leftSampled += 1
                } else {
                    rightLum += lum
                    rightSampled += 1
                }
            }
        }

        guard sampled > 0 else { return .good }
        let avg = totalLum / Double(sampled)
        let avgLeft = leftSampled > 0 ? leftLum / Double(leftSampled) : avg
        let avgRight = rightSampled > 0 ? rightLum / Double(rightSampled) : avg

        if avg < 0.18 { return .tooDark }
        if avg > 0.88 { return .tooBright }
        let unevenLimit = allowUnevenShadow ? 0.48 : unevenLightingThreshold
        if abs(avgLeft - avgRight) > unevenLimit { return .uneven }
        return .good
    }

    nonisolated static func evaluateBackgroundClutter(
        maskBuffer: CVPixelBuffer,
        frameBuffer: CVPixelBuffer
    ) -> Bool {
        CVPixelBufferLockBaseAddress(maskBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(frameBuffer, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(maskBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(frameBuffer, .readOnly)
        }

        guard let maskBase = CVPixelBufferGetBaseAddress(maskBuffer) else { return true }
        let maskWidth = CVPixelBufferGetWidth(maskBuffer)
        let maskHeight = CVPixelBufferGetHeight(maskBuffer)
        let maskBytesPerRow = CVPixelBufferGetBytesPerRow(maskBuffer)
        guard maskWidth > 0, maskHeight > 0, maskBytesPerRow >= maskWidth else { return true }
        let maskPtr = maskBase.assumingMemoryBound(to: UInt8.self)

        let planeCount = CVPixelBufferGetPlaneCount(frameBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(frameBuffer)
        let isPlanar = planeCount > 0

        let frameWidth: Int
        let frameHeight: Int
        let frameBytesPerRow: Int
        let framePtr: UnsafePointer<UInt8>

        if isPlanar {
            guard pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                  pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
                  pixelFormat == kCVPixelFormatType_420YpCbCr8Planar,
                  let base = CVPixelBufferGetBaseAddressOfPlane(frameBuffer, 0) else {
                return true
            }
            frameWidth = CVPixelBufferGetWidthOfPlane(frameBuffer, 0)
            frameHeight = CVPixelBufferGetHeightOfPlane(frameBuffer, 0)
            frameBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(frameBuffer, 0)
            guard frameWidth > 0, frameHeight > 0, frameBytesPerRow >= frameWidth else { return true }
            framePtr = UnsafePointer(base.assumingMemoryBound(to: UInt8.self))
        } else {
            guard pixelFormat == kCVPixelFormatType_32BGRA,
                  let base = CVPixelBufferGetBaseAddress(frameBuffer) else {
                return true
            }
            frameWidth = CVPixelBufferGetWidth(frameBuffer)
            frameHeight = CVPixelBufferGetHeight(frameBuffer)
            frameBytesPerRow = CVPixelBufferGetBytesPerRow(frameBuffer)
            guard frameWidth > 0, frameHeight > 0, frameBytesPerRow >= frameWidth * 4 else { return true }
            framePtr = UnsafePointer(base.assumingMemoryBound(to: UInt8.self))
        }

        var backgroundLums: [Double] = []
        let step = max(1, maskWidth / 25)

        for y in stride(from: 0, to: maskHeight, by: step) {
            for x in stride(from: 0, to: maskWidth, by: step) {
                let maskVal = maskPtr[y * maskBytesPerRow + x]
                if maskVal < 60 {
                    let fx = min(frameWidth - 1, x * frameWidth / maskWidth)
                    let fy = min(frameHeight - 1, y * frameHeight / maskHeight)
                    let lum: Double
                    if isPlanar {
                        lum = Double(framePtr[fy * frameBytesPerRow + fx]) / 255.0
                    } else {
                        let offset = fy * frameBytesPerRow + fx * 4
                        let b = Double(framePtr[offset]) / 255.0
                        let g = Double(framePtr[offset + 1]) / 255.0
                        let r = Double(framePtr[offset + 2]) / 255.0
                        lum = 0.299 * r + 0.587 * g + 0.114 * b
                    }
                    backgroundLums.append(lum)
                }
            }
        }

        guard backgroundLums.count > 15 else { return true }
        let mean = backgroundLums.reduce(0, +) / Double(backgroundLums.count)
        let variance = backgroundLums.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(backgroundLums.count)
        return sqrt(variance) < 0.36
    }

    nonisolated private static func evaluateBackgroundClutter(
        maskBuffer: CVPixelBuffer,
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation
    ) -> Bool {
        CVPixelBufferLockBaseAddress(maskBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(maskBuffer, .readOnly) }

        guard let maskBase = CVPixelBufferGetBaseAddress(maskBuffer) else { return true }
        let maskWidth = CVPixelBufferGetWidth(maskBuffer)
        let maskHeight = CVPixelBufferGetHeight(maskBuffer)
        let maskBytesPerRow = CVPixelBufferGetBytesPerRow(maskBuffer)
        guard maskWidth > 0, maskHeight > 0, maskBytesPerRow >= maskWidth else { return true }
        let maskPtr = maskBase.assumingMemoryBound(to: UInt8.self)

        let sampleSize = 120
        let ciImage = CIImage(cgImage: cgImage).oriented(orientation)
        let extent = ciImage.extent
        guard extent.width > 0, extent.height > 0 else { return true }

        let bytesPerRow = sampleSize * 4
        var rgba = [UInt8](repeating: 0, count: sampleSize * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &rgba,
            width: sampleSize,
            height: sampleSize,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            return true
        }
        let ciContext = CIContext(options: [.useSoftwareRenderer: true])
        guard let rendered = ciContext.createCGImage(ciImage, from: extent) else { return true }
        ctx.draw(rendered, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))

        var backgroundLums: [Double] = []
        let step = max(1, maskWidth / 25)
        for y in stride(from: 0, to: maskHeight, by: step) {
            for x in stride(from: 0, to: maskWidth, by: step) {
                let maskVal = maskPtr[y * maskBytesPerRow + x]
                if maskVal < 60 {
                    let fx = min(sampleSize - 1, x * sampleSize / maskWidth)
                    let fy = min(sampleSize - 1, y * sampleSize / maskHeight)
                    let offset = fy * bytesPerRow + fx * 4
                    let r = Double(rgba[offset]) / 255.0
                    let g = Double(rgba[offset + 1]) / 255.0
                    let b = Double(rgba[offset + 2]) / 255.0
                    backgroundLums.append(0.299 * r + 0.587 * g + 0.114 * b)
                }
            }
        }

        guard backgroundLums.count > 15 else { return true }
        let mean = backgroundLums.reduce(0, +) / Double(backgroundLums.count)
        let variance = backgroundLums.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(backgroundLums.count)
        return sqrt(variance) < 0.36
    }

    // MARK: - Simulator Headshot Generator

    func generateSimulatedHeadshot(angle: HeadshotAngle) -> UIImage {
        let size = CGSize(width: 1200, height: 1500)
        let renderer = UIGraphicsImageRenderer(size: size)

        return renderer.image { ctx in
            let colors = [
                UIColor(red: 0.94, green: 0.94, blue: 0.96, alpha: 1.0).cgColor,
                UIColor(red: 0.88, green: 0.88, blue: 0.92, alpha: 1.0).cgColor
            ] as CFArray
            if let bgGradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: [0.0, 1.0]
            ) {
                ctx.cgContext.drawLinearGradient(bgGradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            } else {
                UIColor(red: 0.91, green: 0.91, blue: 0.94, alpha: 1.0).setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
            }

            let figureColor = UIColor(red: 0.31, green: 0.20, blue: 0.42, alpha: 0.85)
            figureColor.setFill()

            let headCenterX: CGFloat
            switch angle {
            case .front: headCenterX = size.width / 2.0
            case .left: headCenterX = size.width * 0.46
            case .right: headCenterX = size.width * 0.54
            }

            let headRect = CGRect(x: headCenterX - 180, y: size.height * 0.25, width: 360, height: 460)
            ctx.cgContext.fillEllipse(in: headRect)

            let bodyPath = UIBezierPath()
            bodyPath.move(to: CGPoint(x: headCenterX - 450, y: size.height))
            bodyPath.addCurve(
                to: CGPoint(x: headCenterX - 140, y: size.height * 0.58),
                controlPoint1: CGPoint(x: headCenterX - 380, y: size.height * 0.75),
                controlPoint2: CGPoint(x: headCenterX - 220, y: size.height * 0.62)
            )
            bodyPath.addLine(to: CGPoint(x: headCenterX + 140, y: size.height * 0.58))
            bodyPath.addCurve(
                to: CGPoint(x: headCenterX + 450, y: size.height),
                controlPoint1: CGPoint(x: headCenterX + 220, y: size.height * 0.62),
                controlPoint2: CGPoint(x: headCenterX + 380, y: size.height * 0.75)
            )
            bodyPath.close()
            bodyPath.fill()

            let text = "\(angle.rawValue.uppercased()) HEADSHOT TAKE"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 28, weight: .bold),
                .foregroundColor: UIColor.black.withAlphaComponent(0.2)
            ]
            let textSize = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: (size.width - textSize.width) / 2.0, y: size.height - 80), withAttributes: attrs)
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension HeadshotGuidanceService: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard stateBox.tryBeginFrameAnalysis(minInterval: Self.frameAnalysisInterval) else { return }
        defer { stateBox.endFrameAnalysis() }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let isFront = stateBox.isFrontCamera
        let orientation: CGImagePropertyOrientation
        if connection.isVideoRotationAngleSupported(90) && connection.videoRotationAngle == 90 {
            orientation = isFront ? (connection.isVideoMirrored ? .up : .upMirrored) : .up
        } else {
            orientation = isFront ? .leftMirrored : .right
        }

        let faceRequest = VNDetectFaceRectanglesRequest()
        faceRequest.revision = VNDetectFaceRectanglesRequestRevision3
        let wantsHandGesture = stateBox.wantsHandGesture
        let handRequest: VNDetectHumanHandPoseRequest? = wantsHandGesture ? {
            let req = VNDetectHumanHandPoseRequest()
            req.maximumHandCount = 1
            return req
        }() : nil

        var requests: [VNRequest] = [faceRequest]
        if let handRequest {
            requests.append(handRequest)
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        try? handler.perform(requests)

        let face = (faceRequest.results ?? []).max(by: {
            ($0.boundingBox.width * $0.boundingBox.height) < ($1.boundingBox.width * $1.boundingBox.height)
        })
        let rawPosePrediction = HeadshotPosePredictor.shared.predict(pixelBuffer: pixelBuffer, orientation: orientation)

        // CoreML can recognize full 90° profiles when Vision's face box drops out (ported from OneTake-iOS-main).
        let hasFace: Bool
        let rawCenterX: CGFloat
        let rawCenterYTopDown: CGFloat
        let rawFaceHeight: CGFloat
        if let face {
            hasFace = true
            rawCenterX = face.boundingBox.midX
            rawCenterYTopDown = 1.0 - face.boundingBox.midY
            rawFaceHeight = face.boundingBox.height
        } else if let rawPosePrediction, rawPosePrediction.confidence >= 0.65 {
            hasFace = true
            rawCenterX = 0.5
            rawCenterYTopDown = 0.42
            rawFaceHeight = 0.34
        } else {
            hasFace = false
            rawCenterX = 0.5
            rawCenterYTopDown = 0.5
            rawFaceHeight = 0.0
        }

        let targetAngle = stateBox.targetAngle
        let rawVisionYawDeg = face?.yaw.map { $0.doubleValue * 180.0 / .pi }
        let smoothed = stateBox.smoothVisionSignals(
            hasFace: hasFace,
            centerX: rawCenterX,
            centerYTopDown: rawCenterYTopDown,
            faceHeight: rawFaceHeight,
            rawYaw: rawVisionYawDeg,
            posePrediction: rawPosePrediction
        )

        let currentLighting = Self.evaluatePixelBufferLuminance(
            pixelBuffer,
            faceBoundingBox: face?.boundingBox,
            allowUnevenShadow: targetAngle != .front
        )
        let openPalm = handRequest?.results?.contains(where: Self.isOpenPalm) ?? false

        Task { @MainActor [weak self] in
            guard let self, self.isSessionRunning else { return }
            let evaluation = Self.evaluatePoseGuide(
                hasFace: hasFace,
                centerX: smoothed.centerX,
                centerYTopDown: smoothed.centerYTopDown,
                faceHeight: smoothed.faceHeight,
                visionYawDegrees: smoothed.yaw,
                posePrediction: smoothed.pose,
                lighting: currentLighting,
                isEyeLevel: self.feedback.isEyeLevel,
                background: .clean,
                targetAngle: targetAngle,
                autoCaptureEnabled: self.autoCaptureEnabled
            )

            self.feedback.hasFace = hasFace
            self.feedback.isFaceCentered = evaluation.isFaceCentered
            self.feedback.isAngleCorrect = evaluation.isAngleCorrect
            self.feedback.currentYawDegrees = evaluation.resolvedYawDegrees
            self.feedback.lighting = currentLighting
            self.feedback.background = .clean
            self.feedback.posePrediction = smoothed.pose
            self.feedback.guidanceHeadline = evaluation.headline
            self.feedback.spokenAdvice = evaluation.spoken
            self.openPalmDetected = self.gesturesEnabled && openPalm

            if self.feedback.allChecksPassed {
                self.lastAlignedAt = Date()
            }
            self.cancelCountdownIfAlignmentLost()
            guard !self.isCountdownInProgress else { return }

            if evaluation.isAligned {
                self.shutterStatusMessage = nil
            }
            self.speakDebouncedWarning(evaluation.spoken)
        }
    }

    /// Open-palm hand gesture detector ported from `OneTake-iOS-main`'s `CameraController+FaceDetection.swift`.
    nonisolated private static func isOpenPalm(_ hand: VNHumanHandPoseObservation) -> Bool {
        guard let wrist = try? hand.recognizedPoint(.wrist), wrist.confidence >= 0.3 else { return false }
        let fingers: [(VNHumanHandPoseObservation.JointName, VNHumanHandPoseObservation.JointName)] = [
            (.indexTip, .indexPIP),
            (.middleTip, .middlePIP),
            (.ringTip, .ringPIP),
            (.littleTip, .littlePIP)
        ]
        return fingers.allSatisfy { tipName, pipName in
            guard let tip = try? hand.recognizedPoint(tipName),
                  let pip = try? hand.recognizedPoint(pipName),
                  tip.confidence >= 0.25, pip.confidence >= 0.25 else { return false }
            let tipDistance = hypot(tip.location.x - wrist.location.x, tip.location.y - wrist.location.y)
            let pipDistance = hypot(pip.location.x - wrist.location.x, pip.location.y - wrist.location.y)
            return tipDistance > pipDistance * 1.18
        }
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension HeadshotGuidanceService: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let photoData = (error == nil) ? photo.fileDataRepresentation() : nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            let image = photoData.flatMap { UIImage(data: $0) }
            self.completePhotoCapture(with: image)
        }
    }
}

// MARK: - Face-Aware Auto Cropper (ImageFramer)

nonisolated enum ImageFramer {
    static func autoCrop(
        image: UIImage,
        aspectRatio: HeadshotAspectRatio,
        preset: HeadshotCropPreset = .theatrical
    ) async -> UIImage {
        await Task.detached(priority: .userInitiated) {
            let upright = HeadshotCropMath.normalizedImage(image)
            guard let cgImage = upright.cgImage else { return upright }

            let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
            let targetRatio = HeadshotCropMath.targetAspect(
                for: aspectRatio,
                preset: preset,
                imageSize: imageSize
            )

            let faceRect = detectFaceBoundingBox(in: cgImage)
            let cropped = crop(
                cgImage: cgImage,
                targetRatio: targetRatio,
                faceNormalizedRect: faceRect,
                preset: preset
            )
            return UIImage(cgImage: cropped, scale: 1, orientation: .up)
        }.value
    }

    private static func detectFaceBoundingBox(in cgImage: CGImage) -> CGRect? {
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        let request = VNDetectFaceRectanglesRequest()
        if (try? handler.perform([request])) != nil,
           let face = request.results?.max(by: {
               ($0.boundingBox.width * $0.boundingBox.height) < ($1.boundingBox.width * $1.boundingBox.height)
           }),
           face.confidence > 0.3 {
            return face.boundingBox
        }

        // CoreImage fallback (useful when ANE is unavailable in Simulator).
        let ciImage = CIImage(cgImage: cgImage)
        if let detector = CIDetector(ofType: CIDetectorTypeFace, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) {
            let features = detector.features(in: ciImage).compactMap { $0 as? CIFaceFeature }
            if let best = features.max(by: { ($0.bounds.width * $0.bounds.height) < ($1.bounds.width * $1.bounds.height) }) {
                let imgW = CGFloat(cgImage.width)
                let imgH = CGFloat(cgImage.height)
                if imgW > 0, imgH > 0 {
                    return CGRect(
                        x: best.bounds.minX / imgW,
                        y: best.bounds.minY / imgH,
                        width: best.bounds.width / imgW,
                        height: best.bounds.height / imgH
                    )
                }
            }
        }
        return nil
    }

    private static func crop(
        cgImage: CGImage,
        targetRatio: CGFloat,
        faceNormalizedRect: CGRect?,
        preset: HeadshotCropPreset
    ) -> CGImage {
        let imgWidth = CGFloat(cgImage.width)
        let imgHeight = CGFloat(cgImage.height)
        guard imgWidth > 0, imgHeight > 0, targetRatio > 0 else { return cgImage }

        let faceBox = faceNormalizedRect ?? CGRect(x: 0.3, y: 0.35, width: 0.4, height: 0.4)
        let facePixelX = faceBox.origin.x * imgWidth
        let facePixelY = (1.0 - (faceBox.origin.y + faceBox.height)) * imgHeight
        let facePixelW = faceBox.width * imgWidth
        let facePixelH = faceBox.height * imgHeight

        let faceCenter = CGPoint(x: facePixelX + facePixelW / 2.0, y: facePixelY + facePixelH / 2.0)

        let heightMultiplier: CGFloat
        switch preset {
        case .tightCloseUp: heightMultiplier = 2.0
        case .cardSlotFit, .theatrical: heightMultiplier = 2.8
        case .commercial: heightMultiplier = 3.0
        case .headAndShoulders: heightMultiplier = 3.8
        case .square: heightMultiplier = 2.6
        }

        var cropHeight = min(imgHeight, max(imgHeight * 0.45, facePixelH * heightMultiplier))
        var cropWidth = cropHeight * targetRatio

        if cropWidth > imgWidth {
            cropWidth = imgWidth
            cropHeight = cropWidth / targetRatio
        }
        if cropHeight > imgHeight {
            cropHeight = imgHeight
            cropWidth = cropHeight * targetRatio
        }

        let headroomFactor: CGFloat = (preset == .tightCloseUp) ? 0.38 : 0.42
        var cropX = faceCenter.x - cropWidth / 2.0
        var cropY = faceCenter.y - (cropHeight * headroomFactor)

        let roundedW = max(1, min(imgWidth, round(cropWidth)))
        let roundedH = max(1, min(imgHeight, round(cropHeight)))

        cropX = max(0, min(round(cropX), imgWidth - roundedW))
        cropY = max(0, min(round(cropY), imgHeight - roundedH))

        let cropRect = CGRect(x: cropX, y: cropY, width: roundedW, height: roundedH)
        return cgImage.cropping(to: cropRect) ?? cgImage
    }
}
