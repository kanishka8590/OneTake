import Foundation
import AVFoundation
import Speech
import Observation

/// Captures the spoken run and recognizer timings together. Both Speech.framework
/// and the Simulator feed the same cumulative word segments through
/// `processRecognizedSpeech(segments:)`.
@Observable
final class PracticeSpeechRecorder: NSObject, SFSpeechRecognizerDelegate {
    var isRecording = false
    var transcript = ""
    var recognizedWords: [RecognizedPracticeWord] = []
    var audioLevel: CGFloat = 0.12
    var duration: Double = 0
    var pauseDurations: [Double] = []
    var statusText = "Tap Start when you’re ready"
    private(set) var recordedAudioURL: URL?

    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var audioFile: AVAudioFile?
    private var durationTimer: Timer?
    private var simulatedTimer: Timer?
    private var pausedAt: Date?
    private var activeScript: PracticeScript?
    private var simulatedSegments: [RecognizedPracticeWord] = []
    private var simulatedEmissionIndex = 0

    func start(language: ScriptLanguage, script: PracticeScript) {
        resetRun()
        activeScript = script
        VoiceAuthorizationService.shared.requestAccess { [weak self] allowed in
            guard let self else { return }
            allowed ? self.startRecognizer(language: language) : self.startSimulation()
        }
    }

    func pause() {
        guard isRecording else { return }
        pausedAt = .now
        audioEngine.pause()
        simulatedTimer?.invalidate()
        isRecording = false
        statusText = "Paused"
    }

    func resume() {
        guard !isRecording else { return }
        if let pausedAt { pauseDurations.append(Date().timeIntervalSince(pausedAt)); self.pausedAt = nil }
        if request != nil {
            do { try audioEngine.start(); isRecording = true; statusText = "Listening" } catch { startSimulation() }
        } else { startSimulation(continuing: true) }
    }

    func stop() {
        durationTimer?.invalidate(); durationTimer = nil
        simulatedTimer?.invalidate(); simulatedTimer = nil
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio(); request = nil
        task?.cancel(); task = nil
        audioFile = nil
        isRecording = false
        audioLevel = 0.12
    }

    private func resetRun() {
        stop()
        transcript = ""; recognizedWords = []; duration = 0; pauseDurations = []
        recordedAudioURL = nil; statusText = "Preparing microphone…"
    }

    private func startRecognizer(language: ScriptLanguage) {
        let locale = Locale(identifier: language == .hindi ? "hi-IN" : "en-IN")
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else { startSimulation(); return }
        let session = AVAudioSession.sharedInstance()
        do {
            // allowBluetoothHFP is the current SDK name for the Bluetooth
            // hands-free input route (formerly `allowBluetooth`).
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
        } catch {
            startSimulation()
            return
        }
        let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest.shouldReportPartialResults = true
        request = recognitionRequest
        task = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let segments = result.bestTranscription.segments.map {
                    RecognizedPracticeWord(text: $0.substring, timestamp: $0.timestamp, duration: $0.duration)
                }
                DispatchQueue.main.async {
                    self.processRecognizedSpeech(segments: segments)
                }
            }
            if error != nil { DispatchQueue.main.async { self.statusText = "Speech recognition paused — recording is still available" } }
        }

        let node = audioEngine.inputNode
        let inputFormat = node.inputFormat(forBus: 0)
        let outputFormat = node.outputFormat(forBus: 0)
        guard let tapFormat = [inputFormat, outputFormat].first(where: { $0.sampleRate > 0 && $0.channelCount > 0 }) else {
            startSimulation()
            return
        }
        do {
            let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("PracticeRecordings", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("Practice_\(UUID().uuidString).wav")
            audioFile = try AVAudioFile(forWriting: url, settings: tapFormat.settings)
            recordedAudioURL = url
        } catch { recordedAudioURL = nil }
        node.removeTap(onBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] buffer, _ in
            recognitionRequest.append(buffer)
            try? self?.audioFile?.write(from: buffer)
            let level = Self.rms(buffer)
            DispatchQueue.main.async { self?.audioLevel = level }
        }
        do {
            audioEngine.prepare(); try audioEngine.start()
            isRecording = true; statusText = "Listening"; startDurationTimer()
        } catch { startSimulation() }
    }

    /// Receives cumulative SFSpeechRecognizer-equivalent word segments. This is
    /// intentionally the sole transcript/word update path for device and Simulator.
    func processRecognizedSpeech(segments: [RecognizedPracticeWord]) {
        recognizedWords = segments
        transcript = segments.map(\.text).joined(separator: " ")
        pauseDurations = PracticeSpeechDeliveryAnalyzer.hesitationGaps(in: segments)
    }

    private func startSimulation(continuing: Bool = false) {
        if !continuing {
            stop()
            statusText = "Listening (simulated in Simulator)"
            simulatedEmissionIndex = 0
            simulatedSegments = Self.simulationSegments(for: activeScript)
            startDurationTimer()
        }
        isRecording = true
        simulatedTimer?.invalidate()
        simulatedTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] timer in
            guard let self, self.isRecording else { return }
            guard self.simulatedEmissionIndex < self.simulatedSegments.count else { timer.invalidate(); return }
            self.simulatedEmissionIndex += 1
            self.processRecognizedSpeech(segments: Array(self.simulatedSegments.prefix(self.simulatedEmissionIndex)))
            self.audioLevel = CGFloat.random(in: 0.18...0.8)
        }
    }

    private func startDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.duration += 0.1 }
    }

    private static func simulationSegments(for script: PracticeScript?) -> [RecognizedPracticeWord] {
        guard let script else {
            return [RecognizedPracticeWord(text: "Simulator", timestamp: 0, duration: 0.18)]
        }
        let model = PracticeScriptModel(script: script)
        let actorTokens = model.actorTokens
        guard !actorTokens.isEmpty else { return [] }
        // Omit a short phrase only from the final actor sentence. Earlier actor
        // sentences remain complete, so Simulator users can watch the next-clue
        // progression move over real actor lines (and CUE lines) first.
        let finalLineID = model.actorLines.last?.id
        let finalLineIndexes = actorTokens.indices.filter { actorTokens[$0].lineID == finalLineID }
        let phraseLength = min(2, max(1, finalLineIndexes.count / 3))
        let omissionStart = finalLineIndexes.dropFirst(max(1, finalLineIndexes.count / 3)).first
        let omittedIndexes = omissionStart.map { Set($0..<min($0 + phraseLength, actorTokens.count)) } ?? []
        // Add a 2.0s delivery gap and an improvised phrase. The shared analyzer
        // classifies all three characteristics without Simulator-only feedback.
        let insertionIndex = min(actorTokens.count, max(1, actorTokens.count / 2))
        var timestamp = 0.0
        var output: [RecognizedPracticeWord] = []
        for (index, token) in actorTokens.enumerated() {
            if index == insertionIndex { timestamp += 2.0 }
            guard !omittedIndexes.contains(index) else { continue }
            output.append(RecognizedPracticeWord(text: token.word, timestamp: timestamp, duration: 0.18))
            timestamp += 0.28
        }
        for word in ["absolutely", "today"] {
            output.append(RecognizedPracticeWord(text: word, timestamp: timestamp, duration: 0.18))
            timestamp += 0.28
        }
        return output
    }
    private static func rms(_ buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let data = buffer.floatChannelData?.pointee else { return 0.12 }
        let count = Int(buffer.frameLength); guard count > 0 else { return 0.12 }
        var sum: Float = 0
        for i in 0..<count { sum += data[i] * data[i] }
        return min(1, max(0.08, CGFloat(sqrt(sum / Float(count)) * 8)))
    }
}
