import AVFoundation
import Observation
import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import OneTake

@MainActor
final class AppStateAndSettingsTests: XCTestCase {

    private var createdSuiteNames: [String] = []
    private var createdDirectories: [URL] = []

    override func tearDown() {
        for suiteName in createdSuiteNames {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        createdSuiteNames.removeAll()

        for dir in createdDirectories {
            try? FileManager.default.removeItem(at: dir)
        }
        createdDirectories.removeAll()

        super.tearDown()
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "com.onetake.tests.\(UUID().uuidString)"
        createdSuiteNames.append(suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema([
            UserProfile.self,
            Audition.self,
            PracticeScript.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func makeIsolatedAppState() throws -> (AppState, ModelContainer, UserDefaults) {
        let defaults = makeIsolatedDefaults()
        let settings = AppSettings(defaults: defaults)
        let state = AppState(settings: settings, defaults: defaults)
        let container = try makeInMemoryContainer()
        state.configure(with: container.mainContext)
        return (state, container, defaults)
    }

    // MARK: - AppSettings Tests

    private nonisolated final class ObservationFlag: @unchecked Sendable {
        var fired = false
    }

    func testAppSettingsObservableTrackingPersistenceAndReset() {
        let defaults = makeIsolatedDefaults()
        let settings = AppSettings(defaults: defaults)

        let countdownFlag = ObservationFlag()
        withObservationTracking {
            _ = settings.countdownSeconds
        } onChange: {
            countdownFlag.fired = true
        }

        settings.countdownSeconds = 5
        XCTAssertTrue(countdownFlag.fired, "Expected @Observable tracking to fire on countdownSeconds change")

        let mirrorFlag = ObservationFlag()
        withObservationTracking {
            _ = settings.mirrorFrontCamera
        } onChange: {
            mirrorFlag.fired = true
        }

        settings.mirrorFrontCamera = false
        XCTAssertTrue(mirrorFlag.fired, "Expected @Observable tracking to fire on mirrorFrontCamera change")

        settings.cueTriggerMode = .fixedDelay
        settings.videoQuality = .p720
        settings.notifyAuditions = false

        // Verify persistence across a fresh AppSettings instance reading the same defaults.
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.countdownSeconds, 5)
        XCTAssertFalse(reloaded.mirrorFrontCamera)
        XCTAssertEqual(reloaded.cueTriggerMode, .fixedDelay)
        XCTAssertEqual(reloaded.videoQuality, .p720)
        XCTAssertFalse(reloaded.notifyAuditions)
        XCTAssertEqual(defaults.integer(forKey: "onetake.countdownSeconds"), 5)

        // Reset restores defaults and clears "onetake.*" setting keys.
        reloaded.resetToDefaults()
        XCTAssertEqual(reloaded.countdownSeconds, 3)
        XCTAssertTrue(reloaded.mirrorFrontCamera)
        XCTAssertFalse(reloaded.framingTipsOutLoud)
        XCTAssertFalse(reloaded.countdownOutLoud)
        XCTAssertEqual(reloaded.cueTriggerMode, .afterMyLine)
        XCTAssertEqual(reloaded.videoQuality, .p1080)
        XCTAssertTrue(reloaded.notifyAuditions)
        XCTAssertNil(defaults.object(forKey: "onetake.countdownSeconds"))
        XCTAssertNil(defaults.object(forKey: "onetake.mirrorFrontCamera"))
        XCTAssertNil(defaults.object(forKey: "onetake.cueTriggerModeRaw"))
        XCTAssertNil(defaults.object(forKey: "onetake.videoQualityRaw"))
    }

    // MARK: - UserProfile Deduplication Tests

    func testCreateOrUpdateProfileAfterLogoutDoesNotCreateDuplicateRows() throws {
        let (state, container, _) = try makeIsolatedAppState()

        state.createOrUpdateProfile(
            name: "Actor One",
            email: "actor1@example.com",
            height: "5'9\"",
            age: 28,
            basedIn: "Los Angeles"
        )
        XCTAssertEqual(state.currentUser?.name, "Actor One")

        state.logout()
        XCTAssertFalse(state.isAuthenticated)
        XCTAssertEqual(state.currentUser?.name, "Actor One")

        state.createOrUpdateProfile(
            name: "Actor Updated",
            email: "updated@example.com",
            height: "5'10\"",
            age: 29,
            basedIn: "New York",
            representation: "Acme Talent"
        )

        let fetchedProfiles = try container.mainContext.fetch(FetchDescriptor<UserProfile>())
        XCTAssertEqual(fetchedProfiles.count, 1)
        XCTAssertEqual(fetchedProfiles.first?.name, "Actor Updated")
        XCTAssertEqual(fetchedProfiles.first?.email, "updated@example.com")
        XCTAssertEqual(state.currentUser?.representation, "Acme Talent")
    }

    func testLoadDataDeduplicatesExistingProfiles() throws {
        let defaults = makeIsolatedDefaults()
        let settings = AppSettings(defaults: defaults)
        let state = AppState(settings: settings, defaults: defaults)
        let container = try makeInMemoryContainer()

        let first = UserProfile(name: "Primary", email: "primary@example.com")
        let duplicate = UserProfile(name: "Duplicate", email: "dup@example.com")
        container.mainContext.insert(first)
        container.mainContext.insert(duplicate)
        try container.mainContext.save()

        state.configure(with: container.mainContext)

        let remaining = try container.mainContext.fetch(FetchDescriptor<UserProfile>())
        XCTAssertEqual(remaining.count, 1)
        XCTAssertNotNil(state.currentUser)
        XCTAssertNil(state.lastPersistenceError)
    }

    // MARK: - Demo Mode Tests

    func testEnterAndExitDemoModePreservesUserCreatedRecords() throws {
        let (state, container, defaults) = try makeIsolatedAppState()

        let userAudition = Audition(
            projectName: "User Feature",
            roleName: "Lead",
            recipientEmail: "casting@userfilm.com"
        )
        let userScript = PracticeScript(
            title: "User Monologue",
            rawText: "ALEX\nThis is my own scene."
        )
        state.addAudition(userAudition)
        state.addPracticeScript(userScript)

        state.enterDemoMode(generateMedia: false)

        XCTAssertTrue(state.isDemoMode)
        XCTAssertTrue(defaults.bool(forKey: "onetake.isDemoMode"))
        XCTAssertTrue(state.hasCompletedOnboarding)
        XCTAssertTrue(state.isAuthenticated)
        XCTAssertEqual(state.currentUser?.email, MockData.sampleUser.email)
        XCTAssertTrue(state.auditions.contains(where: { $0.id == MockData.heerRanjhaID }))
        XCTAssertTrue(state.auditions.contains(where: { $0.id == MockData.theLastSummerID }))
        XCTAssertTrue(state.auditions.contains(where: { $0.id == userAudition.id }))
        XCTAssertTrue(state.practiceScripts.contains(where: { $0.id == MockData.noahAndAllieID }))
        XCTAssertTrue(state.practiceScripts.contains(where: { $0.id == MockData.nainaID }))
        XCTAssertTrue(state.practiceScripts.contains(where: { $0.id == userScript.id }))

        // Re-entering demo mode should not duplicate deterministic demo rows.
        state.enterDemoMode(generateMedia: false)
        let allAuditions = try container.mainContext.fetch(FetchDescriptor<Audition>())
        let allScripts = try container.mainContext.fetch(FetchDescriptor<PracticeScript>())
        XCTAssertEqual(allAuditions.count, 3)
        XCTAssertEqual(allScripts.count, 3)

        // Exiting demo mode removes ONLY demo records and preserves user records.
        state.exitDemoMode()

        XCTAssertFalse(state.isDemoMode)
        XCTAssertFalse(defaults.bool(forKey: "onetake.isDemoMode"))
        XCTAssertNil(state.currentUser)
        XCTAssertEqual(state.auditions.map(\.id), [userAudition.id])
        XCTAssertEqual(state.practiceScripts.map(\.id), [userScript.id])
    }

    // MARK: - Guest Mode, Session & Tab Reset Tests

    func testLogoutPreservesOnboardingAndLocalDataWhileResettingSessionAndTab() throws {
        let (state, container, _) = try makeIsolatedAppState()
        defer { withExtendedLifetime(container) {} }

        state.hasCompletedOnboarding = true
        state.isAuthenticated = true
        state.selectedTab = .profile
        state.globalSearchQuery = "Heer"
        state.createOrUpdateProfile(
            name: "Local Actor",
            email: "local@example.com",
            height: "5'8\"",
            age: 26,
            basedIn: "Mumbai",
            representation: "Self-represented"
        )

        let userAudition = Audition(
            projectName: "Independent Feature",
            roleName: "Lead",
            recipientEmail: "casting@indie.com"
        )
        let userScript = PracticeScript(
            title: "Audition Sides",
            rawText: "LEAD\nWe need to leave now."
        )
        state.addAudition(userAudition)
        state.addPracticeScript(userScript)

        state.logout()

        XCTAssertTrue(state.hasCompletedOnboarding)
        XCTAssertFalse(state.isAuthenticated)
        XCTAssertEqual(state.selectedTab, .auditions)
        XCTAssertEqual(state.globalSearchQuery, "")
        XCTAssertEqual(state.auditions.count, 1)
        XCTAssertEqual(state.practiceScripts.count, 1)
        XCTAssertEqual(state.currentUser?.name, "Local Actor")
    }

    func testLogoutExitsDemoModeAndPreservesUserRecordsWhileResettingTab() throws {
        let (state, container, _) = try makeIsolatedAppState()
        defer { withExtendedLifetime(container) {} }

        let userAudition = Audition(
            projectName: "User Feature",
            roleName: "Supporting",
            recipientEmail: "casting@user.com"
        )
        state.addAudition(userAudition)
        state.enterDemoMode(generateMedia: false)
        state.selectedTab = .practice
        state.globalSearchQuery = "Naina"

        state.logout()

        XCTAssertFalse(state.isDemoMode)
        XCTAssertFalse(state.isAuthenticated)
        XCTAssertTrue(state.hasCompletedOnboarding)
        XCTAssertEqual(state.selectedTab, .auditions)
        XCTAssertEqual(state.globalSearchQuery, "")
        XCTAssertEqual(state.auditions.map(\.id), [userAudition.id])
    }

    func testCompleteSignInResetsTabToAuditions() throws {
        let (state, container, _) = try makeIsolatedAppState()
        defer { withExtendedLifetime(container) {} }

        state.hasCompletedOnboarding = true
        state.isAuthenticated = false
        state.selectedTab = .profile
        state.globalSearchQuery = "Search Term"

        state.completeSignIn(name: "Signed In Actor", email: "actor@example.com")

        XCTAssertTrue(state.isAuthenticated)
        XCTAssertEqual(state.selectedTab, .auditions)
        XCTAssertEqual(state.globalSearchQuery, "")
        XCTAssertEqual(state.currentUser?.name, "Signed In Actor")
        XCTAssertEqual(state.currentUser?.email, "actor@example.com")
    }

    // MARK: - File Cleanup & Delete All Local Data Tests

    func testDeletePracticeScriptRemovesAudioFilesFromDisk() throws {
        let (state, container, _) = try makeIsolatedAppState()
        defer { withExtendedLifetime(container) {} }

        let folderName = "TestPracticeAudio_\(UUID().uuidString)"
        let folderURL = MediaStorage.documentsDirectory.appendingPathComponent(folderName, isDirectory: true)
        createdDirectories.append(folderURL)

        let cueRelPath = try MediaStorage.saveData(
            Data([0x01, 0x02, 0x03]),
            relativePath: "\(folderName)/cue.m4a"
        )
        let sessionRelPath = try MediaStorage.saveData(
            Data([0x04, 0x05, 0x06]),
            relativePath: "\(folderName)/session.m4a"
        )

        XCTAssertTrue(MediaStorage.fileExists(at: cueRelPath))
        XCTAssertTrue(MediaStorage.fileExists(at: sessionRelPath))

        let script = PracticeScript(
            title: "Cleanup Test Script",
            rawText: "A\nHello",
            cueLines: [
                CueLine(orderIndex: 0, speaker: "B", cueText: "Hi", audioFilePath: cueRelPath)
            ],
            sessions: [
                PracticeSession(sessionNumber: 1, audioFilePath: sessionRelPath)
            ]
        )
        state.addPracticeScript(script)
        state.deletePracticeScript(script)

        XCTAssertFalse(MediaStorage.fileExists(at: cueRelPath))
        XCTAssertFalse(MediaStorage.fileExists(at: sessionRelPath))
        XCTAssertTrue(state.practiceScripts.isEmpty)
    }

    func testDeleteAllLocalDataRemovesAllModelsFilesAndResetsSettings() throws {
        let (state, container, defaults) = try makeIsolatedAppState()

        let folderName = "TestDeleteAll_\(UUID().uuidString)"
        let folderURL = MediaStorage.documentsDirectory.appendingPathComponent(folderName, isDirectory: true)
        createdDirectories.append(folderURL)

        let takeRelPath = try MediaStorage.saveData(
            Data(repeating: 0xAA, count: 1024),
            relativePath: "\(folderName)/take.mp4"
        )
        let sessionRelPath = try MediaStorage.saveData(
            Data(repeating: 0xBB, count: 512),
            relativePath: "\(folderName)/practice.m4a"
        )

        state.createOrUpdateProfile(name: "Test Actor", email: "test@example.com")
        state.settings.countdownSeconds = 10
        state.settings.mirrorFrontCamera = false
        state.enterDemoMode(generateMedia: false)

        let customAudition = Audition(
            projectName: "Custom Project",
            roleName: "Hero",
            slateTakes: [VideoTake(title: "Slate", filePath: takeRelPath, durationSeconds: 2, fileSizeMB: 0.001)]
        )
        let customScript = PracticeScript(
            title: "Custom Script",
            sessions: [PracticeSession(sessionNumber: 1, audioFilePath: sessionRelPath)]
        )
        state.addAudition(customAudition)
        state.addPracticeScript(customScript)

        state.deleteAllLocalData()

        XCTAssertFalse(MediaStorage.fileExists(at: takeRelPath))
        XCTAssertFalse(MediaStorage.fileExists(at: sessionRelPath))
        XCTAssertFalse(state.isDemoMode)
        XCTAssertEqual(state.cachedLocalStorageMB, 0)
        XCTAssertNil(state.currentUser)
        XCTAssertTrue(state.auditions.isEmpty)
        XCTAssertTrue(state.practiceScripts.isEmpty)
        XCTAssertEqual(state.settings.countdownSeconds, 3)
        XCTAssertTrue(state.settings.mirrorFrontCamera)
        XCTAssertNil(defaults.object(forKey: "onetake.countdownSeconds"))

        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<UserProfile>()).isEmpty)
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<Audition>()).isEmpty)
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<PracticeScript>()).isEmpty)
    }

    // MARK: - DemoMediaGenerator Tests

    func testWriteQuickSimulatedClipCreatesPlayableMP4() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DemoMediaGeneratorTests_\(UUID().uuidString)", isDirectory: true)
        createdDirectories.append(tempDir)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let clipURL = tempDir.appendingPathComponent("simulated.mp4")
        let created = await DemoMediaGenerator.writeQuickSimulatedClip(
            to: clipURL,
            title: "Test Slate",
            subtitle: "Avery Vance",
            durationSeconds: 1.2
        )

        XCTAssertTrue(created)
        XCTAssertTrue(FileManager.default.fileExists(atPath: clipURL.path))

        let asset = AVURLAsset(url: clipURL)
        let tracks = try await asset.load(.tracks)
        XCTAssertFalse(tracks.isEmpty)
    }

    func testCanvasBackgroundIsPureBlackInDarkModeAndLightInLightMode() throws {
        let dynamicColor = UIColor(Theme.Colors.canvasBackground)

        let darkResolved = dynamicColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        var dr: CGFloat = -1, dg: CGFloat = -1, db: CGFloat = -1, da: CGFloat = -1
        XCTAssertTrue(darkResolved.getRed(&dr, green: &dg, blue: &db, alpha: &da))
        XCTAssertEqual(dr, 0.0, accuracy: 0.001)
        XCTAssertEqual(dg, 0.0, accuracy: 0.001)
        XCTAssertEqual(db, 0.0, accuracy: 0.001)
        XCTAssertEqual(da, 1.0, accuracy: 0.001)

        let lightResolved = dynamicColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var lr: CGFloat = -1, lg: CGFloat = -1, lb: CGFloat = -1, la: CGFloat = -1
        XCTAssertTrue(lightResolved.getRed(&lr, green: &lg, blue: &lb, alpha: &la))
        XCTAssertGreaterThan(lr, 0.9)
        XCTAssertGreaterThan(lg, 0.9)
        XCTAssertGreaterThan(lb, 0.9)
        XCTAssertEqual(la, 1.0, accuracy: 0.001)
    }

    func testHapticFeedbackLevelDefaultsPersistenceAndGating() {
        let defaults = makeIsolatedDefaults()
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.hapticFeedbackLevel, .selective)

        settings.hapticFeedbackLevel = .rich
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.hapticFeedbackLevel, .rich)

        settings.resetToDefaults()
        XCTAssertEqual(settings.hapticFeedbackLevel, .selective)

        // Mode & mic-capture gating
        XCTAssertTrue(Haptics.shouldPlay(.essential, level: .selective, isMicActive: false))
        XCTAssertFalse(Haptics.shouldPlay(.tactile, level: .selective, isMicActive: false))
        XCTAssertTrue(Haptics.shouldPlay(.essential, level: .rich, isMicActive: false))
        XCTAssertTrue(Haptics.shouldPlay(.tactile, level: .rich, isMicActive: false))
        XCTAssertFalse(Haptics.shouldPlay(.essential, level: .off, isMicActive: false))
        XCTAssertFalse(Haptics.shouldPlay(.tactile, level: .off, isMicActive: false))

        // Active mic capture must suppress all haptics across every level
        XCTAssertFalse(Haptics.shouldPlay(.essential, level: .selective, isMicActive: true))
        XCTAssertFalse(Haptics.shouldPlay(.essential, level: .rich, isMicActive: true))
        XCTAssertFalse(Haptics.shouldPlay(.tactile, level: .rich, isMicActive: true))

        Haptics.resetMicCaptureStateForTesting()
        defer { Haptics.resetMicCaptureStateForTesting() }
        XCTAssertFalse(Haptics.isMicCaptureActive)
        Haptics.setMicCaptureActive(true, source: "teleprompter")
        Haptics.setMicCaptureActive(true, source: "teleprompter")
        Haptics.setMicCaptureActive(true, source: "cue")
        XCTAssertTrue(Haptics.isMicCaptureActive)
        Haptics.setMicCaptureActive(false, source: "teleprompter")
        XCTAssertTrue(Haptics.isMicCaptureActive)
        Haptics.setMicCaptureActive(false, source: "cue")
        XCTAssertFalse(Haptics.isMicCaptureActive)
    }

    func testScrollEdgeTrackerFiresOncePerBoundaryAndOverscroll() {
        var tracker = ScrollEdgeTracker()
        let t0 = Date(timeIntervalSince1970: 1_000)

        // Initial idle layout at top never triggers.
        XCTAssertFalse(tracker.update(offsetY: 0, topEdge: 0, bottomEdge: 400, isActiveScroll: false, now: t0))

        // Scroll down past top rearm distance, then reach bottom -> fires once.
        XCTAssertFalse(tracker.update(offsetY: 120, topEdge: 0, bottomEdge: 400, isActiveScroll: true, now: t0.addingTimeInterval(0.3)))
        XCTAssertTrue(tracker.update(offsetY: 400, topEdge: 0, bottomEdge: 400, isActiveScroll: true, now: t0.addingTimeInterval(0.6)))
        // Continuing past bottom immediately (fling bounce) stays latched.
        XCTAssertFalse(tracker.update(offsetY: 416, topEdge: 0, bottomEdge: 400, isActiveScroll: true, now: t0.addingTimeInterval(0.9)))

        // Scroll back up into middle, then hit top -> fires once.
        XCTAssertFalse(tracker.update(offsetY: 200, topEdge: 0, bottomEdge: 400, isActiveScroll: true, now: t0.addingTimeInterval(1.2)))
        XCTAssertTrue(tracker.update(offsetY: 0, topEdge: 0, bottomEdge: 400, isActiveScroll: true, now: t0.addingTimeInterval(1.5)))
        XCTAssertFalse(tracker.update(offsetY: -14, topEdge: 0, bottomEdge: 400, isActiveScroll: true, now: t0.addingTimeInterval(1.8)))

        // Settle to idle, then pull down from rest at top -> rubber-band overscroll fires once.
        XCTAssertFalse(tracker.update(offsetY: 0, topEdge: 0, bottomEdge: 400, isActiveScroll: false, now: t0.addingTimeInterval(2.1)))
        XCTAssertTrue(tracker.update(offsetY: -12, topEdge: 0, bottomEdge: 400, isActiveScroll: true, now: t0.addingTimeInterval(2.4)))
        XCTAssertFalse(tracker.update(offsetY: -20, topEdge: 0, bottomEdge: 400, isActiveScroll: true, now: t0.addingTimeInterval(2.7)))

        // Non-scrollable short screen fires only when pulled past top/bottom overscroll threshold.
        var shortTracker = ScrollEdgeTracker()
        XCTAssertFalse(shortTracker.update(offsetY: 0, topEdge: 0, bottomEdge: 0, isActiveScroll: false, now: t0))
        XCTAssertFalse(shortTracker.update(offsetY: -4, topEdge: 0, bottomEdge: 0, isActiveScroll: true, now: t0.addingTimeInterval(0.3)))
        XCTAssertTrue(shortTracker.update(offsetY: -12, topEdge: 0, bottomEdge: 0, isActiveScroll: true, now: t0.addingTimeInterval(0.6)))
        XCTAssertFalse(shortTracker.update(offsetY: -12, topEdge: 0, bottomEdge: 0, isActiveScroll: true, now: t0.addingTimeInterval(0.9)))
    }
}
