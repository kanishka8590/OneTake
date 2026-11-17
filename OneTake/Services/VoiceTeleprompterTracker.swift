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
        let token: String
        var tokens: [String] { [token] }
    }

    private(set) var lines: [LineModel] = []
    private(set) var speakableWords: [SpeakableWord] = []
    private(set) var matchedWordCount: Int = 0
    private(set) var activeLineIndex: Int = 0
    private(set) var activeWordIndexInLine: Int = 0
    private(set) var activeCueOrderIndex: Int? = nil
    private(set) var completedCueLineIDs: Set<Int> = []
    private(set) var totalSpokenProgress: Double = 0.0

    var scrollFraction: Double { totalSpokenProgress }

    @ObservationIgnored private var cueSpeakers: Set<String> = []
    @ObservationIgnored private var cueNormalizedTexts: Set<String> = []
    @ObservationIgnored private var lastTranscriptWords: [String] = []
    @ObservationIgnored private var consumedTranscriptWords: Int = 0
    @ObservationIgnored private var lastMatchAdvancedAt: Date = .distantPast

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
            let sp = cue.speaker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if !sp.isEmpty && sp != "SCRIPT" && sp != "ACTOR" {
                mergedSpeakers.insert(sp)
            }
        }
        self.cueSpeakers = mergedSpeakers
        self.cueNormalizedTexts = Set(
            cueLines
                .map { Self.normalizeCueComparisonText($0.cueText) }
                .filter { !$0.isEmpty }
        )

        let preparedLines = Self.expandLongLinesForPrompter(scriptLines, cueChecker: isLineCue)
        var builtLines: [LineModel] = []
        var builtWords: [SpeakableWord] = []
        var nextCueOrder = 0

        for (lineIdx, rawLine) in preparedLines.enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let isCue = isLineCue(trimmed)
            let assignedCueOrder: Int? = isCue ? {
                defer { nextCueOrder += 1 }
                return nextCueOrder
            }() : nil

            let words = rawLine.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            let startGlobal = builtWords.count
            var thresholds: [Int] = Array(repeating: startGlobal + 1, count: words.count)

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

                    // Skip speaker prefix at index 0 (e.g. "HEER:", "NOAH:") and stage directions "(beat)"
                    if wordIdx == 0 && Self.isSpeakerLabelToken(rawWord, nextWord: words.count > 1 ? words[1] : nil) {
                        thresholds[wordIdx] = startGlobal
                        continue
                    }
                    if startsInBracket {
                        thresholds[wordIdx] = builtWords.count
                        continue
                    }

                    let atomicTokens = Self.normalizeToSearchTokens(rawWord)
                    // Pure punctuation/dash/special-character tokens must never block speech matching.
                    guard !atomicTokens.isEmpty else {
                        thresholds[wordIdx] = builtWords.count
                        continue
                    }

                    for token in atomicTokens {
                        let globalIdx = builtWords.count
                        builtWords.append(
                            SpeakableWord(
                                globalIndex: globalIdx,
                                lineIndex: lineIdx,
                                wordIndexInLine: wordIdx,
                                displayText: rawWord,
                                token: token
                            )
                        )
                    }
                    // Display word is marked matched once all of its atomic sub-tokens have been spoken.
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

    private static func isSpeakerLabelToken(_ word: String, nextWord: String?) -> Bool {
        guard word.hasSuffix(":") else { return false }
        let stem = word.dropLast().trimmingCharacters(in: CharacterSet(charactersIn: "[]()"))
        guard stem.count >= 2 && stem.count <= 20 else { return false }
        let letters = stem.filter { $0.isLetter }
        guard !letters.isEmpty else { return false }
        if letters == letters.uppercased() {
            return true
        }
        if let first = stem.first, first.isUppercase, let next = nextWord?.first, (next.isUppercase || next == "\"" || next == "“" || next == "(") {
            return true
        }
        return false
    }

    /// Splits overly long paragraphs (> 18 words) at natural sentence/clause boundaries so
    /// each teleprompter row is easy to read at a glance and scrolls smoothly line-by-line.
    private static func expandLongLinesForPrompter(_ scriptLines: [String], cueChecker: (String) -> Bool) -> [String] {
        var result: [String] = []
        for rawLine in scriptLines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if cueChecker(trimmed) {
                result.append(trimmed)
                continue
            }
            let words = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard words.count > 18 else {
                result.append(trimmed)
                continue
            }

            var currentChunk: [String] = []
            for word in words {
                currentChunk.append(word)
                let count = currentChunk.count
                let endsSentence = word.hasSuffix(".") || word.hasSuffix("!") || word.hasSuffix("?") || word.hasSuffix(".\"") || word.hasSuffix("!”") || word.hasSuffix("?”")
                let endsClause = word.hasSuffix(",") || word.hasSuffix(";") || word.hasSuffix(":") || word.hasSuffix("—") || word == "-" || word == "–" || word == "—"
                if (count >= 7 && endsSentence) || (count >= 11 && endsClause) || count >= 15 {
                    result.append(currentChunk.joined(separator: " "))
                    currentChunk.removeAll(keepingCapacity: true)
                }
            }
            if !currentChunk.isEmpty {
                if currentChunk.count <= 3, !result.isEmpty, !cueChecker(result[result.count - 1]) {
                    result[result.count - 1] += " " + currentChunk.joined(separator: " ")
                } else {
                    result.append(currentChunk.joined(separator: " "))
                }
            }
        }
        return result
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

    func reset(ignoringTranscript: String = "") {
        matchedWordCount = 0
        completedCueLineIDs = []
        let ignoredTokens = Self.normalizeToSearchTokens(ignoringTranscript)
        lastTranscriptWords = ignoredTokens
        consumedTranscriptWords = ignoredTokens.count
        lastMatchAdvancedAt = .distantPast
        refreshActiveIndices()
    }

    func resetTranscriptCursor() {
        lastTranscriptWords = []
        consumedTranscriptWords = 0
    }

    /// Gentle cadence assist when the user is actively speaking into the mic (`rms > 0.014`)
    /// through an out-of-vocabulary proper noun or accent variation so the teleprompter never stalls.
    @discardableResult
    func advanceByCadenceIfStalled(now: Date = Date()) -> Bool {
        guard !speakableWords.isEmpty, matchedWordCount < speakableWords.count else { return false }
        // If we are 1 word away from a cue line, use a shorter 0.45s cadence threshold so a clipped
        // final word before a cue line never delays the cue transition.
        let nextIsCueBoundary = lines.contains {
            $0.isCueLine && !$0.displayWords.isEmpty && !completedCueLineIDs.contains($0.id) && $0.firstGlobalWordIndex == matchedWordCount + 1
        }
        let requiredInterval: TimeInterval = nextIsCueBoundary ? 0.45 : 0.85
        guard now.timeIntervalSince(lastMatchAdvancedAt) >= requiredInterval else { return false }
        lastMatchAdvancedAt = now
        matchedWordCount += 1
        refreshActiveIndices()
        return true
    }

    /// Moves the teleprompter highlight onto the specified cue line while the scene partner cue plays.
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
        lastMatchAdvancedAt = Date()
        refreshActiveIndices()
    }

    /// Marks the cue line as finished and advances `activeLineIndex` to the next actor line.
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
        lastMatchAdvancedAt = Date()
        refreshActiveIndices()
    }

    func completeActiveCueLine() {
        guard let cue = activeCueLine else { return }
        completedCueLineIDs.insert(cue.id)
        resetTranscriptCursor()
        lastMatchAdvancedAt = Date()
        refreshActiveIndices()
    }

    func jumpToLine(_ lineIndex: Int) {
        guard lines.indices.contains(lineIndex) else { return }
        let targetLine = lines[lineIndex]
        completedCueLineIDs = Set(lines.filter { $0.isCueLine && $0.id < lineIndex }.map(\.id))
        if targetLine.isCueLine {
            matchedWordCount = targetLine.firstGlobalWordIndex
        } else if let firstSpeakable = lines[lineIndex...].first(where: { !$0.isCueLine && $0.wordCount > 0 }) {
            matchedWordCount = firstSpeakable.firstGlobalWordIndex
        } else {
            matchedWordCount = speakableWords.count
        }
        resetTranscriptCursor()
        lastMatchAdvancedAt = Date()
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
        guard activeCueLine == nil else { return false }
        guard !speakableWords.isEmpty, matchedWordCount < speakableWords.count else { return false }
        let current = speakableWords[matchedWordCount]
        return current.lineIndex == lineIndex && current.wordIndexInLine == wordIndex
    }

    /// Consumes a partial or final ASR transcript and advances `matchedWordCount`
    /// monotonically to match the actor's live reading position.
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
        } else if spokenTokens.count >= max(2, lastTranscriptWords.count - 2) {
            // ASR revised an earlier word in the same utterance: only re-scan from the revision point
            // (clamped to the last 4 words) so we never replay old words from the start of the take.
            startIdx = max(0, min(commonPrefix, spokenTokens.count - 4))
        } else {
            // Fresh utterance after task rollover
            startIdx = 0
        }

        lastTranscriptWords = spokenTokens
        var cursor = startIdx
        var lastMatchedTokenEnd = startIdx
        let previousMatchedCount = matchedWordCount

        while cursor < spokenTokens.count && matchedWordCount < speakableWords.count {
            if let advance = matchStep(spokenTokens: spokenTokens, spokenCursor: cursor) {
                let targetAfterAdvance = matchedWordCount + advance.expectedWordsConsumed
                // If there is an uncompleted cue line between `matchedWordCount` and `targetAfterAdvance`,
                // clamp at the cue boundary first when the match was on or before the cue boundary,
                // or mark the cue completed if the actor is explicitly speaking the line after the cue.
                if let crossedCue = lines.first(where: {
                    $0.isCueLine && !completedCueLineIDs.contains($0.id)
                        && $0.firstGlobalWordIndex >= matchedWordCount
                        && $0.firstGlobalWordIndex < targetAfterAdvance
                }) {
                    if matchedWordCount < crossedCue.firstGlobalWordIndex && targetAfterAdvance > crossedCue.firstGlobalWordIndex {
                        // Stop cleanly on the cue line when finishing the preceding actor line.
                        matchedWordCount = crossedCue.firstGlobalWordIndex
                        cursor += max(1, advance.spokenTokensConsumed)
                        lastMatchedTokenEnd = cursor
                        break
                    } else if matchedWordCount == crossedCue.firstGlobalWordIndex {
                        // Actor is now speaking words from the line after the cue line -> mark cue completed.
                        completedCueLineIDs.insert(crossedCue.id)
                    }
                }

                matchedWordCount = min(speakableWords.count, targetAfterAdvance)
                cursor += max(1, advance.spokenTokensConsumed)
                lastMatchedTokenEnd = cursor

                // If we just landed on an uncompleted cue boundary, pause matching so the cue line activates immediately.
                if lines.contains(where: {
                    $0.isCueLine && !completedCueLineIDs.contains($0.id) && $0.firstGlobalWordIndex == matchedWordCount
                }) {
                    break
                }
            } else {
                cursor += 1
            }
        }

        if matchedWordCount > previousMatchedCount {
            lastMatchAdvancedAt = Date()
        }

        if isFinal {
            consumedTranscriptWords = 0
            lastTranscriptWords = []
        } else if matchedWordCount > previousMatchedCount {
            consumedTranscriptWords = lastMatchedTokenEnd
        } else {
            // Keep up to the last 3 unmatched spoken tokens available so 1-word partial deliveries
            // can pair with the next word for bigram/trigram phrase resync.
            consumedTranscriptWords = max(0, spokenTokens.count - 3)
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
        guard matchedWordCount < speakableWords.count, spokenCursor < spokenTokens.count else { return nil }
        let spokenToken = spokenTokens[spokenCursor]
        let targetWord = speakableWords[matchedWordCount]

        // 1. Direct match on the immediate next atomic script token.
        if Self.tokensMatch(targetWord.token, spokenToken) {
            return MatchStep(expectedWordsConsumed: 1, spokenTokensConsumed: 1)
        }

        // 2. Small skip (1...6 script tokens) if the actor clipped filler words, punctuation-split subwords, or ASR dropped a word.
        let maxSmallLookahead = min(6, speakableWords.count - matchedWordCount - 1)
        if maxSmallLookahead >= 1 {
            for offset in 1...maxSmallLookahead {
                let candidate = speakableWords[matchedWordCount + offset]
                if offset >= 4 {
                    let isSubstantive = candidate.token.count >= 4
                    let hasNextMatch: Bool = {
                        guard matchedWordCount + offset + 1 < speakableWords.count,
                              spokenCursor + 1 < spokenTokens.count else { return false }
                        let nextCand = speakableWords[matchedWordCount + offset + 1]
                        return Self.tokensMatch(nextCand.token, spokenTokens[spokenCursor + 1])
                    }()
                    let hasPrevMatch: Bool = {
                        guard offset >= 1, spokenCursor >= 1 else { return false }
                        let prevCand = speakableWords[matchedWordCount + offset - 1]
                        return Self.tokensMatch(prevCand.token, spokenTokens[spokenCursor - 1])
                    }()
                    guard isSubstantive || hasNextMatch || hasPrevMatch else { continue }
                }
                if Self.tokensMatch(candidate.token, spokenToken) {
                    return MatchStep(expectedWordsConsumed: offset + 1, spokenTokensConsumed: 1)
                }
            }
        }

        // 3. Forward bigram resync (+2...25 tokens ahead) when 2+ spoken tokens are at `spokenCursor`.
        if spokenCursor + 1 < spokenTokens.count {
            let nextSpoken = spokenTokens[spokenCursor + 1]
            let maxResyncOffset = min(25, speakableWords.count - matchedWordCount - 2)
            if maxResyncOffset >= 2 {
                for offset in 2...maxResyncOffset {
                    let first = speakableWords[matchedWordCount + offset]
                    let second = speakableWords[matchedWordCount + offset + 1]
                    if Self.tokensMatch(first.token, spokenToken) && Self.tokensMatch(second.token, nextSpoken) {
                        return MatchStep(expectedWordsConsumed: offset + 2, spokenTokensConsumed: 2)
                    }
                }
            }
        }

        // 4. Trailing bigram resync (`[spokenTokens[spokenCursor - 1], spokenTokens[spokenCursor]]`)
        // Works even when SFSpeechRecognizer delivers 1 word per partial callback!
        if spokenCursor >= 1 {
            let prevSpoken = spokenTokens[spokenCursor - 1]
            let maxResyncOffset = min(25, speakableWords.count - matchedWordCount - 1)
            if maxResyncOffset >= 2 {
                for offset in 2...maxResyncOffset {
                    let first = speakableWords[matchedWordCount + offset - 1]
                    let second = speakableWords[matchedWordCount + offset]
                    if Self.tokensMatch(first.token, prevSpoken) && Self.tokensMatch(second.token, spokenToken) {
                        return MatchStep(expectedWordsConsumed: offset + 1, spokenTokensConsumed: 1)
                    }
                }
            }
        }

        return nil
    }

    private func refreshActiveIndices() {
        guard !lines.isEmpty else {
            activeLineIndex = 0
            activeWordIndexInLine = 0
            activeCueOrderIndex = nil
            totalSpokenProgress = 0
            return
        }

        // Check if an uncompleted cue line has been reached at the current `matchedWordCount` boundary
        // (for non-leading cue lines, as soon as the preceding actor words are completed).
        if let pendingCue = lines.first(where: { line in
            guard line.isCueLine, !completedCueLineIDs.contains(line.id) else { return false }
            if line.firstGlobalWordIndex == 0 {
                // Leading cue activates when explicitly activated or playing
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
            let normalizedFull = Self.normalizeCueComparisonText(trimmed)
            if cueNormalizedTexts.contains(normalizedFull) {
                return true
            }
            if let colonIdx = trimmed.firstIndex(of: ":") {
                let afterColon = String(trimmed[trimmed.index(after: colonIdx)...])
                let normalizedBody = Self.normalizeCueComparisonText(afterColon)
                if !normalizedBody.isEmpty && cueNormalizedTexts.contains(normalizedBody) {
                    return true
                }
            }
        }
        return false
    }

    nonisolated private static func normalizeCueComparisonText(_ raw: String) -> String {
        normalizeToSearchTokens(raw).joined(separator: " ")
    }

    // MARK: - Token Normalization

    nonisolated private static let contractions: [String: [String]] = [
        "dont": ["do", "not"], "cant": ["can", "not"], "cannot": ["can", "not"], "wont": ["will", "not"],
        "aint": ["am", "not"], "im": ["i", "am"], "youre": ["you", "are"], "theyre": ["they", "are"],
        "were": ["we", "are"], "isnt": ["is", "not"], "arent": ["are", "not"],
        "wasnt": ["was", "not"], "werent": ["were", "not"], "hasnt": ["has", "not"],
        "havent": ["have", "not"], "hadnt": ["had", "not"], "wouldnt": ["would", "not"],
        "couldnt": ["could", "not"], "shouldnt": ["should", "not"], "mustnt": ["must", "not"],
        "neednt": ["need", "not"], "shant": ["shall", "not"],
        "thats": ["that", "is"], "whats": ["what", "is"], "its": ["it", "is"], "lets": ["let", "us"],
        "hes": ["he", "is"], "shes": ["she", "is"], "theres": ["there", "is"], "heres": ["here", "is"],
        "wheres": ["where", "is"], "whos": ["who", "is"], "hows": ["how", "is"],
        "whens": ["when", "is"], "whys": ["why", "is"],
        "didnt": ["did", "not"], "doesnt": ["does", "not"], "ive": ["i", "have"],
        "youve": ["you", "have"], "weve": ["we", "have"], "theyve": ["they", "have"],
        "wouldve": ["would", "have"], "couldve": ["could", "have"], "shouldve": ["should", "have"],
        "mightve": ["might", "have"], "mustve": ["must", "have"],
        "ill": ["i", "will"], "youll": ["you", "will"], "hell": ["he", "will"],
        "shell": ["she", "will"], "theyll": ["they", "will"], "well": ["we", "will"],
        "itll": ["it", "will"], "thatll": ["that", "will"], "therell": ["there", "will"],
        "id": ["i", "would"], "youd": ["you", "would"], "hed": ["he", "would"],
        "shed": ["she", "would"], "wed": ["we", "would"], "theyd": ["they", "would"],
        "itd": ["it", "would"], "thatd": ["that", "would"], "whatd": ["what", "did"],
        "howd": ["how", "did"], "whod": ["who", "would"],
        "gonna": ["going", "to"], "wanna": ["want", "to"], "gotta": ["got", "to"],
        "hafta": ["have", "to"], "lemme": ["let", "me"], "gimme": ["give", "me"],
        "kinda": ["kind", "of"], "sorta": ["sort", "of"], "outta": ["out", "of"],
        "yall": ["you", "all"], "ok": ["okay"], "cuz": ["because"], "cause": ["because"]
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
        "12": "twelve", "twelve": "12",
        "13": "thirteen", "thirteen": "13",
        "14": "fourteen", "fourteen": "14",
        "15": "fifteen", "fifteen": "15",
        "16": "sixteen", "sixteen": "16",
        "17": "seventeen", "seventeen": "17",
        "18": "eighteen", "eighteen": "18",
        "19": "nineteen", "nineteen": "19",
        "20": "twenty", "twenty": "20",
        "30": "thirty", "thirty": "30",
        "40": "forty", "forty": "40",
        "50": "fifty", "fifty": "50",
        "60": "sixty", "sixty": "60",
        "70": "seventy", "seventy": "70",
        "80": "eighty", "eighty": "80",
        "90": "ninety", "ninety": "90"
    ]

    nonisolated private static func expandCompoundNumber(_ token: String) -> [String]? {
        guard token.count == 2, let value = Int(token), (21...99).contains(value), value % 10 != 0 else {
            return nil
        }
        let tens = "\(value / 10 * 10)"
        let ones = "\(value % 10)"
        if let tensWord = numberEquivalents[tens], let onesWord = numberEquivalents[ones] {
            return [tensWord, onesWord]
        }
        return nil
    }

    nonisolated static func normalizeToSearchTokens(_ raw: String) -> [String] {
        // Fold diacritics ("café" -> "cafe") and expand common spoken symbols + imperial height marks ("5′8″" -> "5 8").
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let prepped = folded
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "%", with: " percent ")
            .replacingOccurrences(of: "+", with: " plus ")
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
            .replacingOccurrences(of: "`", with: "")

        let chunks = prepped.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        var out: [String] = []
        for chunk in chunks {
            let token = chunk.lowercased()
            guard !token.isEmpty else { continue }
            if let expanded = contractions[token] {
                out.append(contentsOf: expanded)
            } else if let compound = expandCompoundNumber(token) {
                out.append(contentsOf: compound)
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
        // Possessive / plural trailing 's tolerance ("luke's" -> "lukes" vs "luke")
        if min(lhs.count, rhs.count) >= 3 && (lhs + "s" == rhs || rhs + "s" == lhs) {
            return true
        }
        if lhs.count >= 5 && rhs.count >= 5 {
            if lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs) { return true }
            if editDistance(lhs, rhs) <= 1 { return true }
        }
        // Handle 3-4 letter script typos or ASR homophones (e.g. "ike" vs "like" in The Last Summer, "for" vs "four").
        if lhs.count >= 3 && rhs.count >= 3 && abs(lhs.count - rhs.count) <= 1 {
            if (lhs.first == rhs.first || lhs.suffix(2) == rhs.suffix(2)) && editDistance(lhs, rhs) <= 1 {
                return true
            }
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
