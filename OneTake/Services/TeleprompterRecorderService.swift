import Foundation
import UIKit
import AVFoundation
import Vision
import CoreMotion
import Speech

// MARK: - Quality Indicators

nonisolated struct PreTakeQualityMetrics: Sendable {
    var lightStatus: String = "Not checked"
    var isLightPassed: Bool = false
    var isLightingEvaluated: Bool = false
    var backgroundStatus: String = "Not checked"
    var isBackgroundPassed: Bool = false
    var isBackgroundEvaluated: Bool = false
    var ratioString: String = "16:9"
    var isRatioPassed: Bool = true
    var isAlignmentPassed: Bool = false
    var isFramingEvaluated: Bool = false
    var phoneHeightStatus: String = "Not checked"
    var isPhoneHeightPassed: Bool = false
    var isPhoneHeightEvaluated: Bool = false

    var allPassed: Bool {
        isLightPassed && isBackgroundPassed && isRatioPassed && isAlignmentPassed && isPhoneHeightPassed
    }
}

// MARK: - Protocol

@MainActor
protocol TeleprompterRecorderServiceProtocol: AnyObject {
    var isRecording: Bool { get }
    var isCountingDown: Bool { get }
    var countdownRemaining: Int { get }
    var currentZoomFactor: CGFloat { get }
    var qualityMetrics: PreTakeQualityMetrics { get }
    var recordingDurationSeconds: Double { get }
    var voiceGuidanceEnabled: Bool { get set }
    var isVoiceListening: Bool { get }
    var voiceStatus: LiveSpeechStatus { get }
    var cameraPermissionDenied: Bool { get }
    var cameraErrorMessage: String? { get }
    var isDemoMode: Bool { get set }
    var mirrorFrontCamera: Bool { get set }
    var onLiveMicData: ((_ rms: Float, _ transcript: String, _ isFinal: Bool) -> Void)? { get set }

    func startSession()
    func stopSession()
    func cycleZoom()
    func flipCamera()
    func startCountdownAndRecord(countdownSeconds: Int, completion: @escaping (URL?, Double) -> Void)
    func stopRecording()
    func triggerFramingFeedbackVoice()
    func handleRecognizedTranscript(_ transcript: String, isFinal: Bool)
}

// MARK: - Thread-Safe Cross-Queue State

nonisolated private final class RecorderStateBox: @unchecked Sendable {
    private let lock = NSLock()

    private var _isRecording = false
    private var _isCountingDown = false
    private var _isSessionRunning = false
    private var _latestRMS: Float = 0.0
    private var _latestTranscript = ""
    private var _recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var _activeRecognitionTaskID: UUID?
    private var _isRestartingRecognition = false
    private var _isAudioTapInstalled = false
    private var _isAnalyzingFrame = false
    private var _cameraPosition: AVCaptureDevice.Position = .front
    private var _mirrorFrontCamera = true
    private var _lastMicDispatchTime: CFAbsoluteTime = 0
    private var _lastDispatchedRMS: Float = 0
    private var _activeTapSampleRate: Double = 0
    private var _activeTapChannelCount: AVAudioChannelCount = 0
    private var _hasMovieFileOutput = false

    func withLock<T>(_ body: (RecorderStateBox) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(self)
    }

    var isRecording: Bool {
        get { withLock { $0._isRecording } }
        set { withLock { $0._isRecording = newValue } }
    }

    var isCountingDown: Bool {
        get { withLock { $0._isCountingDown } }
        set { withLock { $0._isCountingDown = newValue } }
    }

    var isSessionRunning: Bool {
        get { withLock { $0._isSessionRunning } }
        set { withLock { $0._isSessionRunning = newValue } }
    }

    var latestRMS: Float {
        get { withLock { $0._latestRMS } }
        set { withLock { $0._latestRMS = newValue } }
    }

    var latestTranscript: String {
        get { withLock { $0._latestTranscript } }
        set { withLock { $0._latestTranscript = newValue } }
    }

    var recognitionRequest: SFSpeechAudioBufferRecognitionRequest? {
        get { withLock { $0._recognitionRequest } }
        set { withLock { $0._recognitionRequest = newValue } }
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

    var cameraPosition: AVCaptureDevice.Position {
        get { withLock { $0._cameraPosition } }
        set { withLock { $0._cameraPosition = newValue } }
    }

    var mirrorFrontCamera: Bool {
        get { withLock { $0._mirrorFrontCamera } }
        set { withLock { $0._mirrorFrontCamera = newValue } }
    }

    var hasMovieFileOutput: Bool {
        get { withLock { $0._hasMovieFileOutput } }
        set { withLock { $0._hasMovieFileOutput = newValue } }
    }

    func tryBeginFrameAnalysis() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !_isAnalyzingFrame, !_isRecording else { return false }
        _isAnalyzingFrame = true
        return true
    }

    func endFrameAnalysis() {
        lock.lock()
        _isAnalyzingFrame = false
        lock.unlock()
    }

    func setTapFormat(sampleRate: Double, channelCount: AVAudioChannelCount) {
        lock.lock()
        _activeTapSampleRate = sampleRate
        _activeTapChannelCount = channelCount
        lock.unlock()
    }

    func tapFormatMatches(sampleRate: Double, channelCount: AVAudioChannelCount) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _activeTapSampleRate == sampleRate && _activeTapChannelCount == channelCount
    }

    /// Appends audio to the active request and throttles MainActor UI updates (~15 Hz unless RMS changes meaningfully).
    func processAudioTapBuffer(_ buffer: AVAudioPCMBuffer, rms: Float) -> (shouldDispatch: Bool, transcript: String) {
        lock.lock()
        _latestRMS = rms
        let request = _recognitionRequest
        let transcript = _latestTranscript
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - _lastMicDispatchTime
        let delta = abs(rms - _lastDispatchedRMS)
        let shouldDispatch = elapsed >= (1.0 / 15.0) || delta >= 0.03
        if shouldDispatch {
            _lastMicDispatchTime = now
            _lastDispatchedRMS = rms
        }
        lock.unlock()

        request?.append(buffer)
        return (shouldDispatch, transcript)
    }
}

// MARK: - Implementation

@MainActor
@Observable
final class TeleprompterRecorderService: NSObject, TeleprompterRecorderServiceProtocol, SFSpeechRecognizerDelegate {
    static let shared = TeleprompterRecorderService()

    var isRecording: Bool = false
    var isCountingDown: Bool = false
    var countdownRemaining: Int = 0
    var currentZoomFactor: CGFloat = 1.0
    var qualityMetrics: PreTakeQualityMetrics = PreTakeQualityMetrics()
    var recordingDurationSeconds: Double = 0.0
    var voiceGuidanceEnabled: Bool = true
    var countdownOutLoud: Bool = true
    var isVoiceListening: Bool = false
    var voiceStatus: LiveSpeechStatus = .idle
    var cameraPermissionDenied: Bool = false
    var cameraErrorMessage: String? = nil
    var isUsingFrontCamera: Bool = true
    var isDemoMode: Bool = false
    var mirrorFrontCamera: Bool = true {
        didSet {
            stateBox.mirrorFrontCamera = mirrorFrontCamera
            let mirror = mirrorFrontCamera
            sessionQueue.async { [weak self] in
                guard let self else { return }
                let pos = self.stateBox.cameraPosition
                if let conn = self.sessionMovieFileOutput?.connection(with: .video), conn.isVideoMirroringSupported {
                    conn.automaticallyAdjustsVideoMirroring = false
                    conn.isVideoMirrored = (pos == .front) && mirror
                }
                if let conn = self.sessionVideoDataOutput?.connection(with: .video), conn.isVideoMirroringSupported {
                    conn.automaticallyAdjustsVideoMirroring = false
                    conn.isVideoMirrored = (pos == .front) && mirror
                }
            }
        }
    }

    @ObservationIgnored var onLiveMicData: ((_ rms: Float, _ transcript: String, _ isFinal: Bool) -> Void)?
    @ObservationIgnored var onVoiceActionTriggered: (() -> Void)?
    /// Supplied by cue playback. A locked cue rejects its own speaker audio before
    /// it can reach either commands or script progression.
    @ObservationIgnored var shouldIgnoreRecognizedTranscript: (() -> Bool)?
    var defaultCountdownSeconds: Int = 3

    // Simulator test controls
    var simulatedCentered: Bool = true
    var simulatedLighting: Bool = true
    var simulatedEyeLevel: Bool = true
    var simulatedPlainBackground: Bool = true

    // State tracking
    private(set) var isSessionRunning: Bool = false
    @ObservationIgnored private let stateBox = RecorderStateBox()
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "com.onetake.teleprompter.session")
    @ObservationIgnored private let visionQueue = DispatchQueue(label: "com.onetake.teleprompter.vision.queue")
    @ObservationIgnored private var taskRestartTimer: Timer?
    @ObservationIgnored private var recognitionRestartWorkItem: DispatchWorkItem?
    @ObservationIgnored private var sessionObservers: [NSObjectProtocol] = []

    // Capture Infrastructure (session-queue owned references + MainActor published session)
    private(set) var captureSession: AVCaptureSession?
    @ObservationIgnored nonisolated(unsafe) private var sessionCaptureSession: AVCaptureSession?
    @ObservationIgnored nonisolated(unsafe) private var sessionVideoDevice: AVCaptureDevice?
    @ObservationIgnored nonisolated(unsafe) private var sessionMovieFileOutput: AVCaptureMovieFileOutput?
    @ObservationIgnored nonisolated(unsafe) private var sessionVideoDataOutput: AVCaptureVideoDataOutput?
    @ObservationIgnored private weak var previewLayer: AVCaptureVideoPreviewLayer?
    @ObservationIgnored private var outputFileURL: URL?

    // Subsystems
    @ObservationIgnored private let motionManager = CMMotionManager()
    @ObservationIgnored private let speechSynthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var speechRecognizer: SFSpeechRecognizer?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
    @ObservationIgnored private let speechAudioEngine = AVAudioEngine()

    // Timers & Callbacks
    @ObservationIgnored private var recordTimer: Timer?
    @ObservationIgnored private var recordingStartTime: Date?
    @ObservationIgnored private var countdownToken: UUID?
    @ObservationIgnored private var simulatorRecordTask: Task<Void, Never>?
    @ObservationIgnored private var recordCompletion: ((URL?, Double) -> Void)?
    @ObservationIgnored private lazy var voiceCommandController: LiveVoiceCommandController = { [weak self] in
        LiveVoiceCommandController(
            mode: .audition,
            state: { [weak self] in
                LiveVoiceCommandState(
                    isRecording: self?.isRecording ?? false,
                    isCountingDown: self?.isCountingDown ?? false,
                    isCapturingPhoto: false
                )
            },
            startRecording: { [weak self] in self?.onVoiceActionTriggered?() },
            stopRecording: { [weak self] in self?.stopRecording() },
            speakFramingFeedback: { [weak self] in self?.triggerFramingFeedbackVoice() }
        )
    }()

    override init() {
        super.init()
        setupMotion()
        observeSystemNotifications()
    }

    deinit {
        for observer in sessionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Motion Monitoring

    private func setupMotion() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 0.25
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self = self, let motion = motion else { return }
            let pitchDeg = motion.attitude.pitch * 180.0 / .pi
            let isVertical = abs(abs(pitchDeg) - 90.0) < 14.0 || abs(pitchDeg) < 14.0
            self.qualityMetrics.isPhoneHeightPassed = isVertical
            self.qualityMetrics.phoneHeightStatus = isVertical ? "Eye Level" : "Tilt Adjust"
            self.qualityMetrics.isPhoneHeightEvaluated = true
        }
    }

    // MARK: - Session Setup

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

    func startSession() {
        isSessionRunning = true
        stateBox.isSessionRunning = true
        cameraErrorMessage = nil

        #if targetEnvironment(simulator)
        applySimulatorMetrics()
        #else
        prepareCameraSession()
        #endif

        setupVoiceCommands()
    }

    func applySimulatorMetrics() {
        qualityMetrics.isAlignmentPassed = simulatedCentered
        qualityMetrics.isLightPassed = simulatedLighting
        qualityMetrics.lightStatus = simulatedLighting ? "Good" : "Too Dark"
        qualityMetrics.isPhoneHeightPassed = simulatedEyeLevel
        qualityMetrics.phoneHeightStatus = simulatedEyeLevel ? "Eye Level" : "Tilt Adjust"
        qualityMetrics.isBackgroundPassed = simulatedPlainBackground
        qualityMetrics.backgroundStatus = simulatedPlainBackground ? "Clean" : "Cluttered"
        qualityMetrics.isLightingEvaluated = true
        qualityMetrics.isBackgroundEvaluated = true
        qualityMetrics.isFramingEvaluated = true
        qualityMetrics.isPhoneHeightEvaluated = true
    }

    func stopSession() {
        isSessionRunning = false
        stateBox.isSessionRunning = false
        cancelCountdown()
        stopVoiceCommands()
        stopRecordingTimer()
        simulatorRecordTask?.cancel()
        simulatorRecordTask = nil

        if isRecording {
            setRecordingState(false)
            sessionQueue.async { [weak self] in
                self?.sessionMovieFileOutput?.stopRecording()
            }
            finishRecording(url: nil, duration: recordingDurationSeconds)
        }

        #if !targetEnvironment(simulator)
        sessionQueue.async { [weak self] in
            self?.sessionCaptureSession?.stopRunning()
        }
        #endif
    }

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
                        self.cameraErrorMessage = "Camera access is denied. Enable camera access in Settings to record."
                    }
                }
            }
        case .denied, .restricted:
            cameraPermissionDenied = true
            cameraErrorMessage = "Camera access is denied. Enable camera access in Settings to record."
        @unknown default:
            cameraPermissionDenied = true
            cameraErrorMessage = "Camera access is unavailable."
        }
    }

    private func setupCameraSession() {
        let mirrorFront = mirrorFrontCamera
        stateBox.mirrorFrontCamera = mirrorFront

        sessionQueue.async { [weak self] in
            guard let self else { return }

            if let existing = self.sessionCaptureSession {
                if !existing.isRunning, self.stateBox.isSessionRunning {
                    existing.startRunning()
                }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.captureSession !== existing {
                        self.captureSession = existing
                    }
                    self.applyPreviewLayerConfiguration(for: self.stateBox.cameraPosition)
                }
                return
            }

            let session = AVCaptureSession()
            session.beginConfiguration()
            session.sessionPreset = .high
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
            self.stateBox.cameraPosition = initialPosition
            self.sessionVideoDevice = camera

            do {
                let videoInput = try AVCaptureDeviceInput(device: camera)
                if session.canAddInput(videoInput) {
                    session.addInput(videoInput)
                }

                if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                   let audioDevice = AVCaptureDevice.default(for: .audio),
                   let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
                   session.canAddInput(audioInput) {
                    session.addInput(audioInput)
                }

                let fileOutput = AVCaptureMovieFileOutput()
                fileOutput.maxRecordedDuration = CMTime(seconds: 600, preferredTimescale: 600)
                if session.canAddOutput(fileOutput) {
                    session.addOutput(fileOutput)
                    self.sessionMovieFileOutput = fileOutput
                    self.stateBox.hasMovieFileOutput = true
                    self.configureVideoConnection(
                        fileOutput.connection(with: .video),
                        position: initialPosition,
                        mirrorFront: mirrorFront
                    )
                }

                let videoDataOut = AVCaptureVideoDataOutput()
                videoDataOut.alwaysDiscardsLateVideoFrames = true
                videoDataOut.setSampleBufferDelegate(self, queue: self.visionQueue)
                if session.canAddOutput(videoDataOut) {
                    session.addOutput(videoDataOut)
                    self.sessionVideoDataOutput = videoDataOut
                    self.configureVideoConnection(
                        videoDataOut.connection(with: .video),
                        position: initialPosition,
                        mirrorFront: mirrorFront
                    )
                }

                session.commitConfiguration()
                self.sessionCaptureSession = session

                if self.stateBox.isSessionRunning {
                    session.startRunning()
                }

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.captureSession = session
                    self.isUsingFrontCamera = (initialPosition == .front)
                    self.currentZoomFactor = 1.0
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

    nonisolated private func configureVideoConnection(
        _ connection: AVCaptureConnection?,
        position: AVCaptureDevice.Position,
        mirrorFront: Bool
    ) {
        guard let connection else { return }
        if connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = (position == .front) && mirrorFront
        }
    }

    // MARK: - Zoom Stepping: 1.0x -> 1.5x -> 2.0x -> 1.0x

    func cycleZoom() {
        guard !isRecording, !isCountingDown else { return }
        if currentZoomFactor < 1.4 {
            setZoom(1.5)
        } else if currentZoomFactor < 1.9 {
            setZoom(2.0)
        } else {
            setZoom(1.0)
        }
    }

    func flipCamera() {
        guard !isRecording, !isCountingDown else { return }
        let mirrorFront = mirrorFrontCamera

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
                self.stateBox.cameraPosition = newPosition

                self.configureVideoConnection(
                    self.sessionMovieFileOutput?.connection(with: .video),
                    position: newPosition,
                    mirrorFront: mirrorFront
                )
                self.configureVideoConnection(
                    self.sessionVideoDataOutput?.connection(with: .video),
                    position: newPosition,
                    mirrorFront: mirrorFront
                )

                do {
                    try newDevice.lockForConfiguration()
                    newDevice.videoZoomFactor = 1.0
                    newDevice.unlockForConfiguration()
                } catch {
                    print("Flip camera zoom reset error: \(error)")
                }
            } else {
                session.addInput(currentInput)
            }

            session.commitConfiguration()

            let finalPosition = activePosition
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentZoomFactor = 1.0
                self.isUsingFrontCamera = (finalPosition == .front)
                self.applyPreviewLayerConfiguration(for: finalPosition)
            }
        }
    }

    private func setZoom(_ factor: CGFloat) {
        currentZoomFactor = factor
        sessionQueue.async { [weak self] in
            guard let self, let device = self.sessionVideoDevice else { return }
            do {
                try device.lockForConfiguration()
                let clamped = max(1.0, min(factor, device.activeFormat.videoMaxZoomFactor))
                device.videoZoomFactor = clamped
                device.unlockForConfiguration()
                Task { @MainActor [weak self] in
                    self?.currentZoomFactor = clamped
                }
            } catch {
                print("Zoom error: \(error)")
            }
        }
    }

    // MARK: - Permission-Gated Voice Command Setup: "Action", "Cut", "How do I look?"

    private func configureRecordingAudioSession() -> Bool {
        VoiceAudioSessionCoordinator.shared.activate()
    }

    private func setupVoiceCommands() {
        voiceStatus = .starting
        VoiceAuthorizationService.shared.requestAccess { [weak self] authorized in
            guard let self = self, self.isSessionRunning else { return }
            guard authorized else {
                self.voiceStatus = .failed
                return
            }
            guard self.configureRecordingAudioSession() else {
                self.voiceStatus = .failed
                return
            }
            self.startVoiceListening()
        }
    }

    private func startVoiceListening() {
        guard isSessionRunning, VoiceAuthorizationService.shared.isAuthorized else {
            voiceStatus = .failed
            return
        }
        guard !isVoiceListening else { return }

        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        speechRecognizer?.delegate = self
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            voiceStatus = .unavailable
            return
        }

        // Activate the shared audio session before reading the node format or adding a tap.
        guard configureRecordingAudioSession() else {
            voiceStatus = .failed
            return
        }

        let inputNode = speechAudioEngine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        let outputFormat = inputNode.outputFormat(forBus: 0)
        guard let tapFormat = [inputFormat, outputFormat].first(where: { $0.sampleRate > 0 && $0.channelCount > 0 }) else {
            print("Invalid audio input formats in TeleprompterRecorderService")
            voiceStatus = .failed
            return
        }

        if !stateBox.isAudioTapInstalled {
            inputNode.removeTap(onBus: 0)
            let box = stateBox
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] readOnlyBuffer, _ in
                var rms: Float = 0.0
                if let channelData = readOnlyBuffer.floatChannelData?[0] {
                    let frameLength = Int(readOnlyBuffer.frameLength)
                    if frameLength > 0 {
                        var sumSquares: Float = 0.0
                        for i in 0..<frameLength {
                            let sample = channelData[i]
                            sumSquares += sample * sample
                        }
                        rms = sqrt(sumSquares / Float(frameLength))
                    }
                }

                let dispatchDecision = box.processAudioTapBuffer(readOnlyBuffer, rms: rms)
                if dispatchDecision.shouldDispatch {
                    Task { @MainActor [weak self] in
                        self?.onLiveMicData?(rms, dispatchDecision.transcript, false)
                    }
                }
            }
            stateBox.setTapFormat(sampleRate: tapFormat.sampleRate, channelCount: tapFormat.channelCount)
            stateBox.isAudioTapInstalled = true
        }

        if !speechAudioEngine.isRunning {
            do {
                try speechAudioEngine.start()
            } catch {
                print("Failed to start speechAudioEngine: \(error)")
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

        // Invalidate before cancelling: cancellation reports an error
        // asynchronously, and that stale callback must not restart the new task.
        stateBox.activeRecognitionTaskID = nil
        stateBox.recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        stateBox.latestTranscript = ""

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = false
        stateBox.recognitionRequest = request

        let taskID = UUID()
        stateBox.activeRecognitionTaskID = taskID
        let box = stateBox

        self.recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard box.isSessionRunning, box.activeRecognitionTaskID == taskID else { return }

            if let result = result {
                let transcript = result.bestTranscription.formattedString
                let isFinal = result.isFinal
                box.latestTranscript = transcript

                Task { @MainActor [weak self] in
                    guard let self,
                          self.isSessionRunning,
                          self.stateBox.activeRecognitionTaskID == taskID else { return }
                    self.handleRecognizedTranscript(transcript, isFinal: isFinal)
                    if isFinal {
                        self.restartRecognitionTaskSeamlessly()
                    }
                }
            }

            if error != nil {
                // A recognition request naturally ends or is rolled over every
                // so often. Keep the UI stable while its replacement starts.
                Task { @MainActor [weak self] in
                    guard let self,
                          self.isSessionRunning,
                          self.stateBox.activeRecognitionTaskID == taskID else { return }
                    self.restartRecognitionTaskSeamlessly()
                }
            }
        }

        isVoiceListening = true
        voiceStatus = .listening

        taskRestartTimer = Timer.scheduledTimer(withTimeInterval: 50.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.isSessionRunning else { return }
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
        stateBox.latestTranscript = ""

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.stateBox.isRestartingRecognition = false
            guard self.isSessionRunning else { return }
            guard self.configureRecordingAudioSession() else {
                self.voiceStatus = .failed
                return
            }
            if !self.speechAudioEngine.isRunning {
                do { try self.speechAudioEngine.start() }
                catch { self.voiceStatus = .failed; return }
            }
            self.startRecognitionTask()
        }
        recognitionRestartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    // MARK: - Single Transcript Entry Point

    /// `SFSpeechRecognizer` partial and final results, Simulator injections, and
    /// XCTest all reach commands and cue ingestion through this one method.
    func handleRecognizedTranscript(_ transcript: String, isFinal: Bool) {
        stateBox.latestTranscript = transcript
        guard !(shouldIgnoreRecognizedTranscript?() ?? false) else { return }
        onLiveMicData?(stateBox.latestRMS, transcript, isFinal)
        voiceCommandController.handleRecognizedTranscript(transcript, isFinal: isFinal)
    }

    private func stopVoiceCommands() {
        isVoiceListening = false
        voiceStatus = .idle
        taskRestartTimer?.invalidate()
        taskRestartTimer = nil
        recognitionRestartWorkItem?.cancel()
        recognitionRestartWorkItem = nil
        stateBox.isRestartingRecognition = false

        stateBox.activeRecognitionTaskID = nil
        stateBox.recognitionRequest?.endAudio()
        stateBox.recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        stateBox.latestTranscript = ""

        if stateBox.isAudioTapInstalled {
            speechAudioEngine.inputNode.removeTap(onBus: 0)
            stateBox.isAudioTapInstalled = false
            stateBox.setTapFormat(sampleRate: 0, channelCount: 0)
        }
        if speechAudioEngine.isRunning {
            speechAudioEngine.stop()
        }
    }

    // MARK: - Notifications & Interruption Recovery

    private func observeSystemNotifications() {
        let center = NotificationCenter.default

        sessionObservers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor [weak self] in
                guard let self, self.isSessionRunning else { return }
                let type = typeRaw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
                if type == .began {
                    self.isVoiceListening = false
                    self.voiceStatus = .interrupted
                } else if type == .ended {
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                    if options.contains(.shouldResume) {
                        self.restartRecognitionTaskSeamlessly()
                    } else {
                        self.isVoiceListening = false
                        self.voiceStatus = .interrupted
                    }
                }
            }
        })

        sessionObservers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reasonRaw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor [weak self] in
                guard let self, self.isSessionRunning else { return }
                let reason = reasonRaw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
                guard reason == .newDeviceAvailable
                    || reason == .oldDeviceUnavailable
                    || reason == .override else {
                    return
                }

                let inputNode = self.speechAudioEngine.inputNode
                let inputFmt = inputNode.inputFormat(forBus: 0)
                let outputFmt = inputNode.outputFormat(forBus: 0)
                let activeFormat = [inputFmt, outputFmt].first(where: { $0.sampleRate > 0 && $0.channelCount > 0 })
                let formatChanged = activeFormat.map {
                    !self.stateBox.tapFormatMatches(sampleRate: $0.sampleRate, channelCount: $0.channelCount)
                } ?? true

                if formatChanged || !self.speechAudioEngine.isRunning {
                    self.restartVoicePipeline()
                } else {
                    self.restartRecognitionTaskSeamlessly()
                }
            }
        })

        sessionObservers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.stateBox.isAudioTapInstalled = false
                self.stateBox.setTapFormat(sampleRate: 0, channelCount: 0)
                self.speechAudioEngine.reset()
                self.isVoiceListening = false
                self.restartVoicePipeline()
            }
        })

        sessionObservers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isSessionRunning else { return }
                self.cancelCountdown()
                if self.isRecording {
                    self.cameraErrorMessage = "Recording was interrupted by the system."
                }
            }
        })

        sessionObservers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isSessionRunning else { return }
                self.cameraErrorMessage = nil
                self.sessionQueue.async { [weak self] in
                    guard let self,
                          self.stateBox.isSessionRunning,
                          let session = self.sessionCaptureSession,
                          !session.isRunning else { return }
                    session.startRunning()
                }
            }
        })

        sessionObservers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: nil, queue: .main) { [weak self] note in
            let err = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.cancelCountdown()
                if self.isRecording {
                    self.setRecordingState(false)
                    self.stopRecordingTimer()
                    self.finishRecording(url: nil, duration: self.recordingDurationSeconds)
                }
                self.cameraErrorMessage = err?.localizedDescription ?? "Camera session encountered a runtime error."
                if self.isSessionRunning, err?.code == AVError.mediaServicesWereReset.rawValue {
                    self.sessionQueue.async { [weak self] in
                        guard let self, self.stateBox.isSessionRunning else { return }
                        self.sessionCaptureSession?.startRunning()
                    }
                }
            }
        })

        sessionObservers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.cancelCountdown()
                if self.isRecording {
                    self.stopRecording()
                }
            }
        })
    }

    private func restartVoicePipeline() {
        guard isSessionRunning else { return }
        stateBox.isRestartingRecognition = false
        stopVoiceCommands()
        if isSessionRunning {
            voiceStatus = .starting
            startVoiceListening()
        }
    }

    nonisolated func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.isSessionRunning else { return }
            if available {
                if !self.isVoiceListening { self.restartRecognitionTaskSeamlessly() }
            } else {
                self.isVoiceListening = false
                self.voiceStatus = .unavailable
            }
        }
    }

    func triggerFramingFeedbackVoice() {
        var adjustments: [String] = []

        if !qualityMetrics.isAlignmentPassed {
            adjustments.append("center yourself in the frame")
        }
        if !qualityMetrics.isLightPassed {
            adjustments.append("brighten your front lighting")
        }
        if !qualityMetrics.isPhoneHeightPassed {
            adjustments.append("raise your camera to eye level")
        }
        if !qualityMetrics.isBackgroundPassed {
            adjustments.append("find a plain, clean background")
        }

        let message: String
        if adjustments.isEmpty {
            message = "You look great — centered, well lit, eye level, and plain background."
        } else {
            message = "Please adjust: " + adjustments.joined(separator: ", ") + "."
        }

        speak(message, forceSpeak: true)
    }

    // MARK: - Countdown and Record

    func startCountdownAndRecord(countdownSeconds: Int = 3, completion: @escaping (URL?, Double) -> Void) {
        startCountdownAndRecord(countdownSeconds: countdownSeconds, isDemoMode: nil, completion: completion)
    }

    func startCountdownAndRecord(
        countdownSeconds: Int = 3,
        isDemoMode: Bool?,
        completion: @escaping (URL?, Double) -> Void
    ) {
        if let isDemoMode {
            self.isDemoMode = isDemoMode
        }
        guard !isRecording, !isCountingDown else { return }
        cameraErrorMessage = nil

        let token = UUID()
        countdownToken = token
        setCountingDownState(true)
        countdownRemaining = countdownSeconds
        recordCompletion = completion

        speakCountdownStep(seconds: countdownSeconds, token: token)
    }

    private func cancelCountdown() {
        countdownToken = nil
        setCountingDownState(false)
        countdownRemaining = 0
    }

    private func speakCountdownStep(seconds: Int, token: UUID) {
        guard isCountingDown, countdownToken == token else { return }
        guard seconds > 0 else {
            countdownToken = nil
            setCountingDownState(false)
            countdownRemaining = 0
            if countdownOutLoud {
                speak("Action!", forceSpeak: true)
            }
            beginRecordingNow()
            return
        }

        countdownRemaining = seconds
        if countdownOutLoud {
            speak("\(seconds)", forceSpeak: true)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, self.isCountingDown, self.countdownToken == token else { return }
            self.speakCountdownStep(seconds: seconds - 1, token: token)
        }
    }

    private func speak(_ text: String, forceSpeak: Bool = false) {
        guard forceSpeak || voiceGuidanceEnabled else { return }
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        speechSynthesizer.speak(utterance)
    }

    private func beginRecordingNow() {
        #if targetEnvironment(simulator)
        guard isDemoMode else {
            cameraErrorMessage = "Camera recording requires a physical device, or enable Demo Mode in Profile."
            finishRecording(url: nil, duration: 0)
            return
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("onetake_take_\(UUID().uuidString).mp4")
        self.outputFileURL = tempURL
        setRecordingState(true)
        recordingDurationSeconds = 0.0
        recordingStartTime = Date()
        startRecordingTimer()
        #else
        guard stateBox.hasMovieFileOutput else {
            cameraErrorMessage = cameraPermissionDenied
                ? "Camera access is denied. Enable camera access in Settings to record."
                : "Camera recording output is not ready yet."
            finishRecording(url: nil, duration: 0)
            return
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("onetake_take_\(UUID().uuidString).mov")
        self.outputFileURL = tempURL
        setRecordingState(true)
        recordingDurationSeconds = 0.0
        recordingStartTime = Date()
        startRecordingTimer()

        sessionQueue.async { [weak self] in
            guard let self, let output = self.sessionMovieFileOutput else {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.setRecordingState(false)
                    self.stopRecordingTimer()
                    self.cameraErrorMessage = "Camera recording output is unavailable."
                    self.finishRecording(url: nil, duration: 0)
                }
                return
            }
            self.configureVideoConnection(
                output.connection(with: .video),
                position: self.stateBox.cameraPosition,
                mirrorFront: self.stateBox.mirrorFrontCamera
            )
            output.startRecording(to: tempURL, recordingDelegate: self)
        }
        #endif

        // Ensure voice recognition stays active throughout recording for "Cut" and "How do I look?"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self = self,
                  self.isSessionRunning,
                  VoiceAuthorizationService.shared.isAuthorized else { return }
            if !self.speechAudioEngine.isRunning {
                try? self.speechAudioEngine.start()
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        setRecordingState(false)
        stopRecordingTimer()

        #if targetEnvironment(simulator)
        let duration = recordingDurationSeconds
        let targetURL = outputFileURL
        outputFileURL = nil

        guard isDemoMode, let url = targetURL else {
            cameraErrorMessage = "Camera recording requires a physical device, or enable Demo Mode in Profile."
            finishRecording(url: nil, duration: duration)
            return
        }

        simulatorRecordTask?.cancel()
        simulatorRecordTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let ok = await DemoMediaGenerator.writeQuickSimulatedClip(
                to: url,
                title: "Simulated Take",
                subtitle: "OneTake Demo",
                durationSeconds: max(1.0, duration)
            )
            guard !Task.isCancelled else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            if ok {
                self.finishRecording(url: url, duration: max(1.0, duration))
            } else {
                self.cameraErrorMessage = "Failed to generate simulated demo video."
                self.finishRecording(url: nil, duration: duration)
            }
        }
        #else
        sessionQueue.async { [weak self] in
            self?.sessionMovieFileOutput?.stopRecording()
        }
        #endif
    }

    private func setRecordingState(_ recording: Bool) {
        isRecording = recording
        stateBox.isRecording = recording
    }

    private func setCountingDownState(_ countingDown: Bool) {
        isCountingDown = countingDown
        stateBox.isCountingDown = countingDown
    }

    private func startRecordingTimer() {
        recordTimer?.invalidate()
        recordTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, let start = self.recordingStartTime else { return }
                self.recordingDurationSeconds = Date().timeIntervalSince(start)
            }
        }
    }

    /// Delivers exactly one result on the main thread. The former dual
    /// `recordCompletion`/`onTakeRecorded` design could recursively invoke its
    /// own callback when a recording began through the voice command.
    private func finishRecording(url: URL?, duration: Double) {
        let completion = recordCompletion
        recordCompletion = nil
        completion?(url, duration)
    }

    private func stopRecordingTimer() {
        recordTimer?.invalidate()
        recordTimer = nil
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension TeleprompterRecorderService: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        let successfullyFinished = error == nil
            || ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false)
        let errorDescription = error?.localizedDescription

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.setRecordingState(false)
            self.stopRecordingTimer()
            let duration = self.recordingDurationSeconds

            if successfullyFinished {
                self.finishRecording(url: outputFileURL, duration: duration)
            } else {
                try? FileManager.default.removeItem(at: outputFileURL)
                self.cameraErrorMessage = errorDescription ?? "Recording failed to save."
                self.finishRecording(url: nil, duration: duration)
            }
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension TeleprompterRecorderService: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard stateBox.tryBeginFrameAnalysis() else { return }
        defer { stateBox.endFrameAnalysis() }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let lumStatus = Self.evaluateLuminance(of: pixelBuffer)
        let isLightOk = (lumStatus == "Good")

        let faceRequest = VNDetectFaceLandmarksRequest { [weak self] req, _ in
            guard let self else { return }
            let centered: Bool
            if let results = req.results as? [VNFaceObservation], let face = results.first {
                let box = face.boundingBox
                centered = (box.midX >= 0.30 && box.midX <= 0.70) && (box.midY >= 0.25 && box.midY <= 0.75)
            } else {
                centered = false
            }
            Task { @MainActor [weak self] in
                self?.qualityMetrics.isAlignmentPassed = centered
                self?.qualityMetrics.isFramingEvaluated = true
            }
        }

        let segRequest = VNGeneratePersonSegmentationRequest { [weak self] req, _ in
            guard let self,
                  let result = req.results?.first as? VNPixelBufferObservation else { return }
            let isPlain = Self.evaluateBackgroundClutter(maskBuffer: result.pixelBuffer, frameBuffer: pixelBuffer)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.qualityMetrics.isBackgroundPassed = isPlain
                self.qualityMetrics.backgroundStatus = isPlain ? "Clean" : "Cluttered"
                self.qualityMetrics.isBackgroundEvaluated = true
                self.qualityMetrics.isLightPassed = isLightOk
                self.qualityMetrics.lightStatus = lumStatus
                self.qualityMetrics.isLightingEvaluated = true
            }
        }
        segRequest.qualityLevel = .fast

        let isFront = (stateBox.cameraPosition == .front)
        let orientation: CGImagePropertyOrientation
        if connection.isVideoRotationAngleSupported(90) && connection.videoRotationAngle == 90 {
            orientation = isFront ? (connection.isVideoMirrored ? .up : .upMirrored) : .up
        } else {
            orientation = isFront ? .leftMirrored : .right
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        try? handler.perform([faceRequest, segRequest])
    }

    nonisolated private static func evaluateLuminance(of pixelBuffer: CVPixelBuffer) -> String {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        if planeCount > 0 {
            guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return "Good" }
            let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let ptr = yBase.assumingMemoryBound(to: UInt8.self)

            var totalLum: Double = 0
            var sampled = 0
            let step = max(1, width / 25)
            for y in stride(from: 0, to: height, by: step) {
                for x in stride(from: 0, to: width, by: step) {
                    let lum = Double(ptr[y * bytesPerRow + x]) / 255.0
                    totalLum += lum
                    sampled += 1
                }
            }
            guard sampled > 0 else { return "Good" }
            let avg = totalLum / Double(sampled)
            if avg < 0.22 { return "Too Dark" }
            if avg > 0.85 { return "Too Bright" }
            return "Good"
        } else {
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return "Good" }
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let ptr = base.assumingMemoryBound(to: UInt8.self)

            var totalLum: Double = 0
            var sampled = 0
            let step = max(1, width / 25)
            for y in stride(from: 0, to: height, by: step) {
                for x in stride(from: 0, to: width, by: step) {
                    let offset = y * bytesPerRow + x * 4
                    let b = Double(ptr[offset]) / 255.0
                    let g = Double(ptr[offset + 1]) / 255.0
                    let r = Double(ptr[offset + 2]) / 255.0
                    let lum = 0.299 * r + 0.587 * g + 0.114 * b
                    totalLum += lum
                    sampled += 1
                }
            }
            guard sampled > 0 else { return "Good" }
            let avg = totalLum / Double(sampled)
            if avg < 0.22 { return "Too Dark" }
            if avg > 0.85 { return "Too Bright" }
            return "Good"
        }
    }

    nonisolated private static func evaluateBackgroundClutter(maskBuffer: CVPixelBuffer, frameBuffer: CVPixelBuffer) -> Bool {
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
        let step = max(1, maskWidth / 20)

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
