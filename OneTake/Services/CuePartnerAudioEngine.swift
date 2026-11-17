import Foundation
import AVFoundation
import Speech

// MARK: - Protocol

@MainActor
protocol CuePartnerAudioEngineProtocol: AnyObject {
    var isRecordingCue: Bool { get }
    var isCuePlaying: Bool { get }
    var isListening: Bool { get }
    var currentAudioLevel: Float { get }
    var currentCueIndex: Int { get }
    var cueVolume: Float { get set }

    func setupAudioSession()
    func requestRecordingPermission(_ completion: @escaping (Bool) -> Void)
    func startRecordingCue(orderIndex: Int) throws -> URL
    func stopRecordingCue() -> (url: URL?, durationSeconds: Double)
    func playCue(at url: URL, completion: (() -> Void)?)
    func stopPlayback()
    func startListening(cues: [CueLine], mode: CueTriggerMode, responseDelay: Double, cueVolume: Double?)
    func stopListening()
    func ingestLiveMicInput(rms: Float, transcript: String, isFinal: Bool)
    func startAuditionScenePartner(
        cues: [CueLine],
        mode: CueTriggerMode,
        responseDelay: Double,
        cueVolume: Double?,
        onCueTriggered: @escaping (Int) -> Void
    )
    func stopAuditionScenePartner()
}

extension CuePartnerAudioEngineProtocol {
    func startListening(cues: [CueLine], mode: CueTriggerMode, responseDelay: Double) {
        startListening(cues: cues, mode: mode, responseDelay: responseDelay, cueVolume: nil)
    }

    func startAuditionScenePartner(
        cues: [CueLine],
        mode: CueTriggerMode,
        responseDelay: Double,
        onCueTriggered: @escaping (Int) -> Void
    ) {
        startAuditionScenePartner(
            cues: cues,
            mode: mode,
            responseDelay: responseDelay,
            cueVolume: nil,
            onCueTriggered: onCueTriggered
        )
    }
}

// MARK: - Implementation

@MainActor
@Observable
final class CuePartnerAudioEngine: NSObject, CuePartnerAudioEngineProtocol {
    static let shared = CuePartnerAudioEngine()

    var isRecordingCue: Bool = false
    var isCuePlaying: Bool = false
    var isListening: Bool = false
    var currentAudioLevel: Float = 0.0
    var currentCueIndex: Int = 0
    var cueVolume: Float = 1.0 {
        didSet {
            let clamped = Self.clampedVolume(cueVolume)
            if cueVolume != clamped {
                cueVolume = clamped
            }
            audioPlayer?.volume = clamped
            activeCuePlayer?.volume = clamped
        }
    }

    private static func clampedVolume(_ value: Float) -> Float {
        guard value.isFinite else { return 1.0 }
        return max(0.0, min(1.0, value))
    }

    // Recording & Playback
    @ObservationIgnored private var audioRecorder: AVAudioRecorder?
    @ObservationIgnored private var audioPlayer: AVAudioPlayer?
    @ObservationIgnored private var activeCuePlayer: AVAudioPlayer?
    @ObservationIgnored private var recordingStartTime: Date?
    @ObservationIgnored private var activeRecordingURL: URL?
    @ObservationIgnored private var playbackGeneration: Int = 0
    @ObservationIgnored private var hasConfiguredAudioSession: Bool = false

    // Shared state
    @ObservationIgnored private var activeCues: [CueLine] = []
    @ObservationIgnored private var cueTriggerCallback: ((Int) -> Void)?
    @ObservationIgnored var onCueStarted: ((Int) -> Void)?
    @ObservationIgnored var onCueFinished: ((Int) -> Void)?
    @ObservationIgnored private var pendingPlaybackCompletion: (() -> Void)?
    @ObservationIgnored private var pendingManualCueIndex: Int?
    @ObservationIgnored private var ignoreMicUntil: Date = .distantPast
    @ObservationIgnored private var scriptCueCoordinator: ScriptSyncedCuePlaybackCoordinator?
    @ObservationIgnored private var meterTimer: Timer?

    // TTS Fallback
    @ObservationIgnored let fallbackSynthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private(set) var activeUtterance: AVSpeechUtterance?

    override init() {
        super.init()
        fallbackSynthesizer.delegate = self
    }

    // MARK: - Audio Session Configuration

    func setupAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            if !hasConfiguredAudioSession || session.category != .playAndRecord {
                try session.setCategory(
                    .playAndRecord,
                    mode: .default,
                    options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers]
                )
                try session.setActive(true)
                hasConfiguredAudioSession = true
            }
            routeToSpeakerIfNoExternalOutput(session)
        } catch {
            print("Failed to configure AVAudioSession: \(error)")
        }
    }

    nonisolated private func routeToSpeakerIfNoExternalOutput(_ session: AVAudioSession) {
        let externalOutputPorts: Set<AVAudioSession.Port> = [
            .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .headphones, .airPlay, .carAudio, .usbAudio
        ]
        let hasExternalOutput = session.currentRoute.outputs.contains { externalOutputPorts.contains($0.portType) }
        if !hasExternalOutput {
            try? session.overrideOutputAudioPort(.speaker)
        }
    }

    func requestRecordingPermission(_ completion: @escaping (Bool) -> Void) {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            completion(true)
        case .denied:
            completion(false)
        case .undetermined:
            AVAudioApplication.requestRecordPermission { granted in
                Task { @MainActor in
                    completion(granted)
                }
            }
        @unknown default:
            completion(false)
        }
    }

    // MARK: - Reader Cue Recording

    func startRecordingCue(orderIndex: Int) throws -> URL {
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw NSError(
                domain: "OneTake.Audio",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Microphone access is required to record a cue."]
            )
        }
        setupAudioSession()
        let cuesDir = MediaStorage.documentsDirectory.appendingPathComponent("Cues", isDirectory: true)
        try FileManager.default.createDirectory(at: cuesDir, withIntermediateDirectories: true)

        let fileURL = cuesDir.appendingPathComponent("cue_\(orderIndex)_\(UUID().uuidString).m4a")
        self.activeRecordingURL = fileURL

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true

        recorder.prepareToRecord()
        guard recorder.record() else {
            throw NSError(
                domain: "OneTake.Audio",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Unable to start cue recording."]
            )
        }
        self.audioRecorder = recorder
        self.isRecordingCue = true
        self.recordingStartTime = Date()
        self.startMeteringTimer()

        return fileURL
    }

    func stopRecordingCue() -> (url: URL?, durationSeconds: Double) {
        stopMeteringTimer()
        guard isRecordingCue, let recorder = audioRecorder else {
            return (nil, 0.0)
        }

        let duration = max(0.3, Date().timeIntervalSince(recordingStartTime ?? Date()))
        recorder.stop()
        isRecordingCue = false
        audioRecorder = nil

        let url = activeRecordingURL
        activeRecordingURL = nil
        return (url, duration)
    }

    private func startMeteringTimer() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, let recorder = self.audioRecorder, recorder.isRecording else { return }
                recorder.updateMeters()
                let power = recorder.averagePower(forChannel: 0)
                let normalized = max(0.0, min(1.0, (power + 60.0) / 60.0))
                self.currentAudioLevel = normalized
            }
        }
    }

    private func stopMeteringTimer() {
        meterTimer?.invalidate()
        meterTimer = nil
        currentAudioLevel = 0.0
    }

    // MARK: - Cue Playback

    func playCue(at url: URL, completion: (() -> Void)?) {
        stopPlayback()
        if let completion = completion {
            self.pendingPlaybackCompletion = completion
        }

        isCuePlaying = true
        ignoreMicUntil = .distantFuture
        let generation = playbackGeneration
        let targetVolume = cueVolume
        setupAudioSession()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.volume = targetVolume
                player.prepareToPlay()

                Task { @MainActor [weak self] in
                    guard let self, self.playbackGeneration == generation else { return }
                    player.delegate = self
                    player.volume = self.cueVolume
                    self.audioPlayer = player
                    if !player.play() {
                        self.isCuePlaying = false
                        self.ignoreMicUntil = Date().addingTimeInterval(0.4)
                        let done = self.pendingPlaybackCompletion
                        self.pendingPlaybackCompletion = nil
                        done?()
                    }
                }
            } catch {
                print("Failed to play cue line: \(error)")
                Task { @MainActor [weak self] in
                    guard let self, self.playbackGeneration == generation else { return }
                    self.isCuePlaying = false
                    self.ignoreMicUntil = Date().addingTimeInterval(0.4)
                    let done = self.pendingPlaybackCompletion
                    self.pendingPlaybackCompletion = nil
                    done?()
                }
            }
        }
    }

    func stopPlayback() {
        playbackGeneration += 1
        pendingManualCueIndex = nil
        audioPlayer?.stop()
        audioPlayer = nil
        activeCuePlayer?.stop()
        activeCuePlayer = nil
        if fallbackSynthesizer.isSpeaking {
            fallbackSynthesizer.stopSpeaking(at: .immediate)
        }
        activeUtterance = nil
        isCuePlaying = false
        pendingPlaybackCompletion = nil
        scriptCueCoordinator?.cuePlaybackDidFinish()
        if let coordinator = scriptCueCoordinator {
            currentCueIndex = coordinator.currentCueIndex
        }
    }

    // MARK: - Live Mic Stream Ingestion (Shared from TeleprompterRecorderService)

    func ingestLiveMicInput(rms: Float, transcript: String, isFinal: Bool) {
        currentAudioLevel = min(1.0, rms * 8.0)

        // Cue playback must never be interpreted as the next actor turn.
        guard isListening, !isCuePlaying, Date() >= ignoreMicUntil else {
            return
        }

        guard let coordinator = scriptCueCoordinator else { return }
        if coordinator.handleRecognizedTranscript(transcript, isFinal: isFinal) {
            // Lock immediately—even during the user-selected response delay—so
            // cue speaker audio cannot be read as "Cut", "Action", or line two.
            isCuePlaying = true
        }
    }

    // MARK: - Start and Stop Listening

    func startListening(
        cues: [CueLine],
        mode: CueTriggerMode = .afterMyLine,
        responseDelay: Double = 0,
        cueVolume: Double? = nil
    ) {
        if let cueVolume {
            self.cueVolume = Float(cueVolume)
        }
        stopPlayback()
        self.activeCues = cues.sorted { $0.orderIndex < $1.orderIndex }
        self.currentCueIndex = 0
        self.isListening = !self.activeCues.isEmpty
        self.isCuePlaying = false
        self.pendingManualCueIndex = nil
        self.ignoreMicUntil = .distantPast
        let effectiveDelay = (mode == .fixedDelay) ? max(0.0, responseDelay) : responseDelay
        self.scriptCueCoordinator = ScriptSyncedCuePlaybackCoordinator(
            cues: self.activeCues,
            responseDelay: effectiveDelay,
            onCueReady: { [weak self] index in
                guard let self else { return }
                let force = (self.pendingManualCueIndex == index)
                self.triggerCue(at: index, force: force)
            }
        )
    }

    func stopListening() {
        self.isListening = false
        stopPlayback()
        self.activeCues = []
        self.currentCueIndex = 0
        self.scriptCueCoordinator = nil
        self.pendingManualCueIndex = nil
        self.ignoreMicUntil = .distantPast
    }

    // MARK: - Audition Scene Partner

    func startAuditionScenePartner(
        cues: [CueLine],
        mode: CueTriggerMode = .afterMyLine,
        responseDelay: Double = 2.0,
        cueVolume: Double? = nil,
        onCueTriggered: @escaping (Int) -> Void
    ) {
        if let cueVolume {
            self.cueVolume = Float(cueVolume)
        }
        self.cueTriggerCallback = onCueTriggered
        startListening(cues: cues, mode: mode, responseDelay: responseDelay, cueVolume: cueVolume)
    }

    func stopAuditionScenePartner() {
        stopListening()
        cueTriggerCallback = nil
    }

    // MARK: - Manual & Teleprompter-Synced Cue Advance

    func playNextCue() {
        guard let coordinator = scriptCueCoordinator,
              let index = coordinator.requestManualCue() else { return }
        pendingManualCueIndex = index
    }

    func triggerCueFromTeleprompter(at index: Int) {
        guard isListening, !isCuePlaying, currentCueIndex == index,
              let coordinator = scriptCueCoordinator else { return }
        pendingManualCueIndex = index
        if coordinator.requestTeleprompterSyncedCue(at: index) {
            isCuePlaying = true
        } else {
            pendingManualCueIndex = nil
        }
    }

    /// Exposes coordinator lock state for diagnostics and unit tests.
    var isCoordinatorPlayingCue: Bool {
        scriptCueCoordinator?.isPlayingCue ?? false
    }

    // MARK: - Trigger Cue

    private func triggerCue(at index: Int, force: Bool = false) {
        pendingManualCueIndex = nil
        guard index < activeCues.count, currentCueIndex == index else {
            isCuePlaying = false
            scriptCueCoordinator?.cuePlaybackDidFinish()
            return
        }
        guard force || scriptCueCoordinator?.isPlayingCue == true else {
            isCuePlaying = false
            return
        }
        let cueToPlay = activeCues[index]
        guard force || !cueToPlay.precedingActorLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            isCuePlaying = false
            scriptCueCoordinator?.cuePlaybackDidFinish()
            return
        }

        // Block the shared microphone stream before starting output, not after a player is created.
        isCuePlaying = true
        ignoreMicUntil = .distantFuture
        cueTriggerCallback?(index)
        onCueStarted?(index)

        let generation = playbackGeneration
        let onDone: () -> Void = { [weak self] in
            guard let self = self else { return }
            self.isCuePlaying = false
            self.activeCuePlayer = nil
            self.activeUtterance = nil
            self.ignoreMicUntil = Date().addingTimeInterval(0.4)
            self.scriptCueCoordinator?.cuePlaybackDidFinish()
            self.currentCueIndex = self.scriptCueCoordinator?.currentCueIndex ?? (index + 1)
            if self.currentCueIndex >= self.activeCues.count {
                self.isListening = false
            }
            self.onCueFinished?(index)
        }

        if let audioURL = MediaStorage.resolveURL(for: cueToPlay.audioFilePath),
           FileManager.default.fileExists(atPath: audioURL.path) {
            VoiceAudioSessionCoordinator.shared.activate()
            routeToSpeakerIfNoExternalOutput(AVAudioSession.sharedInstance())
            let targetVolume = cueVolume
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    let player = try AVAudioPlayer(contentsOf: audioURL)
                    player.volume = targetVolume
                    player.prepareToPlay()

                    Task { @MainActor [weak self] in
                        guard let self, self.playbackGeneration == generation else { return }
                        player.delegate = self
                        player.volume = self.cueVolume
                        self.activeCuePlayer = player
                        self.pendingPlaybackCompletion = onDone
                        if !player.play() {
                            self.pendingPlaybackCompletion = nil
                            onDone()
                        }
                    }
                } catch {
                    print("triggerCue: AVAudioPlayer failed: \(error)")
                    Task { @MainActor [weak self] in
                        guard let self, self.playbackGeneration == generation else { return }
                        onDone()
                    }
                }
            }
        } else {
            speakFallbackCue(text: cueToPlay.cueText, completion: onDone)
        }
    }

    // MARK: - TTS Fallback

    private func speakFallbackCue(text: String, completion: @escaping () -> Void) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion()
            return
        }
        VoiceAudioSessionCoordinator.shared.activate()
        routeToSpeakerIfNoExternalOutput(AVAudioSession.sharedInstance())
        if fallbackSynthesizer.isSpeaking {
            activeUtterance = nil
            fallbackSynthesizer.stopSpeaking(at: .immediate)
        }
        isCuePlaying = true
        pendingPlaybackCompletion = completion
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.volume = cueVolume
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        activeUtterance = utterance
        fallbackSynthesizer.speak(utterance)
    }

    // MARK: - Delegate Handlers

    private func handleAudioRecorderFinished() {
        isRecordingCue = false
    }

    private func handleAudioPlayerFinished() {
        isCuePlaying = false
        let completion = pendingPlaybackCompletion
        pendingPlaybackCompletion = nil
        completion?()
    }

    private func handleSpeechDidFinish(synthesizer: AVSpeechSynthesizer, utterance: AVSpeechUtterance) {
        guard synthesizer === fallbackSynthesizer else { return }
        if let active = activeUtterance, active !== utterance { return }
        activeUtterance = nil
        isCuePlaying = false
        let completion = pendingPlaybackCompletion
        pendingPlaybackCompletion = nil
        completion?()
    }

    private func handleSpeechDidCancel(synthesizer: AVSpeechSynthesizer, utterance: AVSpeechUtterance) {
        guard synthesizer === fallbackSynthesizer else { return }
        if let active = activeUtterance, active !== utterance { return }
        activeUtterance = nil
        isCuePlaying = false
        pendingPlaybackCompletion = nil
        ignoreMicUntil = Date().addingTimeInterval(0.4)
        scriptCueCoordinator?.cuePlaybackDidFinish()
        if let coordinator = scriptCueCoordinator {
            currentCueIndex = coordinator.currentCueIndex
            if currentCueIndex >= activeCues.count {
                isListening = false
            }
        }
    }
}

// MARK: - AVAudioRecorderDelegate

extension CuePartnerAudioEngine: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { handleAudioRecorderFinished() }
        } else {
            Task { @MainActor [weak self] in self?.handleAudioRecorderFinished() }
        }
    }
}

// MARK: - AVAudioPlayerDelegate

extension CuePartnerAudioEngine: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { handleAudioPlayerFinished() }
        } else {
            Task { @MainActor [weak self] in self?.handleAudioPlayerFinished() }
        }
    }
}

// MARK: - AVSpeechSynthesizerDelegate

nonisolated private struct UncheckedSpeechBox<Value>: @unchecked Sendable {
    let value: Value
}

extension CuePartnerAudioEngine: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { handleSpeechDidFinish(synthesizer: synthesizer, utterance: utterance) }
        } else {
            let synthBox = UncheckedSpeechBox(value: synthesizer)
            let uttBox = UncheckedSpeechBox(value: utterance)
            Task { @MainActor [weak self] in
                self?.handleSpeechDidFinish(synthesizer: synthBox.value, utterance: uttBox.value)
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { handleSpeechDidCancel(synthesizer: synthesizer, utterance: utterance) }
        } else {
            let synthBox = UncheckedSpeechBox(value: synthesizer)
            let uttBox = UncheckedSpeechBox(value: utterance)
            Task { @MainActor [weak self] in
                self?.handleSpeechDidCancel(synthesizer: synthBox.value, utterance: uttBox.value)
            }
        }
    }
}
