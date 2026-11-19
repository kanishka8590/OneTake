import XCTest
import UIKit
@testable import OneTake

@MainActor
final class PackageValidationAndExportTests: XCTestCase {

    private func makeTempDirectory(prefix: String = "OneTakePackageExportTests") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Filename Sanitization & Deduplication

    func testSanitizeFileStemStripsIllegalCharactersAndFallsBack() {
        XCTAssertEqual(
            PackageExportHelper.sanitizeFileStem("", fallback: "Fallback"),
            "Fallback"
        )
        XCTAssertEqual(
            PackageExportHelper.sanitizeFileStem("   \n\t ", fallback: "Fallback"),
            "Fallback"
        )
        XCTAssertEqual(
            PackageExportHelper.sanitizeFileStem("///\\\\:::\0", fallback: "Fallback"),
            "Fallback"
        )
        XCTAssertEqual(
            PackageExportHelper.sanitizeFileStem("..", fallback: "Fallback"),
            "Fallback"
        )
        XCTAssertEqual(
            PackageExportHelper.sanitizeFileStem("  Avery/Vance:Heer\\Slate\0  ", fallback: "Slate"),
            "AveryVanceHeerSlate"
        )
    }

    func testDeduplicatedFileNamesHandlesThreeWayCollisionsAndSanitization() {
        let items: [(id: String, title: String, ext: String)] = [
            (id: "item-1", title: "Take", ext: "mp4"),
            (id: "item-2", title: "Take", ext: "mp4"),
            (id: "item-3", title: "Take", ext: "mp4"),
            (id: "item-4", title: "Take_2", ext: "mp4")
        ]
        let customNames: [String: String] = [
            "item-1": "Actor/Slate:1",
            "item-2": "Actor\\Slate:1",
            "item-3": "Actor/Slate1.mp4"
        ]

        let resolved = PackageExportHelper.deduplicatedFileNames(for: items, customNames: customNames)

        XCTAssertEqual(resolved["item-1"], "ActorSlate1.mp4")
        XCTAssertEqual(resolved["item-2"], "ActorSlate1_2.mp4")
        XCTAssertEqual(resolved["item-3"], "ActorSlate1_3.mp4")
        XCTAssertEqual(resolved["item-4"], "Take_2.mp4")

        let uniqueLowercased = Set(resolved.values.map { $0.lowercased() })
        XCTAssertEqual(uniqueLowercased.count, items.count)
    }

    func testMatchesFileNamePatternValidatesStemsAndIllegalChars() {
        XCTAssertTrue(PackageExportHelper.matchesFileNamePattern("Avery Vance_Heer_Slate", pattern: "ActorName_Role"))
        XCTAssertFalse(PackageExportHelper.matchesFileNamePattern("", pattern: "ActorName_Role"))
        XCTAssertFalse(PackageExportHelper.matchesFileNamePattern("Avery_", pattern: "ActorName_Role"))
        XCTAssertFalse(PackageExportHelper.matchesFileNamePattern("_Heer", pattern: "ActorName_Role"))
        XCTAssertFalse(PackageExportHelper.matchesFileNamePattern("Avery_Heer/Bad", pattern: "ActorName_Role"))
        XCTAssertFalse(PackageExportHelper.matchesFileNamePattern("Avery:Heer", pattern: "ActorName_Role"))
        XCTAssertFalse(PackageExportHelper.matchesFileNamePattern("Avery", pattern: "ActorName_Role"))
        XCTAssertTrue(PackageExportHelper.matchesFileNamePattern("AuditionSlate", pattern: "SingleTitle"))
    }

    // MARK: - Video Metadata Inspection & Orientation Validation

    func testInspectVideoMetadataReadsGeneratedH264Clip() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let clipURL = dir.appendingPathComponent("sample_clip.mp4")
        let generated = await DemoMediaGenerator.writeQuickSimulatedClip(
            to: clipURL,
            title: "Test Slate",
            subtitle: "Heer",
            durationSeconds: 1.5
        )
        XCTAssertTrue(generated)

        let metadata = await PackageExportHelper.inspectVideoMetadata(at: clipURL)
        let unwrapped = try XCTUnwrap(metadata)
        XCTAssertFalse(unwrapped.isPortrait)
        XCTAssertEqual(unwrapped.aspectRatioString, "16:9")
        XCTAssertGreaterThan(unwrapped.durationSeconds, 1.0)
        XCTAssertLessThan(unwrapped.durationSeconds, 3.0)
        XCTAssertGreaterThan(unwrapped.fileSizeMB, 0.0)

        let missingMetadata = await PackageExportHelper.inspectVideoMetadata(
            at: dir.appendingPathComponent("does_not_exist.mp4")
        )
        XCTAssertNil(missingMetadata)
    }

    func testValidateOrientationRules() {
        let landscape = (isPortrait: false, aspectRatioString: "16:9")
        let portrait = (isPortrait: true, aspectRatioString: "9:16")

        XCTAssertTrue(PackageExportHelper.validateOrientation(slate: landscape, clip: landscape, requiredPortrait: nil))
        XCTAssertTrue(PackageExportHelper.validateOrientation(slate: portrait, clip: portrait, requiredPortrait: nil))
        XCTAssertFalse(PackageExportHelper.validateOrientation(slate: portrait, clip: landscape, requiredPortrait: nil))

        XCTAssertTrue(PackageExportHelper.validateOrientation(slate: portrait, clip: portrait, requiredPortrait: true))
        XCTAssertFalse(PackageExportHelper.validateOrientation(slate: landscape, clip: landscape, requiredPortrait: true))

        XCTAssertTrue(PackageExportHelper.validateOrientation(slate: landscape, clip: landscape, requiredPortrait: false))
        XCTAssertFalse(PackageExportHelper.validateOrientation(slate: portrait, clip: landscape, requiredPortrait: false))

        XCTAssertFalse(PackageExportHelper.validateOrientation(slate: nil, clip: landscape, requiredPortrait: nil))
    }

    // MARK: - Package Materialization & ZIP Archive

    func testMaterializePackageDirectoryAndZipArchiveVerifyContents() throws {
        let docsDir = try makeTempDirectory(prefix: "OneTakeDocs")
        defer { try? FileManager.default.removeItem(at: docsDir) }

        let frontData = Data(repeating: 0x11, count: 4096)
        let slateData = Data(repeating: 0x22, count: 8192)
        let frontRel = try MediaStorage.saveData(frontData, relativePath: "Headshots/front.jpg", documentsDirectory: docsDir)
        let slateRel = try MediaStorage.saveData(slateData, relativePath: "Takes/slate.mp4", documentsDirectory: docsDir)

        let items: [(id: String, title: String, storedPath: String, ext: String)] = [
            (id: "hs-front", title: "Actor_Role_Front", storedPath: frontRel, ext: "jpg"),
            (id: "hs-left", title: "Actor_Role_Left", storedPath: "Headshots/missing_left.jpg", ext: "jpg"),
            (id: "slate", title: "Actor_Role_Slate", storedPath: slateRel, ext: "mp4")
        ]
        // Intentional collision in custom names to test deduplication during materialization
        let customNames = [
            "hs-front": "Duplicate/Name",
            "slate": "Duplicate:Name"
        ]

        let materialized = try PackageExportHelper.materializePackageDirectoryWithReport(
            items: items,
            customNames: customNames,
            documentsDirectory: docsDir
        )
        defer { try? FileManager.default.removeItem(at: materialized.directory) }

        XCTAssertEqual(materialized.files.count, 2)
        XCTAssertEqual(materialized.missingItemIDs, ["hs-left"])
        XCTAssertEqual(materialized.files.map(\.lastPathComponent), ["DuplicateName.jpg", "DuplicateName.mp4"])

        // Also verify same-extension collision deduplication + ZIP archive round-trip
        let clipRel = try MediaStorage.saveData(Data(repeating: 0x33, count: 2048), relativePath: "Takes/clip.mp4", documentsDirectory: docsDir)
        let zipItems: [(id: String, title: String, storedPath: String, ext: String)] = [
            (id: "slate", title: "Take", storedPath: slateRel, ext: "mp4"),
            (id: "clip", title: "Take", storedPath: clipRel, ext: "mp4"),
            (id: "missing", title: "Missing", storedPath: "Takes/nope.mp4", ext: "mp4")
        ]

        let archived = try PackageExportHelper.createPackageZipArchive(
            items: zipItems,
            customNames: ["slate": "SameName", "clip": "SameName"],
            archiveName: "Actor/Heer:Package",
            documentsDirectory: docsDir
        )
        defer { try? FileManager.default.removeItem(at: archived.directory) }

        XCTAssertEqual(archived.archiveURL.lastPathComponent, "ActorHeerPackage.zip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archived.archiveURL.path))
        XCTAssertEqual(archived.missingItemIDs, ["missing"])
        XCTAssertEqual(archived.includedFiles.map(\.lastPathComponent), ["SameName.mp4", "SameName_2.mp4"])

        let extractDir = try makeTempDirectory(prefix: "OneTakeZipExtract")
        defer { try? FileManager.default.removeItem(at: extractDir) }
        try ZipArchive.extract(from: archived.archiveURL, to: extractDir)

        let extractedSlate = try Data(contentsOf: extractDir.appendingPathComponent("SameName.mp4"))
        let extractedClip = try Data(contentsOf: extractDir.appendingPathComponent("SameName_2.mp4"))
        XCTAssertEqual(extractedSlate, slateData)
        XCTAssertEqual(extractedClip, Data(repeating: 0x33, count: 2048))
    }

    // MARK: - Actual Sizes & Disk Existence

    func testActualHeadshotsAndPackageSizesReadRealFilesOnDisk() throws {
        let docsDir = try makeTempDirectory(prefix: "OneTakeSizeDocs")
        defer { try? FileManager.default.removeItem(at: docsDir) }

        let oneMB = Data(repeating: 0xAA, count: 1_048_576)
        let halfMB = Data(repeating: 0xBB, count: 524_288)
        let quarterMB = Data(repeating: 0xCC, count: 262_144)

        let frontRel = try MediaStorage.saveData(oneMB, relativePath: "Headshots/front.jpg", documentsDirectory: docsDir)
        let leftRel = try MediaStorage.saveData(halfMB, relativePath: "Headshots/left.jpg", documentsDirectory: docsDir)
        let slateRel = try MediaStorage.saveData(quarterMB, relativePath: "Takes/slate.mp4", documentsDirectory: docsDir)

        let audition = Audition(
            headshots: [
                HeadshotAsset(angle: .front, originalFilePath: frontRel, croppedFilePath: frontRel),
                HeadshotAsset(angle: .left, originalFilePath: leftRel, croppedFilePath: "Headshots/missing_crop.jpg"),
                HeadshotAsset(angle: .right, originalFilePath: "Headshots/missing_right.jpg", croppedFilePath: "Headshots/missing_right.jpg")
            ],
            slateTakes: [
                VideoTake(title: "Slate", filePath: slateRel, durationSeconds: 10, fileSizeMB: 99.0)
            ],
            auditionTakes: [
                VideoTake(title: "Clip", filePath: "Takes/missing_clip.mp4", durationSeconds: 20, fileSizeMB: 50.0)
            ]
        )

        // Should compute 1.0 + 0.5 + 0.0 = 1.5 MB (not hardcoded 3 * 1.2 = 3.6 MB)
        let headshotsSize = PackageExportHelper.actualHeadshotsSizeMB(for: audition, documentsDirectory: docsDir)
        XCTAssertEqual(headshotsSize, 1.5, accuracy: 0.01)

        // Package size adds slate (0.25 MB) and ignores missing clip (0 MB) -> 1.75 MB
        let packageSize = PackageExportHelper.actualPackageSizeMB(for: audition, documentsDirectory: docsDir)
        XCTAssertEqual(packageSize, 1.75, accuracy: 0.01)

        XCTAssertFalse(audition.isHeadshotsReady) // right headshot missing on disk
        XCTAssertFalse(MediaStorage.fileExists(at: audition.selectedAuditionTake?.filePath, documentsDirectory: docsDir))
    }

    // MARK: - Demo Mode vs Production Mode Policy & Mail Attachment Limit

    func testDemoModePolicyAndMailSizeLimit() throws {
        XCTAssertFalse(PackageExportHelper.canCreateSimulatedPrivateLink(isDemoMode: false))
        XCTAssertTrue(PackageExportHelper.canCreateSimulatedPrivateLink(isDemoMode: true))

        XCTAssertFalse(PackageExportHelper.canSimulateCompression(isDemoMode: false))
        XCTAssertTrue(PackageExportHelper.canSimulateCompression(isDemoMode: true))
        XCTAssertEqual(PackageExportHelper.formattedSizeString(-1.2), "0.0 MB")
        XCTAssertEqual(PackageExportHelper.formattedSizeString(4.36), "4.4 MB")
        XCTAssertEqual(PackageExportHelper.formattedSizeString(124.7), "125 MB")

        let dir = try makeTempDirectory(prefix: "OneTakeMailLimit")
        defer { try? FileManager.default.removeItem(at: dir) }

        let smallFile = dir.appendingPathComponent("small.jpg")
        try Data(repeating: 0x01, count: 1_048_576).write(to: smallFile)
        XCTAssertTrue(PackageExportHelper.isTotalAttachmentSizeAllowedForMail([smallFile], maxTotalMB: 25.0))

        let largeFile = dir.appendingPathComponent("large.mp4")
        try Data(repeating: 0x02, count: 26 * 1_048_576).write(to: largeFile)
        XCTAssertFalse(PackageExportHelper.isTotalAttachmentSizeAllowedForMail([smallFile, largeFile], maxTotalMB: 25.0))
    }

    // MARK: - Large (~91 MB) Export, Hardware-Accelerated ZIP & Share Sheet Presentation

    func testLarge91MBMaterializeZipAndShareSheetPresentation() throws {
        let docsDir = try makeTempDirectory(prefix: "OneTake91MBDocs")
        defer { try? FileManager.default.removeItem(at: docsDir) }

        // Write a 91.5 MB mock audition take + 512 KB headshot
        let videoRelPath = "Takes/large_audition_take.mp4"
        let videoURL = docsDir.appendingPathComponent(videoRelPath)
        try FileManager.default.createDirectory(at: videoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: videoURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: videoURL)
        let oneMBChunk = Data(repeating: 0x5A, count: 1_048_576)
        for _ in 0..<91 {
            try handle.write(contentsOf: oneMBChunk)
        }
        try handle.write(contentsOf: Data(repeating: 0x7B, count: 524_288))
        try handle.close()

        let headshotRelPath = try MediaStorage.saveData(
            Data(repeating: 0xFF, count: 524_288),
            relativePath: "Headshots/front.jpg",
            documentsDirectory: docsDir
        )

        let items: [(id: String, title: String, storedPath: String, ext: String)] = [
            (id: "headshot-Front", title: "Actor_Role_Front", storedPath: headshotRelPath, ext: "jpg"),
            (id: "audition", title: "Actor_Role_Audition", storedPath: videoRelPath, ext: "mp4")
        ]

        // 1. "More ways to share" materialization
        let materialized = try PackageExportHelper.materializePackageDirectory(
            items: items,
            customNames: [:],
            documentsDirectory: docsDir
        )
        defer { try? FileManager.default.removeItem(at: materialized.directory) }
        XCTAssertEqual(materialized.files.count, 2)
        let totalMB = PackageExportHelper.totalFileSizeMB(for: materialized.files)
        XCTAssertGreaterThan(totalMB, 91.5)
        XCTAssertFalse(PackageExportHelper.isTotalAttachmentSizeAllowedForMail(materialized.files, maxTotalMB: 25.0))

        // 2. "Share as ZIP archive" speed + custom archive name + extract validity check (hardware zlib crc32)
        let start = CFAbsoluteTimeGetCurrent()
        let zipResult = try PackageExportHelper.createPackageZipArchive(
            items: items,
            customNames: [:],
            archiveName: "Custom_Audition_ZIP",
            documentsDirectory: docsDir
        )
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        defer { try? FileManager.default.removeItem(at: zipResult.directory) }

        XCTAssertEqual(zipResult.archiveURL.lastPathComponent, "Custom_Audition_ZIP.zip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: zipResult.archiveURL.path))
        let zipMB = PackageExportHelper.fileSizeOnDiskMB(at: zipResult.archiveURL)
        XCTAssertGreaterThan(zipMB, 91.5)
        XCTAssertLessThan(elapsed, 6.0, "91 MB ZIP creation took \(elapsed)s; must not stall")

        let extractDir = try makeTempDirectory(prefix: "OneTake91MBExtract")
        defer { try? FileManager.default.removeItem(at: extractDir) }
        try ZipArchive.extract(from: zipResult.archiveURL, to: extractDir)
        let extractedFiles = try FileManager.default.contentsOfDirectory(atPath: extractDir.path)
        XCTAssertEqual(Set(extractedFiles), Set(["Actor_Role_Front.jpg", "Actor_Role_Audition.mp4"]))
        XCTAssertGreaterThan(
            PackageExportHelper.fileSizeOnDiskMB(at: extractDir.appendingPathComponent("Actor_Role_Audition.mp4")),
            91.0
        )
    }

    @MainActor
    func testSharePresenterOpensActivityViewControllerOverSheet() throws {
        guard let hostTop = PackageSharePresenter.topMostViewController() else {
            throw XCTSkip("No active host window view controller")
        }

        let dir = try makeTempDirectory(prefix: "OneTakeSharePresent")
        defer { try? FileManager.default.removeItem(at: dir) }
        let archiveURL = dir.appendingPathComponent("Test_Package.zip")
        try ZipArchive.write([(name: "clip.mp4", data: Data(repeating: 0x22, count: 4096))], to: archiveURL)

        let sheetVC = UIViewController()
        sheetVC.view.backgroundColor = .systemBackground
        hostTop.present(sheetVC, animated: false)
        defer {
            if hostTop.presentedViewController === sheetVC {
                hostTop.dismiss(animated: false)
            }
        }

        let attachDeadline = Date().addingTimeInterval(0.6)
        while Date() < attachDeadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(PackageSharePresenter.topMostViewController() === sheetVC, "Expected topMostViewController() to resolve the open sheet")

        let activityController = PackageSharePresenter.presentActivity(
            items: [archiveURL],
            subject: "Test_Package"
        ) { _ in }

        XCTAssertNotNil(activityController)

        let deadline = Date().addingTimeInterval(3.5)
        while Date() < deadline && sheetVC.presentedViewController == nil {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(
            sheetVC.presentedViewController is UIActivityViewController,
            "Expected UIActivityViewController, got: \(String(describing: sheetVC.presentedViewController))"
        )
        sheetVC.dismiss(animated: false)
    }
}
