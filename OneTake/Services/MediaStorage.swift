import Foundation

nonisolated enum MediaStorage {
    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    static func storedRelativePath(
        for pathOrURL: String,
        documentsDirectory: URL = MediaStorage.documentsDirectory
    ) -> String {
        let trimmed = pathOrURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if !trimmed.hasPrefix("/") {
            var relative = trimmed
            while relative.hasPrefix("./") {
                relative.removeFirst(2)
            }
            return relative
        }

        let standardizedDocs = documentsDirectory.standardizedFileURL.path
        let standardizedDocsPrefix = standardizedDocs.hasSuffix("/") ? standardizedDocs : standardizedDocs + "/"
        let standardizedInput = URL(fileURLWithPath: trimmed).standardizedFileURL.path
        if standardizedInput.hasPrefix(standardizedDocsPrefix) {
            return String(standardizedInput.dropFirst(standardizedDocsPrefix.count))
        }

        let rawDocs = documentsDirectory.path
        let rawDocsPrefix = rawDocs.hasSuffix("/") ? rawDocs : rawDocs + "/"
        if trimmed.hasPrefix(rawDocsPrefix) {
            return String(trimmed.dropFirst(rawDocsPrefix.count))
        }

        if let range = trimmed.range(of: "/Documents/") {
            return String(trimmed[range.upperBound...])
        }

        return trimmed
    }

    static func resolveURL(
        for storedPath: String?,
        documentsDirectory: URL = MediaStorage.documentsDirectory
    ) -> URL? {
        guard let raw = storedPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }

        if !raw.hasPrefix("/") {
            var relative = raw
            while relative.hasPrefix("./") {
                relative.removeFirst(2)
            }
            guard !relative.isEmpty else { return nil }
            return documentsDirectory.appendingPathComponent(relative)
        }

        if let range = raw.range(of: "/Documents/") {
            let relative = String(raw[range.upperBound...])
            return relative.isEmpty
                ? documentsDirectory
                : documentsDirectory.appendingPathComponent(relative)
        }

        return URL(fileURLWithPath: raw)
    }

    static func resolvePath(
        for storedPath: String?,
        documentsDirectory: URL = MediaStorage.documentsDirectory
    ) -> String {
        resolveURL(for: storedPath, documentsDirectory: documentsDirectory)?.path ?? ""
    }

    static func fileExists(
        at storedPath: String?,
        documentsDirectory: URL = MediaStorage.documentsDirectory
    ) -> Bool {
        guard let url = resolveURL(for: storedPath, documentsDirectory: documentsDirectory) else {
            return false
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    static func fileSizeMB(
        at storedPath: String?,
        documentsDirectory: URL = MediaStorage.documentsDirectory
    ) -> Double {
        guard let url = resolveURL(for: storedPath, documentsDirectory: documentsDirectory) else {
            return 0
        }
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

    @discardableResult
    static func saveData(
        _ data: Data,
        relativePath: String,
        documentsDirectory: URL = MediaStorage.documentsDirectory
    ) throws -> String {
        let normalized = storedRelativePath(for: relativePath, documentsDirectory: documentsDirectory)
        let destURL = documentsDirectory.appendingPathComponent(normalized)
        try FileManager.default.createDirectory(
            at: destURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destURL, options: .atomic)
        return normalized
    }

    @discardableResult
    static func copyItem(
        from sourceURL: URL,
        toRelativePath relativePath: String,
        documentsDirectory: URL = MediaStorage.documentsDirectory
    ) throws -> String {
        try transferItem(from: sourceURL, toRelativePath: relativePath, documentsDirectory: documentsDirectory, move: false)
    }

    @discardableResult
    static func moveItem(
        from sourceURL: URL,
        toRelativePath relativePath: String,
        documentsDirectory: URL = MediaStorage.documentsDirectory
    ) throws -> String {
        try transferItem(from: sourceURL, toRelativePath: relativePath, documentsDirectory: documentsDirectory, move: true)
    }

    private static func transferItem(
        from sourceURL: URL,
        toRelativePath relativePath: String,
        documentsDirectory: URL,
        move: Bool
    ) throws -> String {
        let normalized = storedRelativePath(for: relativePath, documentsDirectory: documentsDirectory)
        let destURL = documentsDirectory.appendingPathComponent(normalized)
        try FileManager.default.createDirectory(
            at: destURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if sourceURL.standardizedFileURL == destURL.standardizedFileURL {
            return normalized
        }
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        if move {
            try FileManager.default.moveItem(at: sourceURL, to: destURL)
        } else {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        }
        return normalized
    }

    static func removeFile(
        at storedPath: String?,
        documentsDirectory: URL = MediaStorage.documentsDirectory
    ) {
        guard let url = resolveURL(for: storedPath, documentsDirectory: documentsDirectory) else {
            return
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    @MainActor
    static func cleanupFiles(
        for audition: Audition,
        documentsDirectory: URL = MediaStorage.documentsDirectory
    ) {
        for headshot in audition.headshots {
            removeFile(at: headshot.originalFilePath, documentsDirectory: documentsDirectory)
            removeFile(at: headshot.croppedFilePath, documentsDirectory: documentsDirectory)
        }
        for take in audition.slateTakes {
            removeFile(at: take.filePath, documentsDirectory: documentsDirectory)
        }
        for take in audition.auditionTakes {
            removeFile(at: take.filePath, documentsDirectory: documentsDirectory)
        }
        for cue in audition.cueLines {
            removeFile(at: cue.audioFilePath, documentsDirectory: documentsDirectory)
        }
    }

    @MainActor
    static func cleanupFiles(
        for script: PracticeScript,
        documentsDirectory: URL = MediaStorage.documentsDirectory
    ) {
        for cue in script.cueLines {
            removeFile(at: cue.audioFilePath, documentsDirectory: documentsDirectory)
        }
        for session in script.sessions {
            removeFile(at: session.audioFilePath, documentsDirectory: documentsDirectory)
        }
    }

    @MainActor
    @discardableResult
    static func migratePathsIfNeeded(
        auditions: [Audition],
        scripts: [PracticeScript],
        documentsDirectory: URL = MediaStorage.documentsDirectory
    ) -> Bool {
        var didChange = false

        for audition in auditions {
            for idx in audition.headshots.indices {
                if migratePath(&audition.headshots[idx].originalFilePath, documentsDirectory: documentsDirectory) {
                    didChange = true
                }
                if migratePath(&audition.headshots[idx].croppedFilePath, documentsDirectory: documentsDirectory) {
                    didChange = true
                }
            }
            for idx in audition.slateTakes.indices {
                if migratePath(&audition.slateTakes[idx].filePath, documentsDirectory: documentsDirectory) {
                    didChange = true
                }
            }
            for idx in audition.auditionTakes.indices {
                if migratePath(&audition.auditionTakes[idx].filePath, documentsDirectory: documentsDirectory) {
                    didChange = true
                }
            }
            for idx in audition.cueLines.indices {
                if migrateOptionalPath(&audition.cueLines[idx].audioFilePath, documentsDirectory: documentsDirectory) {
                    didChange = true
                }
            }
        }

        for script in scripts {
            for idx in script.cueLines.indices {
                if migrateOptionalPath(&script.cueLines[idx].audioFilePath, documentsDirectory: documentsDirectory) {
                    didChange = true
                }
            }
            for idx in script.sessions.indices {
                if migrateOptionalPath(&script.sessions[idx].audioFilePath, documentsDirectory: documentsDirectory) {
                    didChange = true
                }
            }
        }

        return didChange
    }

    private static func migratePath(_ path: inout String, documentsDirectory: URL) -> Bool {
        let migrated = storedRelativePath(for: path, documentsDirectory: documentsDirectory)
        guard migrated != path else { return false }
        path = migrated
        return true
    }

    private static func migrateOptionalPath(_ path: inout String?, documentsDirectory: URL) -> Bool {
        guard let current = path else { return false }
        let migrated = storedRelativePath(for: current, documentsDirectory: documentsDirectory)
        guard migrated != current else { return false }
        path = migrated
        return true
    }
}
