import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UIKit
import Vision

/// On-device multi-pass Vision OCR ported from OneTake-iOS-main.
/// Handles bright/dark/colored casting flyers, tiny footer contact strips,
/// multi-page scans with sequential `autoreleasepool` bounds, and 2D layout reconstruction.
nonisolated enum NoticeOCR {
    private static let preferredLanguages: [String] = ["en-US", "en-IN", "hi-IN"]
    private static let minimumLineConfidence: Float = 0.35
    private static let sharedCIContext = CIContext(options: [.cacheIntermediates: false])

    private static func configureSupportedLanguages(for request: VNRecognizeTextRequest) {
        if let supported = try? request.supportedRecognitionLanguages() {
            let supportedSet = Set(supported)
            let matched = preferredLanguages.filter { supportedSet.contains($0) }
            if !matched.isEmpty {
                request.recognitionLanguages = matched
                return
            }
            var matchedSupported: [String] = []
            for pref in preferredLanguages {
                let prefix = String(pref.prefix(2))
                if let match = supported.first(where: { $0.hasPrefix(prefix) && !matchedSupported.contains($0) }) {
                    matchedSupported.append(match)
                }
            }
            if !matchedSupported.isEmpty {
                request.recognitionLanguages = matchedSupported
                return
            }
            request.recognitionLanguages = supported.contains("en-US") ? ["en-US"] : Array(supported.prefix(3))
            return
        }
        request.recognitionLanguages = preferredLanguages
    }

    static func recognizeText(in images: [UIImage]) async -> String {
        let pages = await recognizePages(in: images)
        return pages.filter { !looksBlankPage($0) }.joined(separator: "\n\n")
    }

    static func recognizePages(in images: [UIImage]) async -> [String] {
        var results: [String] = []
        for image in images {
            let text = await Task.detached(priority: .userInitiated) {
                autoreleasepool {
                    recognizeText(in: image)
                }
            }.value
            results.append(text)
        }
        return results
    }

    private static func looksBlankPage(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func recognizeText(in image: UIImage) -> String {
        recognizeLayout(in: image, pageIndex: 0).text
    }

    static func recognizeLayout(in image: UIImage, pageIndex: Int = 0) -> (lines: [LayoutLine], text: String) {
        autoreleasepool {
            guard let cgImage = normalizedCGImage(image) else {
                return ([], "")
            }
            return recognizeLayout(fromNormalizedCGImage: cgImage, pageIndex: pageIndex)
        }
    }

    static func recognizeLayout(from cgImage: CGImage, orientation: CGImagePropertyOrientation = .up, pageIndex: Int = 0) -> (lines: [LayoutLine], text: String) {
        autoreleasepool {
            guard let normalized = normalizedCGImage(cgImage: cgImage, orientation: orientation) else {
                return ([], "")
            }
            return recognizeLayout(fromNormalizedCGImage: normalized, pageIndex: pageIndex)
        }
    }

    private static func recognizeLayout(fromNormalizedCGImage cgImage: CGImage, pageIndex: Int) -> (lines: [LayoutLine], text: String) {
        // Pass 1: Direct Vision OCR on normalized upright CGImage
        let primaryBoxes = performVisionOCRBoxes(on: cgImage)
        var mergedBoxes = primaryBoxes
        var bestResult = OCRLayoutReconstructor.reconstruct(boxes: mergedBoxes)

        let longest = max(cgImage.width, cgImage.height)
        let secondarySource: CGImage = {
            if longest < 1400 {
                let scale = min(2.0, 2048.0 / CGFloat(max(longest, 1)))
                return scaledCGImage(cgImage, scale: scale) ?? cgImage
            }
            return cgImage
        }()

        // Pass 2: Adaptive contrast stretch (+ auto dark inversion) when weak or missing email/link
        let missingContactInfo = !bestResult.contains("@") && !bestResult.lowercased().contains("http")
        if isWeakOCR(bestResult) || missingContactInfo {
            autoreleasepool {
                if let processedImage = enhancedCGImage(secondarySource) {
                    let processedBoxes = performVisionOCRBoxes(on: processedImage)
                    let processedText = OCRLayoutReconstructor.reconstruct(boxes: processedBoxes)
                    if isWeakOCR(bestResult), isBetterOCRResult(processedText, than: bestResult) {
                        mergedBoxes = processedBoxes
                        bestResult = processedText
                    } else if !processedBoxes.isEmpty {
                        mergedBoxes = mergeNonOverlappingBoxes(base: mergedBoxes, additions: processedBoxes)
                        bestResult = OCRLayoutReconstructor.reconstruct(boxes: mergedBoxes)
                    }
                }
            }
        }

        // Pass 3: Forced luminance inversion for light-on-dark posters
        if isWeakOCR(bestResult) || !bestResult.contains("@") {
            autoreleasepool {
                if let invertedImage = enhancedCGImage(secondarySource, forceInvert: true) {
                    let invertedBoxes = performVisionOCRBoxes(on: invertedImage)
                    let invertedText = OCRLayoutReconstructor.reconstruct(boxes: invertedBoxes)
                    if isWeakOCR(bestResult), isBetterOCRResult(invertedText, than: bestResult) {
                        mergedBoxes = invertedBoxes
                        bestResult = invertedText
                    } else if !invertedBoxes.isEmpty {
                        mergedBoxes = mergeNonOverlappingBoxes(base: mergedBoxes, additions: invertedBoxes)
                        bestResult = OCRLayoutReconstructor.reconstruct(boxes: mergedBoxes)
                    }
                }
            }
        }

        // Pass 3b: Enlarged footer contact band recovery for small poster emails/URLs
        if !bestResult.contains("@") && !bestResult.lowercased().contains("http") {
            autoreleasepool {
                let footerBoxes = recoverFooterContactBoxes(from: cgImage)
                if !footerBoxes.isEmpty {
                    mergedBoxes = mergeNonOverlappingBoxes(base: mergedBoxes, additions: footerBoxes)
                    bestResult = OCRLayoutReconstructor.reconstruct(boxes: mergedBoxes)
                }
            }
        }

        // Pass 4: Bounded up to 3072px enlargement retry for very small-print flyers if still weak
        if isWeakOCR(bestResult) {
            autoreleasepool {
                let maxBound: CGFloat = 3072
                let candidateCG: CGImage?
                if longest < 2500 {
                    let scale = min(2.0, maxBound / CGFloat(max(longest, 1)))
                    candidateCG = scaledCGImage(cgImage, scale: scale)
                } else {
                    candidateCG = cgImage
                }

                if let candidateCG {
                    let candidateBuilders: [() -> CGImage?] = [
                        { candidateCG },
                        { enhancedCGImage(candidateCG) },
                        { enhancedCGImage(candidateCG, forceInvert: true) }
                    ]
                    for buildVariant in candidateBuilders {
                        guard isWeakOCR(bestResult) else { break }
                        autoreleasepool {
                            guard let variant = buildVariant() else { return }
                            let variantBoxes = performVisionOCRBoxes(on: variant)
                            let variantText = OCRLayoutReconstructor.reconstruct(boxes: variantBoxes)
                            if isBetterOCRResult(variantText, than: bestResult) {
                                mergedBoxes = variantBoxes
                                bestResult = variantText
                            }
                        }
                    }
                }
            }
        }

        let layoutLines = mergedBoxes.map {
            LayoutLine(text: $0.text, rect: $0.rect, pageIndex: pageIndex)
        }
        return (layoutLines, bestResult)
    }

    private static func recoverFooterContactBoxes(from cgImage: CGImage) -> [OCRLayoutReconstructor.TextBoundingBox] {
        let stripFraction: CGFloat = 0.28
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let cropRect = CGRect(
            x: 0,
            y: height * (1 - stripFraction),
            width: width,
            height: height * stripFraction
        ).integral
        guard cropRect.width > 20, cropRect.height > 20,
              let cropped = cgImage.cropping(to: cropRect) else { return [] }

        let targetSource = scaledCGImage(cropped, scale: 2.5) ?? cropped
        var recovered: [OCRLayoutReconstructor.TextBoundingBox] = []
        let variants: [CGImage] = [
            targetSource,
            enhancedCGImage(targetSource),
            enhancedCGImage(targetSource, forceInvert: true)
        ].compactMap { $0 }

        for variant in variants {
            let boxes = performVisionOCRBoxes(on: variant, usesLanguageCorrection: false)
            for box in boxes where box.text.contains("@")
                || box.text.lowercased().contains("http")
                || box.text.lowercased().contains("www.")
                || box.text.lowercased().contains(".in")
                || box.text.lowercased().contains(".com") {
                let mappedRect = CGRect(
                    x: box.rect.minX,
                    y: box.rect.minY * stripFraction,
                    width: box.rect.width,
                    height: box.rect.height * stripFraction
                )
                recovered.append(OCRLayoutReconstructor.TextBoundingBox(
                    text: box.text,
                    rect: mappedRect,
                    confidence: box.confidence
                ))
            }
            if recovered.contains(where: { $0.text.contains("@") }) {
                break
            }
        }
        return recovered
    }

    private static func mergeNonOverlappingBoxes(
        base: [OCRLayoutReconstructor.TextBoundingBox],
        additions: [OCRLayoutReconstructor.TextBoundingBox]
    ) -> [OCRLayoutReconstructor.TextBoundingBox] {
        var result = base
        for candidate in additions {
            let trimmed = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let overlapsExisting = result.contains { existing in
                let intersection = existing.rect.intersection(candidate.rect)
                guard !intersection.isNull, !intersection.isEmpty else { return false }
                let interArea = intersection.width * intersection.height
                let minArea = max(min(existing.rect.width * existing.rect.height, candidate.rect.width * candidate.rect.height), 1e-6)
                let verticalAlign = abs(existing.rect.midY - candidate.rect.midY) < max(existing.rect.height, candidate.rect.height) * 0.6
                return (interArea / minArea) > 0.28 || (verticalAlign && intersection.width > min(existing.rect.width, candidate.rect.width) * 0.35)
            }
            if !overlapsExisting {
                result.append(candidate)
            }
        }
        return result
    }

    private static func isWeakOCR(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || !looksReadable(trimmed) { return true }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .filter { $0.filter(\.isLetter).count >= 2 }
        let lines = trimmed.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return words.count < 6 || lines.count < 2
    }

    private static func ocrScore(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .filter { $0.filter(\.isLetter).count >= 2 }
        let lines = trimmed.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return (words.count * 3) + (lines.count * 2)
    }

    private static func isBetterOCRResult(_ candidate: String, than current: String) -> Bool {
        ocrScore(candidate) > ocrScore(current)
    }

    private static func scaledCGImage(_ source: CGImage, scale: CGFloat) -> CGImage? {
        guard scale > 1.0 else { return source }
        let maxDimension: CGFloat = 3072
        let clampedScale = min(scale, maxDimension / CGFloat(max(source.width, source.height, 1)))
        guard clampedScale > 1.0 else { return source }
        let newWidth = max(1, Int((CGFloat(source.width) * clampedScale).rounded()))
        let newHeight = max(1, Int((CGFloat(source.height) * clampedScale).rounded()))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage()
    }

    private static func performVisionOCRBoxes(
        on cgImage: CGImage,
        usesLanguageCorrection: Bool? = nil
    ) -> [OCRLayoutReconstructor.TextBoundingBox] {
        for level in [VNRequestTextRecognitionLevel.accurate, .fast] {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = level
            request.usesLanguageCorrection = usesLanguageCorrection ?? (level == .accurate)
            #if targetEnvironment(simulator)
            request.usesCPUOnly = true
            #endif
            configureSupportedLanguages(for: request)

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up)
            do {
                try handler.perform([request])
            } catch {
                continue
            }

            let boxes: [OCRLayoutReconstructor.TextBoundingBox] = (request.results ?? []).compactMap { observation in
                let candidates = observation.topCandidates(3)
                guard let best = candidates.first else { return nil }
                let chosen = (best.confidence >= minimumLineConfidence || (best.string.contains("@") && best.confidence >= 0.15))
                    ? best
                    : candidates.first(where: {
                        ($0.confidence >= minimumLineConfidence && $0.string.filter(\.isLetter).count >= 2)
                        || ($0.string.contains("@") && $0.confidence >= 0.15)
                    })
                guard let candidate = chosen else { return nil }
                if isSocialOverlayCounter(text: candidate.string, rect: observation.boundingBox) {
                    return nil
                }
                return OCRLayoutReconstructor.TextBoundingBox(
                    text: candidate.string,
                    rect: observation.boundingBox,
                    confidence: candidate.confidence
                )
            }

            if !boxes.isEmpty {
                // Re-read contact lines (@, http, www.) without language correction so emails/handles stay exact.
                if usesLanguageCorrection == nil && level == .accurate {
                    return reconcileContactLinesWithoutCorrection(boxes: boxes, on: cgImage)
                }
                return boxes
            }
        }
        return []
    }

    private static func isSocialOverlayCounter(text: String, rect: CGRect) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rect.minX >= 0.84, rect.height <= 0.055 else { return false }
        return trimmed.range(of: #"^(?:\d{1,3}(?:,\d{3})*|\d+(?:\.\d+)?[KMkm]?)$"#, options: .regularExpression) != nil
    }

    private static func reconcileContactLinesWithoutCorrection(
        boxes: [OCRLayoutReconstructor.TextBoundingBox],
        on cgImage: CGImage
    ) -> [OCRLayoutReconstructor.TextBoundingBox] {
        let needsRawRead = boxes.contains { box in
            let lower = box.text.lowercased()
            return lower.contains("@") || lower.contains("www.") || lower.contains("http") || lower.contains(".com") || lower.contains(".in")
        }
        guard needsRawRead else { return boxes }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        #if targetEnvironment(simulator)
        request.usesCPUOnly = true
        #endif
        configureSupportedLanguages(for: request)

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up)
        guard (try? handler.perform([request])) != nil,
              let rawObservations = request.results, !rawObservations.isEmpty else {
            return boxes
        }

        return boxes.map { box in
            let lower = box.text.lowercased()
            guard lower.contains("@") || lower.contains("www.") || lower.contains("http") || lower.contains(".com") || lower.contains(".in") else {
                return box
            }
            if let matchingRaw = rawObservations.first(where: { obs in
                let inter = obs.boundingBox.intersection(box.rect)
                guard !inter.isNull, !inter.isEmpty else { return false }
                let area = inter.width * inter.height
                let minArea = max(1e-6, min(obs.boundingBox.width * obs.boundingBox.height, box.rect.width * box.rect.height))
                return (area / minArea) > 0.4
            }),
               let rawText = matchingRaw.topCandidates(1).first?.string,
               rawText.contains("@") || rawText.lowercased().contains("www.") || rawText.lowercased().contains("http") {
                return OCRLayoutReconstructor.TextBoundingBox(
                    text: rawText,
                    rect: box.rect,
                    confidence: box.confidence
                )
            }
            return box
        }
    }

    private static func enhancedCGImage(_ source: CGImage, forceInvert: Bool = false) -> CGImage? {
        var image = CIImage(cgImage: source)

        let profile = luminanceProfile(source)
        let isDark = forceInvert || profile.mean < 0.38

        if let filter = CIFilter(name: "CIColorControls") {
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(0.0, forKey: kCIInputSaturationKey)
            filter.setValue(1.0, forKey: kCIInputContrastKey)
            if let output = filter.outputImage { image = output }
        }

        let low = max(0, profile.low - 0.015)
        let high = min(1, profile.high + 0.015)
        let range = max(high - low, 0.12)
        let scale = min(3.5, max(0.85, 0.94 / range))
        let bias = 0.03 - low * scale
        if let filter = CIFilter(name: "CIColorMatrix") {
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(CIVector(x: scale, y: 0, z: 0, w: 0), forKey: "inputRVector")
            filter.setValue(CIVector(x: 0, y: scale, z: 0, w: 0), forKey: "inputGVector")
            filter.setValue(CIVector(x: 0, y: 0, z: scale, w: 0), forKey: "inputBVector")
            filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
            filter.setValue(CIVector(x: bias, y: bias, z: bias, w: 0), forKey: "inputBiasVector")
            if let output = filter.outputImage { image = output }
        }

        if isDark, let invertFilter = CIFilter(name: "CIColorInvert") {
            invertFilter.setValue(image, forKey: kCIInputImageKey)
            if let output = invertFilter.outputImage { image = output }
        }

        if let filter = CIFilter(name: "CISharpenLuminance") {
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(isDark ? 0.65 : 0.55, forKey: kCIInputSharpnessKey)
            if let output = filter.outputImage { image = output }
        }

        return sharedCIContext.createCGImage(image, from: image.extent)
    }

    private struct LuminanceProfile {
        var mean: CGFloat
        var low: CGFloat
        var high: CGFloat
    }

    private static func luminanceProfile(_ source: CGImage) -> LuminanceProfile {
        let width = 32, height = 32, bytesPerRow = 32 * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let rendered = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return LuminanceProfile(mean: 0.5, low: 0.05, high: 0.95) }

        var values: [CGFloat] = []
        values.reserveCapacity(width * height)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let r = CGFloat(pixels[offset]) / 255
            let g = CGFloat(pixels[offset + 1]) / 255
            let b = CGFloat(pixels[offset + 2]) / 255
            values.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
        }
        values.sort()
        guard !values.isEmpty else { return LuminanceProfile(mean: 0.5, low: 0.05, high: 0.95) }
        let mean = values.reduce(0, +) / CGFloat(values.count)
        let low = values[min(values.count - 1, values.count * 3 / 100)]
        let high = values[min(values.count - 1, values.count * 97 / 100)]
        return LuminanceProfile(mean: mean, low: low, high: max(low, high))
    }

    static func normalizedScanImage(_ image: UIImage, maxDimension: CGFloat = 2048) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > 0, image.size.width > 0, image.size.height > 0 else { return image }
        let scale = longest > maxDimension ? maxDimension / longest : 1
        let size = CGSize(
            width: max(1, (image.size.width * scale).rounded()),
            height: max(1, (image.size.height * scale).rounded())
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private static func normalizedCGImage(_ image: UIImage) -> CGImage? {
        normalizedScanImage(image, maxDimension: 2048).cgImage ?? image.cgImage
    }

    private static func normalizedCGImage(cgImage: CGImage, orientation: CGImagePropertyOrientation) -> CGImage? {
        if orientation == .up && max(cgImage.width, cgImage.height) <= 2048 {
            return cgImage
        }
        let ciImage = CIImage(cgImage: cgImage).oriented(orientation)
        let longest = max(ciImage.extent.width, ciImage.extent.height)
        let scale = longest > 2048 ? (2048.0 / longest) : 1.0
        let targetImage: CIImage = scale < 1.0
            ? ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : ciImage
        return sharedCIContext.createCGImage(targetImage, from: targetImage.extent) ?? cgImage
    }

    static func looksReadable(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .filter { $0.filter(\.isLetter).count >= 2 }
        guard words.count >= 2 else { return false }
        let totalChars = trimmed.count
        guard totalChars > 0 else { return false }
        let printableCount = trimmed.filter { $0.isLetter || $0.isWhitespace || $0.isNewline || $0.isPunctuation || $0.isNumber }.count
        return Double(printableCount) / Double(totalChars) >= 0.40
    }
}
