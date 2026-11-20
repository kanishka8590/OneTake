import Foundation
import Observation
import AVFoundation
import Accelerate
import NaturalLanguage

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

    struct VerbatimPhrase: Hashable, Sendable {
        let lineID: Int
        let tokenIDs: [Int]
        let text: String
    }

    var contextualVocabulary: [String] {
        var seen: Set<String> = []
        var output: [String] = []
        for token in actorTokens {
            let trimmed = token.word.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard trimmed.count >= 2 else { continue }
            let key = trimmed.lowercased()
            if seen.insert(key).inserted {
                output.append(trimmed)
                if output.count >= 200 { break }
            }
        }
        return output
    }

    func tokenRanges(forLineID lineID: Int) -> [(tokenID: Int, range: Range<String.Index>)] {
        guard let line = lines.first(where: { $0.id == lineID }) else { return [] }
        let lineTokens = tokens.filter { $0.lineID == lineID }
        let wordSpans = Self.dialogueWordSpans(in: line.text)
        guard lineTokens.count == wordSpans.count else { return [] }
        return zip(lineTokens, wordSpans).map { (tokenID: $0.id, range: $1.range) }
    }

    func hasCueLine(between earlierLineID: Int, and laterLineID: Int) -> Bool {
        let lower = min(earlierLineID, laterLineID)
        let upper = max(earlierLineID, laterLineID)
        guard lower < upper else { return false }
        return lines.contains { $0.isCue && $0.id > lower && $0.id < upper }
    }

    func verbatimPhrases(for selectedTokens: [PracticeToken]) -> [String] {
        verbatimPhraseSpans(for: selectedTokens).map(\.text)
    }

    func verbatimPhraseSpans(for selectedTokens: [PracticeToken]) -> [VerbatimPhrase] {
        let selectedIDs = Set(selectedTokens.map(\.id))
        let actorTokens = self.actorTokens
        var phrases: [VerbatimPhrase] = []
        var current: [PracticeToken] = []
        var previousActorIndex: Int?

        func finish() {
            guard let first = current.first else {
                current = []
                previousActorIndex = nil
                return
            }
            let ids = current.map(\.id)
            if let text = verbatimText(lineID: first.lineID, tokenIDs: ids) {
                phrases.append(VerbatimPhrase(lineID: first.lineID, tokenIDs: ids, text: text))
            }
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
                speaker = normalizeSpeakerName(spokenLine.speaker)
                output.append(PracticeLine(id: index, speaker: speaker, text: spokenLine.dialogue, isHeader: false, isCue: false))
                continue
            }
            let header = !value.isEmpty && value == value.uppercased() &&
                value.range(of: "[A-Z]", options: .regularExpression) != nil && value.count < 48
            if header {
                let cleanedHeader = value.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ":")))
                if isNonSpeakerHeader(cleanedHeader) {
                    output.append(PracticeLine(id: index, speaker: speaker, text: value, isHeader: true, isCue: false))
                } else {
                    speaker = normalizeSpeakerName(cleanedHeader)
                    output.append(PracticeLine(id: index, speaker: speaker, text: value, isHeader: true, isCue: false))
                }
            } else if !value.isEmpty {
                output.append(PracticeLine(id: index, speaker: speaker, text: value, isHeader: false, isCue: false))
            }
        }
        return output
    }

    private static func normalizeSpeakerName(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: #"\s*-\s*"#, with: "-", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isNonSpeakerHeader(_ upperHeader: String) -> Bool {
        let upper = upperHeader.uppercased()
        if upper.hasPrefix("INT.") || upper.hasPrefix("EXT.") || upper.hasPrefix("INT/EXT") || upper.hasPrefix("I/E.") {
            return true
        }
        if upper == "FADE IN" || upper == "FADE OUT" || upper.hasPrefix("CUT TO") || upper.hasPrefix("DISSOLVE TO") || upper == "(CONTINUED)" || upper == "CONTINUED" || upper == "SONGS & SCENES" {
            return true
        }
        if upper == "SCENE END" || upper == "END SCENE" || upper == "END OF SCENE" || upper.contains("AUDITION SCRIPT") || upper.contains("EXCERPT FROM") {
            return true
        }
        if upper.contains(",") || upper.contains("&") || upper.contains("THE MUSICAL") {
            return true
        }
        if upper.range(of: #"^(?:ACT|SCENE)\s+(?:ONE|TWO|THREE|FOUR|FIVE|SIX|SEVEN|EIGHT|I|II|III|IV|V|\d+)\b"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private static let genericSpeakerNames: Set<String> = ["", "SCRIPT", "ACTOR"]
    private static let nonSpeakerColonPrefixes: Set<String> = [
        "NOTE", "NOTES", "HINT", "TIP", "TIPS", "WARNING", "IMPORTANT",
        "SCENE", "PROJECT", "TITLE", "ROLE", "DEADLINE", "FORMAT", "DURATION",
        "EMAIL", "CONTACT", "SUBMIT", "SUBJECT", "TIME", "DATE", "WAIT", "REMEMBER",
        "ISSUED", "REGION", "AGE", "GENDER", "LANGUAGES", "LANGUAGE", "LOCATION",
        "QUESTION", "ANSWER", "STEP", "RULE", "YES", "NO", "LOOK", "LISTEN"
    ]

    /// The casting parser stores cue text without its speaker label, while a
    /// saved practice script may retain labels either on their own line or
    /// inline (for example, `READER: What's your name?`). Match both forms and
    /// also retain the auto-detected reader role for subsequent lines.
    private static func isCueLine(_ line: PracticeLine, in cues: [CueLine]) -> Bool {
        guard !line.isHeader else { return false }
        let lineText = normalizedDialogue(line.text)
        let normalizedLineSpeaker = line.speaker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return cues.contains { cue in
            if normalizedDialogue(cue.cueText) == lineText {
                return true
            }
            guard cue.isAutoDetected else { return false }
            let normalizedCueSpeaker = cue.speaker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !genericSpeakerNames.contains(normalizedLineSpeaker),
                  !genericSpeakerNames.contains(normalizedCueSpeaker) else {
                return false
            }
            return normalizedLineSpeaker == normalizedCueSpeaker
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
        guard !dialogue.isEmpty, candidate.count >= 2, candidate.count <= 25 else { return nil }
        guard candidate.range(of: "[A-Za-z]", options: .regularExpression) != nil else { return nil }

        let words = candidate.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, words.count <= 3 else { return nil }

        let upper = candidate.uppercased()
        guard !nonSpeakerColonPrefixes.contains(upper) else { return nil }

        let validChars = candidate.range(of: "^[A-Za-z0-9 .'-]+$", options: .regularExpression) != nil
        guard validChars else { return nil }

        let isAllCaps = candidate == upper
        let isMultiWordTitleCase = words.count >= 2 && words.allSatisfy { word in
            guard let first = word.first else { return false }
            return first.isUppercase || first.isNumber
        }
        let startsWithDialogueStarter = dialogue.first.map {
            $0.isUppercase || $0 == "\"" || $0 == "“" || $0 == "'" || $0 == "‘" || $0 == "("
        } ?? false
        let isSingleWordTitleCase = words.count == 1
            && (candidate.first?.isUppercase == true)
            && candidate.dropFirst().allSatisfy { $0.isLowercase || $0 == "-" || $0 == "'" }
            && startsWithDialogueStarter
        guard isAllCaps || isMultiWordTitleCase || isSingleWordTitleCase else { return nil }
        return (upper, dialogue)
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
    let language: ScriptLanguage
    private let actorSentences: [PracticeScriptRange]
    private(set) var currentActorLineIndex = 0
    private(set) var currentActorSentenceIndex = 0
    private(set) var clueRequestedRanges: [PracticeScriptRange] = []

    init(script: PracticeScript) {
        let builtModel = PracticeScriptModel(script: script)
        model = builtModel
        language = script.language
        actorSentences = builtModel.sentenceRanges(containing: Set(builtModel.actorTokens.map(\.id)))
    }

    var nextSentence: PracticeScriptRange? {
        guard actorSentences.indices.contains(currentActorSentenceIndex) else { return nil }
        return actorSentences[currentActorSentenceIndex]
    }

    /// Recomputes progress from the cumulative recognizer result, which avoids
    /// double-counting when Speech.framework revises a partial transcription.
    func processRecognizedSpeech(segments: [RecognizedPracticeWord]) {
        let coalesced = PracticeSpeechDeliveryAnalyzer.coalesceSplitTokens(segments)
        let rawWords = coalesced.map(\.text)
        let spoken = rawWords.flatMap {
            PracticeSpeechDeliveryAnalyzer.comparisonTokens(for: $0, language: language)
        }
        var cursor = 0
        var matchedSentenceCount = 0

        for (index, sentence) in actorSentences.enumerated() {
            let sentenceWords = words(in: sentence.text)
            guard !sentenceWords.isEmpty else { continue }
            if let end = contiguousMatch(of: sentenceWords, in: spoken, startingAt: cursor)
                ?? tolerantForwardMatch(of: sentenceWords, in: spoken, startingAt: cursor) {
                cursor = end
                matchedSentenceCount = index + 1
            } else if language == .hindi,
                      let rawEnd = hindiCompoundMatchEnd(
                          ofRawSentence: PracticeScriptModel.dialogueWords(in: sentence.text),
                          inRawSpoken: rawWords,
                          startingAtNormalizedCursor: cursor
                      ) {
                cursor = rawEnd
                matchedSentenceCount = index + 1
            } else {
                break
            }
        }

        currentActorSentenceIndex = min(matchedSentenceCount, actorSentences.count)
        if currentActorSentenceIndex >= actorSentences.count {
            currentActorLineIndex = model.actorLines.count
        } else {
            let activeLineID = actorSentences[currentActorSentenceIndex].lineID
            currentActorLineIndex = model.actorLines.firstIndex(where: { $0.id == activeLineID }) ?? 0
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
        guard let range = model.sentenceRanges(containing: [tokenID]).first
                ?? model.actorTokens.first(where: { $0.id == tokenID }).map({
                    PracticeScriptRange(lineID: $0.lineID, text: $0.word, tokenIDs: [$0.id])
                })
        else { return nil }
        addClueRange(range)
        return range
    }

    private func addClueRange(_ range: PracticeScriptRange) {
        guard !clueRequestedRanges.contains(where: {
            $0.lineID == range.lineID && $0.tokenIDs == range.tokenIDs
        }) else { return }
        clueRequestedRanges.append(range)
    }

    private func words(in text: String) -> [String] {
        PracticeScriptModel.dialogueWords(in: text)
            .flatMap { PracticeSpeechDeliveryAnalyzer.comparisonTokens(for: $0, language: language) }
    }

    /// Coalesces adjacent hi-IN split compound words matching the target sentence
    /// (for example `"हो" + "जाएगा"` -> `"hojaayega"`) and re-runs tolerant matching
    /// so stumbles or inserted words alongside compound splits still advance cleanly.
    private func hindiCompoundMatchEnd(
        ofRawSentence rawSentenceWords: [String],
        inRawSpoken rawSpoken: [String],
        startingAtNormalizedCursor normCursor: Int
    ) -> Int? {
        guard !rawSentenceWords.isEmpty, !rawSpoken.isEmpty else { return nil }
        var rawStart = 0
        var countSoFar = 0
        while rawStart < rawSpoken.count && countSoFar < normCursor {
            countSoFar += PracticeSpeechDeliveryAnalyzer.comparisonTokens(for: rawSpoken[rawStart], language: language).count
            rawStart += 1
        }
        guard rawStart < rawSpoken.count else { return nil }

        let expectedKeys = rawSentenceWords.flatMap {
            PracticeSpeechDeliveryAnalyzer.comparisonTokens(for: $0, language: language)
        }
        let expectedSet = Set(expectedKeys)
        guard !expectedKeys.isEmpty else { return nil }

        // Build merged spoken keys from rawStart forward alongside how many raw tokens each entry consumed.
        var mergedKeys: [String] = []
        var rawEndAfterMerged: [Int] = []
        var u = rawStart
        while u < rawSpoken.count {
            if u + 1 < rawSpoken.count {
                let compound = PracticeSpeechDeliveryAnalyzer.hindiCompoundKey(rawSpoken[u], rawSpoken[u + 1])
                if !compound.isEmpty && expectedSet.contains(compound) {
                    mergedKeys.append(compound)
                    rawEndAfterMerged.append(u + 2)
                    u += 2
                    continue
                }
            }
            let pieces = PracticeSpeechDeliveryAnalyzer.comparisonTokens(for: rawSpoken[u], language: language)
            for piece in pieces {
                mergedKeys.append(piece)
                rawEndAfterMerged.append(u + 1)
            }
            u += 1
        }

        guard let localEnd = contiguousMatch(of: expectedKeys, in: mergedKeys, startingAt: 0)
                ?? tolerantForwardMatch(of: expectedKeys, in: mergedKeys, startingAt: 0),
              localEnd > 0,
              localEnd - 1 < rawEndAfterMerged.count else {
            return nil
        }

        let rawConsumedEnd = rawEndAfterMerged[localEnd - 1]
        return rawSpoken[0..<rawConsumedEnd].reduce(0) { sum, token in
            sum + PracticeSpeechDeliveryAnalyzer.comparisonTokens(for: token, language: language).count
        }
    }

    private func contiguousMatch(of expected: [String], in spoken: [String], startingAt start: Int) -> Int? {
        guard expected.count <= spoken.count - start else { return nil }
        for candidate in start...(spoken.count - expected.count) where Array(spoken[candidate..<(candidate + expected.count)]) == expected {
            return candidate + expected.count
        }
        return nil
    }

    /// Tolerates a single skipped, substituted, or inserted word during live
    /// line tracking so one recognizer slip does not freeze the scene.
    private func tolerantForwardMatch(of expected: [String], in spoken: [String], startingAt start: Int) -> Int? {
        let m = expected.count
        guard m >= 3, start < spoken.count else { return nil }

        for candidate in start..<spoken.count {
            let remaining = spoken.count - candidate
            guard remaining >= m - 1 else { break }

            let maxPrefix = min(remaining, m + 1)
            let minPrefix = m - 1

            for sLen in minPrefix...maxPrefix {
                // Only match a shorter (m - 1) span if the trailing word matched,
                // avoiding premature matches on incomplete prefixes.
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

enum PracticeAudioSilenceAnalyzer {
    /// Measures true acoustic silence intervals (> minimumDuration) from a recorded audio file
    /// using Accelerate (`vDSP_rmsqv`) and an adaptive noise-floor threshold.
    nonisolated static func detectSilences(
        in url: URL,
        minimumDuration: Double = PracticeSpeechDeliveryAnalyzer.hesitationPauseThresholdSeconds
    ) -> [PracticeSilenceInterval] {
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let totalFrames = AVAudioFrameCount(max(0, file.length))
        guard sampleRate > 0, totalFrames > 0 else { return [] }

        let windowDuration = 0.02 // 20 ms
        let windowFrames = max(1, Int((sampleRate * windowDuration).rounded()))
        let readChunkSize: AVAudioFrameCount = 8192
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: readChunkSize) else {
            return []
        }

        let channelCount = Int(format.channelCount)
        guard channelCount > 0 else { return [] }

        var windowDBs: [Float] = []
        windowDBs.reserveCapacity(Int(totalFrames) / windowFrames + 1)
        var pendingRMSMax: Float = 0
        var pendingFrames = 0

        while true {
            buffer.frameLength = 0
            do {
                try file.read(into: buffer)
            } catch {
                break
            }
            let frameCount = Int(buffer.frameLength)
            if frameCount == 0 { break }
            guard let channelData = buffer.floatChannelData else { break }

            var offset = 0
            while offset < frameCount {
                let take = min(windowFrames - pendingFrames, frameCount - offset)
                var blockMaxRMS: Float = 0
                for ch in 0..<channelCount {
                    var chRMS: Float = 0
                    vDSP_rmsqv(channelData[ch].advanced(by: offset), 1, &chRMS, vDSP_Length(take))
                    if chRMS > blockMaxRMS { blockMaxRMS = chRMS }
                }
                pendingRMSMax = max(pendingRMSMax, blockMaxRMS)
                pendingFrames += take
                offset += take

                if pendingFrames >= windowFrames {
                    let db = 20.0 * log10f(max(pendingRMSMax, 1e-6))
                    windowDBs.append(db)
                    pendingRMSMax = 0
                    pendingFrames = 0
                }
            }
        }
        if pendingFrames > 0 {
            let db = 20.0 * log10f(max(pendingRMSMax, 1e-6))
            windowDBs.append(db)
        }

        guard windowDBs.count >= 10 else { return [] }
        let sorted = windowDBs.sorted()
        let noiseFloorDB = sorted[max(0, Int(Double(sorted.count - 1) * 0.15))]
        let speechPeakDB = sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.92))]
        guard speechPeakDB - noiseFloorDB >= 8.0 else { return [] }

        let thresholdDB = max(noiseFloorDB + 6.0, min(-32.0, speechPeakDB - 18.0))
        var isSilent = windowDBs.map { $0 < thresholdDB }

        // Smooth brief (< 0.24s) consonant closures or dips inside active speech.
        let maxSpeechBridgeWindows = Int((0.24 / windowDuration).rounded())
        var idx = 0
        while idx < isSilent.count {
            if isSilent[idx] {
                var end = idx + 1
                while end < isSilent.count && isSilent[end] { end += 1 }
                let touchesSpeechOnBothSides = idx > 0 && end < isSilent.count
                if touchesSpeechOnBothSides && (end - idx) <= maxSpeechBridgeWindows {
                    for fill in idx..<end { isSilent[fill] = false }
                }
                idx = end
            } else {
                idx += 1
            }
        }

        var intervals: [PracticeSilenceInterval] = []
        idx = 0
        while idx < isSilent.count {
            if isSilent[idx] {
                var end = idx + 1
                while end < isSilent.count && isSilent[end] { end += 1 }
                let startSec = Double(idx) * windowDuration
                let endSec = min(Double(totalFrames) / sampleRate, Double(end) * windowDuration)
                if endSec - startSec > minimumDuration {
                    intervals.append(PracticeSilenceInterval(start: startSec, end: endSec))
                }
                idx = end
            } else {
                idx += 1
            }
        }
        return intervals
    }

    nonisolated static func audioDuration(of url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url),
              file.processingFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}

enum PracticeSpeechDeliveryAnalyzer {
    nonisolated static let hesitationPauseThresholdSeconds: Double = 1.2

    private nonisolated static let fillerWords: Set<String> = [
        "uh", "um", "uhh", "umm", "er", "err", "erm", "ah", "ahh", "hmm", "hm", "mm", "mhm"
    ]
    private nonisolated static let contractionSuffixNoise: Set<String> = [
        "s", "t", "ll", "re", "ve", "d", "m", "nt"
    ]

    static func makeSession(
        script: PracticeScript,
        transcript: String,
        words: [RecognizedPracticeWord],
        clueRequestedRanges: [PracticeScriptRange],
        duration: Double,
        help: HelpLevel,
        audioURL: URL?,
        silenceIntervals: [PracticeSilenceInterval] = []
    ) -> PracticeSession {
        let model = PracticeScriptModel(script: script)
        let language = script.language
        let rawSpokenWords = words.isEmpty
            ? recognizedWords(from: transcript)
            : words
        let spokenWords = coalesceSplitTokens(rawSpokenWords)
        let primaryAlignment = align(scriptTokens: model.actorTokens, spokenWords: spokenWords, language: language)
        let alternativeAlignment = recoverAlternativeMatches(
            in: primaryAlignment,
            scriptTokens: model.actorTokens,
            spokenWords: spokenWords,
            language: language
        )
        let alignment = (language == .hindi || containsDevanagari(in: spokenWords) || containsDevanagari(in: model.actorTokens))
            ? recoverHindiCompoundMatches(
                in: alternativeAlignment,
                scriptTokens: model.actorTokens,
                spokenWords: spokenWords
            )
            : alternativeAlignment

        // All omitted script words count as Skipped (Yellow), eliminating redundant Forgot (Blue).
        let clueTokenIDs = Set(clueRequestedRanges.flatMap(\.tokenIDs))
        let skipped = model.actorTokens.enumerated().compactMap { index, token in
            !alignment.matchedScriptIndexes.contains(index) ? token : nil
        }

        let estimatedScriptTimestamps = estimateScriptTimestamps(
            actorTokens: model.actorTokens,
            alignment: alignment,
            spokenWords: spokenWords,
            duration: duration
        )

        let outcome = analyzeHesitationsAndImprovisations(
            in: spokenWords,
            alignment: alignment,
            model: model,
            language: language,
            silenceIntervals: silenceIntervals
        )

        var annotations: [DeliveryAnnotation] = []
        for phrase in model.verbatimPhraseSpans(for: skipped) {
            let firstActorIdx = phrase.tokenIDs.first.flatMap { tokenID in
                model.actorTokens.firstIndex(where: { $0.id == tokenID })
            }
            let timestamp = firstActorIdx.flatMap { estimatedScriptTimestamps[$0] }
            annotations.append(DeliveryAnnotation(
                text: phrase.text,
                kind: .skipped,
                lineID: phrase.lineID,
                tokenIDs: phrase.tokenIDs,
                timestamp: timestamp
            ))
        }
        for hit in outcome.hesitations {
            let token = model.actorTokens[hit.scriptIndex]
            if let text = model.verbatimText(lineID: token.lineID, tokenIDs: [token.id]) {
                annotations.append(DeliveryAnnotation(
                    text: text,
                    kind: .hesitated,
                    lineID: token.lineID,
                    tokenIDs: [token.id],
                    timestamp: hit.timestamp
                ))
            }
        }
        for addition in outcome.additions {
            annotations.append(DeliveryAnnotation(
                text: addition.text,
                kind: .notInScript,
                timestamp: addition.timestamp
            ))
        }

        return PracticeSession(
            sessionNumber: script.sessions.count + 1,
            durationSeconds: duration,
            helpLevelRaw: help.rawValue,
            skippedCount: skipped.count,
            forgotCount: 0,
            hesitatedCount: outcome.hesitations.count,
            notInScriptCount: outcome.additions.reduce(0) { $0 + $1.wordCount },
            annotations: annotations,
            transcript: transcript,
            recognizedWords: spokenWords,
            clueTokenIDs: Array(clueTokenIDs).sorted(),
            audioFilePath: audioURL.map { MediaStorage.storedRelativePath(for: $0.path) }
        )
    }

    static func hesitationGaps(in words: [RecognizedPracticeWord]) -> [Double] {
        zip(words, words.dropFirst()).compactMap { previous, next in
            let gap = next.timestamp - (previous.timestamp + previous.duration)
            return gap > hesitationPauseThresholdSeconds ? gap : nil
        }
    }

    nonisolated static func normalize(_ word: String) -> String {
        word
            .replacingOccurrences(of: "’", with: "'")
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    /// Joins split Speech.framework tokens such as `"it"` + `"'s"` or `"would"` + `"n't"`.
    nonisolated static func coalesceSplitTokens(_ words: [RecognizedPracticeWord]) -> [RecognizedPracticeWord] {
        var result: [RecognizedPracticeWord] = []
        for word in words {
            let normalizedSuffix = word.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "’", with: "'")
            let isApostropheSuffix = normalizedSuffix.hasPrefix("'") && normalizedSuffix.count >= 2
            let isNT = normalizedSuffix.lowercased() == "n't"
            if (isApostropheSuffix || isNT), let last = result.popLast() {
                let mergedEnd = max(last.timestamp + last.duration, word.timestamp + word.duration)
                let combinedConfidence: Float? = switch (last.confidence, word.confidence) {
                case let (lhs?, rhs?): min(lhs, rhs)
                case let (lhs?, nil): lhs
                case let (nil, rhs?): rhs
                case (nil, nil): nil
                }
                result.append(RecognizedPracticeWord(
                    id: last.id,
                    text: last.text + normalizedSuffix,
                    timestamp: last.timestamp,
                    duration: max(0, mergedEnd - last.timestamp),
                    confidence: combinedConfidence,
                    alternativeSubstrings: last.alternativeSubstrings
                ))
            } else {
                result.append(word)
            }
        }
        return result
    }

    nonisolated static func coalesceSplitStrings(_ words: [String]) -> [String] {
        var result: [String] = []
        for word in words {
            let normalizedSuffix = word
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "’", with: "'")
            let isApostropheSuffix = normalizedSuffix.hasPrefix("'") && normalizedSuffix.count >= 2
            let isNT = normalizedSuffix.lowercased() == "n't"
            if (isApostropheSuffix || isNT), let last = result.popLast() {
                result.append(last + normalizedSuffix)
            } else {
                result.append(word)
            }
        }
        return result
    }

    nonisolated static func comparisonTokens(for word: String, language: ScriptLanguage = .english) -> [String] {
        let baseTokens = normalizedComparisonTokens(for: word)
        guard language == .hindi || containsDevanagari(word) else {
            return baseTokens
        }
        return baseTokens.compactMap { piece in
            let key = hindiPhoneticKey(for: piece)
            return key.isEmpty ? nil : key
        }
    }

    nonisolated static func containsDevanagari(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) }
    }

    private nonisolated static func containsDevanagari(in words: [RecognizedPracticeWord]) -> Bool {
        words.contains { containsDevanagari($0.text) }
    }

    private nonisolated static func containsDevanagari(in tokens: [PracticeToken]) -> Bool {
        tokens.contains { containsDevanagari($0.word) }
    }

    private nonisolated static func transliterateHindiToLatin(_ raw: String) -> (latin: String, hadDevanagari: Bool) {
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .lowercased()
        guard !trimmed.isEmpty else { return ("", false) }
        let hasDevanagari = containsDevanagari(trimmed)
        guard hasDevanagari else { return (trimmed, false) }

        var s = trimmed.applyingTransform(.toLatin, reverse: false) ?? trimmed
        s = s
            .replacingOccurrences(of: "cch", with: "ch")
            .replacingOccurrences(of: "ā", with: "A")
            .replacingOccurrences(of: "ī", with: "I")
            .replacingOccurrences(of: "ū", with: "U")
            .replacingOccurrences(of: "ē", with: "E")
            .replacingOccurrences(of: "ō", with: "O")
            .replacingOccurrences(of: "ś", with: "sh")
            .replacingOccurrences(of: "ṣ", with: "sh")
            .replacingOccurrences(of: "ḵẖ", with: "kh")
            .replacingOccurrences(of: "ġ", with: "gh")
            .replacingOccurrences(of: "ṛ", with: "r")
            .replacingOccurrences(of: "m̐", with: "N")
            .replacingOccurrences(of: "ṁ", with: "N")
        s = s.applyingTransform(.stripDiacritics, reverse: false) ?? s
        // ICU emits 'c' for च and 'ch' for छ; fold standalone 'c' -> 'ch' after cch/chh.
        s = s.replacingOccurrences(of: "cch", with: "ch")
            .replacingOccurrences(of: "ch(h)?", with: "ch", options: .regularExpression)
            .replacingOccurrences(of: "c(?!h)", with: "ch", options: .regularExpression)
            .replacingOccurrences(of: "'", with: "")
        return (s, true)
    }

    /// Maps both Devanagari (`hi-IN` Speech output) and Romanized Hinglish words
    /// into a shared phonetic key powered by Foundation's `StringTransform.toLatin`.
    nonisolated static func hindiPhoneticKey(for raw: String) -> String {
        let (trans, hadDevanagari) = transliterateHindiToLatin(raw)
        return finalizeHindiPhoneticKey(fromLatin: trans, hadDevanagari: hadDevanagari)
    }

    nonisolated static func hindiCompoundKey(_ first: String, _ second: String) -> String {
        let lhs = transliterateHindiToLatin(first)
        let rhs = transliterateHindiToLatin(second)
        guard !lhs.latin.isEmpty, !rhs.latin.isEmpty else { return "" }
        return finalizeHindiPhoneticKey(
            fromLatin: lhs.latin + rhs.latin,
            hadDevanagari: lhs.hadDevanagari || rhs.hadDevanagari
        )
    }

    private nonisolated static func finalizeHindiPhoneticKey(fromLatin rawLatin: String, hadDevanagari: Bool) -> String {
        guard !rawLatin.isEmpty else { return "" }
        var s = rawLatin
            .replacingOccurrences(of: "ph", with: "f")
            .replacingOccurrences(of: "w", with: "v")
            .replacingOccurrences(of: "q", with: "k")
            .replacingOccurrences(of: "x", with: "ks")
            .replacingOccurrences(of: "cch", with: "ch")
            .replacingOccurrences(of: "chh", with: "ch")
            .replacingOccurrences(of: "c(?!h)", with: "k", options: .regularExpression)
            .replacingOccurrences(of: "iy", with: "i")
            .replacingOccurrences(of: "ye", with: "e")
            .replacingOccurrences(of: "ey", with: "e")
            .replacingOccurrences(of: "ee", with: "I")
            .replacingOccurrences(of: "oo", with: "U")
            .replacingOccurrences(of: "aa", with: "A")

        var collapsed = ""
        for ch in s where collapsed.last != ch {
            collapsed.append(ch)
        }
        s = collapsed

        // Drop final anusvara / Hinglish trailing nasal 'n' after vowels (मैं/main, नहीं/nahin, रहें/rahein, क्यों/kyun).
        if s.hasSuffix("N") {
            s.removeLast()
        } else if !hadDevanagari && s.hasSuffix("n") && s.count >= 3 {
            let beforeN = s[s.index(before: s.index(before: s.endIndex))]
            if "aeiouAEIOU".contains(beforeN) {
                s.removeLast()
            }
        }
        s = s.replacingOccurrences(of: "N", with: "n")

        // Devanagari final short 'a' is silent schwa (तुम tuma -> tum), whereas long ā ('A') stays.
        if hadDevanagari && s.hasSuffix("a") {
            s.removeLast()
        }
        // Strip silent English trailing 'e' only on V + [tdnl] + e loanwords (e.g. minute), preserving CC+e (samajhte, tumse).
        if !hadDevanagari && s.count >= 5 && s.hasSuffix("e") {
            let idxC = s.index(s.endIndex, offsetBy: -2)
            let idxV = s.index(s.endIndex, offsetBy: -3)
            if "tdnl".contains(s[idxC]) && "aeiouAEIOU".contains(s[idxV]) {
                s.removeLast()
            }
        }
        if s.count >= 3 && s.hasSuffix("y") {
            s.removeLast()
            s.append("i")
        }

        let chars = Array(s)
        guard chars.count > 2 else { return s.lowercased() }
        let isVowel: (Character) -> Bool = { "aeiouAEIOU".contains($0) }
        var out: [Character] = [chars[0]]
        for i in 1..<(chars.count - 1) {
            let ch = chars[i]
            let prev = chars[i - 1]
            let next = chars[i + 1]
            if isVowel(ch) && !isVowel(prev) && !isVowel(next) {
                continue
            }
            if (ch == "a" || ch == "y" || ch == "A") && isVowel(prev) && isVowel(next) {
                continue
            }
            out.append(ch)
        }
        out.append(chars[chars.count - 1])

        var result = String(out).lowercased()
            .replacingOccurrences(of: "ae", with: "e")
            .replacingOccurrences(of: "ei", with: "e")
        if result == "kyo" || result == "kyu" {
            result = "kyu"
        }
        return result
    }

    /// The vocabulary used by both live clue matching and final delivery
    /// alignment. A contraction has the same comparison shape as its expanded
    /// form, while all comparison pieces retain their original source token.
    nonisolated static func normalizedComparisonTokens(for word: String) -> [String] {
        let normalized = normalize(word)
        guard !normalized.isEmpty else { return [] }
        if let expanded = contractionExpansions[normalized] {
            return expanded
        }
        if normalized.contains("-") || normalized.contains("–") || normalized.contains("—") {
            let parts = normalized
                .split(whereSeparator: { $0 == "-" || $0 == "–" || $0 == "—" })
                .map(String.init)
                .filter { !$0.isEmpty }
            if parts.count > 1 {
                return parts.flatMap { contractionExpansions[$0] ?? [$0] }
            }
        }
        return [normalized]
    }

    private nonisolated static let contractionExpansions: [String: [String]] = [
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
        "that's": ["that", "is"], "that'll": ["that", "will"], "that'd": ["that", "would"],
        "there's": ["there", "is"], "there'll": ["there", "will"], "there'd": ["there", "would"],
        "here's": ["here", "is"],
        "what's": ["what", "is"], "what'll": ["what", "will"], "what'd": ["what", "did"],
        "who's": ["who", "is"], "who'll": ["who", "will"], "who'd": ["who", "would"],
        "where's": ["where", "is"], "when's": ["when", "is"],
        "why's": ["why", "is"], "how's": ["how", "is"], "how'd": ["how", "did"],
        "let's": ["let", "us"],
        "would've": ["would", "have"], "could've": ["could", "have"], "should've": ["should", "have"],
        "might've": ["might", "have"], "must've": ["must", "have"]
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

    private struct HesitationHit {
        let scriptIndex: Int
        let timestamp: Double
    }

    private struct AdditionPhrase {
        let text: String
        let timestamp: Double
        let wordCount: Int
    }

    private static func align(
        scriptTokens: [PracticeToken],
        spokenWords: [RecognizedPracticeWord],
        language: ScriptLanguage
    ) -> Alignment {
        let scriptResult = comparisonTokensWithCounts(from: scriptTokens.map(\.word), language: language)
        let spokenResult = comparisonTokensWithCounts(from: spokenWords.map(\.text), language: language)
        let script = scriptResult.tokens
        let spoken = spokenResult.tokens
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

        var matchedPairs: [(scriptSource: Int, spokenSource: Int)] = []
        var scriptMatchedCounts: [Int: Int] = [:]
        var spokenMatchedCounts: [Int: Int] = [:]
        var scriptIndex = script.count
        var spokenIndex = spoken.count
        while scriptIndex > 0 && spokenIndex > 0 {
            if script[scriptIndex - 1].value == spoken[spokenIndex - 1].value {
                let scriptSourceIndex = script[scriptIndex - 1].sourceIndex
                let spokenSourceIndex = spoken[spokenIndex - 1].sourceIndex
                matchedPairs.append((scriptSourceIndex, spokenSourceIndex))
                scriptMatchedCounts[scriptSourceIndex, default: 0] += 1
                spokenMatchedCounts[spokenSourceIndex, default: 0] += 1
                scriptIndex -= 1
                spokenIndex -= 1
            } else if table[scriptIndex - 1][spokenIndex] > table[scriptIndex][spokenIndex - 1] {
                scriptIndex -= 1
            } else {
                // On tie while walking backwards, prefer advancing through spoken first
                // so earlier spoken script phrases anchor earlier script tokens cleanly.
                spokenIndex -= 1
            }
        }

        // Only consider a multi-token contraction/hyphenated word matched when
        // all of its expanded parts matched on both sides.
        let validScriptSources = Set(scriptResult.partCounts.compactMap { sourceIndex, expectedCount in
            scriptMatchedCounts[sourceIndex] == expectedCount ? sourceIndex : nil
        })
        let validSpokenSources = Set(spokenResult.partCounts.compactMap { sourceIndex, expectedCount in
            spokenMatchedCounts[sourceIndex] == expectedCount ? sourceIndex : nil
        })

        var matchedScript: Set<Int> = []
        var matchedSpoken: Set<Int> = []
        var matchedScriptBySpoken: [Int: Set<Int>] = [:]
        for pair in matchedPairs where validScriptSources.contains(pair.scriptSource) && validSpokenSources.contains(pair.spokenSource) {
            matchedScript.insert(pair.scriptSource)
            matchedSpoken.insert(pair.spokenSource)
            matchedScriptBySpoken[pair.spokenSource, default: []].insert(pair.scriptSource)
        }

        return Alignment(
            matchedScriptIndexes: matchedScript,
            unmatchedSpokenIndexes: Set(spokenWords.indices).subtracting(matchedSpoken),
            matchedScriptIndexesBySpokenIndex: matchedScriptBySpoken
        )
    }

    /// Uses Apple Speech's `alternativeSubstrings` inside unmatched gaps between
    /// aligned anchors so homophones (for example `"for"` vs `"four"`) resolve to
    /// the script word instead of causing false Skipped + Not in Script pairs.
    private static func recoverAlternativeMatches(
        in alignment: Alignment,
        scriptTokens: [PracticeToken],
        spokenWords: [RecognizedPracticeWord],
        language: ScriptLanguage
    ) -> Alignment {
        guard !alignment.unmatchedSpokenIndexes.isEmpty else { return alignment }

        var matchedScript = alignment.matchedScriptIndexes
        var unmatchedSpoken = alignment.unmatchedSpokenIndexes
        var matchedBySpoken = alignment.matchedScriptIndexesBySpokenIndex

        let matchedSpokenSorted = matchedBySpoken.keys.sorted()
        var scriptCursorFloor = 0

        for spokenIndex in spokenWords.indices where unmatchedSpoken.contains(spokenIndex) {
            let alternatives = spokenWords[spokenIndex].alternativeSubstrings
            guard !alternatives.isEmpty else { continue }

            let altTokenSets = Set(alternatives.map { comparisonTokens(for: $0, language: language) }).filter { !$0.isEmpty }
            guard !altTokenSets.isEmpty else { continue }

            let prevMatchedSpoken = matchedSpokenSorted.last(where: { $0 < spokenIndex })
            let nextMatchedSpoken = matchedSpokenSorted.first(where: { $0 > spokenIndex })

            let leftScriptBound = max(
                scriptCursorFloor,
                prevMatchedSpoken.flatMap { matchedBySpoken[$0]?.max().map { $0 + 1 } } ?? 0
            )
            let rightScriptBound = nextMatchedSpoken.flatMap { matchedBySpoken[$0]?.min() } ?? scriptTokens.count
            guard leftScriptBound < rightScriptBound else { continue }

            for candidateScriptIndex in leftScriptBound..<rightScriptBound where !matchedScript.contains(candidateScriptIndex) {
                let expected = comparisonTokens(for: scriptTokens[candidateScriptIndex].word, language: language)
                if altTokenSets.contains(expected) {
                    matchedScript.insert(candidateScriptIndex)
                    unmatchedSpoken.remove(spokenIndex)
                    matchedBySpoken[spokenIndex, default: []].insert(candidateScriptIndex)
                    scriptCursorFloor = candidateScriptIndex + 1
                    break
                }
            }
        }

        return Alignment(
            matchedScriptIndexes: matchedScript,
            unmatchedSpokenIndexes: unmatchedSpoken,
            matchedScriptIndexesBySpokenIndex: matchedBySpoken
        )
    }

    /// Recovers compound Hindi/Hinglish word splits across adjacent tokens in unmatched gaps,
    /// such as `"हो" + "जाएगा"` matching `"hojaayega"` or `"फिर" + "से"` matching `"firse"`.
    private static func recoverHindiCompoundMatches(
        in alignment: Alignment,
        scriptTokens: [PracticeToken],
        spokenWords: [RecognizedPracticeWord]
    ) -> Alignment {
        guard !alignment.unmatchedSpokenIndexes.isEmpty else { return alignment }

        var matchedScript = alignment.matchedScriptIndexes
        var unmatchedSpoken = alignment.unmatchedSpokenIndexes
        var matchedBySpoken = alignment.matchedScriptIndexesBySpokenIndex

        var spokenIndex = 0
        var scriptCursorFloor = 0
        while spokenIndex < spokenWords.count {
            guard unmatchedSpoken.contains(spokenIndex) else {
                if let maxS = matchedBySpoken[spokenIndex]?.max() {
                    scriptCursorFloor = max(scriptCursorFloor, maxS + 1)
                }
                spokenIndex += 1
                continue
            }

            let prevMatchedSpoken = matchedBySpoken.keys.filter { $0 < spokenIndex }.max()
            let nextMatchedSpoken = matchedBySpoken.keys.filter { $0 > spokenIndex }.min()
            let leftScriptBound = max(
                scriptCursorFloor,
                prevMatchedSpoken.flatMap { matchedBySpoken[$0]?.max().map { $0 + 1 } } ?? 0
            )
            let rightScriptBound = nextMatchedSpoken.flatMap { matchedBySpoken[$0]?.min() } ?? scriptTokens.count
            guard leftScriptBound < rightScriptBound else {
                spokenIndex += 1
                continue
            }

            var didRecover = false
            // Case 1: 2 adjacent unmatched spoken tokens -> 1 unmatched script token
            if spokenIndex + 1 < spokenWords.count && unmatchedSpoken.contains(spokenIndex + 1) {
                let joinedKey = hindiCompoundKey(spokenWords[spokenIndex].text, spokenWords[spokenIndex + 1].text)
                if !joinedKey.isEmpty {
                    for sIdx in leftScriptBound..<rightScriptBound where !matchedScript.contains(sIdx) {
                        if hindiPhoneticKey(for: scriptTokens[sIdx].word) == joinedKey {
                            matchedScript.insert(sIdx)
                            unmatchedSpoken.remove(spokenIndex)
                            unmatchedSpoken.remove(spokenIndex + 1)
                            matchedBySpoken[spokenIndex, default: []].insert(sIdx)
                            matchedBySpoken[spokenIndex + 1, default: []].insert(sIdx)
                            scriptCursorFloor = sIdx + 1
                            spokenIndex += 2
                            didRecover = true
                            break
                        }
                    }
                }
            }
            if didRecover { continue }

            // Case 2: 1 unmatched spoken token -> 2 adjacent unmatched script tokens
            let singleKey = hindiPhoneticKey(for: spokenWords[spokenIndex].text)
            if !singleKey.isEmpty && leftScriptBound + 1 < rightScriptBound {
                for sIdx in leftScriptBound..<(rightScriptBound - 1)
                where !matchedScript.contains(sIdx) && !matchedScript.contains(sIdx + 1) {
                    if hindiCompoundKey(scriptTokens[sIdx].word, scriptTokens[sIdx + 1].word) == singleKey {
                        matchedScript.insert(sIdx)
                        matchedScript.insert(sIdx + 1)
                        unmatchedSpoken.remove(spokenIndex)
                        matchedBySpoken[spokenIndex, default: []].insert(sIdx)
                        matchedBySpoken[spokenIndex, default: []].insert(sIdx + 1)
                        scriptCursorFloor = sIdx + 2
                        spokenIndex += 1
                        didRecover = true
                        break
                    }
                }
            }
            if !didRecover {
                spokenIndex += 1
            }
        }

        return Alignment(
            matchedScriptIndexes: matchedScript,
            unmatchedSpokenIndexes: unmatchedSpoken,
            matchedScriptIndexesBySpokenIndex: matchedBySpoken
        )
    }

    private static func comparisonTokensWithCounts(
        from words: [String],
        language: ScriptLanguage
    ) -> (tokens: [ComparisonToken], partCounts: [Int: Int]) {
        var tokens: [ComparisonToken] = []
        var partCounts: [Int: Int] = [:]
        for (index, word) in words.enumerated() {
            let expanded = comparisonTokens(for: word, language: language)
            partCounts[index] = expanded.count
            for value in expanded {
                tokens.append(ComparisonToken(value: value, sourceIndex: index))
            }
        }
        return (tokens, partCounts)
    }

    private static func recognizedWords(from transcript: String) -> [RecognizedPracticeWord] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = transcript
        var tokens: [String] = []
        tokenizer.enumerateTokens(in: transcript.startIndex..<transcript.endIndex) { range, _ in
            let token = String(transcript[range])
            if token.contains(where: { $0.isLetter || $0.isNumber }) {
                tokens.append(token)
            }
            return true
        }
        return tokens.enumerated().map {
            RecognizedPracticeWord(text: $0.element, timestamp: Double($0.offset) * 0.2, duration: 0.18)
        }
    }

    private static func estimateScriptTimestamps(
        actorTokens: [PracticeToken],
        alignment: Alignment,
        spokenWords: [RecognizedPracticeWord],
        duration: Double
    ) -> [Int: Double] {
        var matchedTimeByScript: [Int: Double] = [:]
        for (spokenIndex, scriptSet) in alignment.matchedScriptIndexesBySpokenIndex {
            guard spokenWords.indices.contains(spokenIndex) else { continue }
            let ts = spokenWords[spokenIndex].timestamp
            for sIdx in scriptSet {
                matchedTimeByScript[sIdx] = min(matchedTimeByScript[sIdx] ?? ts, ts)
            }
        }
        var result: [Int: Double] = matchedTimeByScript
        let sortedAnchors = matchedTimeByScript.sorted { $0.key < $1.key }
        let safeDuration = max(1.0, duration, spokenWords.last.map { $0.timestamp + $0.duration } ?? 1.0)

        for scriptIndex in actorTokens.indices where result[scriptIndex] == nil {
            let prev = sortedAnchors.last(where: { $0.key < scriptIndex })
            let next = sortedAnchors.first(where: { $0.key > scriptIndex })
            switch (prev, next) {
            case let (p?, n?):
                let frac = Double(scriptIndex - p.key) / Double(max(1, n.key - p.key))
                result[scriptIndex] = p.value + (n.value - p.value) * frac
            case let (p?, nil):
                let remaining = Double(max(1, actorTokens.count - p.key))
                let frac = Double(scriptIndex - p.key) / remaining
                result[scriptIndex] = p.value + max(0, safeDuration - p.value) * frac * 0.85
            case let (nil, n?):
                let frac = Double(scriptIndex) / Double(max(1, n.key))
                result[scriptIndex] = n.value * frac
            case (nil, nil):
                result[scriptIndex] = safeDuration * (Double(scriptIndex) / Double(max(1, actorTokens.count)))
            }
        }
        return result
    }

    private static func analyzeHesitationsAndImprovisations(
        in spokenWords: [RecognizedPracticeWord],
        alignment: Alignment,
        model: PracticeScriptModel,
        language: ScriptLanguage,
        silenceIntervals: [PracticeSilenceInterval]
    ) -> (hesitations: [HesitationHit], additions: [AdditionPhrase]) {
        let actorTokens = model.actorTokens
        var matchedOrder: [Int] = []
        matchedOrder.reserveCapacity(spokenWords.count)
        for index in spokenWords.indices where !alignment.unmatchedSpokenIndexes.contains(index) {
            matchedOrder.append(index)
        }

        var hesitations: [HesitationHit] = []
        var seenHesitatedScriptIndexes: Set<Int> = []
        var consumedStumbleSpokenIndexes: Set<Int> = []

        var prevMatchedSpokenIndex: Int?
        var prevMatchedScriptIndex: Int?

        for spokenIndex in matchedOrder {
            guard let targetScriptIndex = alignment.matchedScriptIndexesBySpokenIndex[spokenIndex]?.min(),
                  actorTokens.indices.contains(targetScriptIndex) else {
                prevMatchedSpokenIndex = spokenIndex
                continue
            }

            let targetToken = actorTokens[targetScriptIndex]
            let isAcrossCueBoundary: Bool = {
                guard let prevScript = prevMatchedScriptIndex,
                      actorTokens.indices.contains(prevScript) else { return false }
                return model.hasCueLine(between: actorTokens[prevScript].lineID, and: targetToken.lineID)
            }()

            let gapStart = prevMatchedSpokenIndex.map { $0 + 1 } ?? 0

            // Walk backward immediately before the matched word to absorb fillers and
            // false-start repetitions ("I— I cannot" or "um spoken") as hesitations
            // rather than emitting them as Not in Script ad-libs.
            var hasFillerOrStumble = false
            var genuineAdditionInBetween = false
            var localConsumed: Set<Int> = []

            var backIndex = spokenIndex - 1
            while backIndex >= gapStart {
                let candidateText = spokenWords[backIndex].text
                if isFillerDisfluency(candidateText) {
                    hasFillerOrStumble = true
                    localConsumed.insert(backIndex)
                    backIndex -= 1
                } else if isFalseStartStumble(
                    candidateText,
                    spokenTarget: spokenWords[spokenIndex].text,
                    scriptTarget: targetToken.word,
                    language: language
                ) {
                    hasFillerOrStumble = true
                    localConsumed.insert(backIndex)
                    backIndex -= 1
                } else {
                    break
                }
            }

            // Check any remaining unmatched tokens earlier in the gap before the stumble run.
            if backIndex >= gapStart {
                for earlierIndex in gapStart...backIndex {
                    let wordText = spokenWords[earlierIndex].text
                    if isFillerDisfluency(wordText) {
                        localConsumed.insert(earlierIndex)
                    } else if isMeaningfulImprovisation(wordText) {
                        genuineAdditionInBetween = true
                    }
                }
            }

            consumedStumbleSpokenIndexes.formUnion(localConsumed)

            var hasLongPause = false
            if let prevSpoken = prevMatchedSpokenIndex,
               !isAcrossCueBoundary,
               !genuineAdditionInBetween {
                hasLongPause = hasPauseExceedingThreshold(
                    from: prevSpoken,
                    to: spokenIndex,
                    in: spokenWords,
                    silenceIntervals: silenceIntervals,
                    threshold: hesitationPauseThresholdSeconds
                )
            }

            let hasLowConfidenceElongation: Bool = {
                guard !isAcrossCueBoundary,
                      let confidence = spokenWords[spokenIndex].confidence,
                      confidence > 0 else { return false }
                return confidence < 0.25 && spokenWords[spokenIndex].duration > 0.75
            }()

            if (hasLongPause || hasFillerOrStumble || hasLowConfidenceElongation),
               seenHesitatedScriptIndexes.insert(targetScriptIndex).inserted {
                hesitations.append(HesitationHit(
                    scriptIndex: targetScriptIndex,
                    timestamp: spokenWords[spokenIndex].timestamp
                ))
            }

            prevMatchedSpokenIndex = spokenIndex
            prevMatchedScriptIndex = alignment.matchedScriptIndexesBySpokenIndex[spokenIndex]?.max() ?? targetScriptIndex
        }

        var additions: [AdditionPhrase] = []
        var currentWords: [String] = []
        var firstTimestamp: Double?

        func finishPhrase() {
            guard !currentWords.isEmpty, let ts = firstTimestamp else {
                currentWords = []
                firstTimestamp = nil
                return
            }
            additions.append(AdditionPhrase(
                text: currentWords.joined(separator: " "),
                timestamp: ts,
                wordCount: currentWords.count
            ))
            currentWords = []
            firstTimestamp = nil
        }

        for index in spokenWords.indices {
            guard alignment.unmatchedSpokenIndexes.contains(index) else {
                finishPhrase()
                continue
            }
            guard !consumedStumbleSpokenIndexes.contains(index) else { continue }
            let word = spokenWords[index].text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            if isMeaningfulImprovisation(word) {
                if firstTimestamp == nil {
                    firstTimestamp = spokenWords[index].timestamp
                }
                currentWords.append(word)
            }
        }
        finishPhrase()

        return (hesitations, additions)
    }

    private static func hasPauseExceedingThreshold(
        from startSpokenIndex: Int,
        to endSpokenIndex: Int,
        in spokenWords: [RecognizedPracticeWord],
        silenceIntervals: [PracticeSilenceInterval],
        threshold: Double
    ) -> Bool {
        guard startSpokenIndex < endSpokenIndex else { return false }
        for idx in (startSpokenIndex + 1)...endSpokenIndex {
            let previous = spokenWords[idx - 1]
            let current = spokenWords[idx]
            if current.timestamp - (previous.timestamp + previous.duration) > threshold {
                return true
            }
        }

        guard !silenceIntervals.isEmpty else { return false }
        let spanStart = spokenWords[startSpokenIndex].timestamp - 0.05
        let spanEnd = spokenWords[endSpokenIndex].timestamp + 0.15
        for interval in silenceIntervals where interval.duration > threshold {
            let overlap = min(interval.end, spanEnd) - max(interval.start, spanStart)
            if overlap > threshold {
                return true
            }
        }
        return false
    }

    private static func isFalseStartStumble(
        _ rawWord: String,
        spokenTarget: String,
        scriptTarget: String,
        language: ScriptLanguage
    ) -> Bool {
        let candidate = normalize(rawWord)
        guard !candidate.isEmpty else { return false }
        let spokenNorm = normalize(spokenTarget)
        let scriptNorm = normalize(scriptTarget)

        if candidate == spokenNorm || candidate == scriptNorm {
            return true
        }
        if candidate.count >= 2 {
            if spokenNorm.count > candidate.count && spokenNorm.hasPrefix(candidate) {
                return true
            }
            if scriptNorm.count > candidate.count && scriptNorm.hasPrefix(candidate) {
                return true
            }
        }
        if language == .hindi || containsDevanagari(rawWord) || containsDevanagari(spokenTarget) {
            let candKey = hindiPhoneticKey(for: rawWord)
            let spokenKey = hindiPhoneticKey(for: spokenTarget)
            let scriptKey = hindiPhoneticKey(for: scriptTarget)
            if !candKey.isEmpty && (candKey == spokenKey || candKey == scriptKey) {
                return true
            }
            if candKey.count >= 2 {
                if (spokenKey.count > candKey.count && spokenKey.hasPrefix(candKey)) ||
                    (scriptKey.count > candKey.count && scriptKey.hasPrefix(candKey)) {
                    return true
                }
            }
        }
        return false
    }

    private static func isFillerDisfluency(_ word: String) -> Bool {
        fillerWords.contains(normalize(word))
    }

    private static func isMeaningfulImprovisation(_ word: String) -> Bool {
        let normalized = normalize(word)
        guard !normalized.isEmpty else { return false }
        if fillerWords.contains(normalized) || contractionSuffixNoise.contains(normalized) {
            return false
        }
        if normalized.count == 1 && normalized.allSatisfy(\.isASCII) {
            return normalized == "i" || normalized == "a"
        }
        return true
    }
}
