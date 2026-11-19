import Foundation
import Observation

/// Tracks live speech against teleprompter script lines to drive smooth, continuous
/// read-along scrolling, word-by-word highlighting, and automatic cue-line transitions
/// without stalling on special characters, ad-libs, contractions, or ASR rollovers.
@MainActor
@Observable
final class VoiceTeleprompterTracker {
    struct LineModel: Identifiable, Sendable {
        let id: Int
        let rawText: String
        let isCueLine: Bool
        let cueOrderIndex: Int?
        let displayWords: [String]
        let displayWordGlobalThresholds: [Int]
        let firstGlobalWordIndex: Int
        let wordCount: Int
    }

    struct SpeakableWord: Sendable {
        let globalIndex: Int
        let lineIndex: Int
        let wordIndexInLine: Int
        let displayText: String
        let tokens: [String]
    }

    private(set) var lines: [LineModel] = []
    private(set) var speakableWords: [SpeakableWord] = []
    private(set) var matchedWordCount: Int = 0
    private(set) var activeLineIndex: Int = 0
    private(set) var activeWordIndexInLine: Int = 0
    private(set) var activeCueOrderIndex: Int? = nil
    private(set) var completedCueLineIDs: Set<Int> = []
    private(set) var totalSpokenProgress: Double = 0.0

    @ObservationIgnored private var cueSpeakers: Set<String> = []
    @ObservationIgnored private var cueNormalizedTexts: Set<String> = []
    @ObservationIgnored private var lastTranscriptWords: [String] = []
    @ObservationIgnored private var consumedTranscriptWords: Int = 0

    init(scriptLines: [String] = [], cueSpeakers: Set<String> = [], cueLines: [CueLine] = []) {
        configure(scriptLines: scriptLines, cueSpeakers: cueSpeakers, cueLines: cueLines)
    }

    func configure(scriptLines: [String], cueSpeakers: Set<String> = [], cueLines: [CueLine] = []) {
        var mergedSpeakers = Set(
            cueSpeakers
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
                .filter { !$0.isEmpty }
        )
        for cue in cueLines {
            let speaker = cue.speaker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if !speaker.isEmpty && speaker != "SCRIPT" && speaker != "ACTOR" {
                mergedSpeakers.insert(speaker)
            }
        }
        self.cueSpeakers = mergedSpeakers
        self.cueNormalizedTexts = Set(
            cueLines
                .map { Self.normalizeToSearchTokens($0.cueText).joined(separator: " ") }
                .filter { !$0.isEmpty }
        )

        var builtLines: [LineModel] = []
        var builtWords: [SpeakableWord] = []
        var nextCueOrder = 0

        for (lineIdx, rawLine) in scriptLines.enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let isCue = isLineCue(trimmed)
            let assignedCueOrder: Int? = isCue ? {
                defer { nextCueOrder += 1 }
                return nextCueOrder
            }() : nil

            let words = rawLine.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            let startGlobal = builtWords.count
            var thresholds = [Int](repeating: startGlobal + 1, count: words.count)

            if !isCue {
                var inBracketDepth = 0
                for (wordIdx, rawWord) in words.enumerated() {
                    let openCount = rawWord.filter { $0 == "(" || $0 == "[" || $0 == "<" }.count
                    let closeCount = rawWord.filter { $0 == ")" || $0 == "]" || $0 == ">" }.count
                    let isAsteriskStage = rawWord.hasPrefix("*") && rawWord.hasSuffix("*") && rawWord.count > 2
                    let startsInBracket = inBracketDepth > 0
                        || rawWord.hasPrefix("(")
                        || rawWord.hasPrefix("[")
                        || rawWord.hasPrefix("<")
                        || isAsteriskStage
                    inBracketDepth = max(0, inBracketDepth + openCount - closeCount)

                    // Pre-clear speaker labels ("HEER:", "NOAH:") and stage directions so they never stall reading.
                    if wordIdx == 0 && Self.isSpeakerLabelToken(rawWord, nextWord: words.count > 1 ? words[1] : nil) {
                        thresholds[wordIdx] = startGlobal
                        continue
                    }
                    if startsInBracket {
                        thresholds[wordIdx] = builtWords.count
                        continue
                    }

                    let expanded = Self.normalizeToSearchTokens(rawWord)
                    guard !expanded.isEmpty else {
                        thresholds[wordIdx] = builtWords.count
                        continue
                    }

                    builtWords.append(
                        SpeakableWord(
                            globalIndex: builtWords.count,
                            lineIndex: lineIdx,
                            wordIndexInLine: wordIdx,
                            displayText: rawWord,
                            tokens: expanded
                        )
                    )
                    thresholds[wordIdx] = builtWords.count
                }
            }

            let lineSpeakableCount = builtWords.count - startGlobal
            builtLines.append(
                LineModel(
                    id: lineIdx,
                    rawText: rawLine,
                    isCueLine: isCue,
                    cueOrderIndex: assignedCueOrder,
                    displayWords: words,
                    displayWordGlobalThresholds: thresholds,
                    firstGlobalWordIndex: startGlobal,
                    wordCount: isCue ? 0 : lineSpeakableCount
                )
            )
        }

        self.lines = builtLines
        self.speakableWords = builtWords
        reset()
    }

    var isComplete: Bool {
        !speakableWords.isEmpty && matchedWordCount >= speakableWords.count
    }

    var activeCueLine: LineModel? {
        guard lines.indices.contains(activeLineIndex), lines[activeLineIndex].isCueLine else {
            return nil
        }
        return lines[activeLineIndex]
    }

    var contextualStrings: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for word in speakableWords {
            let cleaned = word.displayText.trimmingCharacters(in: .punctuationCharacters)
            guard cleaned.count >= 2, seen.insert(cleaned).inserted else { continue }
            result.append(cleaned)
            if result.count >= 90 { break }
        }
        return result
    }

    func reset() {
        matchedWordCount = 0
        completedCueLineIDs = []
        activeCueOrderIndex = nil
        lastTranscriptWords = []
        consumedTranscriptWords = 0
        refreshActiveIndices()
    }

    func resetTranscriptCursor() {
        lastTranscriptWords = []
        consumedTranscriptWords = 0
    }

    /// Highlights the specified cue line while the scene partner cue plays.
    func activateCue(orderIndex: Int) {
        guard let cueLine = lines.first(where: { $0.isCueLine && $0.cueOrderIndex == orderIndex }) else { return }
        completedCueLineIDs.remove(cueLine.id)
        for earlierCue in lines where earlierCue.isCueLine && earlierCue.id < cueLine.id {
            completedCueLineIDs.insert(earlierCue.id)
        }
        if matchedWordCount < cueLine.firstGlobalWordIndex {
            matchedWordCount = cueLine.firstGlobalWordIndex
        }
        activeCueOrderIndex = orderIndex
        refreshActiveIndices()
    }

    /// Marks the cue finished and advances `activeLineIndex` straight to the next actor line.
    func completeCue(orderIndex: Int) {
        guard let cueLine = lines.first(where: { $0.isCueLine && $0.cueOrderIndex == orderIndex }) else { return }
        for earlierOrCurrent in lines where earlierOrCurrent.isCueLine && earlierOrCurrent.id <= cueLine.id {
            completedCueLineIDs.insert(earlierOrCurrent.id)
        }
        if matchedWordCount < cueLine.firstGlobalWordIndex {
            matchedWordCount = cueLine.firstGlobalWordIndex
        }
        if activeCueOrderIndex == orderIndex {
            activeCueOrderIndex = nil
        }
        resetTranscriptCursor()
        refreshActiveIndices()
    }

    func jumpToLine(_ lineIndex: Int) {
        guard lines.indices.contains(lineIndex) else { return }
        completedCueLineIDs = Set(lines.filter { $0.isCueLine && $0.id < lineIndex }.map(\.id))
        let targetLine = lines[lineIndex]
        if targetLine.isCueLine {
            matchedWordCount = targetLine.firstGlobalWordIndex
        } else if let firstSpeakable = lines[lineIndex...].first(where: { !$0.isCueLine && $0.wordCount > 0 }) {
            matchedWordCount = firstSpeakable.firstGlobalWordIndex
        } else {
            matchedWordCount = speakableWords.count
        }
        resetTranscriptCursor()
        refreshActiveIndices()
    }

    /// Fraction (0...1) of spoken words completed within `lineIndex`.
    func lineWordFraction(_ lineIndex: Int) -> Double {
        guard lines.indices.contains(lineIndex) else { return 0 }
        let line = lines[lineIndex]
        guard line.wordCount > 0 else {
            return lineIndex < activeLineIndex ? 1.0 : 0.0
        }
        let completedInLine = min(line.wordCount, max(0, matchedWordCount - line.firstGlobalWordIndex))
        return Double(completedInLine) / Double(line.wordCount)
    }

    func isWordMatched(lineIndex: Int, wordIndex: Int) -> Bool {
        guard lines.indices.contains(lineIndex) else { return false }
        let line = lines[lineIndex]
        guard !line.isCueLine else { return false }
        if line.displayWordGlobalThresholds.indices.contains(wordIndex) {
            return matchedWordCount >= line.displayWordGlobalThresholds[wordIndex]
        }
        return line.firstGlobalWordIndex + wordIndex < matchedWordCount
    }

    func isWordCurrent(lineIndex: Int, wordIndex: Int) -> Bool {
        guard activeCueOrderIndex == nil else { return false }
        guard !speakableWords.isEmpty, matchedWordCount < speakableWords.count else { return false }
        let current = speakableWords[matchedWordCount]
        return current.lineIndex == lineIndex && current.wordIndexInLine == wordIndex
    }

    /// Consumes a partial or final ASR transcript and advances `matchedWordCount`
    /// monotonically to match the actor's live reading position, pausing cleanly
    /// at uncompleted cue lines so the scene partner can speak.
    @discardableResult
    func ingestTranscript(_ transcript: String, isFinal: Bool) -> Int {
        guard !speakableWords.isEmpty else { return matchedWordCount }

        let spokenTokens = Self.normalizeToSearchTokens(transcript)
        guard !spokenTokens.isEmpty else {
            if isFinal {
                resetTranscriptCursor()
            }
            return matchedWordCount
        }

        let commonPrefix = Self.longestCommonPrefixCount(lastTranscriptWords, spokenTokens)
        let startIdx: Int
        if consumedTranscriptWords == 0 {
            startIdx = 0
        } else if commonPrefix >= consumedTranscriptWords {
            startIdx = consumedTranscriptWords
        } else if commonPrefix >= max(1, consumedTranscriptWords - 2) && spokenTokens.count >= lastTranscriptWords.count {
            startIdx = commonPrefix
        } else {
            startIdx = 0
        }

        lastTranscriptWords = spokenTokens
        var cursor = startIdx

        while cursor < spokenTokens.count && matchedWordCount < speakableWords.count {
            if let advance = matchStep(spokenTokens: spokenTokens, spokenCursor: cursor) {
                let targetAfterAdvance = min(speakableWords.count, matchedWordCount + advance.expectedWordsConsumed)
                if let crossedCue = lines.first(where: {
                    $0.isCueLine && !completedCueLineIDs.contains($0.id)
                        && $0.firstGlobalWordIndex >= matchedWordCount
                        && $0.firstGlobalWordIndex < targetAfterAdvance
                }) {
                    if matchedWordCount < crossedCue.firstGlobalWordIndex {
                        matchedWordCount = crossedCue.firstGlobalWordIndex
                        cursor += advance.spokenTokensConsumed
                        break
                    } else if matchedWordCount == crossedCue.firstGlobalWordIndex {
                        completedCueLineIDs.insert(crossedCue.id)
                    }
                }

                matchedWordCount = targetAfterAdvance
                cursor += advance.spokenTokensConsumed

                if lines.contains(where: {
                    $0.isCueLine && !completedCueLineIDs.contains($0.id) && $0.firstGlobalWordIndex == matchedWordCount
                }) {
                    break
                }
            } else {
                cursor += 1
            }
        }

        consumedTranscriptWords = isFinal ? 0 : spokenTokens.count
        if isFinal {
            lastTranscriptWords = []
        }

        refreshActiveIndices()
        return matchedWordCount
    }

    // MARK: - Private Alignment Helpers

    private struct MatchStep {
        let expectedWordsConsumed: Int
        let spokenTokensConsumed: Int
    }

    private func matchStep(spokenTokens: [String], spokenCursor: Int) -> MatchStep? {
        guard matchedWordCount < speakableWords.count else { return nil }
        let targetWord = speakableWords[matchedWordCount]

        if let spokenConsumed = consumeTokens(targetWord.tokens, in: spokenTokens, startingAt: spokenCursor) {
            return MatchStep(expectedWordsConsumed: 1, spokenTokensConsumed: spokenConsumed)
        }

        let maxSmallLookahead = min(3, speakableWords.count - matchedWordCount - 1)
        if maxSmallLookahead >= 1 {
            for offset in 1...maxSmallLookahead {
                let candidate = speakableWords[matchedWordCount + offset]
                if let spokenConsumed = consumeTokens(candidate.tokens, in: spokenTokens, startingAt: spokenCursor) {
                    return MatchStep(expectedWordsConsumed: offset + 1, spokenTokensConsumed: spokenConsumed)
                }
            }
        }

        if spokenCursor + 1 < spokenTokens.count {
            let maxResyncOffset = min(14, speakableWords.count - matchedWordCount - 2)
            if maxResyncOffset >= 4 {
                for offset in 4...maxResyncOffset {
                    let first = speakableWords[matchedWordCount + offset]
                    let second = speakableWords[matchedWordCount + offset + 1]
                    if let c1 = consumeTokens(first.tokens, in: spokenTokens, startingAt: spokenCursor),
                       consumeTokens(second.tokens, in: spokenTokens, startingAt: spokenCursor + c1) != nil {
                        return MatchStep(expectedWordsConsumed: offset + 1, spokenTokensConsumed: c1)
                    }
                }
            }
        }

        return nil
    }

    private func consumeTokens(_ expectedTokens: [String], in spokenTokens: [String], startingAt start: Int) -> Int? {
        guard !expectedTokens.isEmpty, start + expectedTokens.count <= spokenTokens.count else {
            if expectedTokens.count == 2, start < spokenTokens.count {
                let joined = expectedTokens.joined()
                if Self.tokensMatch(joined, spokenTokens[start]) {
                    return 1
                }
            }
            return nil
        }

        for i in 0..<expectedTokens.count {
            if !Self.tokensMatch(expectedTokens[i], spokenTokens[start + i]) {
                if expectedTokens.count == 2 && Self.tokensMatch(expectedTokens.joined(), spokenTokens[start]) {
                    return 1
                }
                return nil
            }
        }
        return expectedTokens.count
    }

    private func refreshActiveIndices() {
        guard !lines.isEmpty else {
            activeLineIndex = 0
            activeWordIndexInLine = 0
            activeCueOrderIndex = nil
            totalSpokenProgress = 0
            return
        }

        if let pendingCue = lines.first(where: { line in
            guard line.isCueLine, !completedCueLineIDs.contains(line.id) else { return false }
            if line.firstGlobalWordIndex == 0 {
                return activeCueOrderIndex == line.cueOrderIndex
            }
            return matchedWordCount >= line.firstGlobalWordIndex
        }) {
            activeLineIndex = pendingCue.id
            activeWordIndexInLine = 0
            activeCueOrderIndex = pendingCue.cueOrderIndex
            totalSpokenProgress = speakableWords.isEmpty
                ? 0
                : Double(min(matchedWordCount, speakableWords.count)) / Double(speakableWords.count)
            return
        }

        activeCueOrderIndex = nil

        guard !speakableWords.isEmpty else {
            activeLineIndex = 0
            activeWordIndexInLine = 0
            totalSpokenProgress = 0
            return
        }

        if matchedWordCount >= speakableWords.count {
            let last = speakableWords[speakableWords.count - 1]
            activeLineIndex = last.lineIndex
            activeWordIndexInLine = last.wordIndexInLine + 1
            totalSpokenProgress = 1.0
        } else {
            let current = speakableWords[matchedWordCount]
            activeLineIndex = current.lineIndex
            activeWordIndexInLine = current.wordIndexInLine
            totalSpokenProgress = Double(matchedWordCount) / Double(speakableWords.count)
        }
    }

    private func isLineCue(_ trimmed: String) -> Bool {
        if trimmed.hasPrefix("[READER]") || trimmed.hasPrefix("[CUE]") {
            return true
        }
        let upper = trimmed.uppercased()
        for speaker in cueSpeakers {
            if upper.hasPrefix("\(speaker):") || upper.hasPrefix("[\(speaker)]") {
                return true
            }
        }
        if !cueNormalizedTexts.isEmpty {
            let fullNorm = Self.normalizeToSearchTokens(trimmed).joined(separator: " ")
            if !fullNorm.isEmpty && cueNormalizedTexts.contains(fullNorm) {
                return true
            }
            if let colonIdx = trimmed.firstIndex(of: ":") {
                let bodyNorm = Self.normalizeToSearchTokens(String(trimmed[trimmed.index(after: colonIdx)...])).joined(separator: " ")
                if !bodyNorm.isEmpty && cueNormalizedTexts.contains(bodyNorm) {
                    return true
                }
            }
        }
        return false
    }

    private static func isSpeakerLabelToken(_ word: String, nextWord: String?) -> Bool {
        guard word.hasSuffix(":") else { return false }
        let stem = word.dropLast().trimmingCharacters(in: CharacterSet(charactersIn: "[]()"))
        guard stem.count >= 2 && stem.count <= 20 else { return false }
        let letters = stem.filter(\.isLetter)
        guard !letters.isEmpty else { return false }
        if letters == letters.uppercased() {
            return true
        }
        if let first = stem.first, first.isUppercase,
           let next = nextWord?.first, (next.isUppercase || next == "\"" || next == "“" || next == "(") {
            return true
        }
        return false
    }

    // MARK: - Token Normalization

    nonisolated private static let contractions: [String: [String]] = [
        "dont": ["do", "not"], "cant": ["can", "not"], "cannot": ["can", "not"], "wont": ["will", "not"],
        "im": ["i", "am"], "youre": ["you", "are"], "theyre": ["they", "are"],
        "were": ["we", "are"], "isnt": ["is", "not"], "arent": ["are", "not"],
        "wasnt": ["was", "not"], "werent": ["were", "not"], "hasnt": ["has", "not"],
        "havent": ["have", "not"], "hadnt": ["had", "not"], "wouldnt": ["would", "not"],
        "couldnt": ["could", "not"], "shouldnt": ["should", "not"], "thats": ["that", "is"],
        "whats": ["what", "is"], "its": ["it", "is"], "lets": ["let", "us"],
        "hes": ["he", "is"], "shes": ["she", "is"], "theres": ["there", "is"], "heres": ["here", "is"],
        "didnt": ["did", "not"], "doesnt": ["does", "not"], "ive": ["i", "have"],
        "youve": ["you", "have"], "weve": ["we", "have"], "theyve": ["they", "have"],
        "ill": ["i", "will"], "youll": ["you", "will"], "hell": ["he", "will"],
        "shell": ["she", "will"], "theyll": ["they", "will"], "well": ["we", "will"],
        "gonna": ["going", "to"], "wanna": ["want", "to"], "gotta": ["got", "to"],
        "ok": ["okay"], "cuz": ["because"], "cause": ["because"]
    ]

    nonisolated private static let numberEquivalents: [String: String] = [
        "0": "zero", "zero": "0",
        "1": "one", "one": "1",
        "2": "two", "two": "2",
        "3": "three", "three": "3",
        "4": "four", "four": "4",
        "5": "five", "five": "5",
        "6": "six", "six": "6",
        "7": "seven", "seven": "7",
        "8": "eight", "eight": "8",
        "9": "nine", "nine": "9",
        "10": "ten", "ten": "10",
        "11": "eleven", "eleven": "11",
        "12": "twelve", "twelve": "12"
    ]

    nonisolated static func normalizeToSearchTokens(_ raw: String) -> [String] {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let prepped = folded
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "′", with: " ")
            .replacingOccurrences(of: "″", with: " ")
            .replacingOccurrences(of: "\"", with: " ")
            .replacingOccurrences(of: "“", with: " ")
            .replacingOccurrences(of: "”", with: " ")
            .replacingOccurrences(
                of: #"(?<=\d)['’‘](?=\d)"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "‘", with: "")

        let chunks = prepped.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        var out: [String] = []
        for chunk in chunks {
            let token = chunk.lowercased()
            guard !token.isEmpty else { continue }
            if let expanded = contractions[token] {
                out.append(contentsOf: expanded)
            } else {
                out.append(token)
            }
        }
        return out
    }

    nonisolated static func cleanToken(_ raw: String) -> String {
        raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    nonisolated static func tokensMatch(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        if numberEquivalents[lhs] == rhs || numberEquivalents[rhs] == lhs { return true }
        if lhs.count >= 5 && rhs.count >= 5 {
            if lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs) { return true }
            if editDistance(lhs, rhs) <= 1 { return true }
        }
        return false
    }

    nonisolated private static func longestCommonPrefixCount(_ lhs: [String], _ rhs: [String]) -> Int {
        let limit = min(lhs.count, rhs.count)
        var i = 0
        while i < limit && lhs[i] == rhs[i] {
            i += 1
        }
        return i
    }

    nonisolated private static func editDistance(_ a: String, _ b: String) -> Int {
        let s = Array(a)
        let t = Array(b)
        if abs(s.count - t.count) > 1 { return 2 }
        var dp = Array(0...t.count)
        for i in 1...s.count {
            var prev = dp[0]
            dp[0] = i
            for j in 1...t.count {
                let temp = dp[j]
                if s[i - 1] == t[j - 1] {
                    dp[j] = prev
                } else {
                    dp[j] = 1 + min(prev, dp[j], dp[j - 1])
                }
                prev = temp
            }
        }
        return dp[t.count]
    }
}
