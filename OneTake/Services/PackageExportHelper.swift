import AVFoundation
import Foundation

nonisolated enum PackageExportHelper {
    enum ExportError: LocalizedError, Sendable {
        case noAvailableFiles

        var errorDescription: String? {
            switch self {
            case .noAvailableFiles:
                return "No valid media files were found on disk to export."
            }
        }
    }

    struct MaterializedPackage: Sendable {
        let directory: URL
        let files: [URL]
        let missingItemIDs: [String]
    }

    // MARK: - Filename Sanitization & Validation

    static func sanitizeFileStem(_ raw: String, fallback: String) -> String {
        let safeFallback = fallback.isEmpty ? "file" : fallback
        let disallowed = CharacterSet(charactersIn: "/\\:")
            .union(.controlCharacters)
        let cleanedScalars = raw.unicodeScalars.filter { !disallowed.contains($0) }
        let trimmed = String(String.UnicodeScalarView(cleanedScalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != ".." else {
            return safeFallback
        }
        return trimmed
    }

    static func deduplicatedFileNames(
        for items: [(id: String, title: String, ext: String)],
        customNames: [String: String]
    ) -> [String: String] {
        var result: [String: String] = [:]
        var usedLowercasedNames: Set<String> = []

        for item in items {
            let cleanExt = sanitizeFileStem(item.ext, fallback: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let fallbackStem = sanitizeFileStem(item.title, fallback: sanitizeFileStem(item.id, fallback: "file"))
            var stem = sanitizeFileStem(customNames[item.id] ?? item.title, fallback: fallbackStem)

            if !cleanExt.isEmpty {
                let dotExt = ".\(cleanExt)"
                if stem.lowercased().hasSuffix(dotExt.lowercased()), stem.count > dotExt.count {
                    let stripped = String(stem.dropLast(dotExt.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !stripped.isEmpty {
                        stem = stripped
                    }
                }
            }

            func makeFullName(stem candidateStem: String) -> String {
                cleanExt.isEmpty ? candidateStem : "\(candidateStem).\(cleanExt)"
            }

            var candidate = makeFullName(stem: stem)
            if usedLowercasedNames.contains(candidate.lowercased()) {
                var suffix = 2
                while usedLowercasedNames.contains(makeFullName(stem: "\(stem)_\(suffix)").lowercased()) {
                    suffix += 1
                }
                candidate = makeFullName(stem: "\(stem)_\(suffix)")
            }

            usedLowercasedNames.insert(candidate.lowercased())
            result[item.id] = candidate
        }

        return result
    }

    static func matchesFileNamePattern(_ fileName: String, pattern: String) -> Bool {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != ".." else { return false }

        let disallowed = CharacterSet(charactersIn: "/\\:").union(.controlCharacters)
        guard trimmed.unicodeScalars.allSatisfy({ !disallowed.contains($0) }) else {
            return false
        }
        guard trimmed.rangeOfCharacter(from: .alphanumerics) != nil else {
            return false
        }

        let trimmedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPattern.contains("_") {
            let rawSegments = trimmed.split(separator: "_", omittingEmptySubsequences: false)
            guard rawSegments.count >= 2 else { return false }
            return rawSegments.allSatisfy { segment in
                !segment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
        return true
    }

    // MARK: - Video & Package Inspection

    static func inspectVideoMetadata(at url: URL) async -> (isPortrait: Bool, aspectRatioString: String, durationSeconds: Double, fileSizeMB: Double)? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        let asset = AVURLAsset(url: url)
        do {
            let cmDuration = try await asset.load(.duration)
            let rawSeconds = cmDuration.seconds
            let durationSeconds = (rawSeconds.isFinite && rawSeconds > 0) ? rawSeconds : 0

            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = videoTracks.first else {
                return nil
            }
            let (naturalSize, preferredTransform) = try await track.load(.naturalSize, .preferredTransform)
            let transformed = naturalSize.applying(preferredTransform)
            let width = abs(transformed.width)
            let height = abs(transformed.height)
            guard width > 0, height > 0 else {
                return nil
            }

            let isPortrait = height > width
            let aspectRatioString = formatAspectRatio(width: width, height: height)
            let fileSizeMB = fileSizeOnDiskMB(at: url)

            return (
                isPortrait: isPortrait,
                aspectRatioString: aspectRatioString,
                durationSeconds: durationSeconds,
                fileSizeMB: fileSizeMB
            )
        } catch {
            return nil
        }
    }

    private static func formatAspectRatio(width: CGFloat, height: CGFloat) -> String {
        let ratio = width / height
        let known: [(Double, String)] = [
            (16.0 / 9.0, "16:9"),
            (9.0 / 16.0, "9:16"),
            (4.0 / 3.0, "4:3"),
            (3.0 / 4.0, "3:4"),
            (4.0 / 5.0, "4:5"),
            (5.0 / 4.0, "5:4"),
            (2.0 / 3.0, "2:3"),
            (3.0 / 2.0, "3:2"),
            (1.0, "1:1")
        ]
        for (target, label) in known where abs(ratio - target) < 0.04 {
            return label
        }
        let w = max(1, Int(width.rounded()))
        let h = max(1, Int(height.rounded()))
        let divisor = gcd(w, h)
        return "\(w / divisor):\(h / divisor)"
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var x = abs(a)
        var y = abs(b)
        while y != 0 {
            let r = x % y
            x = y
            y = r
        }
        return max(1, x)
    }

    static func fileSizeOnDiskMB(at url: URL) -> Double {
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
           let bytes = values.fileSize {
            return Double(bytes) / 1_048_576.0
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? NSNumber {
            return size.doubleValue / 1_048_576.0
        }
        return 0
    }

    // MARK: - Package Materialization & Archiving

    static func materializePackageDirectory(
        items: [(id: String, title: String, storedPath: String, ext: String)],
        customNames: [String: String],
        documentsDirectory: URL = MediaStorage.documentsDirectory
    ) throws -> (directory: URL, files: [URL]) {
        let result = try materializePackageDirectoryWithReport(
            items: items,
            customNames: customNames,
            documentsDirectory: documentsDirectory
        )
        return (directory: result.directory, files: result.files)
    }

    static func materializePackageDirectoryWithReport(
        items: [(id: String, title: String, storedPath: String, ext: String)],
        customNames: [String: String],
        documentsDirectory: URL = MediaStorage.documentsDirectory
    ) throws -> MaterializedPackage {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory
            .appendingPathComponent("OneTake-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        do {
            let fileNames = deduplicatedFileNames(
                for: items.map { ($0.id, $0.title, $0.ext) },
                customNames: customNames
            )

            var copiedFiles: [URL] = []
            var missingIDs: [String] = []

            for item in items {
                guard let sourceURL = MediaStorage.resolveURL(
                    for: item.storedPath,
                    documentsDirectory: documentsDirectory
                ), fm.fileExists(atPath: sourceURL.path) else {
                    missingIDs.append(item.id)
                    continue
                }

                let fileName = fileNames[item.id] ?? "\(sanitizeFileStem(item.title, fallback: item.id)).\(item.ext)"
                let destinationURL = directory.appendingPathComponent(fileName)
                if fm.fileExists(atPath: destinationURL.path) {
                    try fm.removeItem(at: destinationURL)
                }
                try fm.copyItem(at: sourceURL, to: destinationURL)
                copiedFiles.append(destinationURL)
            }

            return MaterializedPackage(
                directory: directory,
                files: copiedFiles,
                missingItemIDs: missingIDs
            )
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
    }

    static func createPackageZipArchive(
        items: [(id: String, title: String, storedPath: String, ext: String)],
        customNames: [String: String],
        archiveName: String,
        documentsDirectory: URL = MediaStorage.documentsDirectory
    ) throws -> (directory: URL, archiveURL: URL, includedFiles: [URL], missingItemIDs: [String]) {
        let materialized = try materializePackageDirectoryWithReport(
            items: items,
            customNames: customNames,
            documentsDirectory: documentsDirectory
        )
        guard !materialized.files.isEmpty else {
            try? FileManager.default.removeItem(at: materialized.directory)
            throw ExportError.noAvailableFiles
        }

        let safeArchiveStem = sanitizeFileStem(archiveName, fallback: "OneTake_Package")
        let archiveURL = materialized.directory
            .appendingPathComponent(safeArchiveStem)
            .appendingPathExtension("zip")

        let entries = materialized.files.map {
            ZipArchive.Entry(name: $0.lastPathComponent, fileURL: $0)
        }
        do {
            try ZipArchive.write(entries, to: archiveURL)
        } catch {
            try? FileManager.default.removeItem(at: materialized.directory)
            throw error
        }

        return (
            directory: materialized.directory,
            archiveURL: archiveURL,
            includedFiles: materialized.files,
            missingItemIDs: materialized.missingItemIDs
        )
    }

    // MARK: - Size & Policy Helpers

    static func effectiveHeadshotPath(
        for headshot: HeadshotAsset,
        documentsDirectory: URL = MediaStorage.documentsDirectory
    ) -> String {
        if MediaStorage.fileExists(at: headshot.croppedFilePath, documentsDirectory: documentsDirectory) {
            return headshot.croppedFilePath
        }
        if MediaStorage.fileExists(at: headshot.originalFilePath, documentsDirectory: documentsDirectory) {
            return headshot.originalFilePath
        }
        return headshot.croppedFilePath
    }

    @MainActor
    static func actualHeadshotsSizeMB(
        for audition: Audition,
        documentsDirectory: URL = MediaStorage.documentsDirectory
    ) -> Double {
        audition.headshots.reduce(0.0) { partial, headshot in
            let path = effectiveHeadshotPath(for: headshot, documentsDirectory: documentsDirectory)
            return partial + MediaStorage.fileSizeMB(at: path, documentsDirectory: documentsDirectory)
        }
    }

    @MainActor
    static func actualPackageSizeMB(
        for audition: Audition,
        documentsDirectory: URL = MediaStorage.documentsDirectory
    ) -> Double {
        let headshots = actualHeadshotsSizeMB(for: audition, documentsDirectory: documentsDirectory)
        let slate = MediaStorage.fileSizeMB(at: audition.selectedSlateTake?.filePath, documentsDirectory: documentsDirectory)
        let clip = MediaStorage.fileSizeMB(at: audition.selectedAuditionTake?.filePath, documentsDirectory: documentsDirectory)
        return headshots + slate + clip
    }

    static func totalFileSizeMB(for urls: [URL]) -> Double {
        urls.reduce(0.0) { $0 + fileSizeOnDiskMB(at: $1) }
    }

    static func isTotalAttachmentSizeAllowedForMail(
        _ files: [URL],
        maxTotalMB: Double = 25.0
    ) -> Bool {
        totalFileSizeMB(for: files) <= maxTotalMB
    }

    static func validateOrientation(
        slate: (isPortrait: Bool, aspectRatioString: String)?,
        clip: (isPortrait: Bool, aspectRatioString: String)?,
        requiredPortrait: Bool?
    ) -> Bool {
        guard let slate, let clip else { return false }
        if let requiredPortrait {
            return slate.isPortrait == requiredPortrait && clip.isPortrait == requiredPortrait
        }
        return slate.isPortrait == clip.isPortrait
    }

    static func canCreateSimulatedPrivateLink(isDemoMode: Bool) -> Bool {
        isDemoMode
    }

    static func canSimulateCompression(isDemoMode: Bool) -> Bool {
        isDemoMode
    }
}
