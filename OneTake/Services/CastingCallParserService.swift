import Foundation
import UIKit
import Vision
import PDFKit
import ImageIO
import NaturalLanguage

// MARK: - Parsed Result Model

nonisolated struct ParsedCastingCall: Sendable {
    var rawExtractedText: String = ""
    var projectName: String = ""
    var productionType: ProductionType = .featureFilm
    var roleName: String = ""
    var roleDescription: String = ""
    var deadline: Date = Calendar.current.date(byAdding: .day, value: 3, to: Date()) ?? Date()
    var hasDetectedDeadline: Bool = false
    var recipientEmail: String = ""
    var requirements: [SubmissionRequirement] = []
    var requiredHeadshotRatio: HeadshotAspectRatio = .ratio4x5
    var maxSlateSeconds: Double = 45.0
    var maxClipSeconds: Double = 180.0
    var maxPerClipSizeMB: Double = 100.0
    var detectedMainRole: String = ""
    var detectedCueRole: String = ""
    var cueLines: [CueLine] = []
    var teleprompterLines: [String] = []
    var detectedScriptText: String? = nil

    var hasDetectedScript: Bool {
        if let text = detectedScriptText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return false
    }
}

// MARK: - Protocol

nonisolated protocol CastingCallParserServiceProtocol: Sendable {
    func parseImage(_ image: UIImage) async throws -> ParsedCastingCall
    func parseImages(_ images: [UIImage]) async throws -> ParsedCastingCall
    func parsePDF(data: Data) async throws -> ParsedCastingCall
    func parseDocx(data: Data) async throws -> ParsedCastingCall
    func parseText(_ text: String) async -> ParsedCastingCall
    func parseMultipleFiles(urls: [URL]) async throws -> ParsedCastingCall
}

// MARK: - CoreML Classifier Holder

private nonisolated final class ScriptClassifierBox: @unchecked Sendable {
    private let lock = NSLock()
    private let model: NLModel?

    init() {
        let url = Bundle.main.url(forResource: "ScriptElementClassifier", withExtension: "mlmodelc")
            ?? Bundle(for: CastingCallParserService.self).url(forResource: "ScriptElementClassifier", withExtension: "mlmodelc")
        self.model = url.flatMap { try? NLModel(contentsOf: $0) }
    }

    func classify(_ line: String) -> (label: String, confidence: Double)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let model else { return nil }
        let hypotheses = model.predictedLabelHypotheses(for: trimmed, maximumCount: 1)
        guard let best = hypotheses.max(by: { $0.value < $1.value }) else { return nil }
        return (best.key, best.value)
    }
}

// MARK: - CastingCallParserService Implementation

nonisolated final class CastingCallParserService: CastingCallParserServiceProtocol, @unchecked Sendable {
    static let shared = CastingCallParserService()

    private let classifierBox = ScriptClassifierBox()

    init() {}

    // MARK: - Image / Scan OCR with Column Reconstruction

    func parseImage(_ image: UIImage) async throws -> ParsedCastingCall {
        let layout = await Task.detached(priority: .userInitiated) {
            NoticeOCR.recognizeLayout(in: image, pageIndex: 0)
        }.value
        return await parseLayout(lines: layout.lines, rawText: layout.text)
    }

    func parseImages(_ images: [UIImage]) async throws -> ParsedCastingCall {
        var allLines: [LayoutLine] = []
        var pages: [String] = []
        for (idx, image) in images.enumerated() {
            let layout = await Task.detached(priority: .userInitiated) {
                NoticeOCR.recognizeLayout(in: image, pageIndex: idx)
            }.value
            let trimmed = layout.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                allLines.append(contentsOf: layout.lines)
                pages.append(trimmed)
            }
        }
        return await parseLayout(lines: allLines, rawText: pages.joined(separator: "\n\n"))
    }

    func extractRawText(from image: UIImage) async throws -> String {
        await Task.detached(priority: .userInitiated) {
            NoticeOCR.recognizeText(in: image)
        }.value
    }

    /// Reconstructs reading-order text from Vision/layout bounding boxes using `OCRLayoutReconstructor`.
    static func reconstructColumns(from boxes: [OCRLayoutReconstructor.TextBoundingBox]) -> String {
        OCRLayoutReconstructor.reconstruct(boxes: boxes)
    }

    private static func extractTextWithColumnReconstructionSync(
        from cgImage: CGImage,
        orientation: CGImagePropertyOrientation
    ) throws -> String {
        NoticeOCR.recognizeLayout(from: cgImage, orientation: orientation, pageIndex: 0).text
    }

    // MARK: - PDF Parsing with Geometry & Vision OCR Fallback

    func parsePDF(data: Data) async throws -> ParsedCastingCall {
        let text = try await extractRawText(fromPDF: data)
        return await parseText(text)
    }

    func extractRawText(fromPDF data: Data) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try Self.extractRawTextFromPDFSync(data)
        }.value
    }

    private static func extractRawTextFromPDFSync(_ data: Data) throws -> String {
        guard let document = PDFDocument(data: data) else {
            return ""
        }

        var fullExtractedText = ""
        let pageCount = document.pageCount

        for i in 0..<pageCount {
            guard let page = document.page(at: i) else { continue }
            let rawPageText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if rawPageText.isEmpty {
                let ocrText = try renderAndOCRPDFPageSync(page)
                if !ocrText.isEmpty {
                    fullExtractedText += (fullExtractedText.isEmpty ? "" : "\n\n") + ocrText
                }
            } else {
                let layoutLines = PDFGeometryExtractor.extractLines(from: page, pageIndex: i)
                let reconstructed = OCRLayoutReconstructor.reconstruct(layoutLines: layoutLines)
                    .replacingOccurrences(of: "\u{FFFC}", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let cleanedRaw = rawPageText.replacingOccurrences(of: "\u{FFFC}", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                var finalPageText = reconstructed.isEmpty ? cleanedRaw : reconstructed

                // Cover pages often embed the show/film logo as an inline graphic ("\u{FFFC}"). OCR page 0 once to recover it.
                if i == 0 && rawPageText.contains("\u{FFFC}"),
                   let coverOCR = try? renderAndOCRPDFPageSync(page), !coverOCR.isEmpty {
                    let existingLower = finalPageText.lowercased()
                    let uniqueCoverLines = coverOCR
                        .components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty && !existingLower.contains($0.lowercased()) }
                    if !uniqueCoverLines.isEmpty {
                        finalPageText = uniqueCoverLines.joined(separator: "\n") + "\n" + finalPageText
                    }
                }

                if !finalPageText.isEmpty {
                    fullExtractedText += (fullExtractedText.isEmpty ? "" : "\n\n") + finalPageText
                }
            }
        }

        return fullExtractedText
    }

    private static func renderAndOCRPDFPageSync(_ page: PDFPage) throws -> String {
        let mediaBox = page.bounds(for: .mediaBox)
        guard mediaBox.width > 0, mediaBox.height > 0 else { return "" }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 2.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: mediaBox.size, format: format)
        let renderedImage = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: mediaBox.size))
            ctx.cgContext.translateBy(x: 0.0, y: mediaBox.size.height)
            ctx.cgContext.scaleBy(x: 1.0, y: -1.0)
            ctx.cgContext.translateBy(x: -mediaBox.origin.x, y: -mediaBox.origin.y)
            page.draw(with: .mediaBox, to: ctx.cgContext)
        }

        guard let cgImage = renderedImage.cgImage else { return "" }
        return try extractTextWithColumnReconstructionSync(from: cgImage, orientation: .up)
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - DOCX Parsing via ZipArchive & Bounded XMLParser

    func parseDocx(data: Data) async throws -> ParsedCastingCall {
        let text = try await extractRawText(fromDocx: data)
        return await parseText(text)
    }

    func extractRawText(fromDocx data: Data) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try Self.extractRawTextFromDocxSync(data)
        }.value
    }

    private static func extractRawTextFromDocxSync(_ data: Data) throws -> String {
        let xmlData = try ZipArchive.readEntry(
            named: "word/document.xml",
            from: data,
            maxEntryBytes: 32 * 1024 * 1024
        )
        return parseDocxXML(xmlData)
    }

    private static func parseDocxXML(_ data: Data) -> String {
        let delegate = DocxXMLParserDelegate(maxCharacters: 2_000_000)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        parser.parse()
        return delegate.extractedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Multi-File Import Support

    func parseMultipleFiles(urls: [URL]) async throws -> ParsedCastingCall {
        let extractedCombined = try await Task.detached(priority: .userInitiated) {
            var combinedText = ""
            var firstError: Error?

            for url in urls {
                let accessing = url.startAccessingSecurityScopedResource()
                defer {
                    if accessing {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                do {
                    let data = try Data(contentsOf: url)
                    let filename = url.lastPathComponent.lowercased()

                    let extracted: String
                    if filename.hasSuffix(".pdf") {
                        extracted = try Self.extractRawTextFromPDFSync(data)
                    } else if filename.hasSuffix(".docx") {
                        extracted = try Self.extractRawTextFromDocxSync(data)
                    } else if let image = UIImage(data: data) {
                        extracted = NoticeOCR.recognizeText(in: image)
                    } else {
                        extracted = String(data: data, encoding: .utf8)
                            ?? String(data: data, encoding: .unicode)
                            ?? ""
                    }

                    if !extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        combinedText += (combinedText.isEmpty ? "" : "\n\n") + extracted
                    }
                } catch {
                    if firstError == nil {
                        firstError = error
                    }
                }
            }

            if combinedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let firstError {
                throw firstError
            }
            return combinedText
        }.value
        return await self.parseText(extractedCombined)
    }

    // MARK: - Deterministic + ML-Assisted Parser

    func parseText(_ text: String) async -> ParsedCastingCall {
        await parseLayout(lines: [], rawText: text)
    }

    func parseLayout(lines layoutLines: [LayoutLine], rawText text: String) async -> ParsedCastingCall {
        let deterministic = await Task.detached(priority: .userInitiated) { [self] in
            self.parseTextSync(text, layoutLines: layoutLines)
        }.value
        return await OnDeviceIntelligence.refineParsedCall(deterministic, sourceText: text)
    }

    private func parseTextSync(_ text: String, layoutLines: [LayoutLine] = []) -> ParsedCastingCall {
        var result = ParsedCastingCall()
        let normalizedRaw = text.replacingOccurrences(of: "\u{FFFC}", with: "")
        result.rawExtractedText = normalizedRaw
        let cleanText = normalizedRaw.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = cleanText.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        // 1. Recipient Email Extraction (prioritizing "submit to" / "send to" / "casting" emails)
        result.recipientEmail = extractPrioritizedEmail(from: lines)

        // 2. Production Type (word-boundary safe so "screenplay" does not match "play")
        let lowerText = cleanText.lowercased()
        if matchesRegex(#"\b(?:feature\s+film|movie|cinema)\b"#, in: lowerText) {
            result.productionType = .featureFilm
        } else if matchesRegex(#"\bshort\s+film\b"#, in: lowerText) {
            result.productionType = .shortFilm
        } else if matchesRegex(#"\b(?:web\s+series|ott\s+series)\b"#, in: lowerText) {
            result.productionType = .webSeries
        } else if matchesRegex(#"\b(?:series|television|tv\s+show)\b"#, in: lowerText) {
            result.productionType = .series
        } else if matchesRegex(#"\b(?:commercial|ad\s+film|advertisement)\b"#, in: lowerText) {
            result.productionType = .adFilm
        } else if isTheaterProduction(in: lowerText) || matchesRegex(#"\bmusical\b"#, in: lowerText) {
            result.productionType = .theater
        }

        // 3. Dialogue Blocks (parsed early so deadline & notice extraction stay isolated from screenplay dialogue)
        let dialogueResult = parseDialogue(from: lines)
        result.detectedMainRole = dialogueResult.mainRole
        result.detectedCueRole = dialogueResult.cueRole
        result.cueLines = dialogueResult.cueLines
        result.teleprompterLines = dialogueResult.teleprompterLines
        result.detectedScriptText = dialogueResult.scriptText

        // 4. Project Name
        result.projectName = extractProjectName(from: lines, cleanText: cleanText, layoutLines: layoutLines)

        // 5. Deadline Extraction (only inspect notice/header lines, never screenplay dialogue lines)
        if let deadline = extractDeadline(from: lines, hasDialogue: dialogueResult.scriptText != nil) {
            result.deadline = deadline
            result.hasDetectedDeadline = true
        }

        // 6. Constraints: Ratio, Slate Max, Clip Max, Size Max
        if matchesRegex(#"\b4[:x]5\b"#, in: lowerText) {
            result.requiredHeadshotRatio = .ratio4x5
        } else if matchesRegex(#"\b2[:x]3\b"#, in: lowerText) {
            result.requiredHeadshotRatio = .ratio2x3
        } else if matchesRegex(#"\b1[:x]1\b"#, in: lowerText) || mentionsSquareHeadshot(in: lines) {
            result.requiredHeadshotRatio = .ratio1x1
        }

        // Slate / intro video max seconds (e.g., "5s slate", "30–60 second introduction video", "slate: 30s")
        if let slateSeconds = extractSlateSeconds(from: cleanText) {
            result.maxSlateSeconds = slateSeconds
        }

        // Clip max seconds (e.g., "2 min clip", "2-minute tape", "90s clip", "90 seconds clip", "clip: 90s")
        if let clipSeconds = extractClipMaxSeconds(from: cleanText) {
            result.maxClipSeconds = clipSeconds
        }

        // Clip max size MB (e.g. "100 MB", "50mb")
        if let mbValue = firstCaptureDouble(#"(\d+)\s*mb\b"#, in: cleanText) {
            result.maxPerClipSizeMB = mbValue
        }

        // 7. Role Name & Role Description Extraction
        result.roleName = extractRoleName(from: lines, cleanText: cleanText, detectedMainRole: dialogueResult.mainRole)
        result.roleDescription = extractRoleDescription(
            from: lines,
            cleanText: cleanText,
            hasDialogue: dialogueResult.scriptText != nil
        )

        // 8. Requirements Checklist (clean: email kept out; omit self-tape when flyer only asks for photos + intro)
        var reqs: [SubmissionRequirement] = [
            SubmissionRequirement(title: "Guided Headshots (3 Angles: Front, Left, Right)", isCompleted: false),
            SubmissionRequirement(title: "Slate / Introduction Video", isCompleted: false)
        ]

        let asksForScriptOrTape = dialogueResult.scriptText != nil
            || matchesRegex(#"\b(?:self-?tape|audition\s+(?:video|for|script|clip|scene|take)|attached\s+(?:audition\s+)?script|sides|monologue|\bclip\b|\btape\b)\b"#, in: lowerText)
        let asksOnlyForPhotosAndIntro = matchesRegex(#"\b(?:photos?|photographs?|pictures?|headshots?)\b"#, in: lowerText)
            && matchesRegex(#"\b(?:intro(?:duction|ducing)?\s+video|slate)\b"#, in: lowerText)
            && !asksForScriptOrTape
        if asksForScriptOrTape || !asksOnlyForPhotosAndIntro {
            reqs.append(SubmissionRequirement(title: "Audition Self-Tape Take", isCompleted: false))
        }

        if matchesRegex(#"\b(?:resume|cv)\b"#, in: lowerText) {
            reqs.append(SubmissionRequirement(title: "Actor Resume / Bio", isCompleted: false))
        }
        if matchesRegex(#"\b(?:showreel|demo\s+reel)\b"#, in: lowerText) {
            reqs.append(SubmissionRequirement(title: "Demo Showreel", isCompleted: false))
        }

        result.requirements = reqs
        return result
    }

    // MARK: - Regex Extraction Helpers

    private func extractPrioritizedEmail(from lines: [String]) -> String {
        let pattern = #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return ""
        }

        var bestEmail = ""
        var bestScore = Int.min

        for rawLine in lines where !rawLine.isEmpty {
            let line = sanitizeEmailLine(rawLine)
            let nsRange = NSRange(line.startIndex..., in: line)
            let matches = regex.matches(in: line, range: nsRange)
            guard !matches.isEmpty else { continue }
            let lowerLine = line.lowercased()

            for match in matches {
                guard let range = Range(match.range, in: line) else { continue }
                let email = String(line[range])
                let lowerEmail = email.lowercased()

                var score = 0
                if lowerLine.contains("submit to") || lowerLine.contains("send to") || lowerLine.contains("send tape") || lowerLine.contains("send self-tape") || lowerLine.contains("submissions") || lowerLine.contains("email to apply") {
                    score += 100
                } else if lowerLine.contains("submit") || lowerLine.contains("apply") || lowerLine.contains("deliver to") || lowerLine.contains("mail ") {
                    score += 60
                }

                if lowerLine.contains("casting") {
                    score += 40
                }
                if lowerEmail.contains("casting") || lowerEmail.contains("submissions") || lowerEmail.contains("audition") {
                    score += 30
                }

                if score == 0 && (lowerLine.contains("agent") || lowerLine.contains("manager") || lowerLine.contains("contact") || lowerLine.contains("coordinator")) {
                    score -= 10
                }

                if score > bestScore {
                    bestScore = score
                    bestEmail = email
                }
            }
        }

        return bestEmail
    }

    private func sanitizeEmailLine(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: #"\s*@\s*"#, with: "@", options: .regularExpression)
            .replacingOccurrences(of: #"([A-Za-z0-9._%+-]+@[A-Za-z0-9-]+)\s*\.\s*([A-Za-z]{2,})"#, with: "$1.$2", options: .regularExpression)
    }

    private func isTheaterProduction(in lowerText: String) -> Bool {
        if matchesRegex(#"\b(?:theatre|theater|stage\s+play|one-act\s+play|broadway\s+play)\b"#, in: lowerText) {
            return true
        }
        // Match standalone word "play" (e.g., "a new play") without matching "to play a role".
        let pattern = #"\bplay\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return false }
        let matches = regex.matches(in: lowerText, range: NSRange(lowerText.startIndex..., in: lowerText))
        for match in matches {
            guard let range = Range(match.range, in: lowerText) else { continue }
            let before = String(lowerText[..<range.lowerBound])
            let after = String(lowerText[range.upperBound...])
            if before.hasSuffix("to ") || after.hasPrefix(" the ") || after.hasPrefix(" a ") || after.hasPrefix(" an ") {
                continue
            }
            return true
        }
        return false
    }

    private func mentionsSquareHeadshot(in lines: [String]) -> Bool {
        let squareWordRegex = try? NSRegularExpression(pattern: #"\bsquare\b"#, options: .caseInsensitive)
        let properPlaceRegex = try? NSRegularExpression(pattern: #"\b[A-Z][a-z]+\s+Square\b"#, options: [])
        let unitRegex = try? NSRegularExpression(pattern: #"\bsquare\s+(?:feet|ft|meters?|m|miles?|km|yards?|blocks?)\b"#, options: .caseInsensitive)

        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            guard squareWordRegex?.firstMatch(in: line, range: range) != nil else { continue }

            let lower = line.lowercased()
            let hasPhotoContext = lower.contains("headshot")
                || lower.contains("photo")
                || lower.contains("ratio")
                || lower.contains("crop")
                || lower.contains("aspect")
                || lower.contains("format")
                || lower.contains("frame")
                || lower.contains("image")

            if hasPhotoContext {
                return true
            }
            if unitRegex?.firstMatch(in: line, range: range) != nil {
                continue
            }
            if properPlaceRegex?.firstMatch(in: line, range: range) != nil {
                continue
            }
            return true
        }
        return false
    }

    private func extractSlateSeconds(from text: String) -> Double? {
        let rangePatterns = [
            #"(\d+)\s*[–-]\s*(\d+)\s*(?:seconds?|secs?|s)\b(?:\s*|-)*(?:slate|intro(?:duction)?\s+video|intro)\b"#,
            #"\b(?:slate|intro(?:duction)?\s+video)\b(?:\s*(?:max|maximum|limit|under|up\s+to|:|-|\(|of))*\s*(\d+)\s*[–-]\s*(\d+)\s*(?:seconds?|secs?|s)\b"#
        ]
        for pattern in rangePatterns {
            if let upper = secondCaptureDouble(pattern, in: text) {
                return upper
            }
        }

        let patterns = [
            #"(\d+)\s*(?:seconds?|secs?|s)\b(?:\s*|-)*(?:slate|intro(?:duction)?\s+video)\b"#,
            #"\b(?:slate|intro(?:duction)?\s+video)\b(?:\s*(?:max|maximum|limit|under|up\s+to|:|-|\(|of))*\s*(\d+)\s*(?:seconds?|secs?|s)\b"#
        ]
        for pattern in patterns {
            if let value = firstCaptureDouble(pattern, in: text) {
                return value
            }
        }
        return nil
    }

    private func secondCaptureDouble(_ pattern: String, in text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let nsRange = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: nsRange),
              match.numberOfRanges > 2,
              let range = Range(match.range(at: 2), in: text) else {
            return nil
        }
        return Double(text[range])
    }

    private func extractProjectName(
        from lines: [String],
        cleanText: String,
        layoutLines: [LayoutLine] = []
    ) -> String {
        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("project:") || lower.hasPrefix("title:") || lower.hasPrefix("film:") || lower.hasPrefix("audition for:") {
                let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count > 1 && !parts[1].trimmingCharacters(in: .whitespaces).isEmpty {
                    return parts[1].trimmingCharacters(in: .whitespaces)
                }
            }
        }

        // Look for explicit project folder references (e.g. project folder "Heer Ranjha")
        if let folderRegex = try? NSRegularExpression(pattern: #"project\s+folder\s+["“]([^"”\n]{2,60})["”]"#, options: .caseInsensitive),
           let match = folderRegex.firstMatch(in: cleanText, range: NSRange(cleanText.startIndex..., in: cleanText)),
           match.numberOfRanges > 1,
           let range = Range(match.range(at: 1), in: cleanText) {
            let extracted = String(cleanText[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !extracted.isEmpty {
                return extracted
            }
        }

        // Look for musical / play cover headers (e.g. "GREASE - THE MUSICAL" on cover or TOC page 2)
        for line in lines.prefix(120) {
            if let range = line.range(of: #"\s*-\s*THE MUSICAL\b"#, options: [.regularExpression, .caseInsensitive]) {
                let candidate = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty {
                    return smartTitleCase(candidate)
                }
            }
        }

        // Handle explicit feature/short film title banners such as "PHOTON - A FEATURE FILM" before prose fallbacks
        for line in lines.prefix(10) {
            if let range = line.range(of: #"\s*[-–]\s*A\s+(?:FEATURE|SHORT)\s+FILM\b"#, options: [.regularExpression, .caseInsensitive]) {
                let candidate = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty {
                    return smartTitleCase(candidate)
                }
            }
        }

        // Look for named casting studio / production house ("Yash Raj Films is looking for...", "MUKESH CHHABRA CASTING COMPANY")
        if let companyRegex = try? NSRegularExpression(pattern: #"([A-Z][A-Za-z0-9.&'’ -]{2,45}?)\s+(?:is|are)\s+looking\s+for\b"#, options: []),
           let match = companyRegex.firstMatch(in: cleanText, range: NSRange(cleanText.startIndex..., in: cleanText)),
           match.numberOfRanges > 1,
           let range = Range(match.range(at: 1), in: cleanText) {
            let entity = String(cleanText[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            let lowerEntity = entity.lowercased()
            if !lowerEntity.contains("we ") && lowerEntity != "we" && !lowerEntity.hasPrefix("our ") && !lowerEntity.contains("production house") && !lowerEntity.contains("casting call") {
                return entity
            }
        }

        let genericSuffixes: Set<String> = ["casting company", "casting studio", "films", "productions"]
        for (idx, rawLine) in lines.prefix(15).enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = trimmed.lowercased()
            guard !trimmed.isEmpty, trimmed.count <= 60,
                  (lower.contains("casting company") || lower.contains("casting studio") || lower.hasSuffix("films") || lower.hasSuffix("productions")),
                  !lower.contains("production house") else { continue }

            if genericSuffixes.contains(lower), idx > 0 {
                let prev = lines[idx - 1].trimmingCharacters(in: .whitespacesAndNewlines)
                if !prev.isEmpty, prev.count <= 40, !prev.lowercased().contains("casting call") {
                    return smartTitleCase("\(prev) \(trimmed)")
                }
            }
            return smartTitleCase(trimmed)
        }

        // Look for show title in cover notes ("Grease is such a fun production...")
        if let showRegex = try? NSRegularExpression(pattern: #"\b([A-Z][A-Za-z0-9'&-]{2,30})\s+is\s+(?:such\s+a|a)\s+(?:fun\s+|new\s+)?production\b"#, options: []),
           let match = showRegex.firstMatch(in: cleanText, range: NSRange(cleanText.startIndex..., in: cleanText)),
           match.numberOfRanges > 1,
           let range = Range(match.range(at: 1), in: cleanText) {
            let title = String(cleanText[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if title.lowercased() != "this" && title.lowercased() != "it" {
                return title
            }
        }

        let categoryOrBannerExact: Set<String> = [
            "feature film", "short film", "web series", "ad film", "commercial",
            "series", "television", "theater", "theatre", "casting call",
            "casting notice", "now casting", "apply for free", "songs & scenes",
            "audition sides", "project details", "key criteria", "requirements to be submitted", "how to apply",
            "role", "age", "gender", "category", "location", "language", "languages", "skills", "character look"
        ]
        let sentenceStarts = [
            "we are ", "looking for ", "interested ", "kindly ", "please ",
            "age group", "if you ", "audition deadline", "you can reach", "download the",
            "a message from", "issued", "region", "scan qr", "email to apply"
        ]

        // Spatial typographic hierarchy fallback: pick prominent upper-half display titles from OCR layout.
        if !layoutLines.isEmpty {
            let prominent = layoutLines
                .filter { line in
                    let cleaned = line.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”'•-–")))
                    let lower = cleaned.lowercased()
                    guard line.rect.maxY >= 0.45,
                          line.rect.height >= 0.032,
                          cleaned.count >= 3,
                          cleaned.count <= 55,
                          !categoryOrBannerExact.contains(lower),
                          !lower.contains("casting call"),
                          !lower.contains("casting notice"),
                          !lower.contains("looking for"),
                          !sentenceStarts.contains(where: { lower.hasPrefix($0) }),
                          !lower.contains("@"),
                          !lower.contains("http"),
                          !lower.contains("www."),
                          !lower.contains("for a feature film"),
                          !lower.contains("for a short film"),
                          cleaned.rangeOfCharacter(from: .letters) != nil else {
                        return false
                    }
                    return true
                }
                .max { lhs, rhs in
                    if abs(lhs.rect.height - rhs.rect.height) > 0.008 {
                        return lhs.rect.height < rhs.rect.height
                    }
                    return lhs.rect.midY < rhs.rect.midY
                }
            if let prominent {
                return smartTitleCase(prominent.text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        if let headerLine = lines.first(where: { line in
            let cleaned = line.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”'•-–")))
            guard !cleaned.isEmpty, cleaned.count < 60,
                  cleaned.first?.isUppercase == true,
                  !cleaned.hasSuffix("."),
                  cleaned.rangeOfCharacter(from: .letters) != nil else { return false }
            let lower = cleaned.lowercased()
            if categoryOrBannerExact.contains(lower) || lower.contains("casting call") || lower.contains("casting notice") {
                return false
            }
            if sentenceStarts.contains(where: { lower.hasPrefix($0) }) {
                return false
            }
            if lower.contains("@") || lower.contains("http") || lower.contains("www.") {
                return false
            }
            return true
        }) {
            return headerLine
                .replacingOccurrences(of: "CASTING CALL - ", with: "")
                .replacingOccurrences(of: "CASTING CALL – ", with: "")
                .replacingOccurrences(of: "CASTING NOTICE: ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return "Untitled Audition"
    }

    private func extractDeadline(from lines: [String], hasDialogue: Bool) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }

        for (idx, line) in lines.enumerated() {
            let lower = line.lowercased()
            if lower.contains("issued") { continue }
            let isDeadlineCue = lower.contains("deadline")
                || lower.contains("submit by")
                || lower.contains("due")
                || lower.contains("last date")
                || lower.contains("apply by")
                || lower.contains("apply before")
                || lower.contains("closes on")
                || lower.contains("submissions close")
                || lower.contains("closing date")
                || lower.contains("valid till")
                || lower.contains("valid until")
                || ((lower.contains("submission") || lower.contains("send ")) && lower.contains(" by"))
            if isDeadlineCue {
                let candidateLine = idx + 1 < lines.count ? "\(line) \(lines[idx + 1])" : line
                let matches = detector.matches(in: candidateLine, options: [], range: NSRange(candidateLine.startIndex..., in: candidateLine))
                if let dateMatch = matches.first?.date {
                    return dateMatch
                }
            }
        }

        // Handle date phrases split across two wrapped lines (e.g., "...by 15\nDecember, 2026.")
        let nonIssuedLines = lines.filter { !$0.lowercased().contains("issued") }
        let fallbackLines = hasDialogue ? Array(nonIssuedLines.prefix(25)) : nonIssuedLines
        let fallbackText = fallbackLines.joined(separator: " ")
        let explicitMonthOrNumericDate = #"\b(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\b|\b\d{1,2}[/-]\d{1,2}[/-]\d{2,4}\b"#

        let matches = detector.matches(in: fallbackText, options: [], range: NSRange(fallbackText.startIndex..., in: fallbackText))
        for match in matches {
            guard let date = match.date, date > Date(),
                  let range = Range(match.range, in: fallbackText) else { continue }
            let matchedSnippet = String(fallbackText[range])
            if matchesRegex(explicitMonthOrNumericDate, in: matchedSnippet.lowercased()) {
                return date
            }
        }
        return nil
    }

    /// Parses free-form user deadline text (e.g. "Nov 30, 5:00 PM", "30/11/2026 17:00",
    /// "2026-12-15", "tomorrow 6pm") into a `Date`.
    nonisolated func parseUserDeadlineInput(_ rawInput: String) -> Date? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Require at least one letter or date/time separator so bare integers don't misparse.
        let hasCue = trimmed.contains { $0.isLetter || $0 == "/" || $0 == "-" || $0 == ":" }
        guard hasCue else { return nil }

        let posixFormatsWithTime = [
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd h:mm a",
            "yyyy-MM-dd h:mma",
            "MMM d, yyyy h:mm a",
            "MMM d, yyyy 'at' h:mm a",
            "d MMM yyyy h:mm a",
            "d MMM yyyy, h:mm a",
            "d/M/yyyy HH:mm",
            "d/M/yyyy h:mm a",
            "d/M/yy HH:mm",
            "d/M/yy h:mm a",
            "M/d/yyyy HH:mm",
            "M/d/yyyy h:mm a",
            "d-M-yyyy HH:mm",
            "d-M-yyyy h:mm a"
        ]

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.isLenient = false

        for format in posixFormatsWithTime {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }

        let posixDateOnlyFormats = [
            "yyyy-MM-dd",
            "d/M/yyyy",
            "d/M/yy",
            "d-M-yyyy",
            "M/d/yyyy",
            "d MMM yyyy",
            "MMM d, yyyy"
        ]

        for format in posixDateOnlyFormats {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: date) ?? date
            }
        }

        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let fullRange = NSRange(trimmed.startIndex..., in: trimmed)
            let matches = detector.matches(in: trimmed, options: [], range: fullRange)
            if let best = matches.max(by: { $0.range.length < $1.range.length }),
               let date = best.date {
                let coverage = Double(best.range.length) / Double(max(1, fullRange.length))
                if coverage >= 0.5 || best.range.length >= 4 {
                    return date
                }
            }
        }

        return nil
    }

    private func extractRoleName(from lines: [String], cleanText: String, detectedMainRole: String) -> String {
        if !detectedMainRole.isEmpty {
            return detectedMainRole
        }

        let stopHeaders: Set<String> = ["AGE", "AGE GROUP", "GENDER", "CATEGORY", "LOCATION", "LANGUAGE", "LANGUAGES", "SKILLS", "CHARACTER LOOK", "REGION", "ISSUED"]

        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.replacingOccurrences(of: #"^[•\-\*]\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = line.lowercased()
            if lower.hasPrefix("role:") || lower.hasPrefix("character:") || lower.hasPrefix("seeking:") || lower.hasPrefix("role needed:") || lower.hasPrefix("character name:") {
                let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count > 1 {
                    let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty {
                        if let leadRange = value.range(of: #"^(male\s+lead|female\s+lead)\b"#, options: [.regularExpression, .caseInsensitive]) {
                            return smartTitleCase(String(value[leadRange]))
                        }
                        return smartTitleCase(value)
                    }
                }
            } else if lower == "role" || lower == "character" || lower == "character:" || lower == "seeking" {
                var collected: [String] = []
                var offset = 1
                while index + offset < lines.count && collected.count < 2 && offset <= 4 {
                    let candidate = lines[index + offset].trimmingCharacters(in: .whitespacesAndNewlines)
                    if candidate.isEmpty {
                        if !collected.isEmpty { break }
                        offset += 1
                        continue
                    }
                    if stopHeaders.contains(candidate.uppercased()) {
                        break
                    }
                    if candidate.count <= 45 {
                        collected.append(candidate)
                    }
                    offset += 1
                }
                if !collected.isEmpty {
                    return smartTitleCase(collected.joined(separator: " "))
                }
            }
        }

        let rolePhrasePatterns = [
            #"\b(male\s+lead|female\s+lead|fresh\s+female\s+talent|fresh\s+male\s+talent|supporting\s+actor|supporting\s+actress|supporting\s+role|child\s+artist|protagonist|antagonist)\b"#
        ]
        for pattern in rolePhrasePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: cleanText, range: NSRange(cleanText.startIndex..., in: cleanText)),
               let range = Range(match.range(at: 1), in: cleanText) {
                let raw = String(cleanText[range])
                    .replacingOccurrences(of: "fresh ", with: "", options: .caseInsensitive)
                return smartTitleCase(raw)
            }
        }

        return "Lead Character"
    }

    private func extractRoleDescription(from lines: [String], cleanText: String, hasDialogue: Bool) -> String {
        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("role description:") || lower.hasPrefix("character description:") || lower.hasPrefix("bio:") {
                let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count > 1 {
                    let val = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !val.isEmpty { return val }
                }
            }
        }

        if let lookIdx = lines.firstIndex(where: {
            let upper = $0.uppercased()
            return upper == "CHARACTER LOOK" || upper.hasPrefix("CHARACTER LOOK:")
        }) {
            var parts: [String] = []
            for offset in 1...4 {
                let idx = lookIdx + offset
                guard idx < lines.count else { break }
                let candidate = lines[idx].trimmingCharacters(in: .whitespacesAndNewlines)
                if candidate.isEmpty {
                    if !parts.isEmpty { break }
                    continue
                }
                let lower = candidate.lowercased()
                if lower.hasPrefix("apply") || lower.hasPrefix("if you fit") || lower.hasPrefix("email") || lower.hasPrefix("scan qr") {
                    break
                }
                // Skip pure Instagram icon counts like "1,865" or "170"
                if candidate.range(of: #"^[\d,]+$"#, options: .regularExpression) != nil {
                    continue
                }
                parts.append(candidate)
            }
            if !parts.isEmpty {
                return parts.joined(separator: " ")
            }
        }

        guard !hasDialogue else { return "" }

        // Fall back to a looking-for / age description sentence if present on notices without sides
        for line in lines {
            let lower = line.lowercased()
            if lower.contains("looking for") || lower.hasPrefix("age group:") || lower.hasPrefix("women aged") || lower.hasPrefix("men aged") {
                return line
            }
        }
        return ""
    }

    private func smartTitleCase(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (trimmed == trimmed.uppercased() || trimmed == trimmed.lowercased()),
              trimmed.rangeOfCharacter(from: .letters) != nil else {
            return trimmed
        }
        let lowercaseWords: Set<String> = ["a", "an", "and", "as", "at", "by", "for", "in", "of", "on", "or", "the", "to", "with"]
        let parts = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        return parts.enumerated().map { idx, word in
            let lower = word.lowercased()
            if idx > 0 && idx < parts.count - 1 && lowercaseWords.contains(lower) {
                return lower
            }
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }.joined(separator: " ")
    }

    private func extractClipMaxSeconds(from text: String) -> Double? {
        let minutePatterns = [
            #"(\d+)\s*(?:-|\s*)(?:minutes?|mins?)\b\s*(?:max\s*)?(?:clip|tape|video|audition|scene|self-?tape)\b"#,
            #"\b(?:clip|tape|video|audition|scene|self-?tape)\b(?:\s*(?:max|maximum|limit|length|duration|:|-|\(|of))*\s*(\d+)\s*(?:-|\s*)(?:minutes?|mins?)\b"#
        ]
        for pattern in minutePatterns {
            if let mins = firstCaptureDouble(pattern, in: text) {
                return mins * 60.0
            }
        }

        let secondPatterns = [
            #"(\d+)\s*(?:-|\s*)(?:seconds?|secs?|s)\b\s*(?:max\s*)?(?:clip|tape|video|audition|scene|self-?tape)\b"#,
            #"\b(?:clip|tape|video|audition|scene|self-?tape)\b(?:\s*(?:max|maximum|limit|length|duration|:|-|\(|of))*\s*(\d+)\s*(?:-|\s*)(?:seconds?|secs?|s)\b"#
        ]
        for pattern in secondPatterns {
            if let secs = firstCaptureDouble(pattern, in: text) {
                return secs
            }
        }

        return nil
    }

    private func matchesRegex(_ pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private func firstCaptureDouble(_ pattern: String, in text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Double(text[range])
    }

    // MARK: - Dialogue & Script Parser

    func parseSidesText(_ text: String, defaultRole: String = "ACTOR") -> (scriptText: String, cueLines: [CueLine], teleprompterLines: [String]) {
        let cleanText = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = cleanText.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let dialogue = parseDialogue(from: lines)
        if let script = dialogue.scriptText, !script.isEmpty {
            return (script, dialogue.cueLines, dialogue.teleprompterLines)
        }

        // If no distinct character dialogue was detected, treat the text as a monologue.
        let cleaned = stripStageDirections(from: cleanText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return ("", [], []) }

        let chunks = splitIntoTeleprompterChunks(text: cleaned, maxWords: 25)
        let teleprompterLines = chunks.map { "\(defaultRole): \($0)" }
        return (cleaned, [], teleprompterLines)
    }

    private func parseDialogue(from lines: [String]) -> (mainRole: String, cueRole: String, cueLines: [CueLine], teleprompterLines: [String], scriptText: String?) {
        let ignoredKeywords: Set<String> = [
            "PROJECT", "PROJECT TITLE", "TITLE", "FILM", "MOVIE", "SERIES", "ROLE", "CHARACTER",
            "ROLE DESCRIPTION", "CHARACTER DESCRIPTION", "ROLE DETAILS", "PROJECT DETAILS",
            "ABOUT THE PROJECT", "BIO", "DEADLINE", "DUE", "SUBMIT", "SUBMIT TO", "SEND TO",
            "SUBMISSION", "SUBMISSIONS", "SUBMISSION DETAILS", "EMAIL", "CONTACT", "PRODUCER",
            "DIRECTOR", "WRITER", "CASTING DIRECTOR", "CASTING", "CASTING BREAKDOWN",
            "CHARACTER BREAKDOWN", "PRODUCTION", "SHOOT DATES", "SHOOT DATE", "SHOOT LOCATION",
            "LOCATION", "RATE", "PAY", "COMPENSATION", "UNION", "NON-UNION", "STATUS",
            "NOTE", "NOTES", "ADDITIONAL NOTES", "REQUIREMENT", "REQUIREMENTS", "AUDITION",
            "AUDITIONS", "AUDITION SIDES", "GUIDELINES", "INSTRUCTIONS", "SELF TAPE",
            "SELF-TAPE", "SELF TAPE INSTRUCTIONS", "SELF-TAPE INSTRUCTIONS", "SPEC", "SPECS",
            "SLATE", "HEADSHOT", "HEADSHOTS", "TAPE", "CLIP", "LENGTH", "DURATION", "RATIO",
            "ASPECT RATIO", "FORMAT", "CALLBACK", "CALLBACKS", "TYPE", "WARDROBE", "SYNOPSIS",
            "STORYLINE", "LOGLINE", "RESUME", "SHOWREEL", "SCENE", "INT", "EXT", "DAY", "NIGHT",
            "CONTINUED", "NOTICE", "CASTING NOTICE", "CASTING CALL", "INFO", "IMPORTANT",
            "ATTACHMENT", "ATTACHMENTS", "FILE", "FILES",
            "AGE", "AGE GROUP", "GENDER", "CATEGORY", "LANGUAGE", "LANGUAGES",
            "SKILLS", "CHARACTER LOOK", "LOOK", "APPEARANCE", "HEIGHT", "WEIGHT",
            "ETHNICITY", "REGION", "ISSUED", "PAN INDIA", "MUMBAI", "DELHI", "INDIA",
            "FEATURE FILM", "SHORT FILM", "WEB SERIES", "AD FILM", "COMMERCIAL",
            "NOW CASTING", "APPLY FOR FREE", "EMAIL TO APPLY", "FREE", "PRIMARY",
            "MALE", "FEMALE", "MC", "ACTORS", "NON ACTORS", "PAGE",
            "SONGS & SCENES", "TABLE OF CONTENTS", "CAST",
            "ISSUED DATE", "KEY CRITERIA", "REQUIREMENTS TO BE SUBMITTED", "HOW TO APPLY",
            "SCENE END", "END SCENE", "END OF SCENE", "WAIT", "LOOK", "LISTEN"
        ]

        let ignoredPrefixes = ignoredKeywords.map { $0 + " " }

        let colonCharPattern = #"^([A-Z0-9][A-Za-z0-9\s.'#-]{1,29}?)(?:\s*\([^)]*\))?\s*:(.*)$"#
        guard let colonRegex = try? NSRegularExpression(pattern: colonCharPattern, options: []) else {
            return ("", "", [], [], nil)
        }

        struct RawSpeech {
            let speaker: String
            var dialogue: String
            let fromColonFormat: Bool
        }

        var speechList: [RawSpeech] = []
        var speakerLineCounts: [String: Int] = [:]
        var currentSpeaker: String?
        var currentFromColon = false
        var currentBuffer = ""

        func flushCurrentSpeech() {
            guard let speaker = currentSpeaker else { return }
            let trimmedDialogue = currentBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedDialogue.isEmpty {
                speechList.append(RawSpeech(
                    speaker: speaker,
                    dialogue: trimmedDialogue,
                    fromColonFormat: currentFromColon
                ))
                speakerLineCounts[speaker, default: 0] += 1
            }
            currentSpeaker = nil
            currentFromColon = false
            currentBuffer = ""
        }

        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                // Blank lines separate turns once dialogue has been captured.
                if !currentBuffer.isEmpty {
                    flushCurrentSpeech()
                }
                continue
            }

            if Self.isSceneHeading(trimmed) {
                flushCurrentSpeech()
                continue
            }

            let mlPrediction = classifierBox.classify(trimmed)

            // 1. Check explicit COLON dialogue header: "SPEAKER: ..." or "SPEAKER:\ndialogue"
            let colonTarget = trimmed.replacingOccurrences(of: #"^[•\-\*]\s*"#, with: "", options: .regularExpression)
            let isBulletPrefixed = colonTarget != trimmed
            let nsRange = NSRange(colonTarget.startIndex..., in: colonTarget)
            if let match = colonRegex.firstMatch(in: colonTarget, range: nsRange),
               let speakerRange = Range(match.range(at: 1), in: colonTarget),
               let dialogueRange = Range(match.range(at: 2), in: colonTarget) {
                let rawSpeaker = Self.normalizeSpeakerName(String(colonTarget[speakerRange]))
                let speaker = rawSpeaker.uppercased()
                let initialDialogue = String(colonTarget[dialogueRange]).trimmingCharacters(in: .whitespaces)
                let speakerWords = rawSpeaker.split(whereSeparator: \.isWhitespace).map(String.init)
                let wordCount = speakerWords.count

                let isAllCapsSpeaker = rawSpeaker == speaker
                let isMultiWordTitleCase = wordCount >= 2 && speakerWords.allSatisfy { $0.first?.isUppercase == true || $0.first?.isNumber == true }
                let startsWithDialogueStarter = initialDialogue.first.map {
                    $0.isUppercase || $0 == "\"" || $0 == "“" || $0 == "'" || $0 == "‘" || $0 == "("
                } ?? false
                let isSingleWordTitleCase = wordCount == 1
                    && (rawSpeaker.first?.isUppercase == true)
                    && rawSpeaker.dropFirst().allSatisfy { $0.isLowercase || $0 == "-" || $0 == "'" }
                    && startsWithDialogueStarter

                let isIgnored = isBulletPrefixed
                    || !(isAllCapsSpeaker || isMultiWordTitleCase || isSingleWordTitleCase)
                    || ignoredKeywords.contains(speaker)
                    || ignoredPrefixes.contains(where: { speaker.hasPrefix($0) })
                    || speaker.contains("@")
                    || speaker.contains("HTTP")
                    || speaker.hasSuffix(".COM")
                    || wordCount > 4
                    || (mlPrediction?.label == "metadata" && (mlPrediction?.confidence ?? 0) >= 0.85 && initialDialogue.isEmpty)
                    || (mlPrediction?.label == "scene_heading" && (mlPrediction?.confidence ?? 0) >= 0.85)

                flushCurrentSpeech()
                if !isIgnored {
                    currentSpeaker = speaker
                    currentFromColon = true
                    currentBuffer = initialDialogue
                }
                continue
            }

            // 2. Skip standalone parenthetical / bracket stage directions
            if Self.isStandaloneParenthetical(trimmed)
                || (mlPrediction?.label == "parenthetical" && (mlPrediction?.confidence ?? 0) >= 0.8 && trimmed.hasPrefix("(")) {
                continue
            }

            // 3. Check colonless screenplay character cue followed by dialogue
            if let cueSpeaker = detectScreenplayCharacterCue(
                at: index,
                in: lines,
                ignoredKeywords: ignoredKeywords,
                mlPrediction: mlPrediction
            ) {
                flushCurrentSpeech()
                currentSpeaker = cueSpeaker
                currentFromColon = false
                currentBuffer = ""
                continue
            }

            // 4. Continuation of active speaker's dialogue
            if currentSpeaker != nil {
                if let colonIdx = trimmed.firstIndex(of: ":") {
                    let prefix = String(trimmed[..<colonIdx]).trimmingCharacters(in: .whitespaces).uppercased()
                    if ignoredKeywords.contains(prefix)
                        || (mlPrediction?.label == "metadata" && (mlPrediction?.confidence ?? 0) >= 0.85) {
                        flushCurrentSpeech()
                        continue
                    }
                }
                if mlPrediction?.label == "scene_heading" && (mlPrediction?.confidence ?? 0) >= 0.85 {
                    flushCurrentSpeech()
                    continue
                }
                currentBuffer += (currentBuffer.isEmpty ? "" : " ") + trimmed
            }
        }

        flushCurrentSpeech()

        // Require at least one explicit colon speech OR multiple colonless screenplay turns/speakers
        // (or ML-verified single monologue character cue) to avoid false positives on plain notices.
        let hasColonSpeech = speechList.contains(where: \.fromColonFormat)
        let hasMultiSpeakerScreenplay = speakerLineCounts.count >= 2 || speechList.count >= 2
        let hasSingleMLScreenplayCue = speechList.count == 1
            && !speechList[0].fromColonFormat
            && classifierBox.classify(speechList[0].speaker)?.label == "character_cue"
        guard !speakerLineCounts.isEmpty,
              (hasColonSpeech || hasMultiSpeakerScreenplay || hasSingleMLScreenplayCue) else {
            return ("", "", [], [], nil)
        }

        // Build cleanly formatted script sides text consisting ONLY of dialogue
        var scriptTextBuffer = ""
        for speech in speechList {
            let cleaned = stripStageDirections(from: speech.dialogue)
            if !cleaned.isEmpty {
                scriptTextBuffer += "\(speech.speaker):\n\(cleaned)\n\n"
            }
        }
        let formattedScript = scriptTextBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !formattedScript.isEmpty else {
            return ("", "", [], [], nil)
        }

        // Detect character with most lines as actor's main role
        let sortedSpeakers = speakerLineCounts.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }
        let mainRole = sortedSpeakers.first?.key ?? "MAIN"
        let cueRole = sortedSpeakers.count > 1 ? sortedSpeakers[1].key : "READER"

        var cueLines: [CueLine] = []
        var teleprompterLines: [String] = []
        var orderIndex = 0
        var lastActorLine = ""

        for speech in speechList {
            let cleanedSpeech = stripStageDirections(from: speech.dialogue)
            guard !cleanedSpeech.isEmpty else { continue }

            if speech.speaker == mainRole {
                lastActorLine = cleanedSpeech
                let chunks = splitIntoTeleprompterChunks(text: cleanedSpeech, maxWords: 25)
                for chunk in chunks {
                    teleprompterLines.append("\(mainRole): \(chunk)")
                }
            } else {
                let cue = CueLine(
                    id: UUID(),
                    orderIndex: orderIndex,
                    speaker: speech.speaker,
                    cueText: cleanedSpeech,
                    precedingActorLine: lastActorLine,
                    audioFilePath: nil,
                    durationSeconds: 0,
                    isAutoDetected: true
                )
                cueLines.append(cue)
                orderIndex += 1
                teleprompterLines.append("[\(speech.speaker)]: \(cleanedSpeech)")
            }
        }

        return (mainRole, cueRole, cueLines, teleprompterLines, formattedScript)
    }

    private func detectScreenplayCharacterCue(
        at index: Int,
        in lines: [String],
        ignoredKeywords: Set<String>,
        mlPrediction: (label: String, confidence: Double)?
    ) -> String? {
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
        // Strip trailing screenplay tags such as (V.O.), (O.S.), (CONT'D)
        let withoutTag = trimmed.replacingOccurrences(
            of: #"\s*\((?:V\.O\.|O\.S\.|O\.C\.|CONT'D|CONTD|FILTERED|OFF|PRE-LAP)\)\s*$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        ).trimmingCharacters(in: .whitespaces)

        guard (2...30).contains(withoutTag.count),
              !withoutTag.contains(":"),
              !withoutTag.contains("@"),
              !withoutTag.contains("•"),
              !withoutTag.hasPrefix("-"),
              !withoutTag.hasPrefix("*"),
              withoutTag.rangeOfCharacter(from: .lowercaseLetters) == nil,
              withoutTag.rangeOfCharacter(from: .letters) != nil else {
            return nil
        }

        if withoutTag.hasSuffix("?") || withoutTag.hasSuffix("!") || withoutTag.hasSuffix(",") || withoutTag.hasSuffix(".") {
            return nil
        }

        let words = withoutTag.split(whereSeparator: \.isWhitespace)
        guard (1...4).contains(words.count) else { return nil }

        let upperCandidate = Self.normalizeSpeakerName(withoutTag).uppercased()
        if ignoredKeywords.contains(upperCandidate)
            || ignoredKeywords.contains(where: { upperCandidate.hasPrefix($0 + " ") })
            || Self.isSceneHeading(upperCandidate) {
            return nil
        }

        // Multi-character corner headers ("DOODY, ROGER & KENICKIE") and incomplete title fragments ("FEMALE ACTOR WITH A") are not speakers.
        if upperCandidate.contains(",") || upperCandidate.contains("&") {
            return nil
        }
        let trailingPrepositionsOrArticles: Set<String> = ["A", "AN", "THE", "WITH", "FOR", "OF", "IN", "ON", "TO", "AND", "OR", "BY", "FROM", "AT"]
        if let lastWord = words.last, trailingPrepositionsOrArticles.contains(String(lastWord).uppercased()) {
            return nil
        }
        if let lastWord = words.last, Int(String(lastWord)) != nil, words.count > 2 {
            return nil
        }

        // Reject if the ML classifier strongly identifies this line as non-cue notice metadata or scene heading.
        if let pred = mlPrediction,
           (pred.label == "scene_heading" || pred.label == "metadata") && pred.confidence >= 0.75 {
            return nil
        }

        // Must be followed immediately (skipping parentheticals, before any blank line) by a non-cue dialogue line.
        var lookahead = index + 1
        while lookahead < lines.count {
            let nextLine = lines[lookahead].trimmingCharacters(in: .whitespaces)
            if nextLine.isEmpty {
                return nil
            }
            if Self.isStandaloneParenthetical(nextLine) {
                lookahead += 1
                continue
            }
            if Self.isSceneHeading(nextLine) || nextLine.contains(":") {
                return nil
            }
            let nextHasLowercase = nextLine.rangeOfCharacter(from: .lowercaseLetters) != nil
            let nextML = classifierBox.classify(nextLine)
            if let nextML,
               (nextML.label == "scene_heading" || nextML.label == "metadata") && nextML.confidence >= 0.80 {
                return nil
            }
            if nextHasLowercase || nextML?.label == "dialogue" || mlPrediction?.label == "character_cue" {
                return upperCandidate
            }
            return nil
        }

        return nil
    }

    private static func normalizeSpeakerName(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: #"\s*-\s*"#, with: "-", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isSceneHeading(_ line: String) -> Bool {
        let upper = line.trimmingCharacters(in: .whitespaces).uppercased()
        if upper.hasPrefix("INT.") || upper.hasPrefix("EXT.") || upper.hasPrefix("INT/EXT") || upper.hasPrefix("I/E.") {
            return true
        }
        if upper == "FADE IN:" || upper == "FADE OUT." || upper == "FADE OUT:" || upper.hasPrefix("CUT TO:") || upper.hasPrefix("DISSOLVE TO:") {
            return true
        }
        if upper == "SONGS & SCENES" || upper == "(CONTINUED)" || upper == "CONTINUED" || upper == "SCENE END" || upper == "END SCENE" || upper == "END OF SCENE" || upper.contains("AUDITION SCRIPT") || upper.contains("EXCERPT FROM") {
            return true
        }
        if upper.range(of: #"^(?:ACT|SCENE)\s+(?:ONE|TWO|THREE|FOUR|FIVE|SIX|SEVEN|EIGHT|I|II|III|IV|V|\d+)\b"#, options: .regularExpression) != nil {
            return true
        }
        if upper.contains("THE MUSICAL") {
            return true
        }
        return false
    }

    private static func isStandaloneParenthetical(_ line: String) -> Bool {
        (line.hasPrefix("(") && line.hasSuffix(")")) || (line.hasPrefix("[") && line.hasSuffix("]"))
    }

    private func stripStageDirections(from text: String) -> String {
        var result = text
        if let parenRegex = try? NSRegularExpression(pattern: #"\([^)]*\)"#, options: []) {
            result = parenRegex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        if let bracketRegex = try? NSRegularExpression(pattern: #"\[[^\]]*\]"#, options: []) {
            result = bracketRegex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        return result.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func splitIntoTeleprompterChunks(text: String, maxWords: Int = 25) -> [String] {
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        guard words.count > maxWords else { return [text] }

        var chunks: [String] = []
        var currentChunk: [String] = []

        for word in words {
            currentChunk.append(word)
            if currentChunk.count >= maxWords {
                chunks.append(currentChunk.joined(separator: " "))
                currentChunk = []
            }
        }
        if !currentChunk.isEmpty {
            chunks.append(currentChunk.joined(separator: " "))
        }
        return chunks
    }
}

// MARK: - Orientation Bridge

private extension CGImagePropertyOrientation {
    nonisolated init(_ uiOrientation: UIImage.Orientation) {
        switch uiOrientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

// MARK: - Docx XML Parser Delegate

private nonisolated final class DocxXMLParserDelegate: NSObject, XMLParserDelegate {
    var extractedText = ""
    private var isInsideTextElement = false
    private let maxCharacters: Int

    init(maxCharacters: Int) {
        self.maxCharacters = maxCharacters
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "w:t" {
            isInsideTextElement = true
        } else if elementName == "w:p" {
            if !extractedText.isEmpty && !extractedText.hasSuffix("\n") {
                appendLimited("\n", parser: parser)
            }
        } else if elementName == "w:br" || elementName == "w:cr" {
            appendLimited("\n", parser: parser)
        } else if elementName == "w:tab" {
            appendLimited("\t", parser: parser)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isInsideTextElement {
            appendLimited(string, parser: parser)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "w:t" {
            isInsideTextElement = false
        }
    }

    private func appendLimited(_ string: String, parser: XMLParser) {
        if extractedText.count >= maxCharacters {
            parser.abortParsing()
            return
        }
        let remaining = maxCharacters - extractedText.count
        if string.count <= remaining {
            extractedText += string
        } else {
            extractedText += String(string.prefix(remaining))
            parser.abortParsing()
        }
    }
}
