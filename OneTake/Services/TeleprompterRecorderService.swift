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
    var onLiveMicData: ((_ rms: Float, _ transcript: String, _ isFinal: Bool) -> Void)? { get set }

    func startSession()
    func stopSession()
    func cycleZoom()
    func flipCamera()
    func startCountdownAndRecord(countdownSeconds: Int, completion: @escaping (URL?, Double) -> Void)
    func stopRecording()
    func triggerFramingFeedbackVoice()
    @MainActor func handleRecognizedTranscript(_ transcript: String, isFinal: Bool)
}

// MARK: - Implementation

@Observable
final class TeleprompterRecorderService: NSObject, TeleprompterRecorderServiceProtocol, SFSpeechRecognizerDelegate, @unchecked Sendable {
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
    private var lastCommandTriggerTime: Date = .distantPast
    private var isRestartingRecognition: Bool = false
    private var taskRestartTimer: Timer?
    private var activeRecognitionTaskID: UUID?
    private var latestRMS: Float = 0.0
    private var latestTranscript: String = ""
    private var isAudioTapInstalled: Bool = false
    @ObservationIgnored private var audioSessionObservers: [NSObjectProtocol] = []

    // Capture Infrastructure
    private(set) var captureSession: AVCaptureSession?
    private var videoDevice: AVCaptureDevice?
    private var movieFileOutput: AVCaptureMovieFileOutput?
    private var videoDataOutput: AVCaptureVideoDataOutput?
    private var outputFileURL: URL?
    private var isAnalyzingFrame = false

    // Subsystems
    private let motionManager = CMMotionManager()
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let speechAudioEngine = AVAudioEngine()

    // Timers & Callbacks
    private var recordTimer: Timer?
    private var recordingStartTime: Date?
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
        observeAudioSessionChanges()
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

    func startSession() {
        isSessionRunning = true
        #if targetEnvironment(simulator)
        applySimulatorMetrics()
        #else
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
        #if !targetEnvironment(simulator)
        captureSession?.stopRunning()
        #endif
        stopVoiceCommands()
        stopRecordingTimer()
        isRecording = false
        isCountingDown = false
        countdownRemaining = 0
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
        session.sessionPreset = .high
        session.automaticallyConfiguresApplicationAudioSession = false

        guard let frontCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            return
        }
        self.videoDevice = frontCamera

        do {
            let videoInput = try AVCaptureDeviceInput(device: frontCamera)
            if session.canAddInput(videoInput) {
                session.addInput(videoInput)
            }

            if let audioDevice = AVCaptureDevice.default(for: .audio),
               let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
               session.canAddInput(audioInput) {
                session.addInput(audioInput)
            }

            let fileOutput = AVCaptureMovieFileOutput()
            fileOutput.maxRecordedDuration = CMTime(seconds: 600, preferredTimescale: 600)
            if session.canAddOutput(fileOutput) {
                session.addOutput(fileOutput)
                self.movieFileOutput = fileOutput

                if let conn = fileOutput.connection(with: .video), conn.isVideoMirroringSupported {
                    conn.automaticallyAdjustsVideoMirroring = false
                    conn.isVideoMirrored = true
                }
            }

            let videoDataOut = AVCaptureVideoDataOutput()
            videoDataOut.alwaysDiscardsLateVideoFrames = true
            videoDataOut.setSampleBufferDelegate(self, queue: DispatchQueue(label: "com.onetake.teleprompter.vision.queue"))
            if session.canAddOutput(videoDataOut) {
                session.addOutput(videoDataOut)
                self.videoDataOutput = videoDataOut
            }

            self.captureSession = session
            DispatchQueue.global(qos: .userInitiated).async {
                session.startRunning()
            }
        } catch {
            print("Teleprompter camera session configuration error: \(error)")
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
        guard !isRecording, !isCountingDown, let session = captureSession else { return }
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
            if let conn = movieFileOutput?.connection(with: .video), conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = (newPosition == .front)
            }
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
            print("Zoom error: \(error)")
        }
    }

    // MARK: - Permission-Gated Voice Command Setup: "Action", "Cut", "How do I look?"

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
            #if !targetEnvironment(simulator)
            self.setupCameraSession()
            #endif
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

            if !isAudioTapInstalled {
                inputNode.removeTap(onBus: 0)
                inputNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] readOnlyBuffer, _ in
                    guard let self = self else { return }

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

                    self.latestRMS = rms
                    self.recognitionRequest?.append(readOnlyBuffer)

                    let currentTranscript = self.latestTranscript
                    DispatchQueue.main.async { [weak self] in
                        self?.onLiveMicData?(rms, currentTranscript, false)
                    }
                }
                isAudioTapInstalled = true
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
        activeRecognitionTaskID = nil
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        latestTranscript = ""

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
                    self.latestTranscript = transcript
                    self.handleRecognizedTranscript(transcript, isFinal: isFinal)
                }

                if isFinal {
                    self.restartRecognitionTaskSeamlessly()
                }
            }

            if error != nil {
                // A recognition request naturally ends or is rolled over every
                // so often. Keep the UI stable while its replacement starts.
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
        latestTranscript = ""

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, self.isSessionRunning else { return }
            self.isRestartingRecognition = false
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
    }

    // MARK: - Single Transcript Entry Point

    /// `SFSpeechRecognizer` partial and final results, Simulator injections, and
    /// XCTest all reach commands and cue ingestion through this one method.
    @MainActor
    func handleRecognizedTranscript(_ transcript: String, isFinal: Bool) {
        guard !(shouldIgnoreRecognizedTranscript?() ?? false) else { return }
        onLiveMicData?(latestRMS, transcript, isFinal)
        voiceCommandController.handleRecognizedTranscript(transcript, isFinal: isFinal)
    }

    private func stopVoiceCommands() {
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
            speechAudioEngine.inputNode.removeTap(onBus: 0)
            isAudioTapInstalled = false
        }
        if speechAudioEngine.isRunning {
            speechAudioEngine.stop()
        }
    }

    private func observeAudioSessionChanges() {
        let center = NotificationCenter.default
        audioSessionObservers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, self.isSessionRunning else { return }
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            if type == .began {
                self.isVoiceListening = false
                self.voiceStatus = .interrupted
            } else {
                self.restartRecognitionTaskSeamlessly()
            }
        })
        audioSessionObservers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.restartRecognitionTaskSeamlessly()
        })
        audioSessionObservers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.isAudioTapInstalled = false
            self.speechAudioEngine.reset()
            self.isVoiceListening = false
            self.restartVoicePipeline()
        })
    }

    private func restartVoicePipeline() {
        guard isSessionRunning else { return }
        isRestartingRecognition = false
        stopVoiceCommands()
        if isSessionRunning {
            voiceStatus = .starting
            startVoiceListening()
        }
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
        guard !isRecording, !isCountingDown else { return }
        isCountingDown = true
        countdownRemaining = countdownSeconds
        recordCompletion = completion

        speakCountdownStep(seconds: countdownSeconds)
    }

    private func speakCountdownStep(seconds: Int) {
        guard seconds > 0 else {
            isCountingDown = false
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
            guard let self = self, self.isCountingDown else { return }
            self.speakCountdownStep(seconds: seconds - 1)
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
        isRecording = true
        recordingDurationSeconds = 0.0
        recordingStartTime = Date()
        startRecordingTimer()

        #if targetEnvironment(simulator)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("onetake_take_\(UUID().uuidString).mp4")
        self.outputFileURL = tempURL
        #else
        guard let output = movieFileOutput else {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("onetake_take_\(UUID().uuidString).mp4")
            self.outputFileURL = tempURL
            return
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("onetake_take_\(UUID().uuidString).mov")
        self.outputFileURL = tempURL
        output.startRecording(to: tempURL, recordingDelegate: self)
        #endif

        // Ensure voice recognition stays active throughout recording for "Cut" and "How do I look?"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self = self, self.isSessionRunning else { return }
            if !self.speechAudioEngine.isRunning {
                try? self.speechAudioEngine.start()
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        stopRecordingTimer()

        #if targetEnvironment(simulator)
        let duration = recordingDurationSeconds
        if let url = outputFileURL {
            createSimulatedVideoFile(at: url, durationSeconds: duration)
            finishRecording(url: url, duration: duration)
        }
        #else
        movieFileOutput?.stopRecording()
        #endif
    }

    private func startRecordingTimer() {
        recordTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let start = self.recordingStartTime else { return }
            self.recordingDurationSeconds = Date().timeIntervalSince(start)
        }
    }

    /// Delivers exactly one result on the main thread.  The former dual
    /// `recordCompletion`/`onTakeRecorded` design could recursively invoke its
    /// own callback when a recording began through the voice command.
    private func finishRecording(url: URL?, duration: Double) {
        let completion = recordCompletion
        recordCompletion = nil
        DispatchQueue.main.async {
            completion?(url, duration)
        }
    }

    private func stopRecordingTimer() {
        recordTimer?.invalidate()
        recordTimer = nil
    }

    private func createSimulatedVideoFile(at url: URL, durationSeconds: Double) {
        let dummyData = "ONETAKE_SIMULATED_VIDEO_DATA".data(using: .utf8) ?? Data()
        try? dummyData.write(to: url)
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension TeleprompterRecorderService: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        let duration = recordingDurationSeconds
        finishRecording(url: error == nil ? outputFileURL : nil, duration: duration)
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension TeleprompterRecorderService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !isAnalyzingFrame, !isRecording else { return }
        isAnalyzingFrame = true
        defer { isAnalyzingFrame = false }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let lumStatus = evaluateLuminance(of: pixelBuffer)
        let isLightOk = (lumStatus == "Good")

        let faceRequest = VNDetectFaceLandmarksRequest { [weak self] req, _ in
            guard let self = self, let results = req.results as? [VNFaceObservation], let face = results.first else {
                DispatchQueue.main.async {
                    self?.qualityMetrics.isAlignmentPassed = false
                    self?.qualityMetrics.isFramingEvaluated = true
                }
                return
            }
            let box = face.boundingBox
            let midX = box.midX
            let midY = box.midY
            let centered = (midX >= 0.30 && midX <= 0.70) && (midY >= 0.25 && midY <= 0.75)
            DispatchQueue.main.async {
                self.qualityMetrics.isAlignmentPassed = centered
                self.qualityMetrics.isFramingEvaluated = true
            }
        }

        let segRequest = VNGeneratePersonSegmentationRequest { [weak self] req, _ in
            guard let self = self,
                  let result = req.results?.first as? VNPixelBufferObservation else { return }
            let isPlain = self.evaluateBackgroundClutter(maskBuffer: result.pixelBuffer, frameBuffer: pixelBuffer)
            DispatchQueue.main.async {
                self.qualityMetrics.isBackgroundPassed = isPlain
                self.qualityMetrics.backgroundStatus = isPlain ? "Clean" : "Cluttered"
                self.qualityMetrics.isBackgroundEvaluated = true
                self.qualityMetrics.isLightPassed = isLightOk
                self.qualityMetrics.lightStatus = lumStatus
                self.qualityMetrics.isLightingEvaluated = true
            }
        }
        segRequest.qualityLevel = .fast

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .upMirrored, options: [:])
        try? handler.perform([faceRequest, segRequest])
    }

    private func evaluateLuminance(of pixelBuffer: CVPixelBuffer) -> String {
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

    private func evaluateBackgroundClutter(maskBuffer: CVPixelBuffer, frameBuffer: CVPixelBuffer) -> Bool {
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
