import Foundation
import Observation

/// The script representation used by both the live clue UI and final delivery review.
/// Cue lines deliberately never appear in `actorLines` or `actorTokens`.
struct PracticeLine: Identifiable, Hashable, Sendable {
    let id: Int
    let speaker: String
    let text: String
    let isHeader: Bool
}

struct PracticeToken: Identifiable, Hashable, Sendable {
    let id: Int
    let lineID: Int
    let word: String
    let isCue: Bool
}

/// An exact actor-sentence span. Token IDs are stable for a particular script parse
/// and let the saved review associate a clue with the real script words.
struct PracticeScriptRange: Hashable, Sendable {
    let lineID: Int
    let text: String
    let tokenIDs: Set<Int>
}

struct PracticeScriptModel {
    let lines: [PracticeLine]
    let cueLineIDs: Set<Int>
    let tokens: [PracticeToken]

    var actorLines: [PracticeLine] {
        lines.filter { !$0.isHeader && !cueLineIDs.contains($0.id) && !$0.text.isEmpty }
    }
    var actorTokens: [PracticeToken] { tokens.filter { !$0.isCue } }

    init(script: PracticeScript) {
        lines = Self.parse(script.rawText)
        cueLineIDs = Set(lines.filter { line in
            script.cueLines.contains {
                $0.cueText.trimmingCharacters(in: .whitespacesAndNewlines) ==
                line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }.map(\.id))
        var tokenID = 0
        var built: [PracticeToken] = []
        for line in lines where !line.isHeader && !line.text.isEmpty {
            for word in line.text.split(whereSeparator: { $0.isWhitespace }) {
                built.append(PracticeToken(
                    id: tokenID,
                    lineID: line.id,
                    word: String(word),
                    isCue: cueLineIDs.contains(line.id)
                ))
                tokenID += 1
            }
        }
        tokens = built
    }

    func range(forLineID lineID: Int) -> PracticeScriptRange? {
        guard let line = actorLines.first(where: { $0.id == lineID }) else { return nil }
        return PracticeScriptRange(
            lineID: line.id,
            text: line.text,
            tokenIDs: Set(tokens.lazy.filter { $0.lineID == line.id }.map(\.id))
        )
    }

    func range(containingTokenID tokenID: Int) -> PracticeScriptRange? {
        guard let token = tokens.first(where: { $0.id == tokenID }) else { return nil }
        return range(forLineID: token.lineID)
    }

    static func parse(_ text: String) -> [PracticeLine] {
        var speaker = "SCRIPT"
        var output: [PracticeLine] = []
        for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let header = !value.isEmpty && value == value.uppercased() &&
                value.range(of: "[A-Z]", options: .regularExpression) != nil && value.count < 48
            if header {
                speaker = value
                output.append(PracticeLine(id: index, speaker: value, text: value, isHeader: true))
            } else if !value.isEmpty {
                output.append(PracticeLine(id: index, speaker: speaker, text: value, isHeader: false))
            }
        }
        return output
    }
}

/// Tracks the next actor sentence from the recognizer's cumulative word segments.
/// All speech sources (Speech.framework and Simulator) call this exact method.
@Observable
final class PracticeSpeechClueTracker {
    let model: PracticeScriptModel
    private(set) var currentActorLineIndex = 0
    private(set) var clueRequestedRanges: [PracticeScriptRange] = []

    init(script: PracticeScript) {
        model = PracticeScriptModel(script: script)
    }

    var nextSentence: PracticeScriptRange? {
        guard model.actorLines.indices.contains(currentActorLineIndex) else { return nil }
        return model.range(forLineID: model.actorLines[currentActorLineIndex].id)
    }

    /// Recomputes progress from the cumulative recognizer result, which avoids
    /// double-counting when Speech.framework revises a partial transcription.
    func processRecognizedSpeech(segments: [RecognizedPracticeWord]) {
        let spoken = segments.map { PracticeSpeechDeliveryAnalyzer.normalize($0.text) }.filter { !$0.isEmpty }
        var cursor = 0
        for (index, line) in model.actorLines.enumerated() {
            let lineWords = words(in: line.text)
            guard !lineWords.isEmpty else { continue }
            guard let end = contiguousMatch(of: lineWords, in: spoken, startingAt: cursor) else { break }
            cursor = end
            currentActorLineIndex = min(index + 1, model.actorLines.count)
        }
    }

    @discardableResult
    func requestNextSentence() -> PracticeScriptRange? {
        guard let range = nextSentence else { return nil }
        addClueRange(range)
        return range
    }

    @discardableResult
    func requestClue(containingTokenID tokenID: Int) -> PracticeScriptRange? {
        guard let range = model.range(containingTokenID: tokenID) else { return nil }
        addClueRange(range)
        return range
    }

    private func addClueRange(_ range: PracticeScriptRange) {
        guard !clueRequestedRanges.contains(where: { $0.lineID == range.lineID }) else { return }
        clueRequestedRanges.append(range)
    }

    private func words(in text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .map(PracticeSpeechDeliveryAnalyzer.normalize)
            .filter { !$0.isEmpty }
    }

    private func contiguousMatch(of expected: [String], in spoken: [String], startingAt start: Int) -> Int? {
        guard expected.count <= spoken.count - start else { return nil }
        for candidate in start...(spoken.count - expected.count) where Array(spoken[candidate..<(candidate + expected.count)]) == expected {
            return candidate + expected.count
        }
        return nil
    }
}

enum PracticeSpeechDeliveryAnalyzer {
    static func makeSession(
        script: PracticeScript,
        transcript: String,
        words: [RecognizedPracticeWord],
        clueRequestedRanges: [PracticeScriptRange],
        duration: Double,
        help: HelpLevel,
        audioURL: URL?
    ) -> PracticeSession {
        let model = PracticeScriptModel(script: script)
        let spokenWords = words.isEmpty
            ? transcript.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).enumerated().map {
                RecognizedPracticeWord(text: String($0.element), timestamp: Double($0.offset) * 0.2, duration: 0.18)
            }
            : words
        let alignment = align(scriptTokens: model.actorTokens, spokenWords: spokenWords)
        let clueTokenIDs = Set(clueRequestedRanges.flatMap(\.tokenIDs))
        let forgot = model.actorTokens.filter { clueTokenIDs.contains($0.id) }
        let skipped = model.actorTokens.enumerated().compactMap { index, token in
            !alignment.matchedScriptIndexes.contains(index) && !clueTokenIDs.contains(token.id) ? token : nil
        }
        let pauses = hesitationGaps(in: spokenWords)
        let additions = alignment.unmatchedSpokenIndexes.map { spokenWords[$0].text }

        var annotations: [DeliveryAnnotation] = []
        for range in clueRequestedRanges {
            annotations.append(DeliveryAnnotation(text: range.text, kind: .forgot))
        }
        for phrase in skippedPhrases(from: skipped) {
            annotations.append(DeliveryAnnotation(text: phrase, kind: .skipped))
        }
        for pause in pauses {
            annotations.append(DeliveryAnnotation(text: "\(String(format: "%.1f", pause)) second pause", kind: .hesitated))
        }
        if !additions.isEmpty {
            annotations.append(DeliveryAnnotation(text: additions.joined(separator: " "), kind: .notInScript))
        }

        return PracticeSession(
            sessionNumber: script.sessions.count + 1,
            durationSeconds: duration,
            helpLevelRaw: help.rawValue,
            skippedCount: skipped.count,
            forgotCount: forgot.count,
            hesitatedCount: pauses.count,
            notInScriptCount: additions.count,
            annotations: annotations,
            transcript: transcript,
            recognizedWords: spokenWords,
            clueTokenIDs: Array(clueTokenIDs).sorted(),
            audioFilePath: audioURL?.path
        )
    }

    static func hesitationGaps(in words: [RecognizedPracticeWord]) -> [Double] {
        zip(words, words.dropFirst()).compactMap { previous, next in
            let gap = next.timestamp - (previous.timestamp + previous.duration)
            return gap > 1.5 ? gap : nil
        }
    }

    nonisolated static func normalize(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    private static func align(
        scriptTokens: [PracticeToken],
        spokenWords: [RecognizedPracticeWord]
    ) -> (matchedScriptIndexes: Set<Int>, unmatchedSpokenIndexes: Set<Int>) {
        let script = scriptTokens.map { normalize($0.word) }
        let spoken = spokenWords.map { normalize($0.text) }
        var table = Array(repeating: Array(repeating: 0, count: spoken.count + 1), count: script.count + 1)
        guard !script.isEmpty || !spoken.isEmpty else { return ([], []) }
        if !script.isEmpty && !spoken.isEmpty {
            for scriptIndex in 1...script.count {
                for spokenIndex in 1...spoken.count {
                table[scriptIndex][spokenIndex] = script[scriptIndex - 1] == spoken[spokenIndex - 1]
                    ? table[scriptIndex - 1][spokenIndex - 1] + 1
                    : max(table[scriptIndex - 1][spokenIndex], table[scriptIndex][spokenIndex - 1])
                }
            }
        }
        var matchedScript: Set<Int> = []
        var matchedSpoken: Set<Int> = []
        var scriptIndex = script.count
        var spokenIndex = spoken.count
        while scriptIndex > 0 && spokenIndex > 0 {
            if script[scriptIndex - 1] == spoken[spokenIndex - 1] {
                matchedScript.insert(scriptIndex - 1)
                matchedSpoken.insert(spokenIndex - 1)
                scriptIndex -= 1
                spokenIndex -= 1
            } else if table[scriptIndex - 1][spokenIndex] >= table[scriptIndex][spokenIndex - 1] {
                scriptIndex -= 1
            } else {
                spokenIndex -= 1
            }
        }
        return (matchedScript, Set(spoken.indices).subtracting(matchedSpoken))
    }

    private static func skippedPhrases(from tokens: [PracticeToken]) -> [String] {
        var phrases: [String] = []
        var currentLine: Int?
        var words: [String] = []
        func finish() {
            if !words.isEmpty { phrases.append(words.joined(separator: " ")) }
        }
        for token in tokens {
            if currentLine != token.lineID {
                finish()
                words = []
                currentLine = token.lineID
            }
            words.append(token.word)
        }
        finish()
        return phrases
    }
}
