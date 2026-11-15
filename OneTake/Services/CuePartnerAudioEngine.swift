import Foundation
import AVFoundation
import Speech

// MARK: - Protocol

protocol CuePartnerAudioEngineProtocol: AnyObject {
    var isRecordingCue: Bool { get }
    var isCuePlaying: Bool { get }
    var isListening: Bool { get }
    var currentAudioLevel: Float { get }
    var currentCueIndex: Int { get }

    func setupAudioSession()
    func requestRecordingPermission(_ completion: @escaping (Bool) -> Void)
    func startRecordingCue(orderIndex: Int) throws -> URL
    func stopRecordingCue() -> (url: URL?, durationSeconds: Double)
    func playCue(at url: URL, completion: (() -> Void)?)
    func stopPlayback()
    func startListening(cues: [CueLine], mode: CueTriggerMode, responseDelay: Double)
    func stopListening()
    @MainActor func ingestLiveMicInput(rms: Float, transcript: String, isFinal: Bool)
    func startAuditionScenePartner(cues: [CueLine], onCueTriggered: @escaping (Int) -> Void)
    func stopAuditionScenePartner()
}

// MARK: - Implementation

@Observable
final class CuePartnerAudioEngine: NSObject, CuePartnerAudioEngineProtocol, @unchecked Sendable {
    static let shared = CuePartnerAudioEngine()

    var isRecordingCue: Bool = false
    var isCuePlaying: Bool = false
    var isListening: Bool = false
    var currentAudioLevel: Float = 0.0
    var currentCueIndex: Int = 0

    // Recording & Playback
    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    private var activeCuePlayer: AVAudioPlayer?
    private var recordingStartTime: Date?
    private var activeRecordingURL: URL?

    // Shared state
    private var activeCues: [CueLine] = []
    private var cueTriggerCallback: ((Int) -> Void)?
    private var pendingCueWorkItem: DispatchWorkItem?
    private var pendingPlaybackCompletion: (() -> Void)?

    // Speech & RMS state (driven by TeleprompterRecorderService's single mic stream)
    private var currentListeningForCueIndex: Int = 0
    private var lineMatchDebounceWorkItem: DispatchWorkItem?
    private var lineSpeechDuration: TimeInterval = 0.0
    private var lineSilenceDuration: TimeInterval = 0.0
    private var lineHasDetectedSpeech: Bool = false
    private var lineHasTranscriptEvidence: Bool = false
    private var lineRMSTriggered: Bool = false
    private var lastMicInputTimestamp: Date?
    private var ignoreMicUntil: Date = .distantPast
    private var baselineTranscriptForCurrentTurn: String = ""
    private var currentCueTimingMode: CueTriggerMode = .afterMyLine
    private var scriptCueCoordinator: ScriptSyncedCuePlaybackCoordinator?

    private var meterTimer: Timer?

    override init() {
        super.init()
        fallbackSynthesizer.delegate = self
    }

    // MARK: - Audio Session Configuration

    func setupAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
        } catch {
            print("Failed to configure AVAudioSession: \(error)")
        }
    }

    func requestRecordingPermission(_ completion: @escaping (Bool) -> Void) {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            completion(true)
        case .denied:
            completion(false)
        case .undetermined:
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    DispatchQueue.main.async { completion(granted) }
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    DispatchQueue.main.async { completion(granted) }
                }
            }
        @unknown default:
            completion(false)
        }
    }

    // MARK: - Reader Cue Recording

    func startRecordingCue(orderIndex: Int) throws -> URL {
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw NSError(domain: "OneTake.Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone access is required to record a cue."])
        }
        setupAudioSession()
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let cuesDir = docsDir.appendingPathComponent("Cues", isDirectory: true)
        try? FileManager.default.createDirectory(at: cuesDir, withIntermediateDirectories: true)

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
            throw NSError(domain: "OneTake.Audio", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unable to start cue recording."])
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
            guard let self = self, let recorder = self.audioRecorder, recorder.isRecording else { return }
            recorder.updateMeters()
            let power = recorder.averagePower(forChannel: 0)
            let normalized = max(0.0, min(1.0, (power + 60.0) / 60.0))
            self.currentAudioLevel = normalized
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
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .allowBluetoothHFP])
                try session.setActive(true)
                try session.overrideOutputAudioPort(.speaker)
            } catch {
                print("playCue: AVAudioSession setup failed: \(error)")
            }

            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.volume = 1.0
                player.prepareToPlay()

                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    player.delegate = self
                    self.audioPlayer = player
                    player.play()
                }
            } catch {
                print("Failed to play cue line: \(error)")
                DispatchQueue.main.async { [weak self] in
                    self?.isCuePlaying = false
                    self?.ignoreMicUntil = Date().addingTimeInterval(0.6)
                    self?.pendingPlaybackCompletion?()
                    self?.pendingPlaybackCompletion = nil
                }
            }
        }
    }

    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        activeCuePlayer?.stop()
        activeCuePlayer = nil
        if fallbackSynthesizer.isSpeaking {
            fallbackSynthesizer.stopSpeaking(at: .immediate)
        }
        isCuePlaying = false
        pendingPlaybackCompletion = nil
    }

    // MARK: - Live Mic Stream Ingestion (Shared from TeleprompterRecorderService)

    @MainActor
    func ingestLiveMicInput(rms: Float, transcript: String, isFinal: Bool) {
        currentAudioLevel = min(1.0, rms * 8.0)

        // Cue playback must never be interpreted as the next actor turn.
        guard isListening, !isCuePlaying, Date() >= ignoreMicUntil else {
            resetTurnSpeechState()
            baselineTranscriptForCurrentTurn = transcript
            return
        }

        guard let coordinator = scriptCueCoordinator else { return }
        if coordinator.handleRecognizedTranscript(transcript, isFinal: isFinal) {
            // Lock immediately—even during the user-selected response delay—so
            // cue speaker audio cannot be read as "Cut", "Action", or line two.
            isCuePlaying = true
        }
    }

    @MainActor
    private func processLiveMicRMS(rms: Float, hasCredibleWords: Bool) {
        let now = Date()
        let dt: TimeInterval = lastMicInputTimestamp.map { min(0.2, now.timeIntervalSince($0)) } ?? 0.03
        lastMicInputTimestamp = now

        let micSpeechThreshold: Float = 0.045
        let requiredSpeechDuration: TimeInterval = 0.75
        let requiredSilenceDuration: TimeInterval = 1.7

        if rms > micSpeechThreshold {
            // Actor is actively speaking: reset silence timer & cancel any premature scheduled cue
            lineSpeechDuration += dt
            lineSilenceDuration = 0.0
            lineMatchDebounceWorkItem?.cancel()
            lineMatchDebounceWorkItem = nil

            if lineSpeechDuration >= requiredSpeechDuration && (hasCredibleWords || lineHasTranscriptEvidence) {
                lineHasDetectedSpeech = true
            }
        } else if lineHasDetectedSpeech {
            // Only a real actor turn followed by sustained silence can advance the scene.
            lineSilenceDuration += dt
            if lineSilenceDuration >= requiredSilenceDuration && !lineRMSTriggered {
                lineRMSTriggered = true
                triggerCue(at: currentListeningForCueIndex)
            }
        } else {
            // Transient ambient noise below 0.45s: decay back to 0
            lineSpeechDuration = max(0.0, lineSpeechDuration - dt)
        }
    }

    private func resetTurnSpeechState() {
        lineSpeechDuration = 0.0
        lineSilenceDuration = 0.0
        lineHasDetectedSpeech = false
        lineHasTranscriptEvidence = false
        lineRMSTriggered = false
        lastMicInputTimestamp = nil
        lineMatchDebounceWorkItem?.cancel()
        lineMatchDebounceWorkItem = nil
    }

    // MARK: - Start and Stop Listening

    func startListening(cues: [CueLine], mode: CueTriggerMode = .afterMyLine, responseDelay: Double = 0) {
        self.activeCues = cues.sorted { $0.orderIndex < $1.orderIndex }
        self.currentCueIndex = 0
        self.currentListeningForCueIndex = 0
        self.currentCueTimingMode = mode
        self.isListening = true
        self.isCuePlaying = false
        self.baselineTranscriptForCurrentTurn = ""
        self.pendingCueWorkItem?.cancel()
        self.pendingCueWorkItem = nil
        self.scriptCueCoordinator = ScriptSyncedCuePlaybackCoordinator(
            cues: self.activeCues,
            responseDelay: responseDelay,
            onCueReady: { [weak self] index in self?.triggerCue(at: index) }
        )
        resetTurnSpeechState()
    }

    func stopListening() {
        self.isListening = false
        self.pendingCueWorkItem?.cancel()
        self.pendingCueWorkItem = nil
        stopPlayback()
        self.activeCues = []
        self.currentCueIndex = 0
        self.currentListeningForCueIndex = 0
        self.scriptCueCoordinator = nil
        self.baselineTranscriptForCurrentTurn = ""
        resetTurnSpeechState()
    }

    // MARK: - Audition Scene Partner

    func startAuditionScenePartner(cues: [CueLine], onCueTriggered: @escaping (Int) -> Void) {
        self.cueTriggerCallback = onCueTriggered
        let settings = AppSettings()
        startListening(cues: cues, mode: settings.cueTriggerMode, responseDelay: settings.cueDelaySeconds)
    }

    func stopAuditionScenePartner() {
        stopListening()
        cueTriggerCallback = nil
    }

    /// Fuzzy match: lowercased contains, or word overlap >= 60%
    private func textSimilar(_ transcript: String, to target: String) -> Bool {
        let t = transcript.lowercased()
        let g = target.lowercased()
        if g.isEmpty { return false }
        if t.contains(g) { return true }
        let targetWords = Set(g.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
        let transcriptWords = Set(t.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
        guard !targetWords.isEmpty else { return false }
        let overlap = targetWords.intersection(transcriptWords).count
        return Double(overlap) / Double(targetWords.count) >= 0.6
    }

    // MARK: - Manual Cue Advance

    func playNextCue() {
        guard let coordinator = scriptCueCoordinator,
              coordinator.requestManualCue() != nil else { return }
        pendingCueWorkItem?.cancel()
        pendingCueWorkItem = nil
        isCuePlaying = true
    }

    // MARK: - Trigger Cue

    private func triggerCue(at index: Int, force: Bool = false) {
        guard index < activeCues.count, currentCueIndex == index else { return }
        guard force || scriptCueCoordinator?.isPlayingCue == true else { return }
        let cueToPlay = activeCues[index]
        guard force || !cueToPlay.precedingActorLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Block the shared microphone stream before starting output, not after a player is created.
        isCuePlaying = true
        ignoreMicUntil = .distantFuture
        pendingCueWorkItem?.cancel()
        pendingCueWorkItem = nil
        resetTurnSpeechState()

        cueTriggerCallback?(index)

        let onDone: () -> Void = { [weak self] in
            guard let self = self else { return }
            self.isCuePlaying = false
            self.activeCuePlayer = nil
            self.ignoreMicUntil = Date().addingTimeInterval(0.4)
            self.resetTurnSpeechState()
            self.scriptCueCoordinator?.cuePlaybackDidFinish()
            self.currentCueIndex = self.scriptCueCoordinator?.currentCueIndex ?? (index + 1)
            self.currentListeningForCueIndex = self.currentCueIndex
            if self.currentCueIndex >= self.activeCues.count {
                self.isListening = false
            }
        }

        if let audioPath = cueToPlay.audioFilePath, !audioPath.isEmpty,
           FileManager.default.fileExists(atPath: audioPath) {
            let url = URL(fileURLWithPath: audioPath)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let session = AVAudioSession.sharedInstance()
                do {
                    try session.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .allowBluetoothHFP])
                    try session.setActive(true)
                    try session.overrideOutputAudioPort(.speaker)
                } catch {
                    print("triggerCue: AVAudioSession setup failed: \(error)")
                }

                do {
                    let player = try AVAudioPlayer(contentsOf: url)
                    player.volume = 1.0
                    player.prepareToPlay()

                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        player.delegate = self
                        self.activeCuePlayer = player
                        self.pendingPlaybackCompletion = { onDone() }
                        player.play()
                    }
                } catch {
                    print("triggerCue: AVAudioPlayer failed: \(error)")
                    DispatchQueue.main.async { [weak self] in
                        self?.isCuePlaying = false
                        onDone()
                    }
                }
            }
        } else {
            speakFallbackCue(text: cueToPlay.cueText) { onDone() }
        }
    }

    // MARK: - TTS Fallback

    private let fallbackSynthesizer = AVSpeechSynthesizer()

    private func speakFallbackCue(text: String, completion: @escaping () -> Void) {
        isCuePlaying = true
        pendingPlaybackCompletion = completion
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        fallbackSynthesizer.speak(utterance)
    }
}

// MARK: - AVAudioRecorderDelegate

extension CuePartnerAudioEngine: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        isRecordingCue = false
    }
}

// MARK: - AVAudioPlayerDelegate

extension CuePartnerAudioEngine: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isCuePlaying = false
        pendingPlaybackCompletion?()
        pendingPlaybackCompletion = nil
    }
}

extension CuePartnerAudioEngine: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard synthesizer === fallbackSynthesizer else { return }
        isCuePlaying = false
        pendingPlaybackCompletion?()
        pendingPlaybackCompletion = nil
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        guard synthesizer === fallbackSynthesizer else { return }
        isCuePlaying = false
        pendingPlaybackCompletion = nil
    }
}
