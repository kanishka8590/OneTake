import AVFoundation
import PDFKit
import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import OneTake

@MainActor
final class PhysicalDeviceAuditTests: XCTestCase {

    private var savedRootVC: UIViewController?
    private var auditWindow: UIWindow?

    override func tearDown() {
        if let window = auditWindow {
            window.isHidden = true
            window.rootViewController = nil
        }
        auditWindow = nil
        super.tearDown()
    }

    private func fixtureURL(named name: String) throws -> URL {
        let bundle = Bundle(for: PhysicalDeviceAuditTests.self)
        if let url = bundle.url(forResource: name, withExtension: nil, subdirectory: "TestFixtures") {
            return url
        }
        if let url = bundle.url(forResource: name, withExtension: nil) {
            return url
        }
        let sourceFallback = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("TestFixtures")
            .appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: sourceFallback.path) {
            return sourceFallback
        }
        throw XCTSkip("Fixture \(name) not found in test bundle")
    }

    private func makeInMemoryState(withSampleData: Bool = true) throws -> (AppState, ModelContainer) {
        let schema = Schema([Audition.self, PracticeScript.self, UserProfile.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let defaultsSuite = "com.porage.onetake.audit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        let state = AppState(defaults: defaults)
        state.hasCompletedOnboarding = true
        state.configure(with: container.mainContext)
        if withSampleData {
            state.enterDemoMode(generateMedia: false)
        }
        return (state, container)
    }

    private func findScrollView(in view: UIView) -> UIScrollView? {
        if let sv = view as? UIScrollView { return sv }
        for sub in view.subviews {
            if let found = findScrollView(in: sub) { return found }
        }
        return nil
    }

    private func captureView<V: View>(
        _ view: V,
        name: String,
        appState: AppState,
        style: UIUserInterfaceStyle = .dark,
        waitSeconds: TimeInterval = 0.45,
        scrollDownOffset: CGFloat = 0
    ) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else {
            XCTFail("No active UIWindowScene on physical device")
            return
        }

        let window = auditWindow ?? UIWindow(windowScene: scene)
        auditWindow = window
        window.frame = scene.coordinateSpace.bounds
        window.windowLevel = .alert + 1
        window.overrideUserInterfaceStyle = style

        let hosting = UIHostingController(rootView: view.environment(appState))
        window.rootViewController = hosting
        window.makeKeyAndVisible()

        let deadline = Date().addingTimeInterval(waitSeconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if scrollDownOffset > 0, let sv = findScrollView(in: hosting.view) {
            sv.setContentOffset(CGPoint(x: 0, y: -sv.adjustedContentInset.top + scrollDownOffset), animated: false)
            let scrollDeadline = Date().addingTimeInterval(0.2)
            while Date() < scrollDeadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
        }
        hosting.view.setNeedsLayout()
        hosting.view.layoutIfNeeded()

        // Audit UIKit view tree for clipped labels or invalid geometry
        var warnings: [String] = []
        inspectViewHierarchy(hosting.view, depth: 0, warnings: &warnings)
        if !warnings.isEmpty {
            print("===UI_AUDIT_WARNINGS[\(name)]=== \(warnings.prefix(10).joined(separator: " | "))")
        }

        autoreleasepool {
            let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
            let image = renderer.image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image, quality: .medium)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        window.rootViewController = nil
    }

    private func inspectViewHierarchy(_ view: UIView, depth: Int, warnings: inout [String]) {
        if let label = view as? UILabel, let text = label.text, !text.isEmpty, label.bounds.width > 0 {
            let needed = label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude))
            if needed.height > label.bounds.height + 4 && label.numberOfLines == 1 {
                warnings.append("Truncated1Line(\"\(text.prefix(24))\") h=\(Int(label.bounds.height))<\(Int(needed.height))")
            }
        }
        for sub in view.subviews {
            inspectViewHierarchy(sub, depth: depth + 1, warnings: &warnings)
        }
    }

    // MARK: - 1. All Test Fixtures Full Parse Audit on Physical iPhone 11

    func test01_AuditAllRealTestFixturesOnPhysicalDevice() async throws {
        let parser = CastingCallParserService.shared

        let txtURL = try fixtureURL(named: "1.txt")
        let txtString = try String(contentsOf: txtURL, encoding: .utf8)
        let parsed1 = await parser.parseText(txtString)
        logParsed("1.txt", parsed: parsed1)
        XCTAssertEqual(parsed1.projectName, "Yash Raj Films")
        XCTAssertEqual(parsed1.maxSlateSeconds, 60.0)
        XCTAssertFalse(parsed1.hasDetectedScript)
        XCTAssertFalse(parsed1.roleDescription.isEmpty)

        let img2 = try XCTUnwrap(UIImage(contentsOfFile: try fixtureURL(named: "2.png").path))
        let parsed2 = try await parser.parseImage(img2)
        logParsed("2.png", parsed: parsed2)
        XCTAssertNotEqual(parsed2.projectName, "FEATURE FILM")
        XCTAssertFalse(parsed2.hasDetectedScript, "Casting notice metadata must not false-trigger script parsing")
        XCTAssertFalse(parsed2.roleName.contains("865"))
        XCTAssertTrue(parsed2.roleName.localizedCaseInsensitiveContains("Traditional Indian Look"))
        XCTAssertFalse(parsed2.roleDescription.isEmpty)
        XCTAssertFalse(parsed2.requirements.contains(where: { $0.title == "Audition Self-Tape Take" }))

        let img3 = try XCTUnwrap(UIImage(contentsOfFile: try fixtureURL(named: "3.png").path))
        let parsed3 = try await parser.parseImage(img3)
        logParsed("3.png", parsed: parsed3)
        XCTAssertEqual(parsed3.recipientEmail.lowercased(), "profilesforlead@gmail.com")
        XCTAssertEqual(parsed3.roleName, "Male Lead")
        XCTAssertFalse(parsed3.hasDetectedScript)
        XCTAssertFalse(parsed3.roleDescription.isEmpty)
        XCTAssertFalse(parsed3.requirements.contains(where: { $0.title == "Audition Self-Tape Take" }))

        let img4 = try XCTUnwrap(UIImage(contentsOfFile: try fixtureURL(named: "4.png").path))
        let parsed4 = try await parser.parseImage(img4)
        logParsed("4.png", parsed: parsed4)
        XCTAssertEqual(parsed4.projectName, "Heer Ranjha")
        XCTAssertEqual(parsed4.roleName, "Female Lead")
        XCTAssertEqual(parsed4.recipientEmail.lowercased(), "vaishak@anticasting.in")
        XCTAssertFalse(parsed4.hasDetectedScript)
        XCTAssertFalse(parsed4.roleDescription.isEmpty)
        XCTAssertFalse(parsed4.requirements.contains(where: { $0.title == "Audition Self-Tape Take" }))

        let pdfURL = try fixtureURL(named: "5.pdf")
        let pdfData = try Data(contentsOf: pdfURL)
        let parsed5 = try await parser.parsePDF(data: pdfData)
        logParsed("5.pdf", parsed: parsed5)
        XCTAssertFalse(parsed5.projectName.contains("\u{FFFC}"))
        XCTAssertTrue(parsed5.projectName.localizedCaseInsensitiveContains("Grease"))
        let daysUntilDeadline = Calendar.current.dateComponents([.day], from: Date(), to: parsed5.deadline).day ?? 0
        XCTAssertGreaterThanOrEqual(daysUntilDeadline, 2, "Script dialogue 'Next Friday' must not override default +3d deadline")
        XCTAssertTrue(parsed5.hasDetectedScript)
        XCTAssertFalse(parsed5.cueLines.contains(where: { $0.speaker.contains("ACT ") || $0.speaker.contains(",") }))

        // Inspect Practice parsing on 5.pdf page 3, 12, 13 (colons vs non-colons)
        if let doc = PDFDocument(data: pdfData) {
            for pageIdx in [2, 11, 12, 31] where pageIdx < doc.pageCount {
                let pageText = doc.page(at: pageIdx)?.string ?? ""
                let cues = autoDetectCueLines(from: pageText)
                let script = PracticeScript(title: "Grease p.\(pageIdx+1)", rawText: pageText)
                script.cueLines = cues
                let model = PracticeScriptModel(script: script)
                let speakers = Set(model.lines.map(\.speaker)).sorted()
                print("===AUDIT_5PDF_PAGE[\(pageIdx+1)]=== lines=\(model.lines.count) tokens=\(model.actorTokens.count) cues=\(cues.count) speakers=\(speakers)")
            }
        }
    }

    // MARK: - 2. Render & Snapshot Every Screen on Physical iPhone 11

    func test02_CaptureEveryScreenOnPhysicalDevice() throws {
        let (state, container) = try makeInMemoryState(withSampleData: true)
        let audition = try XCTUnwrap(state.auditions.first)
        let script = try XCTUnwrap(state.practiceScripts.first)

        // Onboarding
        captureView(OnboardingView(appState: state), name: "01_onboarding_slide0", appState: state, style: .light)

        // Auth View
        captureView(AuthView(appState: state), name: "02_auth_dark", appState: state, style: .dark)
        captureView(AuthView(appState: state), name: "03_auth_light", appState: state, style: .light)

        // Main Tab: Auditions
        state.selectedTab = .auditions
        captureView(
            MainTabView(appState: state).modelContainer(container),
            name: "04_main_auditions_dark",
            appState: state,
            style: .dark,
            waitSeconds: 0.6
        )
        captureView(
            MainTabView(appState: state).modelContainer(container),
            name: "04b_main_auditions_scrolled",
            appState: state,
            style: .dark,
            waitSeconds: 0.5,
            scrollDownOffset: 160
        )
        captureView(
            MainTabView(appState: state).modelContainer(container),
            name: "05_main_auditions_light",
            appState: state,
            style: .light,
            waitSeconds: 0.5
        )

        // Empty Auditions
        let (emptyState, emptyContainer) = try makeInMemoryState(withSampleData: false)
        captureView(
            AuditionsListView(appState: emptyState).modelContainer(emptyContainer),
            name: "06_auditions_empty_dark",
            appState: emptyState,
            style: .dark
        )

        // Global Search Tab (Prominent Search Tab in Bottom Nav Bar): Match & Zero Results
        state.selectedTab = .search
        state.globalSearchQuery = "Heer"
        captureView(
            MainTabView(appState: state).modelContainer(container),
            name: "07_search_matches",
            appState: state,
            style: .dark,
            waitSeconds: 0.55
        )
        state.globalSearchQuery = "NonExistentQuery999"
        captureView(
            MainTabView(appState: state).modelContainer(container),
            name: "08_search_zero_results",
            appState: state,
            style: .dark,
            waitSeconds: 0.55
        )
        state.globalSearchQuery = ""
        state.selectedTab = .auditions

        // Audition Details Editor (Check sheet & inline)
        captureView(
            AuditionDetailsEditorView(existingAudition: audition).modelContainer(container),
            name: "09_audition_details_editor",
            appState: state,
            style: .dark
        )

        // Audition Package Hub
        captureView(
            NavigationStack {
                AuditionPackageHubView(audition: audition)
            }.modelContainer(container),
            name: "10_audition_package_hub",
            appState: state,
            style: .dark
        )

        // Headshots Flow
        let sampleImg = DemoMediaGenerator.renderHeadshotImage(angle: "Front")
        captureView(
            NavigationStack {
                HeadshotPackageGridView(
                    audition: audition,
                    frontCropped: sampleImg,
                    leftCropped: sampleImg,
                    rightCropped: sampleImg,
                    onRetakeAngle: { _ in },
                    onSaveCompleted: {}
                )
            }.modelContainer(container),
            name: "11_headshot_package_grid",
            appState: state,
            style: .dark
        )
        captureView(
            HeadshotReviewView(audition: audition, initialFront: sampleImg, initialLeft: sampleImg, initialRight: sampleImg)
                .modelContainer(container),
            name: "12_headshot_review",
            appState: state,
            style: .dark
        )

        // Slate & Teleprompter Subviews
        captureView(
            NavigationStack {
                SlateProfileSetupView(audition: audition, onSlateSaved: {})
            }.modelContainer(container),
            name: "13_slate_setup",
            appState: state,
            style: .dark
        )
        captureView(
            NavigationStack {
                AuditionModeAndCuesView(audition: audition, onAuditionTakeSaved: {})
            }.modelContainer(container),
            name: "14_audition_mode_and_cues",
            appState: state,
            style: .dark
        )
        captureView(
            NavigationStack {
                CueRecorderView(audition: audition, cueLines: .constant(audition.cueLines), onFinished: {})
            }.modelContainer(container),
            name: "15_cue_recorder",
            appState: state,
            style: .dark
        )
        captureView(
            NavigationStack {
                TalkToOneTakeBriefingView(audition: audition, onReadyToRecord: { _ in })
            }.modelContainer(container),
            name: "16_talk_to_onetake_briefing",
            appState: state,
            style: .dark
        )
        captureView(
            NavigationStack {
                TakesListView(
                    audition: audition,
                    isSlate: false,
                    takes: .constant(audition.auditionTakes),
                    selectedTakeID: .constant(audition.selectedAuditionTakeID)
                )
            }.modelContainer(container),
            name: "17_takes_list",
            appState: state,
            style: .dark
        )
        captureView(
            NavigationStack {
                PackageValidationAndExportView(audition: audition)
            }.modelContainer(container),
            name: "18_package_validation_export",
            appState: state,
            style: .dark
        )

        // Main Tab: Practice
        state.selectedTab = .practice
        captureView(
            MainTabView(appState: state).modelContainer(container),
            name: "19_main_practice_hub_dark",
            appState: state,
            style: .dark,
            waitSeconds: 0.6
        )
        captureView(
            PracticeHubView(appState: emptyState).modelContainer(emptyContainer),
            name: "20_practice_hub_empty",
            appState: emptyState,
            style: .dark
        )
        captureView(
            PracticeASceneSheet(appState: state, isPresented: .constant(true), onScriptReady: { _ in }).modelContainer(container),
            name: "21_practice_add_scene_sheet",
            appState: state,
            style: .dark
        )
        captureView(
            NavigationStack {
                MemoriseView(script: script, appState: state)
            }.modelContainer(container),
            name: "22_practice_unified_memorise",
            appState: state,
            style: .dark
        )
        captureView(
            NavigationStack {
                SayItAloudView(script: script, appState: state, help: .letters)
            }.modelContainer(container),
            name: "23_practice_say_it_aloud",
            appState: state,
            style: .dark
        )
        // Practice Review (pick script with sessions)
        if let reviewScript = state.practiceScripts.first(where: { !$0.sessions.isEmpty }),
           let session = reviewScript.sessions.first {
            captureView(
                NavigationStack {
                    PracticeReviewView(script: reviewScript, session: session, appState: state, isSavedReview: true)
                }.modelContainer(container),
                name: "24_practice_review",
                appState: state,
                style: .dark
            )
        }
        captureView(
            PracticeHistoryView(scripts: state.practiceScripts, appState: state).modelContainer(container),
            name: "25_practice_history",
            appState: state,
            style: .dark
        )

        // Main Tab: Profile & Settings
        state.selectedTab = .profile
        captureView(
            MainTabView(appState: state).modelContainer(container),
            name: "26_main_profile_guest",
            appState: state,
            style: .dark,
            waitSeconds: 0.5
        )
        captureView(
            NavigationStack { RecordingSettingsView(appState: state) }.modelContainer(container),
            name: "27_recording_settings",
            appState: state,
            style: .dark
        )
        captureView(
            NavigationStack { NotificationPreferencesView(appState: state) }.modelContainer(container),
            name: "28_notification_preferences",
            appState: state,
            style: .dark
        )
        captureView(
            NavigationStack { PrivacyAndDataView(appState: state) }.modelContainer(container),
            name: "29_privacy_and_data",
            appState: state,
            style: .dark
        )
        captureView(
            EditProfileSheet(appState: state, isPresented: .constant(true)).modelContainer(container),
            name: "30_edit_profile_sheet",
            appState: state,
            style: .dark
        )
    }

    // MARK: - 3. Real Hardware Services Audit (Camera, Audio, CoreML, Export, Zip, Reminders)

    func test03_AuditServicesAndEdgeCasesOnPhysicalDevice() async throws {
        // Check CoreML Models loaded properly
        let sampleCG = try XCTUnwrap(DemoMediaGenerator.renderHeadshotImage(angle: "Front").cgImage)
        let posePrediction = HeadshotPosePredictor.shared.predict(cgImage: sampleCG)
        print("===AUDIT_COREML=== posePrediction=\(String(describing: posePrediction))")

        // Check AVFoundation Video Hardware on Physical iPhone 11
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera],
            mediaType: .video,
            position: .unspecified
        )
        print("===AUDIT_CAMERA_DEVICES=== count=\(discovery.devices.count) names=\(discovery.devices.map(\.localizedName))")

        // Check DemoMediaGenerator + VideoPostProcessingService + ZipArchive on real physical iOS 27.2.1 paths
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("AuditMedia_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let clipURL = tempDir.appendingPathComponent("audit_clip.mp4")
        let clipOK = await DemoMediaGenerator.writeQuickSimulatedClip(to: clipURL, title: "Audit", subtitle: "iPhone 11", durationSeconds: 1.5)
        let meta = await VideoPostProcessingService.inspectTrackMetadata(at: clipURL)
        print("===AUDIT_VIDEO_GEN=== ok=\(clipOK) duration=\(meta.durationSeconds) sizeMB=\(meta.fileSizeMB) ratio=\(meta.aspectRatioString)")

        // Test Audio Cleanup & Compression on physical hardware
        let postService = VideoPostProcessingService()
        let cleanedURL = tempDir.appendingPathComponent("audit_cleaned.mp4")
        let cleanResult = try? await postService.exportWithAudioCleanup(sourceURL: clipURL, enableNoiseSuppression: true, destinationURL: cleanedURL)
        print("===AUDIT_VIDEO_CLEANUP=== ok=\(cleanResult != nil)")

        let compressedURL = tempDir.appendingPathComponent("audit_compressed.mp4")
        let compressResult = try? await postService.compressVideoToTargetSize(sourceURL: clipURL, targetSizeMB: 1.0, destinationURL: compressedURL)
        print("===AUDIT_VIDEO_COMPRESS=== ok=\(compressResult != nil)")

        // Check ZipArchive on iOS 27.2.1 path behavior
        let zipURL = tempDir.appendingPathComponent("audit.zip")
        let extractDir = tempDir.appendingPathComponent("extract", isDirectory: true)
        try ZipArchive.write([(name: "hello.txt", data: Data("hello".utf8))], to: zipURL)
        do {
            try ZipArchive.extract(from: zipURL, to: extractDir)
            print("===AUDIT_ZIP=== extractOK=true")
        } catch {
            print("===AUDIT_ZIP=== extractFAILED=\(error)")
        }

        // Check AppState Sign In -> Sign Out preserves SwiftData & resets tab
        let (state, container) = try makeInMemoryState(withSampleData: false)
        let realAudition = Audition(projectName: "Real Saved Audition", roleName: "Lead")
        state.addAudition(realAudition)
        let realScript = PracticeScript(title: "Real Saved Script", rawText: "ALICE: Hi")
        state.addPracticeScript(realScript)
        state.completeSignIn(name: "Jitun", email: "jitund05@gmail.com")
        state.selectedTab = .profile
        state.logout()
        print("===AUDIT_LOGOUT=== isAuth=\(state.isAuthenticated) tab=\(state.selectedTab.rawValue) auditions=\(state.auditions.count) scripts=\(state.practiceScripts.count) contextNotNil=\(container.mainContext.autosaveEnabled)")
    }

    func test04_CaptureCameraCropReviewAndModalSheetsOnPhysicalDevice() async throws {
        let (state, container) = try makeInMemoryState(withSampleData: true)
        let audition = try XCTUnwrap(state.auditions.first)
        let sampleImg = DemoMediaGenerator.renderHeadshotImage(angle: "Front")

        // 31. HeadshotGuidanceView
        captureView(
            HeadshotGuidanceView(audition: audition).modelContainer(container),
            name: "31_headshot_guidance",
            appState: state,
            style: .dark,
            waitSeconds: 0.6
        )

        // 32. TeleprompterRecorderView
        captureView(
            TeleprompterRecorderView(
                audition: audition,
                modeTitle: "Audition Take",
                scriptLines: ["HEER: I won't let them decide my fate.", "[RANJHA]: Then come with me. Tonight."],
                isSlate: false,
                onTakeSaved: { _ in }
            ).modelContainer(container),
            name: "32_teleprompter_recorder",
            appState: state,
            style: .dark,
            waitSeconds: 0.6
        )

        // 33. HeadshotCropView
        captureView(
            HeadshotCropView(
                originalImage: sampleImg,
                defaultRatio: .ratio4x5,
                onCropConfirmed: { _, _, _ in }
            ).modelContainer(container),
            name: "33_headshot_crop",
            appState: state,
            style: .dark,
            waitSeconds: 0.6
        )

        // 34. TakeReviewView with real generated MP4
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("audit_review_\(UUID().uuidString).mp4")
        _ = await DemoMediaGenerator.writeQuickSimulatedClip(to: tempURL, title: "Audit Take", subtitle: "Heer", durationSeconds: 2.0)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        captureView(
            TakeReviewView(
                audition: audition,
                rawVideoURL: tempURL,
                totalDurationSeconds: 2.0,
                isSlate: false,
                qualityMetrics: PreTakeQualityMetrics(),
                onTakeApproved: { _ in },
                onRetake: {}
            ).modelContainer(container),
            name: "34_take_review",
            appState: state,
            style: .dark,
            waitSeconds: 0.6
        )

        // 35. AuditionDetailsEditorView presented as real .sheet on iPhone 11
        captureView(
            Color.black.ignoresSafeArea()
                .sheet(isPresented: .constant(true)) {
                    AuditionDetailsEditorView(existingAudition: audition)
                        .presentationDragIndicator(.hidden)
                        .presentationBackground(Theme.Colors.canvasBackground)
                        .environment(state)
                }
                .modelContainer(container),
            name: "35_audition_details_presented_sheet",
            appState: state,
            style: .dark,
            waitSeconds: 0.8
        )

        // 36. EmailOTPView
        captureView(
            EmailOTPView(appState: state, isPresented: .constant(true), onComplete: {}).modelContainer(container),
            name: "36_email_otp",
            appState: state,
            style: .dark,
            waitSeconds: 0.5
        )
    }

    // MARK: - 5. Practice & Casting New Test Suites (test/practice + test/casting)

    func test05_AuditPracticeAndCastingFixturesOnPhysicalDevice() async throws {
        let parser = CastingCallParserService.shared

        // --- Practice & Audition Sides: 1p.txt, 2p.png, 3p.pdf ---
        let p1Text = try String(contentsOf: try fixtureURL(named: "1p.txt"), encoding: .utf8)
        let p1Script = PracticeScript(title: "Gilmore 1p", rawText: p1Text)
        p1Script.cueLines = autoDetectCueLines(from: p1Text)
        let p1Model = PracticeScriptModel(script: p1Script)
        let p1Sides = parser.parseSidesText(p1Text, defaultRole: "LUKE")
        print("===AUDIT_PRACTICE[1p.txt]=== speakers=\(Set(p1Model.lines.map(\.speaker)).sorted()) practiceCues=\(p1Script.cueLines.count) auditionCues=\(p1Sides.cueLines.count) tele=\(p1Sides.teleprompterLines.count)")
        XCTAssertTrue(Set(p1Model.lines.map(\.speaker)).contains("LUKE"))
        XCTAssertTrue(Set(p1Model.lines.map(\.speaker)).contains("LORELAI"))
        XCTAssertGreaterThanOrEqual(p1Script.cueLines.count, 1)
        XCTAssertGreaterThanOrEqual(p1Sides.cueLines.count, 1)
        XCTAssertFalse(p1Sides.teleprompterLines.isEmpty)

        let p2Img = try XCTUnwrap(UIImage(contentsOfFile: try fixtureURL(named: "2p.png").path))
        let p2OCR = try await parser.extractRawText(from: p2Img)
        let p2Script = PracticeScript(title: "Gilmore 2p", rawText: p2OCR)
        p2Script.cueLines = autoDetectCueLines(from: p2OCR)
        let p2Model = PracticeScriptModel(script: p2Script)
        let p2Sides = parser.parseSidesText(p2OCR, defaultRole: "RORY")
        print("===AUDIT_PRACTICE[2p.png]=== speakers=\(Set(p2Model.lines.map(\.speaker)).sorted()) practiceCues=\(p2Script.cueLines.count) auditionCues=\(p2Sides.cueLines.count) tele=\(p2Sides.teleprompterLines.count)")
        XCTAssertTrue(Set(p2Model.lines.map(\.speaker)).contains("RORY"))
        XCTAssertTrue(Set(p2Model.lines.map(\.speaker)).contains("PARIS"))
        XCTAssertFalse(Set(p2Model.lines.map(\.speaker)).contains("SCENE END"))
        XCTAssertGreaterThanOrEqual(p2Script.cueLines.count, 1)
        XCTAssertGreaterThanOrEqual(p2Sides.cueLines.count, 1)

        let p3Data = try Data(contentsOf: try fixtureURL(named: "3p.pdf"))
        let p3Text = try await parser.extractRawText(fromPDF: p3Data)
        let p3Script = PracticeScript(title: "Notebook 3p", rawText: p3Text)
        p3Script.cueLines = autoDetectCueLines(from: p3Text)
        let p3Model = PracticeScriptModel(script: p3Script)
        let p3Sides = parser.parseSidesText(p3Text, defaultRole: "NOAH")
        print("===AUDIT_PRACTICE[3p.pdf]=== speakers=\(Set(p3Model.lines.map(\.speaker)).sorted()) practiceCues=\(p3Script.cueLines.count) auditionCues=\(p3Sides.cueLines.count) tele=\(p3Sides.teleprompterLines.count)")
        XCTAssertTrue(Set(p3Model.lines.map(\.speaker)).contains("NOAH"))
        XCTAssertTrue(Set(p3Model.lines.map(\.speaker)).contains("ALLIE"))
        XCTAssertGreaterThanOrEqual(p3Script.cueLines.count, 2)
        XCTAssertGreaterThanOrEqual(p3Sides.cueLines.count, 2)

        // --- Audition Casting Calls: 1c.txt, 2c.png, 3c.pdf ---
        let c1Text = try String(contentsOf: try fixtureURL(named: "1c.txt"), encoding: .utf8)
        let c1 = await parser.parseText(c1Text)
        logParsed("1c.txt", parsed: c1)
        XCTAssertEqual(c1.projectName, "Photon")
        XCTAssertEqual(c1.productionType, .featureFilm)
        XCTAssertEqual(c1.roleName, "Male Talent")
        XCTAssertEqual(c1.recipientEmail.lowercased(), "casting@schoolofdrama.com")
        XCTAssertFalse(c1.hasDetectedScript)
        XCTAssertTrue(c1.requirements.contains(where: { $0.title == "Audition Self-Tape Take" }))
        XCTAssertEqual(Calendar.current.component(.day, from: c1.deadline), 30)
        XCTAssertEqual(Calendar.current.component(.month, from: c1.deadline), 11)

        let c2Img = try XCTUnwrap(UIImage(contentsOfFile: try fixtureURL(named: "2c.png").path))
        let c2 = try await parser.parseImage(c2Img)
        logParsed("2c.png", parsed: c2)
        XCTAssertEqual(c2.projectName, "Casting Bay - Casting Studio")
        XCTAssertEqual(c2.roleName, "Male Lead")
        XCTAssertEqual(c2.recipientEmail.lowercased(), "profilesforlead@gmail.com")
        XCTAssertFalse(c2.hasDetectedScript)
        XCTAssertTrue(c2.requirements.contains(where: { $0.title == "Audition Self-Tape Take" }))
        XCTAssertEqual(Calendar.current.component(.year, from: c2.deadline), 2026)

        let c3Data = try Data(contentsOf: try fixtureURL(named: "3c.pdf"))
        let c3 = try await parser.parsePDF(data: c3Data)
        logParsed("3c.pdf", parsed: c3)
        XCTAssertEqual(c3.projectName, "MCCC - KOSHISHE")
        XCTAssertEqual(c3.roleName, "Male Lead")
        XCTAssertEqual(c3.recipientEmail.lowercased(), "abhinav@mcc.in")
        XCTAssertFalse(c3.hasDetectedScript)
        XCTAssertTrue(c3.requirements.contains(where: { $0.title == "Audition Self-Tape Take" }))
        XCTAssertEqual(Calendar.current.component(.day, from: c3.deadline), 15)
        XCTAssertEqual(Calendar.current.component(.month, from: c3.deadline), 12)
    }

    private func logParsed(_ label: String, parsed: ParsedCastingCall) {
        print("""
        ===AUDIT_PARSE[\(label)]===
        projectName: \(parsed.projectName)
        productionType: \(parsed.productionType.rawValue)
        roleName: \(parsed.roleName)
        roleDescription: \(parsed.roleDescription.replacingOccurrences(of: "\n", with: " "))
        deadline: \(parsed.deadline)
        recipientEmail: \(parsed.recipientEmail)
        requirements: \(parsed.requirements.map(\.title))
        maxSlateSeconds: \(parsed.maxSlateSeconds)
        maxClipSeconds: \(parsed.maxClipSeconds)
        hasDetectedScript: \(parsed.hasDetectedScript)
        detectedMainRole: \(parsed.detectedMainRole)
        detectedCueRole: \(parsed.detectedCueRole)
        cueLinesCount: \(parsed.cueLines.count)
        teleprompterLinesCount: \(parsed.teleprompterLines.count)
        rawExtractedText_prefix: \(String(parsed.rawExtractedText.prefix(400)).replacingOccurrences(of: "\n", with: " | "))
        detectedScriptText_prefix: \(String((parsed.detectedScriptText ?? "").prefix(300)).replacingOccurrences(of: "\n", with: " | "))
        ===END_AUDIT_PARSE[\(label)]===
        """)
    }
}
