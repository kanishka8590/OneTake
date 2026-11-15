import Foundation
import UIKit
import AVFoundation
import Vision
import CoreMotion
import Speech

// MARK: - Enums & Status Models

enum LightingStatus: String, CaseIterable, Sendable {
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

enum BackgroundStatus: String, CaseIterable, Sendable {
    case clean = "Clean Background"
    case cluttered = "Cluttered"
    case uneven = "Uneven Backdrop"
}

nonisolated struct GuidanceFeedback: Sendable {
    var isFaceCentered: Bool = false
    var isAngleCorrect: Bool = false
    var currentYawDegrees: Double = 0.0
    var lighting: LightingStatus = .good
    var background: BackgroundStatus = .clean
    var isEyeLevel: Bool = true
    var pitchDegrees: Double = 90.0
    var spokenAdvice: String? = nil

    var allChecksPassed: Bool {
        isFaceCentered && isAngleCorrect && (lighting == .good) && isEyeLevel && (background == .clean)
    }
}

// MARK: - Protocol

protocol HeadshotGuidanceServiceProtocol: AnyObject {
    var feedback: GuidanceFeedback { get }
    var currentZoomFactor: CGFloat { get }
    var isCapturing: Bool { get }
    var countdownRemaining: Int { get }
    var voiceGuidanceEnabled: Bool { get set }
    var isVoiceListening: Bool { get }
    var voiceStatus: LiveSpeechStatus { get }

    func startSession(for angle: HeadshotAngle)
    func stopSession()
    func cycleZoom()
    func flipCamera()
    func startCountdown(seconds: Int, completion: @escaping (UIImage?) -> Void)
    func evaluateImage(_ image: UIImage, for angle: HeadshotAngle) async -> GuidanceFeedback
    func triggerFramingFeedbackVoice()
    @MainActor func handleRecognizedTranscript(_ transcript: String, isFinal: Bool)
}

// MARK: - HeadshotGuidanceService Implementation

@Observable
final class HeadshotGuidanceService: NSObject, HeadshotGuidanceServiceProtocol, SFSpeechRecognizerDelegate, @unchecked Sendable {
    static let shared = HeadshotGuidanceService()

    var feedback: GuidanceFeedback = GuidanceFeedback()
    var currentZoomFactor: CGFloat = 1.0
    var isCapturing: Bool = false
    var countdownRemaining: Int = 0
    var voiceGuidanceEnabled: Bool = true
    var isVoiceListening: Bool = false
    var voiceStatus: LiveSpeechStatus = .idle

    @ObservationIgnored var onShutterTriggered: (() -> Void)?

    // State tracking
    private(set) var isSessionRunning: Bool = false
    private var lastCommandTriggerTime: Date = .distantPast
    private var isRestartingRecognition: Bool = false
    private var taskRestartTimer: Timer?
    private var activeRecognitionTaskID: UUID?
    private var isAudioTapInstalled: Bool = false
    @ObservationIgnored private var audioSessionObservers: [NSObjectProtocol] = []

    // Capture Session
    private(set) var captureSession: AVCaptureSession?
    private var videoDevice: AVCaptureDevice?
    private var photoOutput: AVCapturePhotoOutput?
    private var videoDataOutput: AVCaptureVideoDataOutput?

    // Subsystems
    private let motionManager = CMMotionManager()
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    // State & Debouncing
    private var targetAngle: HeadshotAngle = .front
    private var lastSpokenTime: Date = .distantPast
    private let speechDebounceInterval: TimeInterval = 4.0
    @ObservationIgnored private var pendingPhotoCompletion: ((UIImage?) -> Void)?
    private var isAnalyzingFrame = false
    private var countdownToken: UUID?
    private var isCountdownInProgress = false
    private var isCountdownSpeechActive = false
    private var poseAnnouncementToken: UUID?
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

    // Simulator test controls
    var simulatedCentered: Bool = true
    var simulatedLighting: LightingStatus = .good
    var simulatedYaw: Double = 0.0
    var simulatedEyeLevel: Bool = true
    var simulatedPlainBackground: Bool = true

    override init() {
        super.init()
        setupMotion()
        observeAudioSessionChanges()
    }

    // MARK: - Motion Setup

    private func setupMotion() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 0.2
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self = self, let motion = motion else { return }
            let pitchDeg = motion.attitude.pitch * 180.0 / .pi
            let isVertical = abs(abs(pitchDeg) - 90.0) < 14.0 || abs(pitchDeg) < 14.0
            self.feedback.pitchDegrees = pitchDeg
            self.feedback.isEyeLevel = isVertical
            self.cancelCountdownIfAlignmentLost()
        }
    }

    // MARK: - Session Lifecycle

    func startSession(for angle: HeadshotAngle) {
        let needsInitialVoiceSetup = !isSessionRunning
        self.targetAngle = angle
        self.poseAnnouncementToken = nil
        self.isCapturing = false
        self.countdownRemaining = 0
        self.countdownToken = nil
        self.isCountdownInProgress = false
        self.isCountdownSpeechActive = false
        self.pendingPhotoCompletion = nil
        self.feedback = GuidanceFeedback()
        self.currentZoomFactor = 1.0

        #if targetEnvironment(simulator)
        configureSimulatorDefaults(for: angle)
        if needsInitialVoiceSetup {
            isSessionRunning = true
            setupVoiceTrigger()
        }
        #else
        isSessionRunning = true
        prepareCameraSession()
        if needsInitialVoiceSetup {
            setupVoiceTrigger()
        }
        #endif
    }

    func stopSession() {
        isSessionRunning = false
        #if !targetEnvironment(simulator)
        captureSession?.stopRunning()
        #endif
        stopVoiceTrigger()
        poseAnnouncementToken = nil
        countdownToken = nil
        isCountdownInProgress = false
        isCountdownSpeechActive = false
        pendingPhotoCompletion = nil
        isCapturing = false
        countdownRemaining = 0
    }

    private func configureSimulatorDefaults(for angle: HeadshotAngle) {
        switch angle {
        case .front: simulatedYaw = 0.0
        case .left: simulatedYaw = 50.0
        case .right: simulatedYaw = -50.0
        }
        feedback.isAngleCorrect = true
        feedback.isFaceCentered = simulatedCentered
        feedback.lighting = simulatedLighting
        feedback.isEyeLevel = simulatedEyeLevel
        feedback.background = simulatedPlainBackground ? .clean : .cluttered
        feedback.currentYawDegrees = simulatedYaw
    }

    // MARK: - Zoom Stepping

    func cycleZoom() {
        guard !isCapturing else { return }
        if currentZoomFactor < 1.4 {
            setZoom(1.5)
        } else if currentZoomFactor < 1.9 {
            setZoom(2.0)
        } else {
            setZoom(1.0)
        }
    }

    func flipCamera() {
        guard !isCapturing, let session = captureSession else { return }
        session.beginConfiguration()
        guard let currentInput = session.inputs.first(where: { ($0 as? AVCaptureDeviceInput)?.device.hasMediaType(.video) == true }) as? AVCaptureDeviceInput else {
            session.commitConfiguration()
            return
        }
        session.removeInput(currentInput)
        let newPosition: AVCaptureDevice.Position = (currentInput.device.position == .front) ? .back : .front
        if let newDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPosition),
           let newInput = try? AVCaptureDeviceInput(device: newDevice),
           session.canAddInput(newInput) {
            session.addInput(newInput)
            self.videoDevice = newDevice
        } else {
            session.addInput(currentInput)
        }
        session.commitConfiguration()
    }

    private func setZoom(_ factor: CGFloat) {
        currentZoomFactor = factor
        guard let device = videoDevice else { return }
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = max(1.0, min(factor, device.activeFormat.videoMaxZoomFactor))
            device.unlockForConfiguration()
        } catch {
            print("Zoom lock error: \(error)")
        }
    }

    // MARK: - Countdown & Capture Flow

    func startCountdown(seconds: Int = 3, completion: @escaping (UIImage?) -> Void) {
        guard !isCapturing else { return }

        // Do not begin a capture sequence from an already-invalid frame. Live analysis
        // will keep providing the adjustment prompt until the subject is aligned.
        guard feedback.allChecksPassed else {
            speakCurrentPoseGuidanceIfNeeded()
            return
        }

        isCapturing = true
        // Keep the visual counter hidden while a current guidance phrase finishes.
        // The first visible tick is the first spoken number.
        countdownRemaining = 0
        pendingPhotoCompletion = completion
        isCountdownInProgress = true
        isCountdownSpeechActive = false

        let token = UUID()
        countdownToken = token

        speakCountdown(seconds: seconds, token: token)
    }

    private func speakCountdown(seconds: Int, token: UUID) {
        guard isCapturing, isCountdownInProgress, countdownToken == token else { return }

        // A countdown must never cut off a coaching phrase. This applies to the
        // first number and every subsequent tick.
        guard !speechSynthesizer.isSpeaking else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.speakCountdown(seconds: seconds, token: token)
            }
            return
        }

        guard feedback.allChecksPassed else {
            cancelCountdownAndResumePoseGuidance()
            return
        }

        guard seconds > 0 else {
            capturePhotoNow(token: token)
            return
        }

        countdownRemaining = seconds
        isCountdownSpeechActive = true
        speak("\(seconds)", forceSpeak: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.speakCountdown(seconds: seconds - 1, token: token)
        }
    }

    private func capturePhotoNow(token: UUID) {
        guard isCapturing, countdownToken == token else { return }
        guard feedback.allChecksPassed else {
            cancelCountdownAndResumePoseGuidance()
            return
        }

        // The countdown has reached zero. Cancel every pending countdown tick
        // before handing control to the still-in-progress photo capture.
        isCountdownInProgress = false
        isCountdownSpeechActive = false
        countdownRemaining = 0
        countdownToken = nil

        #if targetEnvironment(simulator)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, self.isCapturing else { return }
            let simulatedPhoto = self.generateSimulatedHeadshot(angle: self.targetAngle)
            self.completePhotoCapture(with: simulatedPhoto)
        }
        #else
        guard let photoOutput = self.photoOutput else {
            let fallback = generateSimulatedHeadshot(angle: targetAngle)
            completePhotoCapture(with: fallback)
            return
        }

        let settings = AVCapturePhotoSettings()
        photoOutput.capturePhoto(with: settings, delegate: self)
        #endif
    }

    private func completePhotoCapture(with image: UIImage?) {
        isCapturing = false
        countdownRemaining = 0
        countdownToken = nil
        isCountdownInProgress = false
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
            setupCameraSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard granted else { return }
                DispatchQueue.main.async {
                    guard let self, self.isSessionRunning else { return }
                    self.setupCameraSession()
                }
            }
        case .denied, .restricted:
            break
        @unknown default:
            break
        }
    }

    private func setupCameraSession() {
        if let existing = captureSession {
            if !existing.isRunning {
                DispatchQueue.global(qos: .userInitiated).async {
                    existing.startRunning()
                }
            }
            return
        }

        let session = AVCaptureSession()
        session.sessionPreset = .photo
        session.automaticallyConfiguresApplicationAudioSession = false

        guard let frontCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            return
        }
        self.videoDevice = frontCamera

        do {
            let input = try AVCaptureDeviceInput(device: frontCamera)
            if session.canAddInput(input) {
                session.addInput(input)
            }

            let photo = AVCapturePhotoOutput()
            if session.canAddOutput(photo) {
                session.addOutput(photo)
                self.photoOutput = photo
            }

            let videoOutput = AVCaptureVideoDataOutput()
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "com.onetake.vision.queue"))
            if session.canAddOutput(videoOutput) {
                session.addOutput(videoOutput)
                self.videoDataOutput = videoOutput
            }

            self.captureSession = session
            DispatchQueue.global(qos: .userInitiated).async {
                session.startRunning()
            }
        } catch {
            print("Camera configuration failed: \(error)")
        }
    }

    // MARK: - Permission-Gated Voice Trigger Setup (SFSpeechRecognizer)

    private func requestMicrophonePermission(_ completion: @escaping (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        }
    }

    private func configureGuidanceAudioSession() -> Bool {
        VoiceAudioSessionCoordinator.shared.activate()
    }

    private func setupVoiceTrigger() {
        voiceStatus = .starting
        VoiceAuthorizationService.shared.requestAccess { [weak self] authorized in
            guard let self = self, self.isSessionRunning else { return }
            guard authorized else { self.voiceStatus = .failed; return }
            guard self.configureGuidanceAudioSession() else { self.voiceStatus = .failed; return }
            self.startVoiceListening()
        }
    }

    private func startVoiceListening() {
        guard isSessionRunning, VoiceAuthorizationService.shared.isAuthorized else { voiceStatus = .failed; return }
        guard !isVoiceListening else { return }
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        speechRecognizer?.delegate = self
        guard let speechRecognizer, speechRecognizer.isAvailable else { voiceStatus = .unavailable; return }

        // The audio session must be active before inputNode/tap access.
        guard configureGuidanceAudioSession() else { voiceStatus = .failed; return }
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        let outputFormat = inputNode.outputFormat(forBus: 0)
            guard let tapFormat = [inputFormat, outputFormat].first(where: { $0.sampleRate > 0 && $0.channelCount > 0 }) else {
                print("Invalid audio input formats in HeadshotGuidanceService")
                voiceStatus = .failed
                return
            }

            if !isAudioTapInstalled {
                inputNode.removeTap(onBus: 0)
                inputNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] readOnlyBuffer, _ in
                    guard let self = self else { return }
                    self.recognitionRequest?.append(readOnlyBuffer)
                }
                isAudioTapInstalled = true
            }

            if !audioEngine.isRunning {
                do {
                    try audioEngine.start()
                } catch {
                    print("Failed to start audioEngine in HeadshotGuidanceService: \(error)")
                    voiceStatus = .failed
                    return
                }
            }

        guard isSessionRunning else { return }
        startRecognitionTask()
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

        // Ignore the asynchronous cancellation callback from the task we are
        // deliberately replacing; otherwise it can schedule a second restart.
        activeRecognitionTaskID = nil
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = false
        self.recognitionRequest = request
        let taskID = UUID()
        activeRecognitionTaskID = taskID

        self.recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self,
                  self.isSessionRunning,
                  self.activeRecognitionTaskID == taskID else { return }

            if let result = result {
                let transcript = result.bestTranscription.formattedString
                let isFinal = result.isFinal

                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.handleRecognizedTranscript(transcript, isFinal: isFinal)
                }

                if isFinal {
                    self.restartRecognitionTaskSeamlessly()
                }
            }

            if error != nil {
                // Keep the indicator steady while the next short recognition
                // request replaces this completed one.
                self.restartRecognitionTaskSeamlessly()
            }
        }

        isVoiceListening = true
        voiceStatus = .listening

        taskRestartTimer = Timer.scheduledTimer(withTimeInterval: 50.0, repeats: false) { [weak self] _ in
            guard let self = self, self.isSessionRunning else { return }
            self.restartRecognitionTaskSeamlessly()
        }
    }

    private func restartRecognitionTaskSeamlessly() {
        guard isSessionRunning, !isRestartingRecognition else { return }
        isRestartingRecognition = true

        taskRestartTimer?.invalidate()
        taskRestartTimer = nil

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, self.isSessionRunning else { return }
            self.isRestartingRecognition = false
            guard self.configureGuidanceAudioSession() else { self.voiceStatus = .failed; return }
            if !self.audioEngine.isRunning {
                do { try self.audioEngine.start() }
                catch { self.voiceStatus = .failed; return }
            }
            self.startRecognitionTask()
        }
    }

    // MARK: - Single Transcript Entry Point

    /// Device recognizer results and injectable Simulator/XCTest transcripts use
    /// the same command parser. Headshots intentionally has no Cut behavior.
    @MainActor
    func handleRecognizedTranscript(_ transcript: String, isFinal: Bool) {
        voiceCommandController.handleRecognizedTranscript(transcript, isFinal: isFinal)
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
        lastSpokenTime = Date()
        var adjustments: [String] = []

        if !feedback.isFaceCentered {
            adjustments.append("center your face in the guide oval")
        }
        if !feedback.isAngleCorrect {
            switch targetAngle {
            case .front: adjustments.append("face the camera directly")
            case .left: adjustments.append("turn slightly to your left")
            case .right: adjustments.append("turn slightly to your right")
            }
        }
        if feedback.lighting != .good {
            if feedback.lighting == .tooDark {
                adjustments.append("brighten your front lighting")
            } else if feedback.lighting == .uneven {
                adjustments.append("balance the light across your face")
            } else if feedback.lighting == .tooBright {
                adjustments.append("reduce glare or harsh lighting")
            }
        }
        if !feedback.isEyeLevel {
            adjustments.append("raise your camera to eye level")
        }
        if feedback.background != .clean {
            adjustments.append("use a plain, clean background")
        }

        let message: String
        if adjustments.isEmpty {
            message = "You look great — centered, well lit, eye level, and plain background."
        } else {
            message = "Please adjust: " + adjustments.joined(separator: ", ") + "."
        }

        speak(message, forceSpeak: true)
    }

    /// Resets completed capture state, then announces the next pose without
    /// interrupting the last countdown utterance.
    func transitionToNextPose(_ angle: HeadshotAngle) {
        startSession(for: angle)
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

        recognitionRequest?.endAudio()
        activeRecognitionTaskID = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        if isAudioTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isAudioTapInstalled = false
        }
        if audioEngine.isRunning {
            audioEngine.stop()
        }

    }

    private func observeAudioSessionChanges() {
        let center = NotificationCenter.default
        audioSessionObservers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, self.isSessionRunning else { return }
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            if type == .began { self.isVoiceListening = false; self.voiceStatus = .interrupted }
            else { self.restartRecognitionTaskSeamlessly() }
        })
        audioSessionObservers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.restartRecognitionTaskSeamlessly()
        })
        audioSessionObservers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.isAudioTapInstalled = false
            self.audioEngine.reset()
            self.isVoiceListening = false
            self.restartVoicePipeline()
        })
    }

    private func restartVoicePipeline() {
        guard isSessionRunning else { return }
        isRestartingRecognition = false
        stopVoiceTrigger()
        if isSessionRunning { voiceStatus = .starting; startVoiceListening() }
    }

    func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        guard isSessionRunning else { return }
        if available {
            if !isVoiceListening { restartRecognitionTaskSeamlessly() }
        } else {
            isVoiceListening = false
            voiceStatus = .unavailable
        }
    }

    // MARK: - Real-Time Guidance & Spoken Warnings

    func speakDebouncedWarning(_ message: String) {
        guard voiceGuidanceEnabled else { return }
        let now = Date()
        guard now.timeIntervalSince(lastSpokenTime) > speechDebounceInterval, !isCapturing else { return }
        lastSpokenTime = now
        speak(message, forceSpeak: false)
    }

    private func speak(_ text: String, forceSpeak: Bool) {
        guard forceSpeak || voiceGuidanceEnabled else { return }
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        speechSynthesizer.speak(utterance)
    }

    /// Called from live analysis and the view so a countdown cannot produce a
    /// photo after the subject has moved out of the required framing.
    func cancelCountdownIfAlignmentLost() {
        guard isCountdownInProgress, !feedback.allChecksPassed else { return }
        cancelCountdownAndResumePoseGuidance()
    }

    private func cancelCountdownAndResumePoseGuidance() {
        guard isCountdownInProgress else { return }

        let wasSpeakingCountdown = isCountdownSpeechActive
        countdownToken = nil
        isCountdownInProgress = false
        isCountdownSpeechActive = false
        isCapturing = false
        countdownRemaining = 0
        pendingPhotoCompletion = nil
        lastSpokenTime = .distantPast

        // If a countdown number is currently audible, remove it before returning
        // to a pose prompt. If this was still waiting for the prior coaching phrase,
        // the helper below waits for that phrase instead of interrupting it.
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

        if !feedback.isFaceCentered {
            speak("Center your face in the guide oval.", forceSpeak: false)
        } else if !feedback.isAngleCorrect {
            switch targetAngle {
            case .front: speak("Turn your head to face front.", forceSpeak: false)
            case .left: speak("Turn slightly to your left.", forceSpeak: false)
            case .right: speak("Turn slightly to your right.", forceSpeak: false)
            }
        } else if feedback.lighting != .good {
            speak("Adjust your lighting before capturing.", forceSpeak: false)
        } else if !feedback.isEyeLevel {
            speak("Hold your phone at eye level.", forceSpeak: false)
        } else if feedback.background != .clean {
            speak("Use a plain background behind you.", forceSpeak: false)
        }
    }

    // MARK: - Single Image Evaluation

    func evaluateImage(_ image: UIImage, for angle: HeadshotAngle) async -> GuidanceFeedback {
        guard let cgImage = image.cgImage else { return feedback }

        return await withCheckedContinuation { continuation in
            let faceRequest = VNDetectFaceLandmarksRequest { [weak self] request, _ in
                guard let self = self else {
                    continuation.resume(returning: GuidanceFeedback())
                    return
                }
                guard let results = request.results as? [VNFaceObservation], let face = results.first else {
                    var fb = GuidanceFeedback()
                    fb.isFaceCentered = false
                    fb.spokenAdvice = "Face not detected. Center yourself in the frame."
                    continuation.resume(returning: fb)
                    return
                }

                var fb = GuidanceFeedback()
                let box = face.boundingBox
                let midX = box.midX
                let midY = box.midY

                fb.isFaceCentered = (midX >= 0.35 && midX <= 0.65) && (midY >= 0.30 && midY <= 0.70)

                let yawRad = face.yaw?.doubleValue ?? 0.0
                let yawDeg = yawRad * 180.0 / .pi
                fb.currentYawDegrees = yawDeg

                switch angle {
                case .front:
                    fb.isAngleCorrect = abs(yawDeg) <= 18.0
                    if !fb.isAngleCorrect { fb.spokenAdvice = "Look directly at the camera." }
                case .left:
                    fb.isAngleCorrect = yawDeg >= 30.0 && yawDeg <= 85.0
                    if !fb.isAngleCorrect { fb.spokenAdvice = "Turn your face to the left." }
                case .right:
                    fb.isAngleCorrect = yawDeg <= -30.0 && yawDeg >= -85.0
                    if !fb.isAngleCorrect { fb.spokenAdvice = "Turn your face to the right." }
                }

                fb.lighting = self.evaluateLuminance(of: cgImage)
                if fb.lighting == .tooDark {
                    fb.spokenAdvice = "Face is too dark. Add key light in front of you."
                } else if fb.lighting == .uneven {
                    fb.spokenAdvice = "Lighting is uneven. Balance the light across your face."
                }

                continuation.resume(returning: fb)
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([faceRequest])
        }
    }

    private func evaluateLuminance(of cgImage: CGImage) -> LightingStatus {
        guard let dataProvider = cgImage.dataProvider,
              let data = dataProvider.data,
              let ptr = CFDataGetBytePtr(data) else {
            return .good
        }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = cgImage.bitsPerPixel / 8
        let bytesPerRow = cgImage.bytesPerRow

        var totalLum: Double = 0
        var leftLum: Double = 0
        var rightLum: Double = 0
        var sampledCount = 0
        var leftCount = 0
        var rightCount = 0

        let step = max(1, width / 40)
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let r = Double(ptr[offset]) / 255.0
                let g = Double(ptr[offset + 1]) / 255.0
                let b = Double(ptr[offset + 2]) / 255.0
                let lum = 0.299 * r + 0.587 * g + 0.114 * b

                totalLum += lum
                sampledCount += 1

                if x < width / 2 {
                    leftLum += lum
                    leftCount += 1
                } else {
                    rightLum += lum
                    rightCount += 1
                }
            }
        }

        guard sampledCount > 0 else { return .good }
        let avgLum = totalLum / Double(sampledCount)
        let avgLeft = leftCount > 0 ? leftLum / Double(leftCount) : avgLum
        let avgRight = rightCount > 0 ? rightLum / Double(rightCount) : avgLum

        if avgLum < 0.22 { return .tooDark }
        if avgLum > 0.85 { return .tooBright }
        if abs(avgLeft - avgRight) > 0.32 { return .uneven }
        return .good
    }

    // MARK: - Simulator Headshot Generator

    func generateSimulatedHeadshot(angle: HeadshotAngle) -> UIImage {
        let size = CGSize(width: 1200, height: 1500)
        let renderer = UIGraphicsImageRenderer(size: size)

        return renderer.image { ctx in
            let bgGradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [
                    UIColor(red: 0.94, green: 0.94, blue: 0.96, alpha: 1.0).cgColor,
                    UIColor(red: 0.88, green: 0.88, blue: 0.92, alpha: 1.0).cgColor
                ] as CFArray,
                locations: [0.0, 1.0]
            )!
            ctx.cgContext.drawLinearGradient(bgGradient, start: CGPoint.zero, end: CGPoint(x: 0, y: size.height), options: [])

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
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Continue checking alignment during the countdown. Guidance speech remains
        // locked out by isCapturing, but a lost check must cancel the pending photo.
        guard !isAnalyzingFrame, (!isCapturing || isCountdownInProgress) else { return }
        isAnalyzingFrame = true
        defer { isAnalyzingFrame = false }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let currentLighting = evaluatePixelBufferLuminance(pixelBuffer)

        let faceRequest = VNDetectFaceLandmarksRequest { [weak self] req, _ in
            guard let self = self, let results = req.results as? [VNFaceObservation], let face = results.first else {
                DispatchQueue.main.async {
                    self?.feedback.isFaceCentered = false
                    self?.feedback.isAngleCorrect = false
                    self?.cancelCountdownIfAlignmentLost()
                }
                return
            }

            let box = face.boundingBox
            let midX = box.midX
            let midY = box.midY
            let centered = (midX >= 0.35 && midX <= 0.65) && (midY >= 0.30 && midY <= 0.70)
            let yawRad = face.yaw?.doubleValue ?? 0.0
            let yawDeg = yawRad * 180.0 / .pi

            var anglePass = false
            switch self.targetAngle {
            case .front: anglePass = abs(yawDeg) <= 18.0
            case .left: anglePass = yawDeg >= 30.0 && yawDeg <= 85.0
            case .right: anglePass = yawDeg <= -30.0 && yawDeg >= -85.0
            }

            DispatchQueue.main.async {
                self.feedback.isFaceCentered = centered
                self.feedback.isAngleCorrect = anglePass
                self.feedback.currentYawDegrees = yawDeg
                self.feedback.lighting = currentLighting

                self.cancelCountdownIfAlignmentLost()
                guard !self.isCountdownInProgress else { return }

                if self.feedback.allChecksPassed {
                    self.speakDebouncedWarning("Framing and lighting look great.")
                } else if !centered {
                    self.speakDebouncedWarning("Center your face in the guide oval.")
                } else if !anglePass {
                    switch self.targetAngle {
                    case .front: self.speakDebouncedWarning("Turn your head to face front.")
                    case .left: self.speakDebouncedWarning("Turn slightly to your left.")
                    case .right: self.speakDebouncedWarning("Turn slightly to your right.")
                    }
                } else if currentLighting == .tooDark {
                    self.speakDebouncedWarning("Lighting is too dark. Add key light in front of you.")
                } else if currentLighting == .uneven {
                    self.speakDebouncedWarning("Lighting is uneven. Balance the light across your face.")
                } else if currentLighting == .tooBright {
                    self.speakDebouncedWarning("Lighting is too bright. Reduce glare.")
                } else if !self.feedback.isEyeLevel {
                    self.speakDebouncedWarning("Hold your phone at eye level.")
                } else if self.feedback.background == .cluttered {
                    self.speakDebouncedWarning("Background looks busy. Try a plain wall behind you.")
                }
            }
        }

        let segRequest = VNGeneratePersonSegmentationRequest { [weak self] req, _ in
            guard let self = self,
                  let result = req.results?.first as? VNPixelBufferObservation else { return }
            let isPlain = self.evaluateBackgroundClutter(maskBuffer: result.pixelBuffer, frameBuffer: pixelBuffer)
            DispatchQueue.main.async {
                self.feedback.background = isPlain ? .clean : .cluttered
                self.cancelCountdownIfAlignmentLost()
            }
        }
        segRequest.qualityLevel = .fast

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .upMirrored, options: [:])
        try? handler.perform([faceRequest, segRequest])
    }

    func evaluatePixelBufferLuminance(_ pixelBuffer: CVPixelBuffer) -> LightingStatus {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        if planeCount > 0 {
            guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return .good }
            let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let ptr = yBase.assumingMemoryBound(to: UInt8.self)

            var totalLum: Double = 0
            var leftLum: Double = 0
            var rightLum: Double = 0
            var sampled = 0
            var leftSampled = 0
            var rightSampled = 0

            let step = max(1, width / 30)
            for y in stride(from: 0, to: height, by: step) {
                for x in stride(from: 0, to: width, by: step) {
                    let lum = Double(ptr[y * bytesPerRow + x]) / 255.0
                    totalLum += lum
                    sampled += 1
                    if x < width / 2 {
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

            if avg < 0.22 { return .tooDark }
            if avg > 0.85 { return .tooBright }
            if abs(avgLeft - avgRight) > 0.30 { return .uneven }
            return .good
        } else {
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return .good }
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let ptr = base.assumingMemoryBound(to: UInt8.self)

            var totalLum: Double = 0
            var leftLum: Double = 0
            var rightLum: Double = 0
            var sampled = 0
            var leftSampled = 0
            var rightSampled = 0

            let step = max(1, width / 30)
            for y in stride(from: 0, to: height, by: step) {
                for x in stride(from: 0, to: width, by: step) {
                    let offset = y * bytesPerRow + x * 4
                    let b = Double(ptr[offset]) / 255.0
                    let g = Double(ptr[offset + 1]) / 255.0
                    let r = Double(ptr[offset + 2]) / 255.0
                    let lum = 0.299 * r + 0.587 * g + 0.114 * b
                    totalLum += lum
                    sampled += 1
                    if x < width / 2 {
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

            if avg < 0.22 { return .tooDark }
            if avg > 0.85 { return .tooBright }
            if abs(avgLeft - avgRight) > 0.30 { return .uneven }
            return .good
        }
    }

    func evaluateBackgroundClutter(maskBuffer: CVPixelBuffer, frameBuffer: CVPixelBuffer) -> Bool {
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
        let maskPtr = maskBase.assumingMemoryBound(to: UInt8.self)

        let isPlanar = CVPixelBufferGetPlaneCount(frameBuffer) > 0
        let frameWidth = isPlanar ? CVPixelBufferGetWidthOfPlane(frameBuffer, 0) : CVPixelBufferGetWidth(frameBuffer)
        let frameHeight = isPlanar ? CVPixelBufferGetHeightOfPlane(frameBuffer, 0) : CVPixelBufferGetHeight(frameBuffer)
        let frameBytesPerRow = isPlanar ? CVPixelBufferGetBytesPerRowOfPlane(frameBuffer, 0) : CVPixelBufferGetBytesPerRow(frameBuffer)
        guard let frameBase = isPlanar ? CVPixelBufferGetBaseAddressOfPlane(frameBuffer, 0) : CVPixelBufferGetBaseAddress(frameBuffer) else { return true }
        let framePtr = frameBase.assumingMemoryBound(to: UInt8.self)

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
        return sqrt(variance) < 0.26
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension HeadshotGuidanceService: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else {
            completePhotoCapture(with: nil)
            return
        }
        completePhotoCapture(with: image)
    }
}

// MARK: - Face-Aware Auto Cropper (ImageFramer)

enum ImageFramer {
    static func autoCrop(
        image: UIImage,
        aspectRatio: HeadshotAspectRatio,
        preset: HeadshotCropPreset = .theatrical
    ) async -> UIImage {
        guard let cgImage = image.cgImage else { return image }

        let targetRatio: CGFloat
        switch preset {
        case .cardSlotFit: targetRatio = 4.0 / 5.0
        case .theatrical: targetRatio = 4.0 / 5.0
        case .commercial: targetRatio = 3.0 / 4.0
        case .square: targetRatio = 1.0
        case .tightCloseUp: targetRatio = 4.0 / 5.0
        case .headAndShoulders: targetRatio = 2.0 / 3.0
        }

        let faceRect = await detectFaceBoundingBox(in: cgImage)
        let cropped = crop(cgImage: cgImage, targetRatio: targetRatio, faceNormalizedRect: faceRect, preset: preset)
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }

    private static func detectFaceBoundingBox(in cgImage: CGImage) async -> CGRect? {
        await withCheckedContinuation { continuation in
            let request = VNDetectFaceRectanglesRequest { req, _ in
                guard let results = req.results as? [VNFaceObservation], let face = results.first else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: face.boundingBox)
            }
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
        }
    }

    private static func crop(
        cgImage: CGImage,
        targetRatio: CGFloat,
        faceNormalizedRect: CGRect?,
        preset: HeadshotCropPreset
    ) -> CGImage {
        let imgWidth = CGFloat(cgImage.width)
        let imgHeight = CGFloat(cgImage.height)

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

        var cropHeight = min(imgHeight, facePixelH * heightMultiplier)
        var cropWidth = cropHeight * targetRatio

        if cropWidth > imgWidth {
            cropWidth = imgWidth
            cropHeight = cropWidth / targetRatio
        }

        let headroomFactor: CGFloat = (preset == .tightCloseUp) ? 0.38 : 0.42
        var cropX = faceCenter.x - cropWidth / 2.0
        var cropY = faceCenter.y - (cropHeight * headroomFactor)

        cropX = max(0, min(cropX, imgWidth - cropWidth))
        cropY = max(0, min(cropY, imgHeight - cropHeight))

        let cropRect = CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight)
        return cgImage.cropping(to: cropRect) ?? cgImage
    }
}
