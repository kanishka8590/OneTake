import CoreGraphics
import Foundation
import ImageIO
import UIKit

/// Pure, testable geometry and off-main-thread rendering helper matching SwiftUI's `.scaledToFill()`
/// + `.scaleEffect(scale)` + `.offset(offset)` crop preview.
nonisolated enum HeadshotCropMath {
    static func targetAspect(
        for ratio: HeadshotAspectRatio,
        preset: HeadshotCropPreset? = nil,
        imageSize: CGSize? = nil
    ) -> CGFloat {
        switch ratio {
        case .ratio4x5:
            return 4.0 / 5.0
        case .ratio2x3:
            return 2.0 / 3.0
        case .ratio1x1:
            return 1.0
        case .free:
            if let preset {
                switch preset {
                case .cardSlotFit:
                    break
                case .theatrical, .tightCloseUp:
                    return 4.0 / 5.0
                case .commercial:
                    return 3.0 / 4.0
                case .square:
                    return 1.0
                case .headAndShoulders:
                    return 2.0 / 3.0
                }
            }
            if let size = imageSize, size.width > 0, size.height > 0 {
                return size.width / size.height
            }
            return 4.0 / 5.0
        }
    }

    /// Computes the exact fitted frame inside `bounds` preserving `aspectRatio` so visual clips and strokes align 1:1.
    static func aspectFittedSize(aspect: CGFloat, inside bounds: CGSize) -> CGSize {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        let safeAspect = max(0.25, aspect)
        let heightByWidth = bounds.width / safeAspect
        if heightByWidth <= bounds.height {
            return CGSize(width: bounds.width, height: heightByWidth)
        }
        return CGSize(width: bounds.height * safeAspect, height: bounds.height)
    }

    static func maxOffset(
        imageSize: CGSize,
        containerSize: CGSize,
        scale: CGFloat
    ) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0,
              containerSize.width > 0, containerSize.height > 0 else {
            return .zero
        }
        let effectiveScale = max(1.0, scale)
        let baseFillScale = max(
            containerSize.width / imageSize.width,
            containerSize.height / imageSize.height
        )
        let displayW = imageSize.width * baseFillScale * effectiveScale
        let displayH = imageSize.height * baseFillScale * effectiveScale
        return CGSize(
            width: max(0, (displayW - containerSize.width) / 2.0),
            height: max(0, (displayH - containerSize.height) / 2.0)
        )
    }

    static func clampedOffset(
        _ offset: CGSize,
        imageSize: CGSize,
        containerSize: CGSize,
        scale: CGFloat
    ) -> CGSize {
        let limit = maxOffset(imageSize: imageSize, containerSize: containerSize, scale: scale)
        return CGSize(
            width: min(limit.width, max(-limit.width, offset.width)),
            height: min(limit.height, max(-limit.height, offset.height))
        )
    }

    /// Clamps `baseRatio * containerSize` to the active frame bounds before applying `translation`,
    /// preventing pan dead-zones after switching aspect ratios while preserving reversible framing.
    static func adjustedOffset(
        baseRatio: CGSize,
        translation: CGSize = .zero,
        imageSize: CGSize,
        containerSize: CGSize,
        scale: CGFloat
    ) -> CGSize {
        let clampedBase = clampedOffset(
            CGSize(
                width: baseRatio.width * containerSize.width,
                height: baseRatio.height * containerSize.height
            ),
            imageSize: imageSize,
            containerSize: containerSize,
            scale: scale
        )
        return clampedOffset(
            CGSize(
                width: clampedBase.width + translation.width,
                height: clampedBase.height + translation.height
            ),
            imageSize: imageSize,
            containerSize: containerSize,
            scale: scale
        )
    }

    /// Computes the exact visible crop rect in upright image pixel coordinates (top-left origin)
    /// corresponding to SwiftUI `.scaledToFill()` inside `containerSize` with `scale` and `offset`.
    static func cropRect(
        imageSize: CGSize,
        containerSize: CGSize,
        targetAspect: CGFloat,
        scale: CGFloat,
        offset: CGSize
    ) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, targetAspect > 0 else {
            return .zero
        }

        let effectiveContainer: CGSize
        if containerSize.width > 0, containerSize.height > 0 {
            effectiveContainer = containerSize
        } else {
            effectiveContainer = CGSize(width: 300.0, height: 300.0 / targetAspect)
        }

        let effectiveScale = max(1.0, scale)
        let baseFillScale = max(
            effectiveContainer.width / imageSize.width,
            effectiveContainer.height / imageSize.height
        )
        let pointsPerPixel = baseFillScale * effectiveScale

        var cropW = effectiveContainer.width / pointsPerPixel
        var cropH = cropW / targetAspect

        if cropW > imageSize.width {
            cropW = imageSize.width
            cropH = cropW / targetAspect
        }
        if cropH > imageSize.height {
            cropH = imageSize.height
            cropW = cropH * targetAspect
        }

        let clamped = clampedOffset(
            offset,
            imageSize: imageSize,
            containerSize: effectiveContainer,
            scale: effectiveScale
        )
        let centerX = imageSize.width / 2.0 - (clamped.width / pointsPerPixel)
        let centerY = imageSize.height / 2.0 - (clamped.height / pointsPerPixel)

        let originX = max(0, min(imageSize.width - cropW, centerX - cropW / 2.0))
        let originY = max(0, min(imageSize.height - cropH, centerY - cropH / 2.0))

        return CGRect(x: originX, y: originY, width: cropW, height: cropH)
    }

    /// Normalizes a UIImage into `.up` orientation with `scale == 1` so pixel dimensions and
    /// `cgImage` coordinates always match UIKit `size`.
    static func normalizedImage(_ image: UIImage) -> UIImage {
        if image.imageOrientation == .up, image.scale == 1, image.cgImage != nil {
            return image
        }
        let pixelSize = CGSize(
            width: max(1, round(image.size.width * image.scale)),
            height: max(1, round(image.size.height * image.scale))
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: pixelSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: pixelSize))
        }
    }

    /// Renders the exact cropped image off-thread safe via `UIGraphicsImageRenderer`.
    static func renderCroppedImage(
        _ image: UIImage,
        containerSize: CGSize,
        targetAspect: CGFloat,
        scale: CGFloat,
        offset: CGSize
    ) -> UIImage {
        let upright = normalizedImage(image)
        let uprightSize = CGSize(
            width: max(1, upright.size.width * upright.scale),
            height: max(1, upright.size.height * upright.scale)
        )
        let rect = cropRect(
            imageSize: uprightSize,
            containerSize: containerSize,
            targetAspect: targetAspect,
            scale: scale,
            offset: offset
        )
        guard rect.width > 0, rect.height > 0 else { return upright }

        let outputSize = CGSize(
            width: max(1, round(rect.width)),
            height: max(1, round(rect.height))
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: outputSize, format: format).image { _ in
            upright.draw(at: CGPoint(x: -rect.origin.x, y: -rect.origin.y))
        }
    }

    /// Downsamples large image payloads (e.g. PhotosPicker 48MP photos) via ImageIO while applying
    /// EXIF orientation, keeping memory bounded.
    static func downsampledImage(from data: Data, maxPixelDimension: CGFloat = 2400) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return UIImage(data: data).map(normalizedImage)
        }

        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let pixelW = (props?[kCGImagePropertyPixelWidth] as? CGFloat) ?? 0
        let pixelH = (props?[kCGImagePropertyPixelHeight] as? CGFloat) ?? 0

        if max(pixelW, pixelH) > maxPixelDimension {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension,
                kCGImageSourceShouldCacheImmediately: true
            ]
            if let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return UIImage(cgImage: cgThumb, scale: 1, orientation: .up)
            }
        }

        return UIImage(data: data).map(normalizedImage)
    }
}
