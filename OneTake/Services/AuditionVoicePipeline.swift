import Foundation
import Observation

/// A camera-independent description of the active capture workflow.
enum LiveVoiceCommandMode: Sendable {
    case slate
    case audition
    case headshots
}

struct LiveVoiceCommandState: Sendable {
    var isRecording: Bool
    var isCountingDown: Bool
    var isCapturingPhoto: Bool
}

/// The one deterministic command parser used by Slate, Audition, and Headshots.
/// Hardware services inject their recording/capture/speech effects, allowing the
/// real decision logic to run in Simulator and XCTest without a camera.
@Observable
final class LiveVoiceCommandController {
    let mode: LiveVoiceCommandMode
    @ObservationIgnored var state: () -> LiveVoiceCommandState
    @ObservationIgnored var startRecording: () -> Void
    @ObservationIgnored var stopRecording: () -> Void
    @ObservationIgnored var capturePhoto: () -> Void
    @ObservationIgnored var speakFramingFeedback: () -> Void

    init(
        mode: LiveVoiceCommandMode,
        state: @escaping () -> LiveVoiceCommandState,
        startRecording: @escaping () -> Void = {},
        stopRecording: @escaping () -> Void = {},
        capturePhoto: @escaping () -> Void = {},
        speakFramingFeedback: @escaping () -> Void = {}
    ) {
        self.mode = mode
        self.state = state
        self.startRecording = startRecording
        self.stopRecording = stopRecording
        self.capturePhoto = capturePhoto
        self.speakFramingFeedback = speakFramingFeedback
    }

    /// The sole transcript entry point. `isFinal` is accepted intentionally so
    /// Speech.framework partial and final results share exactly one route; state
    /// guards make repeated partial results harmless.
    func handleRecognizedTranscript(_ transcript: String, isFinal: Bool) {
        let normalized = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        let tokens = Set(normalized.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        let captureState = state()

        if normalized.contains("how do i look") || normalized.contains("check framing") {
            speakFramingFeedback()
            return
        }

        switch mode {
        case .headshots:
            guard !captureState.isCapturingPhoto else { return }
            if tokens.contains("action") || tokens.contains("now") {
                capturePhoto()
            }
            // "Cut" intentionally has no Headshots behavior.

        case .slate, .audition:
            if tokens.contains("action"), !captureState.isRecording, !captureState.isCountingDown {
                startRecording()
            } else if tokens.contains("cut"), captureState.isRecording {
                stopRecording()
            }
        }
    }
}

/// Exact, progressive actor-line matcher for script-synced cue playback.
/// The coordinator locks transcripts as soon as a cue is scheduled, so cue
/// speaker bleed cannot become a command or trigger the following cue.
@Observable
final class ScriptSyncedCuePlaybackCoordinator {
    private let cues: [CueLine]
    private let responseDelay: TimeInterval
    @ObservationIgnored private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    @ObservationIgnored private let onCueReady: (Int) -> Void

    private(set) var currentCueIndex = 0
    private(set) var isPlayingCue = false
    private var searchStart = 0

    init(
        cues: [CueLine],
        responseDelay: TimeInterval,
        schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        },
        onCueReady: @escaping (Int) -> Void
    ) {
        self.cues = cues.sorted { $0.orderIndex < $1.orderIndex }
        self.responseDelay = max(0, responseDelay)
        self.schedule = schedule
        self.onCueReady = onCueReady
    }

    /// Returns true only when a full actor line has unlocked its next cue.
    @discardableResult
    func handleRecognizedTranscript(_ transcript: String, isFinal: Bool) -> Bool {
        guard !isPlayingCue, currentCueIndex < cues.count else { return false }
        let expected = words(in: cues[currentCueIndex].precedingActorLine)
        guard !expected.isEmpty else { return false }
        let spoken = words(in: transcript)
        // Speech recognition may roll over to a fresh transcript between turns.
        // Retain position for cumulative results, but safely restart matching when
        // a new request produces a shorter transcript.
        let start = min(searchStart, spoken.count)
        let end = contiguousMatch(expected, in: spoken, startingAt: start)
            ?? (start > 0 ? contiguousMatch(expected, in: spoken, startingAt: 0) : nil)
        guard let end else { return false }

        searchStart = end
        isPlayingCue = true // lock before the configured response delay begins
        let cueIndex = currentCueIndex
        schedule(responseDelay) { [weak self] in
            guard let self, self.isPlayingCue, self.currentCueIndex == cueIndex else { return }
            self.onCueReady(cueIndex)
        }
        return true
    }

    func cuePlaybackDidFinish() {
        guard isPlayingCue else { return }
        isPlayingCue = false
        currentCueIndex += 1
    }

    @discardableResult
    func requestManualCue() -> Int? {
        guard !isPlayingCue, currentCueIndex < cues.count else { return nil }
        let cueIndex = currentCueIndex
        isPlayingCue = true
        schedule(0) { [weak self] in
            guard let self, self.isPlayingCue, self.currentCueIndex == cueIndex else { return }
            self.onCueReady(cueIndex)
        }
        return cueIndex
    }

    private func words(in text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    private func contiguousMatch(_ expected: [String], in spoken: [String], startingAt start: Int) -> Int? {
        guard expected.count <= spoken.count - start else { return nil }
        for index in start...(spoken.count - expected.count) where Array(spoken[index..<(index + expected.count)]) == expected {
            return index + expected.count
        }
        return nil
    }
}
