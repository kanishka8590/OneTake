import Foundation
import UIKit
import Vision
import PDFKit
import Compression

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

protocol CastingCallParserServiceProtocol: Sendable {
    func parseImage(_ image: UIImage) async throws -> ParsedCastingCall
    func parseImages(_ images: [UIImage]) async throws -> ParsedCastingCall
    func parsePDF(data: Data) async throws -> ParsedCastingCall
    func parseDocx(data: Data) async throws -> ParsedCastingCall
    func parseText(_ text: String) async -> ParsedCastingCall
    func parseMultipleFiles(urls: [URL]) async throws -> ParsedCastingCall
}

// MARK: - CastingCallParserService Implementation

final class CastingCallParserService: CastingCallParserServiceProtocol {
    static let shared = CastingCallParserService()

    init() {}

    // MARK: - Image / Scan OCR with Column Reconstruction

    func parseImage(_ image: UIImage) async throws -> ParsedCastingCall {
        let rawText = try await extractRawText(from: image)
        return await parseText(rawText)
    }

    func parseImages(_ images: [UIImage]) async throws -> ParsedCastingCall {
        var combinedText = ""
        for image in images {
            let pageText = try await extractRawText(from: image)
            if !pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                combinedText += (combinedText.isEmpty ? "" : "\n\n") + pageText
            }
        }
        return await parseText(combinedText)
    }

    func extractRawText(from image: UIImage) async throws -> String {
        guard let cgImage = image.cgImage else { return "" }
        return try await extractTextWithColumnReconstruction(from: cgImage)
    }

    private func extractTextWithColumnReconstruction(from cgImage: CGImage) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation], !observations.isEmpty else {
                    continuation.resume(returning: "")
                    return
                }

                // Layout reconstruction:
                // Vision bounding boxes are normalized [0, 1] with origin at lower-left.
                // Convert to top-left origin for intuitive reading order.
                struct TextBlock {
                    let text: String
                    let minX: CGFloat
                    let maxX: CGFloat
                    let minY: CGFloat // from top
                    let maxY: CGFloat
                }

                var blocks: [TextBlock] = []
                for obs in observations {
                    guard let candidate = obs.topCandidates(1).first else { continue }
                    let box = obs.boundingBox
                    // Flip Y so 0 is top
                    let topY = 1.0 - (box.origin.y + box.size.height)
                    let bottomY = 1.0 - box.origin.y
                    blocks.append(TextBlock(
                        text: candidate.string,
                        minX: box.origin.x,
                        maxX: box.origin.x + box.size.width,
                        minY: topY,
                        maxY: bottomY
                    ))
                }

                // Check for multi-column layout by finding distinct horizontal columns
                // Compute column buckets:
                let reconstructedText = Self.reconstructColumns(from: blocks)
                continuation.resume(returning: reconstructedText)
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func reconstructColumns(from blocks: [Any]) -> String {
        // Group blocks by columns based on X position
        struct Block {
            let text: String
            let minX: CGFloat
            let maxX: CGFloat
            let topY: CGFloat
        }

        let typedBlocks: [Block] = blocks.compactMap { b in
            if let tb = b as? (text: String, minX: CGFloat, maxX: CGFloat, minY: CGFloat, maxY: CGFloat) {
                return Block(text: tb.text, minX: tb.minX, maxX: tb.maxX, topY: tb.minY)
            }
            return nil
        }

        if typedBlocks.isEmpty {
            // Fallback for internal helper
            return ""
        }

        // Determine if there are 2 distinct columns (e.g. median width < 0.45 and blocks split across center)
        let midpoints = typedBlocks.map { ($0.minX + $0.maxX) / 2.0 }
        let hasLeftColumn = midpoints.contains { $0 < 0.45 }
        let hasRightColumn = midpoints.contains { $0 > 0.55 }
        let isTwoColumn = hasLeftColumn && hasRightColumn

        if isTwoColumn {
            let leftBlocks = typedBlocks.filter { ($0.minX + $0.maxX) / 2.0 <= 0.5 }.sorted { $0.topY < $1.topY }
            let rightBlocks = typedBlocks.filter { ($0.minX + $0.maxX) / 2.0 > 0.5 }.sorted { $0.topY < $1.topY }

            let leftText = leftBlocks.map { $0.text }.joined(separator: "\n")
            let rightText = rightBlocks.map { $0.text }.joined(separator: "\n")
            return "\(leftText)\n\n\(rightText)"
        } else {
            let sortedBlocks = typedBlocks.sorted { $0.topY < $1.topY }
            return sortedBlocks.map { $0.text }.joined(separator: "\n")
        }
    }

    // MARK: - PDF Parsing with Vision OCR Fallback

    func parsePDF(data: Data) async throws -> ParsedCastingCall {
        let text = try await extractRawText(fromPDF: data)
        return await parseText(text)
    }

    func extractRawText(fromPDF data: Data) async throws -> String {
        guard let document = PDFDocument(data: data) else {
            return ""
        }

        var fullExtractedText = ""
        let pageCount = document.pageCount

        for i in 0..<pageCount {
            guard let page = document.page(at: i) else { continue }
            let pageText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            // Fallback to Vision OCR if page has no selectable text layer
            if pageText.isEmpty {
                let pageBounds = page.bounds(for: .mediaBox)
                let renderer = UIGraphicsImageRenderer(size: pageBounds.size)
                let renderedImage = renderer.image { ctx in
                    UIColor.white.set()
                    ctx.fill(pageBounds)
                    ctx.cgContext.translateBy(x: 0.0, y: pageBounds.size.height)
                    ctx.cgContext.scaleBy(x: 1.0, y: -1.0)
                    page.draw(with: .mediaBox, to: ctx.cgContext)
                }

                if let cgImage = renderedImage.cgImage {
                    let ocrText = try? await extractTextWithColumnReconstruction(from: cgImage)
                    if let ocr = ocrText, !ocr.isEmpty {
                        fullExtractedText += (fullExtractedText.isEmpty ? "" : "\n\n") + ocr
                    }
                }
            } else {
                fullExtractedText += (fullExtractedText.isEmpty ? "" : "\n\n") + pageText
            }
        }

        return fullExtractedText
    }

    // MARK: - DOCX Parsing via Zip Extraction & XMLParser

    func parseDocx(data: Data) async throws -> ParsedCastingCall {
        let text = try await extractRawText(fromDocx: data)
        return await parseText(text)
    }

    func extractRawText(fromDocx data: Data) async throws -> String {
        // Unzip word/document.xml from docx data
        if let xmlText = extractDocumentXml(from: data) {
            let parsedText = parseDocxXML(xmlText)
            if !parsedText.isEmpty {
                return parsedText
            }
        }

        // Fallback: search raw utf8 data for XML text tags <w:t>...</w:t>
        return extractTextFromRawDocx(data: data)
    }

    // MARK: - Multi-File Import Support

    func parseMultipleFiles(urls: [URL]) async throws -> ParsedCastingCall {
        var combinedText = ""
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            guard let data = try? Data(contentsOf: url) else { continue }
            let filename = url.lastPathComponent.lowercased()

            let extracted: String
            if filename.hasSuffix(".pdf") {
                extracted = (try? await extractRawText(fromPDF: data)) ?? ""
            } else if filename.hasSuffix(".docx") {
                extracted = (try? await extractRawText(fromDocx: data)) ?? ""
            } else if let image = UIImage(data: data) {
                extracted = (try? await extractRawText(from: image)) ?? ""
            } else {
                extracted = String(data: data, encoding: .utf8) ?? ""
            }

            if !extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                combinedText += (combinedText.isEmpty ? "" : "\n\n") + extracted
            }
        }
        return await parseText(combinedText)
    }

    private func extractDocumentXml(from data: Data) -> String? {
        // Native docx zip reader: look for "word/document.xml" entry header
        // Zip local file header signature: 0x04034b50 (PK\x03\x04)
        var offset = 0
        let count = data.count
        let targetName = "word/document.xml"

        while offset + 30 <= count {
            let sig = data.withUnsafeBytes { ptr -> UInt32 in
                ptr.load(fromByteOffset: offset, as: UInt32.self)
            }
            if sig != 0x04034b50 {
                // Not a local header, advance by 1
                offset += 1
                continue
            }

            let compMethod = data.withUnsafeBytes { ptr -> UInt16 in
                ptr.load(fromByteOffset: offset + 8, as: UInt16.self)
            }
            let compSize = Int(data.withUnsafeBytes { ptr -> UInt32 in
                ptr.load(fromByteOffset: offset + 18, as: UInt32.self)
            })
            let uncompSize = Int(data.withUnsafeBytes { ptr -> UInt32 in
                ptr.load(fromByteOffset: offset + 22, as: UInt32.self)
            })
            let nameLen = Int(data.withUnsafeBytes { ptr -> UInt16 in
                ptr.load(fromByteOffset: offset + 26, as: UInt16.self)
            })
            let extraLen = Int(data.withUnsafeBytes { ptr -> UInt16 in
                ptr.load(fromByteOffset: offset + 28, as: UInt16.self)
            })

            let headerSize = 30 + nameLen + extraLen
            guard offset + headerSize <= count else { break }

            let nameData = data.subdata(in: (offset + 30)..<(offset + 30 + nameLen))
            let fileName = String(data: nameData, encoding: .utf8) ?? ""

            let dataOffset = offset + headerSize
            if fileName == targetName, dataOffset + compSize <= count {
                let fileData = data.subdata(in: dataOffset..<(dataOffset + compSize))
                if compMethod == 8 { // Deflated
                    if let inflated = decompressDeflate(data: fileData, expectedSize: uncompSize) {
                        return String(data: inflated, encoding: .utf8)
                    }
                } else if compMethod == 0 { // Stored
                    return String(data: fileData, encoding: .utf8)
                }
            }

            offset = dataOffset + compSize
        }
        return nil
    }

    private func decompressDeflate(data: Data, expectedSize: Int) -> Data? {
        guard !data.isEmpty else { return nil }
        let bufferSize = max(expectedSize, data.count * 4, 1024)
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destinationBuffer.deallocate() }

        let decompressedSize = data.withUnsafeBytes { (srcPtr: UnsafeRawBufferPointer) -> Int in
            guard let baseAddress = srcPtr.baseAddress else { return 0 }
            return compression_decode_buffer(
                destinationBuffer,
                bufferSize,
                baseAddress.assumingMemoryBound(to: UInt8.self),
                data.count,
                nil,
                COMPRESSION_ZLIB
            )
        }

        if decompressedSize > 0 {
            return Data(bytes: destinationBuffer, count: decompressedSize)
        }
        return nil
    }

    private func extractTextFromRawDocx(data: Data) -> String {
        // Fast regex fallback matching <w:t>...</w:t> inside raw payload
        guard let content = String(data: data, encoding: .ascii) else { return "" }
        let pattern = "<w:t[^>]*>(.*?)</w:t>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return "" }
        let matches = regex.matches(in: content, range: NSRange(content.startIndex..., in: content))

        var result = ""
        for match in matches {
            if let range = Range(match.range(at: 1), in: content) {
                result += content[range] + " "
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseDocxXML(_ xml: String) -> String {
        guard let data = xml.data(using: .utf8) else { return "" }
        let delegate = DocxXMLParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.extractedText
    }

    // MARK: - Deterministic Parser

    func parseText(_ text: String) async -> ParsedCastingCall {
        var result = ParsedCastingCall()
        result.rawExtractedText = text
        let cleanText = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = cleanText.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }

        // 1. Recipient Email Extraction (kept out of requirements)
        let emailRegex = try? NSRegularExpression(pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", options: .caseInsensitive)
        if let emailMatch = emailRegex?.firstMatch(in: cleanText, range: NSRange(cleanText.startIndex..., in: cleanText)),
           let emailRange = Range(emailMatch.range, in: cleanText) {
            result.recipientEmail = String(cleanText[emailRange])
        }

        // 2. Production Type
        let lowerText = cleanText.lowercased()
        if lowerText.contains("feature film") || lowerText.contains("movie") || lowerText.contains("cinema") {
            result.productionType = .featureFilm
        } else if lowerText.contains("short film") {
            result.productionType = .shortFilm
        } else if lowerText.contains("web series") || lowerText.contains("ott series") {
            result.productionType = .webSeries
        } else if lowerText.contains("series") || lowerText.contains("television") || lowerText.contains("tv show") {
            result.productionType = .series
        } else if lowerText.contains("commercial") || lowerText.contains("ad film") || lowerText.contains("advertisement") {
            result.productionType = .adFilm
        } else if lowerText.contains("theatre") || lowerText.contains("theater") || lowerText.contains("play") {
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
            // First prominent non-empty line
            if let firstLine = lines.first(where: { !$0.isEmpty && $0.count < 60 && !$0.lowercased().contains("casting call") }) {
                result.projectName = firstLine.replacingOccurrences(of: "CASTING CALL - ", with: "")
                    .replacingOccurrences(of: "CASTING NOTICE: ", with: "")
                    .trimmingCharacters(in: .whitespaces)
            } else {
                result.projectName = "Untitled Audition"
            }
        }

        // 4. Deadline Extraction
        var foundDeadline = false
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            // Check lines mentioning deadline/submit
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
        if lowerText.contains("4:5") || lowerText.contains("4x5") {
            result.requiredHeadshotRatio = .ratio4x5
        } else if lowerText.contains("2:3") || lowerText.contains("2x3") {
            result.requiredHeadshotRatio = .ratio2x3
        } else if lowerText.contains("1:1") || lowerText.contains("square") {
            result.requiredHeadshotRatio = .ratio1x1
        }

        // Slate max seconds
        let slateRegex = try? NSRegularExpression(pattern: "(\\d{2})\\s*(?:seconds?|s|sec)\\s*slate", options: .caseInsensitive)
        if let match = slateRegex?.firstMatch(in: cleanText, range: NSRange(cleanText.startIndex..., in: cleanText)),
           let range = Range(match.range(at: 1), in: cleanText),
           let sec = Double(cleanText[range]) {
            result.maxSlateSeconds = sec
        }

        // Clip max seconds (e.g., "2-minute clip", "120s")
        let clipMinRegex = try? NSRegularExpression(pattern: "(\\d+)\\s*(?:-|\\s*)minute(?:s)?\\s*(?:clip|tape|video|audition)", options: .caseInsensitive)
        if let match = clipMinRegex?.firstMatch(in: cleanText, range: NSRange(cleanText.startIndex..., in: cleanText)),
           let range = Range(match.range(at: 1), in: cleanText),
           let mins = Double(cleanText[range]) {
            result.maxClipSeconds = mins * 60.0
        }

        // Clip max size MB (e.g. "100 MB", "50mb")
        let mbRegex = try? NSRegularExpression(pattern: "(\\d+)\\s*mb", options: .caseInsensitive)
        if let match = mbRegex?.firstMatch(in: cleanText, range: NSRange(cleanText.startIndex..., in: cleanText)),
           let range = Range(match.range(at: 1), in: cleanText),
           let mb = Double(cleanText[range]) {
            result.maxPerClipSizeMB = mb
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
            // Fallback role name search
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
            // Take the line after role name if available
            if let idx = lines.firstIndex(where: { $0.lowercased().contains("role:") }), idx + 1 < lines.count {
                result.roleDescription = lines[idx + 1]
            }
        }

        // 7. Requirements Checklist (clean: email kept out)
        var reqs: [SubmissionRequirement] = []
        reqs.append(SubmissionRequirement(title: "Guided Headshots (3 Angles: Front, Left, Right)", isCompleted: false))
        reqs.append(SubmissionRequirement(title: "Slate / Introduction Video", isCompleted: false))
        reqs.append(SubmissionRequirement(title: "Audition Self-Tape Take", isCompleted: false))

        if lowerText.contains("resume") || lowerText.contains("cv") {
            reqs.append(SubmissionRequirement(title: "Actor Resume / Bio", isCompleted: false))
        }
        if lowerText.contains("showreel") || lowerText.contains("demo reel") {
            reqs.append(SubmissionRequirement(title: "Demo Showreel", isCompleted: false))
        }

        result.requirements = reqs
        return result
    }

    // MARK: - Dialogue & Script Parser

    func parseSidesText(_ text: String, defaultRole: String = "ACTOR") -> (scriptText: String, cueLines: [CueLine], teleprompterLines: [String]) {
        let cleanText = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = cleanText.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let dialogue = parseDialogue(from: lines)
        if let script = dialogue.scriptText, !script.isEmpty {
            return (script, dialogue.cueLines, dialogue.teleprompterLines)
        }

        // If no distinct CHARACTER: format was detected, treat the entire text as a monologue
        let cleaned = stripStageDirections(from: cleanText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return ("", [], []) }

        let chunks = splitIntoTeleprompterChunks(text: cleaned, maxWords: 25)
        let teleprompterLines = chunks.map { "\(defaultRole): \($0)" }
        return (cleaned, [], teleprompterLines)
    }

    private func parseDialogue(from lines: [String]) -> (mainRole: String, cueRole: String, cueLines: [CueLine], teleprompterLines: [String], scriptText: String?) {
        // Reserved metadata keywords to ignore as speakers:
        let ignoredKeywords: Set<String> = [
            "PROJECT", "TITLE", "FILM", "MOVIE", "SERIES", "ROLE", "CHARACTER",
            "ROLE DESCRIPTION", "CHARACTER DESCRIPTION", "BIO", "DEADLINE", "DUE",
            "SUBMIT", "SUBMISSION", "EMAIL", "CONTACT", "PRODUCER", "DIRECTOR",
            "WRITER", "CASTING DIRECTOR", "CASTING", "PRODUCTION", "SHOOT DATES",
            "SHOOT DATE", "LOCATION", "RATE", "PAY", "UNION", "NON-UNION", "STATUS",
            "NOTE", "NOTES", "REQUIREMENT", "REQUIREMENTS", "AUDITION", "AUDITIONS",
            "SPEC", "SPECS", "SLATE", "HEADSHOT", "HEADSHOTS", "TAPE", "SELF-TAPE",
            "SCENE", "INT", "EXT", "DAY", "NIGHT", "CONTINUED", "NOTICE", "CASTING NOTICE",
            "CASTING CALL", "INFO", "IMPORTANT", "ATTACHMENT", "ATTACHMENTS", "FILE", "FILES"
        ]

        // Find dialogue pattern:
        // CHARACTER: dialogue...
        // or CHARACTER (parenthetical): dialogue...
        let charPattern = "^([A-Z0-9\\s]{2,25})(?:\\s*\\([^)]*\\))?\\s*:(.*)$"
        guard let regex = try? NSRegularExpression(pattern: charPattern, options: []) else {
            return ("", "", [], [], nil)
        }

        struct RawSpeech {
            let speaker: String
            var dialogue: String
        }

        var speechList: [RawSpeech] = []
        var speakerLineCounts: [String: Int] = [:]
        var currentSpeaker: String?
        var currentBuffer = ""

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let range = NSRange(trimmed.startIndex..., in: trimmed)
            if let match = regex.firstMatch(in: trimmed, range: range),
               let speakerRange = Range(match.range(at: 1), in: trimmed),
               let dialogueRange = Range(match.range(at: 2), in: trimmed) {

                let speaker = String(trimmed[speakerRange]).trimmingCharacters(in: .whitespaces).uppercased()
                let initialDialogue = String(trimmed[dialogueRange]).trimmingCharacters(in: .whitespaces)

                // Check if this matched a metadata header rather than actual dialogue
                if ignoredKeywords.contains(speaker) || speaker.contains("@") || speaker.contains("HTTP") || speaker.hasSuffix(".COM") {
                    if let prevSpeaker = currentSpeaker, !currentBuffer.isEmpty {
                        speechList.append(RawSpeech(speaker: prevSpeaker, dialogue: currentBuffer))
                        speakerLineCounts[prevSpeaker, default: 0] += 1
                    }
                    currentSpeaker = nil
                    currentBuffer = ""
                    continue
                }

                // If previous speaker was ongoing, flush it
                if let prevSpeaker = currentSpeaker, !currentBuffer.isEmpty {
                    speechList.append(RawSpeech(speaker: prevSpeaker, dialogue: currentBuffer))
                    speakerLineCounts[prevSpeaker, default: 0] += 1
                }

                currentSpeaker = speaker
                currentBuffer = initialDialogue
            } else if let _ = currentSpeaker {
                // Check if this continuation line is actually a metadata header
                if let colonIdx = trimmed.firstIndex(of: ":") {
                    let prefix = String(trimmed[..<colonIdx]).trimmingCharacters(in: .whitespaces).uppercased()
                    if ignoredKeywords.contains(prefix) {
                        if let prevSpeaker = currentSpeaker, !currentBuffer.isEmpty {
                            speechList.append(RawSpeech(speaker: prevSpeaker, dialogue: currentBuffer))
                            speakerLineCounts[prevSpeaker, default: 0] += 1
                        }
                        currentSpeaker = nil
                        currentBuffer = ""
                        continue
                    }
                }

                // Check if it's stage direction like [hesitates] or (whispers)
                if trimmed.hasPrefix("(") && trimmed.hasSuffix(")") {
                    continue
                }
                if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                    continue
                }
                currentBuffer += (currentBuffer.isEmpty ? "" : " ") + trimmed
            }
        }

        if let prevSpeaker = currentSpeaker, !currentBuffer.isEmpty {
            speechList.append(RawSpeech(speaker: prevSpeaker, dialogue: currentBuffer))
            speakerLineCounts[prevSpeaker, default: 0] += 1
        }

        // Only treat as script if there are genuine dialogue lines
        guard !speakerLineCounts.isEmpty else {
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
        let sortedSpeakers = speakerLineCounts.sorted { $0.value > $1.value }
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

    private func stripStageDirections(from text: String) -> String {
        var result = text
        // Strip (parentheticals)
        if let parenRegex = try? NSRegularExpression(pattern: "\\([^)]*\\)", options: []) {
            result = parenRegex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        // Strip [brackets]
        if let bracketRegex = try? NSRegularExpression(pattern: "\\[[^\\]]*\\]", options: []) {
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

// MARK: - Docx XML Parser Delegate

private final class DocxXMLParserDelegate: NSObject, XMLParserDelegate {
    var extractedText = ""
    private var isInsideTextElement = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        if elementName == "w:t" {
            isInsideTextElement = true
        } else if elementName == "w:p" {
            // Paragraph break
            if !extractedText.isEmpty && !extractedText.hasSuffix("\n") {
                extractedText += "\n"
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isInsideTextElement {
            extractedText += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "w:t" {
            isInsideTextElement = false
        }
    }
}
