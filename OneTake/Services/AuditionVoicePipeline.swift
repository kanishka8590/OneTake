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

    @ObservationIgnored private var consumedWordCount = 0
    @ObservationIgnored private var lastWords: [String] = []
    @ObservationIgnored private var lastFramingFeedbackAt: Date = .distantPast
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let framingDebounceInterval: TimeInterval

    init(
        mode: LiveVoiceCommandMode,
        state: @escaping () -> LiveVoiceCommandState,
        startRecording: @escaping () -> Void = {},
        stopRecording: @escaping () -> Void = {},
        capturePhoto: @escaping () -> Void = {},
        speakFramingFeedback: @escaping () -> Void = {},
        framingDebounceInterval: TimeInterval = 2.0,
        now: @escaping () -> Date = Date.init
    ) {
        self.mode = mode
        self.state = state
        self.startRecording = startRecording
        self.stopRecording = stopRecording
        self.capturePhoto = capturePhoto
        self.speakFramingFeedback = speakFramingFeedback
        self.framingDebounceInterval = framingDebounceInterval
        self.now = now
    }

    func resetTranscriptCursor() {
        consumedWordCount = 0
        lastWords = []
    }

    /// The sole transcript entry point. `isFinal` is accepted intentionally so
    /// Speech.framework partial and final results share exactly one route; a word
    /// cursor prevents cumulative replay while allowing multiple commands in one utterance.
    func handleRecognizedTranscript(_ transcript: String, isFinal: Bool) {
        let normalized = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        let words = normalized.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !words.isEmpty else { return }

        let isContinuation = consumedWordCount > 0
            && words.count >= consumedWordCount
            && lastWords.count >= consumedWordCount
            && (Array(words.prefix(consumedWordCount)) == Array(lastWords.prefix(consumedWordCount))
                || (words.count > lastWords.count && words[consumedWordCount - 1] == lastWords[consumedWordCount - 1]))
        let startIndex = isContinuation ? consumedWordCount : 0
        let newWords = Array(words[startIndex...])
        lastWords = words
        guard !newWords.isEmpty else {
            consumedWordCount = startIndex
            return
        }

        var newConsumed = startIndex

        if let framingEnd = framingMatchEnd(in: newWords) {
            let currentTime = now()
            if currentTime.timeIntervalSince(lastFramingFeedbackAt) >= framingDebounceInterval {
                lastFramingFeedbackAt = currentTime
                speakFramingFeedback()
            }
            newConsumed = max(newConsumed, startIndex + framingEnd)
        }

        let captureState = state()
        switch mode {
        case .headshots:
            if !captureState.isCapturingPhoto,
               let offset = newWords.firstIndex(where: { $0 == "action" || $0 == "now" }) {
                capturePhoto()
                newConsumed = max(newConsumed, startIndex + offset + 1)
            }
            // "Cut" intentionally has no Headshots behavior.

        case .slate, .audition:
            if !captureState.isRecording && !captureState.isCountingDown,
               let offset = newWords.firstIndex(of: "action") {
                startRecording()
                newConsumed = max(newConsumed, startIndex + offset + 1)
            } else if captureState.isRecording, newWords.last == "cut" {
                // Only treat "cut" as a stop command at a standalone/trailing boundary.
                stopRecording()
                newConsumed = max(newConsumed, words.count)
            }
        }

        if isFinal {
            newConsumed = max(newConsumed, words.count)
        }
        consumedWordCount = newConsumed
    }

    private func framingMatchEnd(in words: [String]) -> Int? {
        let patterns: [[String]] = [
            ["how", "do", "i", "look"],
            ["check", "framing"]
        ]
        var earliestEnd: Int?
        for pattern in patterns {
            guard pattern.count <= words.count else { continue }
            for index in 0...(words.count - pattern.count) where Array(words[index..<(index + pattern.count)]) == pattern {
                let end = index + pattern.count
                if earliestEnd == nil || end < earliestEnd! {
                    earliestEnd = end
                }
                break
            }
        }
        return earliestEnd
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

    func resetTranscriptSearch() {
        searchStart = 0
    }

    /// Returns true only when a full actor line has unlocked its next cue (or an
    /// empty-preceding cue becomes auto-ready once speech arrives).
    @discardableResult
    func handleRecognizedTranscript(_ transcript: String, isFinal: Bool) -> Bool {
        guard !isPlayingCue, currentCueIndex < cues.count else { return false }
        let spoken = words(in: transcript)
        guard !spoken.isEmpty else { return false }

        let expected = words(in: cues[currentCueIndex].precedingActorLine)
        if expected.isEmpty {
            isPlayingCue = true
            let cueIndex = currentCueIndex
            schedule(0) { [weak self] in
                guard let self, self.isPlayingCue, self.currentCueIndex == cueIndex else { return }
                self.onCueReady(cueIndex)
            }
            return true
        }

        // Speech recognition may roll over to a fresh transcript between turns.
        // Retain position for cumulative results, but safely restart matching when
        // a new request produces a shorter transcript.
        let start = min(searchStart, spoken.count)
        let exactEnd = contiguousMatch(expected, in: spoken, startingAt: start)
            ?? (start > 0 ? contiguousMatch(expected, in: spoken, startingAt: 0) : nil)
        let tolerantEnd: Int? = exactEnd == nil && expected.count >= 4
            ? (tolerantMatch(expected, in: spoken, startingAt: start)
                ?? (start > 0 ? tolerantMatch(expected, in: spoken, startingAt: 0) : nil))
            : nil

        guard let end = exactEnd ?? tolerantEnd else { return false }

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
        let splitWords = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" }).map(String.init)
        return PracticeSpeechDeliveryAnalyzer.coalesceSplitStrings(splitWords)
            .flatMap(PracticeSpeechDeliveryAnalyzer.normalizedComparisonTokens)
    }

    private func contiguousMatch(_ expected: [String], in spoken: [String], startingAt start: Int) -> Int? {
        guard expected.count <= spoken.count - start else { return nil }
        for index in start...(spoken.count - expected.count) where Array(spoken[index..<(index + expected.count)]) == expected {
            return index + expected.count
        }
        return nil
    }

    /// Tolerates one missed or misheard word on lines of 4+ words while
    /// requiring the trailing word to match on shortened spans so partial speech
    /// does not trigger early.
    private func tolerantMatch(_ expected: [String], in spoken: [String], startingAt start: Int) -> Int? {
        let m = expected.count
        guard m >= 4, start < spoken.count else { return nil }

        for candidate in start..<spoken.count {
            let remaining = spoken.count - candidate
            guard remaining >= m - 1 else { break }

            let maxPrefix = min(remaining, m + 1)
            for sLen in (m - 1)...maxPrefix {
                if sLen == m - 1, expected[m - 1] != spoken[candidate + sLen - 1] {
                    continue
                }
                if editDistance(expected, Array(spoken[candidate..<(candidate + sLen)])) <= 1 {
                    return candidate + sLen
                }
            }
        }
        return nil
    }

    private func editDistance(_ lhs: [String], _ rhs: [String]) -> Int {
        let m = lhs.count
        let n = rhs.count
        if abs(m - n) > 1 { return 2 }
        var dp = Array(0...n)
        for i in 1...m {
            var prev = dp[0]
            dp[0] = i
            for j in 1...n {
                let temp = dp[j]
                if lhs[i - 1] == rhs[j - 1] {
                    dp[j] = prev
                } else {
                    dp[j] = 1 + min(prev, dp[j], dp[j - 1])
                }
                prev = temp
            }
        }
        return dp[n]
    }
}
