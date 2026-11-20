import Foundation
import AVFoundation
import Speech
import Observation

/// Thread-safe bridge for the real-time audio render tap so `PracticeSpeechRecorder`
/// stays cleanly `@MainActor` without data races.
private nonisolated final class PracticeAudioTapState: @unchecked Sendable {
    private let lock = NSLock()
    private var _request: SFSpeechAudioBufferRecognitionRequest?
    private var _audioFile: AVAudioFile?
    private var _converter: AVAudioConverter?
    private var _writeFormat: AVAudioFormat?

    func setRequest(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        _request = request
        lock.unlock()
    }

    func setAudioFile(
        _ audioFile: AVAudioFile?,
        converter: AVAudioConverter?,
        writeFormat: AVAudioFormat?
    ) {
        lock.lock()
        _audioFile = audioFile
        _converter = converter
        _writeFormat = writeFormat
        lock.unlock()
    }

    func processBuffer(_ buffer: AVAudioPCMBuffer) -> CGFloat {
        lock.lock()
        let request = _request
        let audioFile = _audioFile
        let converter = _converter
        let writeFormat = _writeFormat
        lock.unlock()

        request?.append(buffer)

        var bufferForFileAndLevel = buffer
        if let converter, let writeFormat,
           let converted = Self.convert(buffer, using: converter, to: writeFormat) {
            bufferForFileAndLevel = converted
        }

        if let audioFile {
            try? audioFile.write(from: bufferForFileAndLevel)
        }
        return Self.rms(bufferForFileAndLevel)
    }

    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / max(1, buffer.format.sampleRate)
        let capacity = max(1, AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }

        final class InputBox: @unchecked Sendable {
            var consumed = false
            let buffer: AVAudioPCMBuffer
            init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        }
        let box = InputBox(buffer)
        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if box.consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            box.consumed = true
            outStatus.pointee = .haveData
            return box.buffer
        }
        if error != nil || outputBuffer.frameLength == 0 {
            return nil
        }
        return outputBuffer
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let data = buffer.floatChannelData?.pointee else { return 0.12 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0.12 }
        var sum: Float = 0
        for i in 0..<count {
            sum += data[i] * data[i]
        }
        return min(1, max(0.08, CGFloat(sqrt(sum / Float(count)) * 8)))
    }
}

/// Captures the spoken run and recognizer timings together. Both Speech.framework
/// and the Simulator feed the same cumulative word segments through
/// `processRecognizedSpeech(segments:)`.
@MainActor
@Observable
final class PracticeSpeechRecorder: NSObject, SFSpeechRecognizerDelegate {
    typealias AccessRequester = (@escaping (Bool) -> Void) -> Void

    var isRecording = false {
        didSet {
            Haptics.setMicCaptureActive(isRecording, source: "practice")
        }
    }
    var transcript = ""
    var recognizedWords: [RecognizedPracticeWord] = []
    var audioLevel: CGFloat = 0.12
    var duration: Double = 0
    var pauseDurations: [Double] = []
    var statusText = "Tap Start when you’re ready"
    var permissionDenied = false
    var errorMessage: String?
    private(set) var recordedAudioURL: URL?

    var recordedAudioRelativePath: String? {
        recordedAudioURL.map { MediaStorage.storedRelativePath(for: $0.path) }
    }

    @ObservationIgnored private let audioEngine = AVAudioEngine()
    @ObservationIgnored private let tapState = PracticeAudioTapState()
    @ObservationIgnored private let requestAccess: AccessRequester?
    @ObservationIgnored private var speechRecognizer: SFSpeechRecognizer?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var activeTaskID: UUID?
    @ObservationIgnored private var activeSessionToken: UUID?
    @ObservationIgnored private var audioFile: AVAudioFile?
    @ObservationIgnored private var durationTimer: Timer?
    @ObservationIgnored private var simulatedTimer: Timer?
    @ObservationIgnored private var taskRestartTimer: Timer?
    @ObservationIgnored private var stopFinalizeWorkItem: DispatchWorkItem?
    @ObservationIgnored private var pausedAt: Date?
    @ObservationIgnored private var activeSegmentStartedAt: Date?
    @ObservationIgnored private var accumulatedDuration: Double = 0
    @ObservationIgnored private var activeScript: PracticeScript?
    @ObservationIgnored private var activeContextualVocabulary: [String] = []
    @ObservationIgnored private var activeLanguage: ScriptLanguage = .english
    @ObservationIgnored private var activeIsDemoMode = false
    @ObservationIgnored private var isSimulationRun = false
    @ObservationIgnored private var hasAudioTap = false
    @ObservationIgnored private var committedWords: [RecognizedPracticeWord] = []
    @ObservationIgnored private var currentEpochWords: [RecognizedPracticeWord] = []
    @ObservationIgnored private var epochTimeOffset: Double = 0
    @ObservationIgnored private var simulatedSegments: [RecognizedPracticeWord] = []
    @ObservationIgnored private var simulatedEmissionIndex = 0
    @ObservationIgnored private var sessionObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var liveTaskFinalizationContinuations: [CheckedContinuation<Void, Never>] = []

    struct FinalizedPracticeCapture: Sendable {
        let transcript: String
        let words: [RecognizedPracticeWord]
        let silenceIntervals: [PracticeSilenceInterval]
        let duration: Double
        let audioURL: URL?
    }

    init(requestAccess: AccessRequester? = nil) {
        self.requestAccess = requestAccess
        super.init()
        observeAudioSessionNotifications()
    }

    deinit {
        for observer in sessionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func start(language: ScriptLanguage, script: PracticeScript, isDemoMode: Bool = false) {
        reset()
        activeScript = script
        activeContextualVocabulary = PracticeScriptModel(script: script).contextualVocabulary
        activeLanguage = language
        activeIsDemoMode = isDemoMode
        statusText = "Preparing microphone…"

        let token = UUID()
        activeSessionToken = token

        let onAccessResult: (Bool) -> Void = { [weak self] allowed in
            let handle: @MainActor () -> Void = {
                guard let self, self.activeSessionToken == token else { return }
                if allowed {
                    self.startRecognizer(language: language)
                } else if isDemoMode {
                    self.startSimulation()
                } else {
                    self.activeSessionToken = nil
                    self.permissionDenied = true
                    self.errorMessage = "Microphone and speech recognition access are required to practice aloud."
                    self.statusText = "Microphone or speech access denied"
                    self.isRecording = false
                }
            }
            if Thread.isMainThread {
                MainActor.assumeIsolated(handle)
            } else {
                Task { @MainActor in handle() }
            }
        }

        if let requestAccess {
            requestAccess(onAccessResult)
        } else {
            VoiceAuthorizationService.shared.requestAccess(completion: onAccessResult)
        }
    }

    func pause() {
        guard isRecording else { return }
        if let started = activeSegmentStartedAt {
            accumulatedDuration += Date().timeIntervalSince(started)
            duration = accumulatedDuration
            activeSegmentStartedAt = nil
        }
        durationTimer?.invalidate()
        durationTimer = nil
        taskRestartTimer?.invalidate()
        taskRestartTimer = nil
        simulatedTimer?.invalidate()
        simulatedTimer = nil
        pausedAt = .now
        if !isSimulationRun {
            audioEngine.pause()
        }
        isRecording = false
        statusText = "Paused"
    }

    func resume() {
        guard !isRecording else { return }
        if let pausedAt {
            pauseDurations.append(Date().timeIntervalSince(pausedAt))
            self.pausedAt = nil
        }

        if isSimulationRun {
            activeSegmentStartedAt = .now
            startDurationTimer()
            startSimulation(continuing: true)
            return
        }

        if hasAudioTap {
            guard VoiceAudioSessionCoordinator.shared.activate() else {
                errorMessage = "Unable to reactivate the audio session."
                statusText = "Audio session unavailable"
                return
            }
            do {
                if !audioEngine.isRunning {
                    try audioEngine.start()
                }
            } catch {
                errorMessage = "Unable to resume microphone recording: \(error.localizedDescription)"
                statusText = "Recording paused"
                return
            }

            if task == nil || request == nil {
                let locale = Locale(identifier: activeLanguage == .hindi ? "hi-IN" : "en-IN")
                if let recognizer = speechRecognizer ?? SFSpeechRecognizer(locale: locale), recognizer.isAvailable {
                    recognizer.delegate = self
                    speechRecognizer = recognizer
                    commitCurrentEpochWords()
                    beginRecognitionEpoch(with: recognizer)
                }
            } else {
                scheduleTaskRolloverTimer()
            }
        }

        activeSegmentStartedAt = .now
        isRecording = true
        statusText = "Listening"
        startDurationTimer()
    }

    func stop() {
        activeSessionToken = nil
        if let started = activeSegmentStartedAt {
            accumulatedDuration += Date().timeIntervalSince(started)
            duration = accumulatedDuration
            activeSegmentStartedAt = nil
        }
        durationTimer?.invalidate()
        durationTimer = nil
        simulatedTimer?.invalidate()
        simulatedTimer = nil
        taskRestartTimer?.invalidate()
        taskRestartTimer = nil

        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if hasAudioTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasAudioTap = false
        }

        tapState.setRequest(nil)
        tapState.setAudioFile(nil, converter: nil, writeFormat: nil)
        audioFile = nil

        request?.endAudio()
        request = nil

        if let activeTask = task {
            activeTask.finish()
            stopFinalizeWorkItem?.cancel()
            let cleanup = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if self.task === activeTask {
                    self.activeTaskID = nil
                    activeTask.cancel()
                    self.task = nil
                }
                self.resumeLiveFinalizationWaiters()
            }
            stopFinalizeWorkItem = cleanup
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: cleanup)
        } else {
            resumeLiveFinalizationWaiters()
        }

        isRecording = false
        audioLevel = 0.12
    }

    /// Stops live capture cleanly, waits briefly for final recognizer segments,
    /// and runs offline `SFSpeechURLRecognitionRequest` + `vDSP` silence analysis
    /// over the saved WAV file when available.
    func stopAndFinalizeForAnalysis() async -> FinalizedPracticeCapture {
        let language = activeLanguage
        let vocabulary = activeContextualVocabulary
        let wasSimulation = isSimulationRun
        let wavURL = recordedAudioURL
        let hadActiveTask = task != nil

        stop()

        if hadActiveTask && !wasSimulation {
            await waitForLiveTaskFinalization()
        }

        let liveWords = recognizedWords
        let liveTranscript = transcript
        let fallbackDuration = duration

        guard !wasSimulation,
              let wavURL,
              FileManager.default.fileExists(atPath: wavURL.path) else {
            return FinalizedPracticeCapture(
                transcript: liveTranscript,
                words: liveWords,
                silenceIntervals: [],
                duration: fallbackDuration,
                audioURL: wavURL
            )
        }

        let minimumPause = PracticeSpeechDeliveryAnalyzer.hesitationPauseThresholdSeconds
        async let acousticTask: (silences: [PracticeSilenceInterval], audioDuration: Double?) = Task.detached(priority: .userInitiated) {
            let silences = PracticeAudioSilenceAnalyzer.detectSilences(in: wavURL, minimumDuration: minimumPause)
            let audioDuration = PracticeAudioSilenceAnalyzer.audioDuration(of: wavURL)
            return (silences, audioDuration)
        }.value

        async let urlRecognition = recognizeAudioFile(
            url: wavURL,
            language: language,
            contextualStrings: vocabulary,
            timeoutSeconds: 4.0
        )

        let (acoustic, urlResult) = await (acousticTask, urlRecognition)
        let shouldPreferURLWords = !urlResult.words.isEmpty && urlResult.words.count >= max(1, liveWords.count / 2)
        let finalWords = shouldPreferURLWords ? urlResult.words : liveWords
        let finalTranscript = shouldPreferURLWords
            ? (urlResult.transcript.isEmpty ? finalWords.map(\.text).joined(separator: " ") : urlResult.transcript)
            : liveTranscript

        if shouldPreferURLWords {
            processRecognizedSpeech(segments: finalWords)
        }
        let resolvedDuration = acoustic.audioDuration ?? fallbackDuration
        if resolvedDuration > 0 {
            duration = resolvedDuration
        }

        return FinalizedPracticeCapture(
            transcript: finalTranscript,
            words: finalWords,
            silenceIntervals: acoustic.silences,
            duration: resolvedDuration,
            audioURL: wavURL
        )
    }

    func reset() {
        stopImmediately()
        transcript = ""
        recognizedWords = []
        committedWords = []
        currentEpochWords = []
        epochTimeOffset = 0
        duration = 0
        accumulatedDuration = 0
        activeSegmentStartedAt = nil
        pausedAt = nil
        pauseDurations = []
        recordedAudioURL = nil
        activeContextualVocabulary = []
        permissionDenied = false
        errorMessage = nil
        isSimulationRun = false
        statusText = "Tap Start when you’re ready"
    }

    private func stopImmediately() {
        activeSessionToken = nil
        stopFinalizeWorkItem?.cancel()
        stopFinalizeWorkItem = nil
        resumeLiveFinalizationWaiters()
        durationTimer?.invalidate()
        durationTimer = nil
        simulatedTimer?.invalidate()
        simulatedTimer = nil
        taskRestartTimer?.invalidate()
        taskRestartTimer = nil

        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if hasAudioTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasAudioTap = false
        }

        tapState.setRequest(nil)
        tapState.setAudioFile(nil, converter: nil, writeFormat: nil)
        audioFile = nil

        activeTaskID = nil
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil

        isRecording = false
        audioLevel = 0.12
    }

    private func startRecognizer(language: ScriptLanguage) {
        let locale = Locale(identifier: language == .hindi ? "hi-IN" : "en-IN")
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            if activeIsDemoMode {
                startSimulation()
            } else {
                failRealStart(message: "Speech recognition is unavailable for \(language.rawValue).")
            }
            return
        }
        recognizer.delegate = self
        speechRecognizer = recognizer

        guard VoiceAudioSessionCoordinator.shared.activate() else {
            if activeIsDemoMode {
                startSimulation()
            } else {
                failRealStart(message: "Unable to configure the audio session for recording.")
            }
            return
        }

        let node = audioEngine.inputNode
        let inputFormat = node.inputFormat(forBus: 0)
        let outputFormat = node.outputFormat(forBus: 0)
        guard let tapFormat = [inputFormat, outputFormat].first(where: { $0.sampleRate > 0 && $0.channelCount > 0 }) else {
            if activeIsDemoMode {
                startSimulation()
            } else {
                failRealStart(message: "No valid microphone input format is available.")
            }
            return
        }

        let writeFormat: AVAudioFormat
        let converter: AVAudioConverter?
        if tapFormat.commonFormat == .pcmFormatFloat32 && !tapFormat.isInterleaved {
            writeFormat = tapFormat
            converter = nil
        } else if let floatFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: tapFormat.sampleRate,
            channels: tapFormat.channelCount,
            interleaved: false
        ) {
            writeFormat = floatFormat
            converter = AVAudioConverter(from: tapFormat, to: floatFormat)
        } else {
            writeFormat = tapFormat
            converter = nil
        }

        do {
            let folder = MediaStorage.documentsDirectory.appendingPathComponent("PracticeRecordings", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("Practice_\(UUID().uuidString).wav")
            let createdFile = try AVAudioFile(forWriting: url, settings: writeFormat.settings)
            audioFile = createdFile
            recordedAudioURL = url
            tapState.setAudioFile(createdFile, converter: converter, writeFormat: writeFormat)
        } catch {
            recordedAudioURL = nil
            audioFile = nil
            tapState.setAudioFile(nil, converter: nil, writeFormat: nil)
        }

        if hasAudioTap {
            node.removeTap(onBus: 0)
            hasAudioTap = false
        }
        let tapBridge = tapState
        node.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] buffer, _ in
            let level = tapBridge.processBuffer(buffer)
            DispatchQueue.main.async {
                self?.audioLevel = level
            }
        }
        hasAudioTap = true

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            cleanupFailedEngineStart()
            if activeIsDemoMode {
                startSimulation()
            } else {
                failRealStart(message: "Unable to start audio capture: \(error.localizedDescription)")
            }
            return
        }

        isSimulationRun = false
        committedWords = []
        currentEpochWords = []
        epochTimeOffset = 0
        beginRecognitionEpoch(with: recognizer)

        accumulatedDuration = 0
        activeSegmentStartedAt = .now
        isRecording = true
        statusText = "Listening"
        startDurationTimer()
    }

    private func beginRecognitionEpoch(with recognizer: SFSpeechRecognizer) {
        taskRestartTimer?.invalidate()
        taskRestartTimer = nil

        activeTaskID = nil
        request?.endAudio()
        task?.cancel()
        task = nil

        let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.taskHint = .dictation
        if !activeContextualVocabulary.isEmpty {
            recognitionRequest.contextualStrings = activeContextualVocabulary
        }
        request = recognitionRequest
        tapState.setRequest(recognitionRequest)

        let taskID = UUID()
        activeTaskID = taskID
        let epochOffset = epochTimeOffset

        task = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            let handleResult: @MainActor () -> Void = {
                guard let self, self.activeTaskID == taskID else { return }

                if let result {
                    let segments = Self.recognizedWords(
                        from: result.bestTranscription,
                        timeOffset: epochOffset
                    )
                    self.currentEpochWords = segments
                    self.processRecognizedSpeech(segments: self.committedWords + segments)

                    if result.isFinal {
                        self.commitCurrentEpochWords()
                        if self.isRecording {
                            self.rolloverRecognitionTask()
                        } else {
                            self.activeTaskID = nil
                            self.task = nil
                            self.stopFinalizeWorkItem?.cancel()
                            self.stopFinalizeWorkItem = nil
                            self.resumeLiveFinalizationWaiters()
                        }
                        return
                    }
                }

                if error != nil {
                    if self.isRecording {
                        self.commitCurrentEpochWords()
                        self.rolloverRecognitionTask()
                    } else {
                        self.activeTaskID = nil
                        self.task = nil
                        self.stopFinalizeWorkItem?.cancel()
                        self.stopFinalizeWorkItem = nil
                        self.resumeLiveFinalizationWaiters()
                    }
                }
            }
            if Thread.isMainThread {
                MainActor.assumeIsolated(handleResult)
            } else {
                Task { @MainActor in handleResult() }
            }
        }

        scheduleTaskRolloverTimer()
    }

    private func waitForLiveTaskFinalization() async {
        guard task != nil else { return }
        await withCheckedContinuation { continuation in
            if task == nil {
                continuation.resume()
            } else {
                liveTaskFinalizationContinuations.append(continuation)
            }
        }
    }

    private func resumeLiveFinalizationWaiters() {
        guard !liveTaskFinalizationContinuations.isEmpty else { return }
        let waiters = liveTaskFinalizationContinuations
        liveTaskFinalizationContinuations.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func recognizeAudioFile(
        url: URL,
        language: ScriptLanguage,
        contextualStrings: [String],
        timeoutSeconds: Double
    ) async -> (transcript: String, words: [RecognizedPracticeWord]) {
        let locale = Locale(identifier: language == .hindi ? "hi-IN" : "en-IN")
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            return ("", [])
        }

        let urlRequest = SFSpeechURLRecognitionRequest(url: url)
        urlRequest.shouldReportPartialResults = false
        urlRequest.taskHint = .dictation
        if !contextualStrings.isEmpty {
            urlRequest.contextualStrings = contextualStrings
        }

        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var resolved = false
            var task: SFSpeechRecognitionTask?
            var timeoutItem: DispatchWorkItem?

            func finish(
                continuation: CheckedContinuation<(transcript: String, words: [RecognizedPracticeWord]), Never>,
                value: (transcript: String, words: [RecognizedPracticeWord])
            ) {
                lock.lock()
                guard !resolved else {
                    lock.unlock()
                    return
                }
                resolved = true
                let pendingTask = task
                let pendingTimeout = timeoutItem
                task = nil
                timeoutItem = nil
                lock.unlock()

                pendingTimeout?.cancel()
                pendingTask?.cancel()
                continuation.resume(returning: value)
            }
        }

        return await withCheckedContinuation { continuation in
            let box = Box()
            let recognitionTask = recognizer.recognitionTask(with: urlRequest) { result, error in
                if let result, result.isFinal {
                    let words = Self.recognizedWords(from: result.bestTranscription, timeOffset: 0)
                    let text = result.bestTranscription.formattedString
                    box.finish(continuation: continuation, value: (text, words))
                } else if error != nil {
                    box.finish(continuation: continuation, value: ("", []))
                }
            }
            box.task = recognitionTask

            let timeout = DispatchWorkItem {
                box.finish(continuation: continuation, value: ("", []))
            }
            box.timeoutItem = timeout
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + timeoutSeconds,
                execute: timeout
            )
        }
    }

    private nonisolated static func recognizedWords(
        from transcription: SFTranscription,
        timeOffset: Double
    ) -> [RecognizedPracticeWord] {
        transcription.segments.map { segment in
            let alternatives = segment.alternativeSubstrings.filter {
                $0.caseInsensitiveCompare(segment.substring) != .orderedSame
            }
            return RecognizedPracticeWord(
                text: segment.substring,
                timestamp: timeOffset + segment.timestamp,
                duration: segment.duration,
                confidence: segment.confidence,
                alternativeSubstrings: Array(alternatives.prefix(4))
            )
        }
    }

    private func scheduleTaskRolloverTimer() {
        taskRestartTimer?.invalidate()
        taskRestartTimer = Timer.scheduledTimer(withTimeInterval: 50.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording, !self.isSimulationRun else { return }
                self.commitCurrentEpochWords()
                self.rolloverRecognitionTask()
            }
        }
    }

    private func commitCurrentEpochWords() {
        guard !currentEpochWords.isEmpty else { return }
        committedWords.append(contentsOf: currentEpochWords)
        currentEpochWords = []
        let lastEnd = committedWords.last.map { $0.timestamp + $0.duration + 0.05 } ?? 0
        epochTimeOffset = max(duration, lastEnd)
    }

    private func rolloverRecognitionTask() {
        guard isRecording, !isSimulationRun else { return }
        let locale = Locale(identifier: activeLanguage == .hindi ? "hi-IN" : "en-IN")
        guard let recognizer = speechRecognizer ?? SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            statusText = "Speech recognition paused — recording is still available"
            return
        }
        speechRecognizer = recognizer
        beginRecognitionEpoch(with: recognizer)
    }

    private func cleanupFailedEngineStart() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if hasAudioTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasAudioTap = false
        }
        tapState.setRequest(nil)
        tapState.setAudioFile(nil, converter: nil, writeFormat: nil)
        audioFile = nil
        if let orphanedURL = recordedAudioURL {
            try? FileManager.default.removeItem(at: orphanedURL)
            recordedAudioURL = nil
        }
        activeTaskID = nil
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
    }

    private func failRealStart(message: String) {
        activeSessionToken = nil
        errorMessage = message
        statusText = message
        isRecording = false
    }

    /// Receives cumulative SFSpeechRecognizer-equivalent word segments. This is
    /// intentionally the sole transcript/word update path for device and Simulator.
    func processRecognizedSpeech(segments: [RecognizedPracticeWord]) {
        recognizedWords = segments
        transcript = segments.map(\.text).joined(separator: " ")
        pauseDurations = PracticeSpeechDeliveryAnalyzer.hesitationGaps(in: segments)
    }

    private func startSimulation(continuing: Bool = false) {
        guard activeIsDemoMode else { return }
        if !continuing {
            stopImmediately()
            isSimulationRun = true
            statusText = "Listening (Demo Mode)"
            simulatedEmissionIndex = 0
            simulatedSegments = Self.simulationSegments(for: activeScript)
            accumulatedDuration = 0
            activeSegmentStartedAt = .now
            startDurationTimer()
        }
        isRecording = true
        simulatedTimer?.invalidate()
        simulatedTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] timer in
            let shouldInvalidate: Bool = MainActor.assumeIsolated {
                guard let self, self.isRecording else { return false }
                guard self.simulatedEmissionIndex < self.simulatedSegments.count else { return true }
                self.simulatedEmissionIndex += 1
                self.processRecognizedSpeech(segments: Array(self.simulatedSegments.prefix(self.simulatedEmissionIndex)))
                self.audioLevel = CGFloat.random(in: 0.18...0.8)
                return false
            }
            if shouldInvalidate {
                timer.invalidate()
            }
        }
    }

    private func startDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording, let started = self.activeSegmentStartedAt else { return }
                self.duration = self.accumulatedDuration + Date().timeIntervalSince(started)
            }
        }
    }

    private func observeAudioSessionNotifications() {
        let center = NotificationCenter.default
        let interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            let typeRaw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor [weak self] in
                guard let self,
                      let typeRaw,
                      let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
                if type == .began, self.isRecording {
                    self.pause()
                    self.statusText = "Audio interrupted — tap Resume to continue"
                }
            }
        }

        let routeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            let reasonRaw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor [weak self] in
                guard let self,
                      let reasonRaw,
                      let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else { return }
                if reason == .oldDeviceUnavailable, self.isRecording, !self.isSimulationRun, !self.audioEngine.isRunning {
                    self.pause()
                    self.statusText = "Audio route changed — tap Resume to continue"
                }
            }
        }

        sessionObservers = [interruptionObserver, routeObserver]
    }

    nonisolated func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.isRecording, !self.isSimulationRun else { return }
            self.statusText = available ? "Listening" : "Speech recognition temporarily unavailable"
        }
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
}
