import Foundation
import Observation

/// The script representation used by both the live clue UI and final delivery review.
/// Cue lines deliberately never appear in `actorLines` or `actorTokens`.
struct PracticeLine: Identifiable, Hashable, Sendable {
    let id: Int
    let speaker: String
    let text: String
    let isHeader: Bool
    /// A cue is a reader/scene-partner line. Keeping this on the line avoids
    /// treating a cue as actor text when the source contains speaker labels.
    let isCue: Bool
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
        lines.filter {
            !$0.isHeader &&
            !$0.isCue &&
            !$0.text.isEmpty &&
            !Self.isStageDirection($0.text)
        }
    }
    var actorTokens: [PracticeToken] { tokens.filter { !$0.isCue } }

    init(script: PracticeScript) {
        let parsedLines = Self.parse(script.rawText)
        let cueIDs = Set(parsedLines.filter { Self.isCueLine($0, in: script.cueLines) }.map(\.id))
        cueLineIDs = cueIDs
        lines = parsedLines.map { line in
            PracticeLine(
                id: line.id,
                speaker: line.speaker,
                text: line.text,
                isHeader: line.isHeader,
                isCue: cueIDs.contains(line.id)
            )
        }
        var tokenID = 0
        var built: [PracticeToken] = []
        for line in lines where !line.isHeader && !line.text.isEmpty && !Self.isStageDirection(line.text) {
            for word in Self.dialogueWords(in: line.text) {
                built.append(PracticeToken(
                    id: tokenID,
                    lineID: line.id,
                    word: word,
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

    /// Returns full, verbatim sentences for the requested dialogue tokens. This
    /// lets a clue cover its surrounding sentence even when a line has several.
    func sentenceRanges(containing tokenIDs: Set<Int>) -> [PracticeScriptRange] {
        var ranges: [PracticeScriptRange] = []
        var seen: Set<String> = []

        for line in actorLines {
            let lineTokens = tokens.filter { $0.lineID == line.id }
            let wordSpans = Self.dialogueWordSpans(in: line.text)
            guard lineTokens.count == wordSpans.count else { continue }

            for (offset, token) in lineTokens.enumerated() where tokenIDs.contains(token.id) {
                let sentence = Self.sentenceRange(in: line.text, containing: wordSpans[offset].range)
                let sentenceTokenIDs = Set(zip(lineTokens, wordSpans).compactMap { candidate, span in
                    Self.isRange(span.range, within: sentence) ? candidate.id : nil
                })
                guard !sentenceTokenIDs.isEmpty else { continue }

                let startOffset = line.text.distance(from: line.text.startIndex, to: sentence.lowerBound)
                let key = "\(line.id):\(startOffset)"
                guard seen.insert(key).inserted else { continue }
                ranges.append(PracticeScriptRange(
                    lineID: line.id,
                    text: String(line.text[sentence]).trimmingCharacters(in: .whitespacesAndNewlines),
                    tokenIDs: sentenceTokenIDs
                ))
            }
        }
        return ranges
    }

    /// Produces exact text from one line without rebuilding it from normalized
    /// tokens, preserving the source punctuation and apostrophes for highlights.
    func verbatimText(lineID: Int, tokenIDs: [Int]) -> String? {
        guard
            let line = actorLines.first(where: { $0.id == lineID }),
            let firstID = tokenIDs.first,
            let lastID = tokenIDs.last
        else { return nil }

        let lineTokens = tokens.filter { $0.lineID == lineID }
        let wordSpans = Self.dialogueWordSpans(in: line.text)
        guard
            lineTokens.count == wordSpans.count,
            let firstOffset = lineTokens.firstIndex(where: { $0.id == firstID }),
            let lastOffset = lineTokens.firstIndex(where: { $0.id == lastID })
        else { return nil }

        let lower = min(firstOffset, lastOffset)
        let upper = max(firstOffset, lastOffset)
        // `DialogueWordSpan.range` is half-open. Its upper bound can be
        // `endIndex`, which is valid as a range boundary but not as an element
        // index in a closed range. Preserve that half-open shape when slicing
        // the source text so final words are safe in previews and at runtime.
        return String(line.text[wordSpans[lower].range.lowerBound..<wordSpans[upper].range.upperBound])
    }

    func hasStageDirectionBetween(lineID: Int, tokenID: Int, and nextTokenID: Int) -> Bool {
        guard
            let line = actorLines.first(where: { $0.id == lineID }),
            let first = tokens.filter({ $0.lineID == lineID }).firstIndex(where: { $0.id == tokenID }),
            let second = tokens.filter({ $0.lineID == lineID }).firstIndex(where: { $0.id == nextTokenID })
        else { return false }
        let wordSpans = Self.dialogueWordSpans(in: line.text)
        guard wordSpans.indices.contains(first), wordSpans.indices.contains(second) else { return false }

        let lower = min(first, second)
        let upper = max(first, second)
        let between = line.text[wordSpans[lower].range.upperBound..<wordSpans[upper].range.lowerBound]
        return between.contains("(") || between.contains(")")
    }

    func verbatimPhrases(for selectedTokens: [PracticeToken]) -> [String] {
        let selectedIDs = Set(selectedTokens.map(\.id))
        let actorTokens = self.actorTokens
        var phrases: [String] = []
        var current: [PracticeToken] = []
        var previousActorIndex: Int?

        func finish() {
            guard let first = current.first,
                  let text = verbatimText(lineID: first.lineID, tokenIDs: current.map(\.id))
            else { return }
            phrases.append(text)
            current = []
            previousActorIndex = nil
        }

        for (actorIndex, token) in actorTokens.enumerated() where selectedIDs.contains(token.id) {
            let canContinue: Bool
            if let previous = current.last, let previousActorIndex {
                canContinue = previous.lineID == token.lineID &&
                    actorIndex == previousActorIndex + 1 &&
                    !hasStageDirectionBetween(lineID: token.lineID, tokenID: previous.id, and: token.id)
            } else {
                canContinue = false
            }

            if !canContinue { finish() }
            current.append(token)
            previousActorIndex = actorIndex
        }
        finish()
        return phrases
    }

    static func parse(_ text: String) -> [PracticeLine] {
        var speaker = "SCRIPT"
        var output: [PracticeLine] = []
        for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let spokenLine = splitSpeakerAndDialogue(in: value) {
                speaker = spokenLine.speaker
                output.append(PracticeLine(id: index, speaker: speaker, text: spokenLine.dialogue, isHeader: false, isCue: false))
                continue
            }
            let header = !value.isEmpty && value == value.uppercased() &&
                value.range(of: "[A-Z]", options: .regularExpression) != nil && value.count < 48
            if header {
                speaker = value.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ":")))
                output.append(PracticeLine(id: index, speaker: speaker, text: value, isHeader: true, isCue: false))
            } else if !value.isEmpty {
                output.append(PracticeLine(id: index, speaker: speaker, text: value, isHeader: false, isCue: false))
            }
        }
        return output
    }

    /// The casting parser stores cue text without its speaker label, while a
    /// saved practice script may retain labels either on their own line or
    /// inline (for example, `READER: What's your name?`). Match both forms and
    /// also retain the auto-detected reader role for subsequent lines.
    private static func isCueLine(_ line: PracticeLine, in cues: [CueLine]) -> Bool {
        guard !line.isHeader else { return false }
        let lineText = normalizedDialogue(line.text)
        return cues.contains { cue in
            let sameText = normalizedDialogue(cue.cueText) == lineText
            let sameSpeaker = !line.speaker.isEmpty &&
                !cue.speaker.isEmpty &&
                line.speaker.caseInsensitiveCompare(cue.speaker) == .orderedSame
            return sameText || sameSpeaker
        }
    }

    private static func normalizedDialogue(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
    }

    private static func splitSpeakerAndDialogue(in value: String) -> (speaker: String, dialogue: String)? {
        guard
            let colon = value.firstIndex(of: ":"),
            colon != value.startIndex
        else { return nil }

        let candidate = String(value[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
        let dialogue = String(value[value.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let isSpeakerLabel = candidate.count <= 25 &&
            candidate.range(of: "^[A-Za-z0-9 ]+$", options: .regularExpression) != nil
        guard isSpeakerLabel, !dialogue.isEmpty else { return nil }
        return (candidate.uppercased(), dialogue)
    }

    static func dialogueWords(in text: String) -> [String] {
        dialogueWordSpans(in: text).map(\.text)
    }

    private static func isStageDirection(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("(") && trimmed.hasSuffix(")")
    }

    private struct DialogueWordSpan {
        let text: String
        let range: Range<String.Index>
    }

    private static func dialogueWordSpans(in text: String) -> [DialogueWordSpan] {
        var output: [DialogueWordSpan] = []
        var wordStart: String.Index?
        var parentheticalDepth = 0

        func finishWord(at index: String.Index) {
            guard let wordStart, wordStart < index else { return }
            let word = String(text[wordStart..<index])
            guard word.contains(where: { $0.isLetter || $0.isNumber }) else { return }
            output.append(DialogueWordSpan(text: word, range: wordStart..<index))
        }

        for index in text.indices {
            let character = text[index]
            if character == "(" {
                finishWord(at: index)
                wordStart = nil
                parentheticalDepth += 1
                continue
            }
            if character == ")" && parentheticalDepth > 0 {
                parentheticalDepth -= 1
                continue
            }
            guard parentheticalDepth == 0 else { continue }
            if character.isWhitespace {
                finishWord(at: index)
                wordStart = nil
            } else if wordStart == nil {
                wordStart = index
            }
        }
        finishWord(at: text.endIndex)
        return output
    }

    private static func sentenceRange(in text: String, containing wordRange: Range<String.Index>) -> Range<String.Index> {
        let beforeWord = text[..<wordRange.lowerBound]
        let start = beforeWord.lastIndex(where: { ".!?".contains($0) || $0 == ")" }).map { text.index(after: $0) } ?? text.startIndex
        let afterWord = text[wordRange.upperBound...]
        let end = afterWord.firstIndex(where: { ".!?".contains($0) || $0 == "(" }).map {
            ".!?".contains(text[$0]) ? text.index(after: $0) : $0
        } ?? text.endIndex
        return trimWhitespace(in: text, range: start..<end)
    }

    private static func trimWhitespace(in text: String, range: Range<String.Index>) -> Range<String.Index> {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper && text[lower].isWhitespace { lower = text.index(after: lower) }
        while lower < upper {
            let previous = text.index(before: upper)
            guard text[previous].isWhitespace else { break }
            upper = previous
        }
        return lower..<upper
    }

    private static func isRange(_ inner: Range<String.Index>, within outer: Range<String.Index>) -> Bool {
        inner.lowerBound >= outer.lowerBound && inner.upperBound <= outer.upperBound
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
        let spoken = segments.flatMap { PracticeSpeechDeliveryAnalyzer.normalizedComparisonTokens(for: $0.text) }
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
        PracticeScriptModel.dialogueWords(in: text)
            .flatMap(PracticeSpeechDeliveryAnalyzer.normalizedComparisonTokens)
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
            ? recognizedWords(from: transcript)
            : words
        let alignment = align(scriptTokens: model.actorTokens, spokenWords: spokenWords)
        let clueTokenIDs = Set(clueRequestedRanges.flatMap(\.tokenIDs))
        let actorTokenIDs = Set(model.actorTokens.map(\.id))
        let forgotTokenIDs = clueTokenIDs.intersection(actorTokenIDs)
        let skipped = model.actorTokens.enumerated().compactMap { index, token in
            !alignment.matchedScriptIndexes.contains(index) && !clueTokenIDs.contains(token.id) ? token : nil
        }
        let forgotRanges = model.sentenceRanges(containing: forgotTokenIDs)
        let hesitatedIndexes = hesitatedScriptIndexes(in: spokenWords, alignment: alignment, scriptTokenCount: model.actorTokens.count)
        let additions = improvisedPhrases(from: spokenWords, unmatchedIndexes: alignment.unmatchedSpokenIndexes)

        var annotations: [DeliveryAnnotation] = []
        for range in forgotRanges {
            annotations.append(DeliveryAnnotation(text: range.text, kind: .forgot))
        }
        for phrase in model.verbatimPhrases(for: skipped) {
            annotations.append(DeliveryAnnotation(text: phrase, kind: .skipped))
        }
        for index in hesitatedIndexes {
            let token = model.actorTokens[index]
            if let text = model.verbatimText(lineID: token.lineID, tokenIDs: [token.id]) {
                annotations.append(DeliveryAnnotation(text: text, kind: .hesitated))
            }
        }
        for phrase in additions {
            annotations.append(DeliveryAnnotation(text: phrase, kind: .notInScript))
        }

        return PracticeSession(
            sessionNumber: script.sessions.count + 1,
            durationSeconds: duration,
            helpLevelRaw: help.rawValue,
            skippedCount: skipped.count,
            forgotCount: forgotTokenIDs.count,
            hesitatedCount: hesitatedIndexes.count,
            notInScriptCount: additions.reduce(0) { $0 + $1.split(whereSeparator: { $0.isWhitespace }).count },
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
        word
            .replacingOccurrences(of: "’", with: "'")
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    /// The vocabulary used by both live clue matching and final delivery
    /// alignment. A contraction has the same comparison shape as its expanded
    /// form, while all comparison pieces retain their original source token.
    nonisolated static func normalizedComparisonTokens(for word: String) -> [String] {
        let normalized = normalize(word)
        guard !normalized.isEmpty else { return [] }
        return contractionExpansions[normalized] ?? [normalized]
    }

    private static let contractionExpansions: [String: [String]] = [
        "ain't": ["am", "not"],
        "aren't": ["are", "not"],
        "can't": ["can", "not"],
        "cannot": ["can", "not"],
        "couldn't": ["could", "not"],
        "didn't": ["did", "not"],
        "doesn't": ["does", "not"],
        "don't": ["do", "not"],
        "hadn't": ["had", "not"],
        "hasn't": ["has", "not"],
        "haven't": ["have", "not"],
        "isn't": ["is", "not"],
        "mustn't": ["must", "not"],
        "needn't": ["need", "not"],
        "shan't": ["shall", "not"],
        "shouldn't": ["should", "not"],
        "wasn't": ["was", "not"],
        "weren't": ["were", "not"],
        "won't": ["will", "not"],
        "wouldn't": ["would", "not"],
        "i'm": ["i", "am"], "i've": ["i", "have"], "i'll": ["i", "will"], "i'd": ["i", "would"],
        "you're": ["you", "are"], "you've": ["you", "have"], "you'll": ["you", "will"], "you'd": ["you", "would"],
        "he's": ["he", "is"], "he'll": ["he", "will"], "he'd": ["he", "would"],
        "she's": ["she", "is"], "she'll": ["she", "will"], "she'd": ["she", "would"],
        "it's": ["it", "is"], "it'll": ["it", "will"], "it'd": ["it", "would"],
        "we're": ["we", "are"], "we've": ["we", "have"], "we'll": ["we", "will"], "we'd": ["we", "would"],
        "they're": ["they", "are"], "they've": ["they", "have"], "they'll": ["they", "will"], "they'd": ["they", "would"],
        "that's": ["that", "is"], "there's": ["there", "is"], "what's": ["what", "is"],
        "who's": ["who", "is"], "where's": ["where", "is"], "when's": ["when", "is"],
        "why's": ["why", "is"], "how's": ["how", "is"], "let's": ["let", "us"]
    ]

    private struct Alignment {
        let matchedScriptIndexes: Set<Int>
        let unmatchedSpokenIndexes: Set<Int>
        let matchedScriptIndexesBySpokenIndex: [Int: Set<Int>]
    }

    private struct ComparisonToken {
        let value: String
        let sourceIndex: Int
    }

    private static func align(
        scriptTokens: [PracticeToken],
        spokenWords: [RecognizedPracticeWord]
    ) -> Alignment {
        let script = comparisonTokens(from: scriptTokens.map(\.word))
        let spoken = comparisonTokens(from: spokenWords.map(\.text))
        var table = Array(repeating: Array(repeating: 0, count: spoken.count + 1), count: script.count + 1)
        guard !script.isEmpty || !spoken.isEmpty else {
            return Alignment(matchedScriptIndexes: [], unmatchedSpokenIndexes: [], matchedScriptIndexesBySpokenIndex: [:])
        }
        if !script.isEmpty && !spoken.isEmpty {
            for scriptIndex in 1...script.count {
                for spokenIndex in 1...spoken.count {
                table[scriptIndex][spokenIndex] = script[scriptIndex - 1].value == spoken[spokenIndex - 1].value
                    ? table[scriptIndex - 1][spokenIndex - 1] + 1
                    : max(table[scriptIndex - 1][spokenIndex], table[scriptIndex][spokenIndex - 1])
                }
            }
        }
        var matchedScript: Set<Int> = []
        var matchedSpoken: Set<Int> = []
        var matchedScriptBySpoken: [Int: Set<Int>] = [:]
        var scriptIndex = script.count
        var spokenIndex = spoken.count
        while scriptIndex > 0 && spokenIndex > 0 {
            if script[scriptIndex - 1].value == spoken[spokenIndex - 1].value {
                let scriptSourceIndex = script[scriptIndex - 1].sourceIndex
                let spokenSourceIndex = spoken[spokenIndex - 1].sourceIndex
                matchedScript.insert(scriptSourceIndex)
                matchedSpoken.insert(spokenSourceIndex)
                matchedScriptBySpoken[spokenSourceIndex, default: []].insert(scriptSourceIndex)
                scriptIndex -= 1
                spokenIndex -= 1
            } else if table[scriptIndex - 1][spokenIndex] >= table[scriptIndex][spokenIndex - 1] {
                scriptIndex -= 1
            } else {
                spokenIndex -= 1
            }
        }
        return Alignment(
            matchedScriptIndexes: matchedScript,
            unmatchedSpokenIndexes: Set(spokenWords.indices).subtracting(matchedSpoken),
            matchedScriptIndexesBySpokenIndex: matchedScriptBySpoken
        )
    }

    private static func comparisonTokens(from words: [String]) -> [ComparisonToken] {
        words.enumerated().flatMap { index, word in
            normalizedComparisonTokens(for: word).map { ComparisonToken(value: $0, sourceIndex: index) }
        }
    }

    private static func recognizedWords(from transcript: String) -> [RecognizedPracticeWord] {
        transcript
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" })
            .enumerated()
            .map {
                RecognizedPracticeWord(text: String($0.element), timestamp: Double($0.offset) * 0.2, duration: 0.18)
            }
    }

    private static func hesitatedScriptIndexes(
        in spokenWords: [RecognizedPracticeWord],
        alignment: Alignment,
        scriptTokenCount: Int
    ) -> [Int] {
        var indexes: [Int] = []
        var seen: Set<Int> = []

        for spokenIndex in spokenWords.indices.dropFirst() {
            let previous = spokenWords[spokenIndex - 1]
            let current = spokenWords[spokenIndex]
            guard current.timestamp - (previous.timestamp + previous.duration) > 1.5 else { continue }

            let matchingIndex = alignment.matchedScriptIndexesBySpokenIndex[spokenIndex]?.min()
            let priorIndex = alignment.matchedScriptIndexesBySpokenIndex[spokenIndex - 1]?.max().flatMap {
                $0 + 1 < scriptTokenCount ? $0 + 1 : nil
            }
            guard let target = matchingIndex ?? priorIndex, seen.insert(target).inserted else { continue }
            indexes.append(target)
        }
        return indexes
    }

    private static func improvisedPhrases(
        from spokenWords: [RecognizedPracticeWord],
        unmatchedIndexes: Set<Int>
    ) -> [String] {
        var phrases: [String] = []
        var current: [String] = []

        func finish() {
            guard !current.isEmpty else { return }
            phrases.append(current.joined(separator: " "))
            current = []
        }

        for index in spokenWords.indices {
            guard unmatchedIndexes.contains(index) else {
                finish()
                continue
            }
            let word = spokenWords[index].text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            if isMeaningfulImprovisation(word) { current.append(word) }
        }
        finish()
        return phrases
    }

    private static func isMeaningfulImprovisation(_ word: String) -> Bool {
        let normalized = normalize(word)
        let noise = ["s", "t", "ll", "re", "ve", "d", "m", "nt", "uh", "um", "erm", "ah", "mm", "hmm"]
        return normalized.count > 2 && !noise.contains(normalized)
    }
}
