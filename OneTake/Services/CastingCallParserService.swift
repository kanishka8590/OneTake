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
        let rawText = try await extractRawText(from: image)
        return await parseText(rawText)
    }

    func parseImages(_ images: [UIImage]) async throws -> ParsedCastingCall {
        let snapshots = images.compactMap { image -> (CGImage, CGImagePropertyOrientation)? in
            Self.cgImageAndOrientation(for: image)
        }
        return try await Task.detached(priority: .userInitiated) { [self] in
            var combinedText = ""
            for (cgImage, orientation) in snapshots {
                let pageText = try Self.extractTextWithColumnReconstructionSync(
                    from: cgImage,
                    orientation: orientation
                )
                if !pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    combinedText += (combinedText.isEmpty ? "" : "\n\n") + pageText
                }
            }
            return self.parseTextSync(combinedText)
        }.value
    }

    func extractRawText(from image: UIImage) async throws -> String {
        guard let (cgImage, orientation) = Self.cgImageAndOrientation(for: image) else {
            return ""
        }
        return try await Task.detached(priority: .userInitiated) {
            try Self.extractTextWithColumnReconstructionSync(from: cgImage, orientation: orientation)
        }.value
    }

    /// Reconstructs reading-order text from Vision/layout bounding boxes using `OCRLayoutReconstructor`.
    static func reconstructColumns(from boxes: [OCRLayoutReconstructor.TextBoundingBox]) -> String {
        OCRLayoutReconstructor.reconstruct(boxes: boxes)
    }

    private static func cgImageAndOrientation(for image: UIImage) -> (CGImage, CGImagePropertyOrientation)? {
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        if let cgImage = image.cgImage {
            return (cgImage, orientation)
        }
        // Fallback for CIImage-backed or synthetic UIImages without a backing CGImage.
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let renderedCG = rendered.cgImage else { return nil }
        return (renderedCG, .up)
    }

    private static func extractTextWithColumnReconstructionSync(
        from cgImage: CGImage,
        orientation: CGImagePropertyOrientation
    ) throws -> String {
        var recognizedBoxes: [OCRLayoutReconstructor.TextBoundingBox] = []
        var recognitionError: Error?

        let request = VNRecognizeTextRequest { request, error in
            if let error {
                recognitionError = error
                return
            }
            guard let observations = request.results as? [VNRecognizedTextObservation], !observations.isEmpty else {
                return
            }
            recognizedBoxes = observations.compactMap { obs in
                guard let candidate = obs.topCandidates(1).first else { return nil }
                return OCRLayoutReconstructor.TextBoundingBox(
                    text: candidate.string,
                    rect: obs.boundingBox,
                    confidence: candidate.confidence
                )
            }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        try handler.perform([request])

        if let recognitionError {
            throw recognitionError
        }
        return reconstructColumns(from: recognizedBoxes)
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
                // Scanned PDF page: render at 2x scale honoring mediaBox.origin and run Vision OCR.
                let mediaBox = page.bounds(for: .mediaBox)
                guard mediaBox.width > 0, mediaBox.height > 0 else { continue }

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

                if let cgImage = renderedImage.cgImage {
                    let ocrText = try extractTextWithColumnReconstructionSync(from: cgImage, orientation: .up)
                    if !ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        fullExtractedText += (fullExtractedText.isEmpty ? "" : "\n\n") + ocrText
                    }
                }
            } else {
                let layoutLines = PDFGeometryExtractor.extractLines(from: page, pageIndex: i)
                let reconstructed = OCRLayoutReconstructor.reconstruct(layoutLines: layoutLines)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let finalPageText = reconstructed.isEmpty ? rawPageText : reconstructed
                fullExtractedText += (fullExtractedText.isEmpty ? "" : "\n\n") + finalPageText
            }
        }

        return fullExtractedText
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
        try await Task.detached(priority: .userInitiated) { [self] in
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
                    } else if let image = UIImage(data: data),
                              let (cgImage, orientation) = Self.cgImageAndOrientation(for: image) {
                        extracted = try Self.extractTextWithColumnReconstructionSync(from: cgImage, orientation: orientation)
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
            return self.parseTextSync(combinedText)
        }.value
    }

    // MARK: - Deterministic + ML-Assisted Parser

    func parseText(_ text: String) async -> ParsedCastingCall {
        await Task.detached(priority: .userInitiated) { [self] in
            self.parseTextSync(text)
        }.value
    }

    private func parseTextSync(_ text: String) -> ParsedCastingCall {
        var result = ParsedCastingCall()
        result.rawExtractedText = text
        let cleanText = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = cleanText.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }

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
        } else if isTheaterProduction(in: lowerText) {
            result.productionType = .theater
        }

        // 3. Project Name
        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("project:") || lower.hasPrefix("title:") || lower.hasPrefix("film:") || lower.hasPrefix("audition for:") {
                let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count > 1 && !parts[1].trimmingCharacters(in: .whitespaces).isEmpty {
                    result.projectName = parts[1].trimmingCharacters(in: .whitespaces)
                    break
                }
            }
        }
        if result.projectName.isEmpty {
            if let firstLine = lines.first(where: { !$0.isEmpty && $0.count < 60 && !$0.lowercased().contains("casting call") }) {
                result.projectName = firstLine
                    .replacingOccurrences(of: "CASTING CALL - ", with: "")
                    .replacingOccurrences(of: "CASTING NOTICE: ", with: "")
                    .trimmingCharacters(in: .whitespaces)
            } else {
                result.projectName = "Untitled Audition"
            }
        }

        // 4. Deadline Extraction
        var foundDeadline = false
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            for line in lines {
                let lower = line.lowercased()
                if lower.contains("deadline") || lower.contains("submit by") || lower.contains("due") || lower.contains("last date") {
                    let matches = detector.matches(in: line, options: [], range: NSRange(line.startIndex..., in: line))
                    if let dateMatch = matches.first?.date {
                        result.deadline = dateMatch
                        foundDeadline = true
                        break
                    }
                }
            }
            if !foundDeadline {
                let matches = detector.matches(in: cleanText, options: [], range: NSRange(cleanText.startIndex..., in: cleanText))
                if let futureDate = matches.compactMap({ $0.date }).first(where: { $0 > Date() }) {
                    result.deadline = futureDate
                }
            }
        }

        // 5. Constraints: Ratio, Slate Max, Clip Max, Size Max
        if matchesRegex(#"\b4[:x]5\b"#, in: lowerText) {
            result.requiredHeadshotRatio = .ratio4x5
        } else if matchesRegex(#"\b2[:x]3\b"#, in: lowerText) {
            result.requiredHeadshotRatio = .ratio2x3
        } else if matchesRegex(#"\b1[:x]1\b"#, in: lowerText) || mentionsSquareHeadshot(in: lines) {
            result.requiredHeadshotRatio = .ratio1x1
        }

        // Slate max seconds (e.g., "5s slate", "30 seconds slate", "slate: 30s")
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

        // 6. Dialogue Blocks & Role Extraction
        let dialogueResult = parseDialogue(from: lines)
        result.detectedMainRole = dialogueResult.mainRole
        result.detectedCueRole = dialogueResult.cueRole
        result.cueLines = dialogueResult.cueLines
        result.teleprompterLines = dialogueResult.teleprompterLines
        result.detectedScriptText = dialogueResult.scriptText

        if !dialogueResult.mainRole.isEmpty {
            result.roleName = dialogueResult.mainRole
        } else {
            for line in lines {
                let lower = line.lowercased()
                if lower.hasPrefix("role:") || lower.hasPrefix("character:") {
                    let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
                    if parts.count > 1 {
                        result.roleName = parts[1].trimmingCharacters(in: .whitespaces)
                        break
                    }
                }
            }
            if result.roleName.isEmpty {
                result.roleName = "Lead Character"
            }
        }

        // Role Description
        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("role description:") || lower.hasPrefix("character description:") || lower.hasPrefix("bio:") {
                let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count > 1 {
                    result.roleDescription = parts[1].trimmingCharacters(in: .whitespaces)
                    break
                }
            }
        }
        if result.roleDescription.isEmpty {
            if let idx = lines.firstIndex(where: { $0.lowercased().hasPrefix("role:") }), idx + 1 < lines.count {
                result.roleDescription = lines[idx + 1]
            }
        }

        // 7. Requirements Checklist (clean: email kept out)
        var reqs: [SubmissionRequirement] = [
            SubmissionRequirement(title: "Guided Headshots (3 Angles: Front, Left, Right)", isCompleted: false),
            SubmissionRequirement(title: "Slate / Introduction Video", isCompleted: false),
            SubmissionRequirement(title: "Audition Self-Tape Take", isCompleted: false)
        ]

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

        for line in lines where !line.isEmpty {
            let nsRange = NSRange(line.startIndex..., in: line)
            let matches = regex.matches(in: line, range: nsRange)
            guard !matches.isEmpty else { continue }
            let lowerLine = line.lowercased()

            for match in matches {
                guard let range = Range(match.range, in: line) else { continue }
                let email = String(line[range])
                let lowerEmail = email.lowercased()

                var score = 0
                if lowerLine.contains("submit to") || lowerLine.contains("send to") || lowerLine.contains("send tape") || lowerLine.contains("send self-tape") || lowerLine.contains("submissions") {
                    score += 100
                } else if lowerLine.contains("submit") || lowerLine.contains("apply") || lowerLine.contains("deliver to") {
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
        let patterns = [
            #"(\d+)\s*(?:seconds?|secs?|s)\b(?:\s*|-)?slate\b"#,
            #"\bslate\b(?:\s*(?:max|maximum|limit|under|up\s+to|:|-|\(|of))*\s*(\d+)\s*(?:seconds?|secs?|s)\b"#
        ]
        for pattern in patterns {
            if let value = firstCaptureDouble(pattern, in: text) {
                return value
            }
        }
        return nil
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
            "ATTACHMENT", "ATTACHMENTS", "FILE", "FILES"
        ]

        let colonCharPattern = #"^([A-Z0-9][A-Z0-9\s.'#-]{1,29}?)(?:\s*\([^)]*\))?\s*:(.*)$"#
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
            let nsRange = NSRange(trimmed.startIndex..., in: trimmed)
            if let match = colonRegex.firstMatch(in: trimmed, range: nsRange),
               let speakerRange = Range(match.range(at: 1), in: trimmed),
               let dialogueRange = Range(match.range(at: 2), in: trimmed) {
                let rawSpeaker = String(trimmed[speakerRange]).trimmingCharacters(in: .whitespaces)
                let speaker = rawSpeaker.uppercased()
                let initialDialogue = String(trimmed[dialogueRange]).trimmingCharacters(in: .whitespaces)
                let wordCount = speaker.split(whereSeparator: \.isWhitespace).count

                let isIgnored = ignoredKeywords.contains(speaker)
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

        let upperCandidate = withoutTag.uppercased()
        if ignoredKeywords.contains(upperCandidate) || Self.isSceneHeading(upperCandidate) {
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

    private static func isSceneHeading(_ line: String) -> Bool {
        let upper = line.trimmingCharacters(in: .whitespaces).uppercased()
        if upper.hasPrefix("INT.") || upper.hasPrefix("EXT.") || upper.hasPrefix("INT/EXT") || upper.hasPrefix("I/E.") {
            return true
        }
        if upper == "FADE IN:" || upper == "FADE OUT." || upper == "FADE OUT:" || upper.hasPrefix("CUT TO:") || upper.hasPrefix("DISSOLVE TO:") {
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
