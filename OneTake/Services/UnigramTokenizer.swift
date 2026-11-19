import Foundation

/// Pure-Swift SentencePiece Unigram Viterbi tokenizer for the pruned Flan-T5 Core ML notice parser.
///
/// Mirrors `scripts/ml/vocab_surgery.py` 1:1 (preserving `\n` via `<0x0A>` and using
/// `Unicode.Scalar` indexing for exact codepoint parity with Python).
nonisolated final class UnigramTokenizer: @unchecked Sendable {
    static let shared = UnigramTokenizer()

    let padTokenID: Int = 0
    let eosTokenID: Int = 1
    let unkTokenID: Int = 2

    private let lock = NSLock()
    private var pieces: [String] = []
    private var scores: [Double] = []
    private var pieceToID: [String: Int] = [:]
    private var maxPieceScalarLength: Int = 1
    private var newlineTokenID: Int = 2
    private var byteTokenIDs: [UInt8: Int] = [:]
    private let usesBundledAsset: Bool
    private var isLoaded: Bool = false

    init(pieces customPieces: [(piece: String, score: Double)] = []) {
        self.usesBundledAsset = customPieces.isEmpty
        if !customPieces.isEmpty {
            applyPiecesLocked(customPieces)
            self.isLoaded = true
        }
    }

    var isLoadedInMemory: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isLoaded
    }

    var hasFullVocab: Bool {
        lock.lock()
        defer { lock.unlock() }
        ensureLoadedLocked()
        return pieces.count > 1000
    }

    func loadIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        ensureLoadedLocked()
    }

    func unload() {
        lock.lock()
        defer { lock.unlock() }
        guard usesBundledAsset, isLoaded else { return }
        pieces.removeAll(keepingCapacity: false)
        scores.removeAll(keepingCapacity: false)
        pieceToID.removeAll(keepingCapacity: false)
        byteTokenIDs.removeAll(keepingCapacity: false)
        maxPieceScalarLength = 1
        newlineTokenID = unkTokenID
        isLoaded = false
    }

    func encode(text: String, appendEOS: Bool = true) -> [Int] {
        lock.lock()
        ensureLoadedLocked()
        let localPieceToID = pieceToID
        let localScores = scores
        let localMaxLen = maxPieceScalarLength
        let localNewlineID = newlineTokenID
        let localBytes = byteTokenIDs
        let localEOS = eosTokenID
        let localUNK = unkTokenID
        lock.unlock()

        var ids: [Int] = []
        let canonical = normalizeInputSymbols(text)
        let lines = canonical.components(separatedBy: "\n")

        for (lineIdx, rawLine) in lines.enumerated() {
            if lineIdx > 0 {
                ids.append(localNewlineID)
            }
            let normalized = normalizeSegment(rawLine)
            guard !normalized.isEmpty else { continue }

            let scalars = Array(normalized.unicodeScalars)
            let n = scalars.count
            var bestScore = [Double](repeating: -.infinity, count: n + 1)
            var bestStep = [Int](repeating: 0, count: n + 1)
            bestScore[0] = 0.0

            for i in 0..<n {
                let baseScore = bestScore[i]
                if baseScore == -.infinity { continue }
                let limit = min(n, i + localMaxLen)
                var matchedAny = false

                for j in (i + 1)...limit {
                    let sub = String(String.UnicodeScalarView(scalars[i..<j]))
                    if let pid = localPieceToID[sub] {
                        let cand = baseScore + localScores[pid]
                        if cand > bestScore[j] {
                            bestScore[j] = cand
                            bestStep[j] = j - i
                            matchedAny = true
                        }
                    }
                }

                if bestStep[i + 1] == 0 || (!matchedAny && bestScore[i + 1] == -.infinity) {
                    let cand = baseScore - 30.0
                    if cand > bestScore[i + 1] {
                        bestScore[i + 1] = cand
                        bestStep[i + 1] = -1
                    }
                }
            }

            var spans: [(start: Int, end: Int)] = []
            var pos = n
            while pos > 0 {
                let step = bestStep[pos]
                if step > 0 {
                    let start = pos - step
                    spans.append((start, pos))
                    pos = start
                } else {
                    spans.append((pos - 1, -1))
                    pos -= 1
                }
            }
            spans.reverse()

            for span in spans {
                if span.end == -1 {
                    let scalar = scalars[span.start]
                    for byte in String(scalar).utf8 {
                        ids.append(localBytes[byte] ?? localUNK)
                    }
                } else {
                    let sub = String(String.UnicodeScalarView(scalars[span.start..<span.end]))
                    ids.append(localPieceToID[sub] ?? localUNK)
                }
            }
        }

        if appendEOS {
            ids.append(localEOS)
        }
        return ids
    }

    func decode(tokens: [Int], skipSpecialTokens: Bool = true) -> String {
        lock.lock()
        ensureLoadedLocked()
        let localPieces = pieces
        let localNewlineID = newlineTokenID
        lock.unlock()

        var outParts: [String] = []
        var byteBuffer: [UInt8] = []

        func flushBytes() {
            if !byteBuffer.isEmpty {
                outParts.append(String(decoding: byteBuffer, as: UTF8.self))
                byteBuffer.removeAll(keepingCapacity: true)
            }
        }

        for tid in tokens {
            if skipSpecialTokens && (tid == padTokenID || tid == eosTokenID) {
                continue
            }
            if tid == localNewlineID {
                flushBytes()
                outParts.append("\n")
                continue
            }
            if tid == unkTokenID {
                flushBytes()
                continue
            }
            guard tid >= 0 && tid < localPieces.count else { continue }
            let piece = localPieces[tid]
            if let byteVal = parseByteToken(piece) {
                byteBuffer.append(byteVal)
                continue
            }
            flushBytes()
            outParts.append(piece.replacingOccurrences(of: "\u{2581}", with: " "))
        }
        flushBytes()

        var joined = outParts.joined()
        if joined.hasPrefix(" ") {
            joined.removeFirst()
        }
        return joined.replacingOccurrences(of: "\n ", with: "\n")
    }

    // MARK: - Private Helpers

    private func ensureLoadedLocked() {
        guard usesBundledAsset, !isLoaded else { return }
        autoreleasepool {
            if let url = locateVocabAsset(),
               let data = try? Data(contentsOf: url),
               let rawArray = try? JSONSerialization.jsonObject(with: data) as? [[Any]] {
                var loaded: [(String, Double)] = []
                loaded.reserveCapacity(rawArray.count)
                for pair in rawArray where pair.count >= 2 {
                    if let piece = pair[0] as? String,
                       let scoreNum = pair[1] as? NSNumber {
                        loaded.append((piece, scoreNum.doubleValue))
                    }
                }
                if !loaded.isEmpty {
                    applyPiecesLocked(loaded)
                } else {
                    applyFallbackPiecesLocked()
                }
            } else {
                applyFallbackPiecesLocked()
            }
        }
        isLoaded = true
    }

    private func locateVocabAsset() -> URL? {
        if let url = Bundle.main.url(forResource: "sp_vocab", withExtension: "json") {
            return url
        }
        if let url = Bundle(for: UnigramTokenizer.self).url(forResource: "sp_vocab", withExtension: "json") {
            return url
        }
        let nested = Bundle.main.bundleURL.appendingPathComponent("MLModels/sp_vocab.json")
        if FileManager.default.fileExists(atPath: nested.path) {
            return nested
        }
        return nil
    }

    private func applyPiecesLocked(_ items: [(piece: String, score: Double)]) {
        pieces = items.map(\.piece)
        scores = items.map(\.score)
        pieceToID = Dictionary(minimumCapacity: items.count)
        byteTokenIDs = Dictionary(minimumCapacity: 256)
        var maxLen = 1

        for (idx, item) in items.enumerated() {
            pieceToID[item.piece] = idx
            if let byteVal = parseByteToken(item.piece) {
                byteTokenIDs[byteVal] = idx
            } else if !(item.piece.hasPrefix("<") && item.piece.hasSuffix(">")) {
                let len = item.piece.unicodeScalars.count
                if len > maxLen { maxLen = len }
            }
        }

        maxPieceScalarLength = maxLen
        newlineTokenID = byteTokenIDs[0x0A] ?? pieceToID["<extra_id_0>"] ?? unkTokenID
    }

    private func applyFallbackPiecesLocked() {
        var minimal: [(String, Double)] = [("<pad>", 0.0), ("</s>", 0.0), ("<unk>", 0.0)]
        for b in 0...255 {
            minimal.append((String(format: "<0x%02X>", b), -20.0))
        }
        applyPiecesLocked(minimal)
    }

    private func normalizeInputSymbols(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2014}", with: "-")
            .replacingOccurrences(of: "\u{2212}", with: "-")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2026}", with: "...")
            .replacingOccurrences(of: "\u{20B9}", with: "Rs.")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private func normalizeSegment(_ raw: String) -> String {
        var collapsed = ""
        collapsed.reserveCapacity(raw.count)
        var inSpace = true // trims leading spaces naturally
        for scalar in raw.unicodeScalars {
            if scalar == " " || scalar == "\t" || scalar == "\r" {
                if !inSpace {
                    collapsed.append(" ")
                    inSpace = true
                }
            } else {
                collapsed.unicodeScalars.append(scalar)
                inSpace = false
            }
        }
        if collapsed.hasSuffix(" ") {
            collapsed.removeLast()
        }
        guard !collapsed.isEmpty else { return "" }
        return "\u{2581}" + collapsed.replacingOccurrences(of: " ", with: "\u{2581}")
    }

    private func parseByteToken(_ piece: String) -> UInt8? {
        guard piece.count == 6,
              piece.hasPrefix("<0x"),
              piece.hasSuffix(">") else {
            return nil
        }
        let start = piece.index(piece.startIndex, offsetBy: 3)
        let end = piece.index(piece.startIndex, offsetBy: 5)
        return UInt8(piece[start..<end], radix: 16)
    }
}
