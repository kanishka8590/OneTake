import XCTest
@testable import OneTake

@MainActor
final class MediaStorageAndModelsTests: XCTestCase {

    private func makeTempDocumentsDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OneTakeMediaStorageTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testStoredRelativePathHandlesRelativeCurrentAndLegacyPaths() throws {
        let docsDir = try makeTempDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: docsDir) }

        XCTAssertEqual(MediaStorage.storedRelativePath(for: "", documentsDirectory: docsDir), "")
        XCTAssertEqual(MediaStorage.storedRelativePath(for: "   \n ", documentsDirectory: docsDir), "")

        XCTAssertEqual(
            MediaStorage.storedRelativePath(for: "Takes_123/clip.mp4", documentsDirectory: docsDir),
            "Takes_123/clip.mp4"
        )
        XCTAssertEqual(
            MediaStorage.storedRelativePath(for: "./Takes_123/clip.mp4", documentsDirectory: docsDir),
            "Takes_123/clip.mp4"
        )

        let currentAbs = docsDir.appendingPathComponent("Headshots/front.jpg").path
        XCTAssertEqual(
            MediaStorage.storedRelativePath(for: currentAbs, documentsDirectory: docsDir),
            "Headshots/front.jpg"
        )

        let legacyAbs = "/var/mobile/Containers/Data/Application/OLD-UUID/Documents/Takes_123/clip.mp4"
        XCTAssertEqual(
            MediaStorage.storedRelativePath(for: legacyAbs, documentsDirectory: docsDir),
            "Takes_123/clip.mp4"
        )

        let outsidePath = "/tmp/outside_file.mov"
        XCTAssertEqual(
            MediaStorage.storedRelativePath(for: outsidePath, documentsDirectory: docsDir),
            outsidePath
        )
    }

    func testResolveURLHandlesRelativeLegacyAndEmptyPaths() throws {
        let docsDir = try makeTempDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: docsDir) }

        XCTAssertNil(MediaStorage.resolveURL(for: nil, documentsDirectory: docsDir))
        XCTAssertNil(MediaStorage.resolveURL(for: "", documentsDirectory: docsDir))
        XCTAssertNil(MediaStorage.resolveURL(for: "   ", documentsDirectory: docsDir))
        XCTAssertEqual(MediaStorage.resolvePath(for: nil, documentsDirectory: docsDir), "")

        let expectedRel = docsDir.appendingPathComponent("Takes_123/clip.mp4")
        XCTAssertEqual(
            MediaStorage.resolveURL(for: "Takes_123/clip.mp4", documentsDirectory: docsDir)?.standardizedFileURL,
            expectedRel.standardizedFileURL
        )

        let legacyAbs = "/var/mobile/Containers/Data/Application/OLD-UUID/Documents/Takes_123/clip.mp4"
        XCTAssertEqual(
            MediaStorage.resolveURL(for: legacyAbs, documentsDirectory: docsDir)?.standardizedFileURL,
            expectedRel.standardizedFileURL
        )
    }

    func testFileOperationsSaveSizeCopyMoveRemoveAndCleanup() throws {
        let docsDir = try makeTempDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: docsDir) }

        let payload = Data(repeating: 0xAB, count: 512 * 1024) // 0.5 MB
        let savedRel = try MediaStorage.saveData(payload, relativePath: "Takes_1/slate.mp4", documentsDirectory: docsDir)
        XCTAssertEqual(savedRel, "Takes_1/slate.mp4")
        XCTAssertTrue(MediaStorage.fileExists(at: savedRel, documentsDirectory: docsDir))
        XCTAssertEqual(MediaStorage.fileSizeMB(at: savedRel, documentsDirectory: docsDir), 0.5, accuracy: 0.01)

        // Copy and move
        let savedURL = try XCTUnwrap(MediaStorage.resolveURL(for: savedRel, documentsDirectory: docsDir))
        let copiedRel = try MediaStorage.copyItem(from: savedURL, toRelativePath: "Takes_1/slate_copy.mp4", documentsDirectory: docsDir)
        XCTAssertTrue(MediaStorage.fileExists(at: copiedRel, documentsDirectory: docsDir))

        let movedRel = try MediaStorage.moveItem(
            from: try XCTUnwrap(MediaStorage.resolveURL(for: copiedRel, documentsDirectory: docsDir)),
            toRelativePath: "Takes_1/slate_moved.mp4",
            documentsDirectory: docsDir
        )
        XCTAssertFalse(MediaStorage.fileExists(at: copiedRel, documentsDirectory: docsDir))
        XCTAssertTrue(MediaStorage.fileExists(at: movedRel, documentsDirectory: docsDir))

        MediaStorage.removeFile(at: movedRel, documentsDirectory: docsDir)
        XCTAssertFalse(MediaStorage.fileExists(at: movedRel, documentsDirectory: docsDir))
        XCTAssertEqual(MediaStorage.fileSizeMB(at: movedRel, documentsDirectory: docsDir), 0)

        // Cleanup for Audition
        let hsOrig = try MediaStorage.saveData(Data([1]), relativePath: "Headshots/front_orig.jpg", documentsDirectory: docsDir)
        let hsCrop = try MediaStorage.saveData(Data([2]), relativePath: "Headshots/front_crop.jpg", documentsDirectory: docsDir)
        let takePath = try MediaStorage.saveData(Data([3]), relativePath: "Takes_1/audition.mp4", documentsDirectory: docsDir)
        let auditionCuePath = try MediaStorage.saveData(Data([4]), relativePath: "Cues/audition_cue.m4a", documentsDirectory: docsDir)

        let audition = Audition(
            headshots: [HeadshotAsset(angle: .front, originalFilePath: hsOrig, croppedFilePath: hsCrop)],
            slateTakes: [VideoTake(title: "Slate", filePath: savedRel, durationSeconds: 5, fileSizeMB: 0.5)],
            auditionTakes: [VideoTake(title: "Take 1", filePath: takePath, durationSeconds: 10, fileSizeMB: 1)],
            cueLines: [
                CueLine(orderIndex: 0, speaker: "READER", cueText: "Hi", audioFilePath: auditionCuePath),
                CueLine(orderIndex: 1, speaker: "READER", cueText: "Missing", audioFilePath: "Cues/does_not_exist.m4a")
            ]
        )

        MediaStorage.cleanupFiles(for: audition, documentsDirectory: docsDir)
        XCTAssertFalse(MediaStorage.fileExists(at: hsOrig, documentsDirectory: docsDir))
        XCTAssertFalse(MediaStorage.fileExists(at: hsCrop, documentsDirectory: docsDir))
        XCTAssertFalse(MediaStorage.fileExists(at: savedRel, documentsDirectory: docsDir))
        XCTAssertFalse(MediaStorage.fileExists(at: takePath, documentsDirectory: docsDir))
        XCTAssertFalse(MediaStorage.fileExists(at: auditionCuePath, documentsDirectory: docsDir))

        // Cleanup for PracticeScript
        let scriptCuePath = try MediaStorage.saveData(Data([5]), relativePath: "Cues/script_cue.m4a", documentsDirectory: docsDir)
        let sessionAudioPath = try MediaStorage.saveData(Data([6]), relativePath: "Practice/session_1.m4a", documentsDirectory: docsDir)
        let script = PracticeScript(
            title: "Scene",
            cueLines: [CueLine(orderIndex: 0, speaker: "CUE", cueText: "Line", audioFilePath: scriptCuePath)],
            sessions: [PracticeSession(sessionNumber: 1, audioFilePath: sessionAudioPath)]
        )

        MediaStorage.cleanupFiles(for: script, documentsDirectory: docsDir)
        XCTAssertFalse(MediaStorage.fileExists(at: scriptCuePath, documentsDirectory: docsDir))
        XCTAssertFalse(MediaStorage.fileExists(at: sessionAudioPath, documentsDirectory: docsDir))
    }

    func testMigratePathsIfNeededConvertsLegacyPathsOnce() throws {
        let docsDir = try makeTempDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: docsDir) }

        let audition = Audition(
            headshots: [
                HeadshotAsset(
                    angle: .front,
                    originalFilePath: "/var/mobile/Containers/Data/Application/OLD-UUID/Documents/Headshots/orig.jpg",
                    croppedFilePath: docsDir.appendingPathComponent("Headshots/crop.jpg").path
                )
            ],
            slateTakes: [
                VideoTake(
                    title: "Slate",
                    filePath: "/var/mobile/Containers/Data/Application/OLD-UUID/Documents/Slates/slate.mp4",
                    durationSeconds: 10,
                    fileSizeMB: 2
                )
            ],
            auditionTakes: [
                VideoTake(
                    title: "Take",
                    filePath: "/var/mobile/Containers/Data/Application/OLD-UUID/Documents/Takes/take.mp4",
                    durationSeconds: 20,
                    fileSizeMB: 4
                )
            ],
            cueLines: [
                CueLine(
                    orderIndex: 0,
                    speaker: "READER",
                    cueText: "Ready?",
                    audioFilePath: "/var/mobile/Containers/Data/Application/OLD-UUID/Documents/Cues/c1.m4a"
                )
            ]
        )

        let script = PracticeScript(
            title: "Script",
            cueLines: [
                CueLine(
                    orderIndex: 0,
                    speaker: "CUE",
                    cueText: "Go",
                    audioFilePath: "/var/mobile/Containers/Data/Application/OLD-UUID/Documents/Cues/sc1.m4a"
                )
            ],
            sessions: [
                PracticeSession(
                    sessionNumber: 1,
                    audioFilePath: "/var/mobile/Containers/Data/Application/OLD-UUID/Documents/Practice/s1.m4a"
                )
            ]
        )

        let firstPassChanged = MediaStorage.migratePathsIfNeeded(
            auditions: [audition],
            scripts: [script],
            documentsDirectory: docsDir
        )
        XCTAssertTrue(firstPassChanged)
        XCTAssertEqual(audition.headshots[0].originalFilePath, "Headshots/orig.jpg")
        XCTAssertEqual(audition.headshots[0].croppedFilePath, "Headshots/crop.jpg")
        XCTAssertEqual(audition.slateTakes[0].filePath, "Slates/slate.mp4")
        XCTAssertEqual(audition.auditionTakes[0].filePath, "Takes/take.mp4")
        XCTAssertEqual(audition.cueLines[0].audioFilePath, "Cues/c1.m4a")
        XCTAssertEqual(script.cueLines[0].audioFilePath, "Cues/sc1.m4a")
        XCTAssertEqual(script.sessions[0].audioFilePath, "Practice/s1.m4a")

        let secondPassChanged = MediaStorage.migratePathsIfNeeded(
            auditions: [audition],
            scripts: [script],
            documentsDirectory: docsDir
        )
        XCTAssertFalse(secondPassChanged)
    }

    func testResilientCodableDecodingWithMissingKeys() throws {
        let decoder = JSONDecoder()

        let headshot = try decoder.decode(HeadshotAsset.self, from: Data("{}".utf8))
        XCTAssertEqual(headshot.angle, .front)
        XCTAssertEqual(headshot.originalFilePath, "")
        XCTAssertEqual(headshot.croppedFilePath, "")
        XCTAssertEqual(headshot.aspectRatio, .ratio4x5)
        XCTAssertNil(headshot.cropPreset)
        XCTAssertFalse(headshot.lightingPassed)

        let take = try decoder.decode(VideoTake.self, from: Data(#"{"title":"Take 1"}"#.utf8))
        XCTAssertEqual(take.title, "Take 1")
        XCTAssertEqual(take.filePath, "")
        XCTAssertEqual(take.durationSeconds, 0)
        XCTAssertEqual(take.fileSizeMB, 0)
        XCTAssertEqual(take.aspectRatioString, "16:9")

        let cue = try decoder.decode(CueLine.self, from: Data(#"{"cueText":"Hello"}"#.utf8))
        XCTAssertEqual(cue.orderIndex, 0)
        XCTAssertEqual(cue.speaker, "")
        XCTAssertEqual(cue.cueText, "Hello")
        XCTAssertNil(cue.audioFilePath)
        XCTAssertFalse(cue.isAutoDetected)

        let rules = try decoder.decode(ValidationRules.self, from: Data("{}".utf8))
        XCTAssertFalse(rules.isFromNotice)
        XCTAssertEqual(rules.requiredHeadshotRatio, .ratio4x5)
        XCTAssertEqual(rules.maxSlateSeconds, 45.0)
        XCTAssertEqual(rules.maxClipSeconds, 180.0)
        XCTAssertEqual(rules.fileNamePattern, "ActorName_Role")
        XCTAssertEqual(rules.maxPerClipSizeMB, 100.0)

        let session = try decoder.decode(PracticeSession.self, from: Data(#"{"sessionNumber":3}"#.utf8))
        XCTAssertEqual(session.sessionNumber, 3)
        XCTAssertEqual(session.helpLevel, .nothing)
        XCTAssertEqual(session.annotations, [])
        XCTAssertEqual(session.recognizedWords, [])
        XCTAssertEqual(session.clueTokenIDs, [])
        XCTAssertNil(session.audioFilePath)
    }

    func testAuditionSelectedTakeAndReadinessVerifyFilesOnDisk() throws {
        let folder = "TestReadiness_\(UUID().uuidString)"
        let folderURL = MediaStorage.documentsDirectory.appendingPathComponent(folder, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folderURL) }

        let existingTake = VideoTake(
            title: "Slate 1",
            filePath: "\(folder)/slate1.mp4",
            durationSeconds: 12,
            fileSizeMB: 1
        )
        let deletedTakeID = UUID()

        // Selected ID points to deleted take -> must return nil rather than falling back
        let auditionWithDeletedSelection = Audition(
            slateTakes: [existingTake],
            selectedSlateTakeID: deletedTakeID,
            auditionTakes: [existingTake],
            selectedAuditionTakeID: deletedTakeID
        )
        XCTAssertNil(auditionWithDeletedSelection.selectedSlateTake)
        XCTAssertNil(auditionWithDeletedSelection.selectedAuditionTake)
        XCTAssertFalse(auditionWithDeletedSelection.isSlateReady)
        XCTAssertFalse(auditionWithDeletedSelection.isAuditionReady)

        // When selectedID is nil, falls back to last take, but readiness still requires file on disk
        let auditionMissingFiles = Audition(
            headshots: [
                HeadshotAsset(angle: .front, originalFilePath: "\(folder)/front.jpg", croppedFilePath: ""),
                HeadshotAsset(angle: .left, originalFilePath: "\(folder)/left.jpg", croppedFilePath: ""),
                HeadshotAsset(angle: .right, originalFilePath: "\(folder)/right.jpg", croppedFilePath: "")
            ],
            slateTakes: [existingTake],
            auditionTakes: [
                VideoTake(title: "Audition 1", filePath: "\(folder)/audition1.mp4", durationSeconds: 30, fileSizeMB: 3)
            ]
        )
        XCTAssertNotNil(auditionMissingFiles.selectedSlateTake)
        XCTAssertNotNil(auditionMissingFiles.selectedAuditionTake)
        XCTAssertFalse(auditionMissingFiles.isHeadshotsReady)
        XCTAssertFalse(auditionMissingFiles.isSlateReady)
        XCTAssertFalse(auditionMissingFiles.isAuditionReady)

        // Create actual files on disk
        _ = try MediaStorage.saveData(Data([1]), relativePath: "\(folder)/front.jpg")
        _ = try MediaStorage.saveData(Data([2]), relativePath: "\(folder)/left.jpg")
        _ = try MediaStorage.saveData(Data([3]), relativePath: "\(folder)/right.jpg")
        _ = try MediaStorage.saveData(Data([4]), relativePath: "\(folder)/slate1.mp4")
        _ = try MediaStorage.saveData(Data([5]), relativePath: "\(folder)/audition1.mp4")

        XCTAssertTrue(auditionMissingFiles.isHeadshotsReady)
        XCTAssertTrue(auditionMissingFiles.isSlateReady)
        XCTAssertTrue(auditionMissingFiles.isAuditionReady)
    }

    func testAuditionCustomHeroImageCleanupAndMigration() throws {
        let folder = "TestHero_\(UUID().uuidString)"
        let folderURL = MediaStorage.documentsDirectory.appendingPathComponent(folder, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folderURL) }

        let heroRelPath = try MediaStorage.saveData(Data([0xFF, 0xD8, 0xFF]), relativePath: "\(folder)/hero.jpg")
        let absHeroPath = MediaStorage.documentsDirectory.appendingPathComponent(heroRelPath).path
        let audition = Audition(
            projectName: "Hero Project",
            heroArtworkName: Theme.Artwork.dramaBanner,
            heroImagePath: absHeroPath
        )

        XCTAssertTrue(MediaStorage.migratePathsIfNeeded(auditions: [audition], scripts: []))
        XCTAssertEqual(audition.heroImagePath, heroRelPath)
        XCTAssertEqual(audition.heroArtworkName, Theme.Artwork.dramaBanner)
        XCTAssertTrue(MediaStorage.fileExists(at: audition.heroImagePath))

        MediaStorage.cleanupFiles(for: audition)
        XCTAssertFalse(MediaStorage.fileExists(at: heroRelPath))
    }

    func testAuditionDeadlineUrgencyLabelUsesCalendarDaysConsistently() throws {
        let cal = Calendar.current
        let now = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 9, minute: 0)))

        // Same day 5h ahead -> hours
        let sameDay = try XCTUnwrap(cal.date(byAdding: .hour, value: 5, to: now))
        XCTAssertEqual(Audition(deadline: sameDay).deadlineUrgencyLabel(referenceDate: now), "Due in 5h")

        // Next calendar day even if <24h away (e.g. tomorrow 6 AM vs today 9 AM = 21h) -> Due Tomorrow
        let tomorrowEarly = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 6, minute: 0)))
        XCTAssertEqual(Audition(deadline: tomorrowEarly).deadlineUrgencyLabel(referenceDate: now), "Due Tomorrow")

        // 3 calendar days ahead even if <72h away (e.g. Nov 23 6 AM vs Nov 20 9 AM) -> 3 Days Left
        let threeDaysEarly = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 6, minute: 0)))
        let audition = Audition(deadline: threeDaysEarly)
        XCTAssertEqual(audition.daysUntilDeadline(from: now), 3)
        XCTAssertEqual(audition.deadlineUrgencyLabel(referenceDate: now), "3 Days Left")

        // Past deadline -> Overdue; no deadline -> No Deadline; sent -> Submitted
        let past = try XCTUnwrap(cal.date(byAdding: .hour, value: -1, to: now))
        XCTAssertEqual(Audition(deadline: past).deadlineUrgencyLabel(referenceDate: now), "Overdue")
        XCTAssertEqual(Audition(hasDeadline: false).deadlineUrgencyLabel(referenceDate: now), "No Deadline")
        XCTAssertEqual(Audition(deadline: past, statusRaw: AuditionStatus.sent.rawValue).deadlineUrgencyLabel(referenceDate: now), "Submitted")
    }
}
