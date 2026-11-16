import SwiftUI
import SwiftData

@MainActor
@Observable
final class AppState {
    @ObservationIgnored private let defaults: UserDefaults

    // MARK: - App Lifecycle
    var hasCompletedOnboarding: Bool {
        didSet {
            defaults.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding")
        }
    }

    var isAuthenticated: Bool {
        didSet {
            defaults.set(isAuthenticated, forKey: "isAuthenticated")
        }
    }

    var isDemoMode: Bool {
        didSet {
            defaults.set(isDemoMode, forKey: "onetake.isDemoMode")
        }
    }

    // MARK: - Current User
    var currentUser: UserProfile?

    // MARK: - Navigation
    var selectedTab: AppTab = .auditions
    var globalSearchQuery: String = ""

    // MARK: - Data Collections (loaded from SwiftData)
    var auditions: [Audition] = []
    var practiceScripts: [PracticeScript] = []

    // MARK: - Diagnostics & Cached Metrics
    var lastPersistenceError: String?
    var cachedLocalStorageMB: Double = 0

    // MARK: - Settings
    var settings: AppSettings

    // MARK: - ModelContext reference
    var modelContext: ModelContext?

    // MARK: - Initializer
    init(
        settings: AppSettings? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.settings = settings ?? AppSettings(defaults: defaults)
        self.defaults = defaults
        self.hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
        self.isAuthenticated = defaults.bool(forKey: "isAuthenticated")
        self.isDemoMode = defaults.bool(forKey: "onetake.isDemoMode")
    }

    // MARK: - Setup
    func configure(with modelContext: ModelContext) {
        self.modelContext = modelContext
        loadData()
    }

    // MARK: - Data Loading
    func loadData() {
        guard let context = modelContext else { return }

        do {
            let auditionDescriptor = FetchDescriptor<Audition>(
                sortBy: [SortDescriptor(\.deadline, order: .forward)]
            )
            auditions = try context.fetch(auditionDescriptor)

            let scriptDescriptor = FetchDescriptor<PracticeScript>(
                sortBy: [SortDescriptor(\.title, order: .forward)]
            )
            practiceScripts = try context.fetch(scriptDescriptor)

            var didMutate = MediaStorage.migratePathsIfNeeded(
                auditions: auditions,
                scripts: practiceScripts
            )

            let profileDescriptor = FetchDescriptor<UserProfile>()
            let profiles = try context.fetch(profileDescriptor)
            currentUser = profiles.first
            if profiles.count > 1 {
                for extraProfile in profiles.dropFirst() {
                    context.delete(extraProfile)
                }
                didMutate = true
            }

            if didMutate {
                try context.save()
            }

            lastPersistenceError = nil
        } catch {
            lastPersistenceError = error.localizedDescription
            print("Failed to load data: \(error)")
        }
    }

    // MARK: - CRUD: Auditions
    func addAudition(_ audition: Audition) {
        modelContext?.insert(audition)
        saveAndReload()
    }

    func deleteAudition(_ audition: Audition) {
        MediaStorage.cleanupFiles(for: audition)
        modelContext?.delete(audition)
        saveAndReload()
    }

    func updateAuditionStatus(_ audition: Audition, to status: AuditionStatus) {
        audition.statusRaw = status.rawValue
        if status == .sent {
            audition.sentDate = Date()
        }
        saveAndReload()
    }

    /// Records a private, expiring delivery link and keeps the Sent transition in
    /// one place so every sharing route has identical list-state behaviour.
    func markAuditionSent(_ audition: Audition, privateLink: PrivateShareLink? = nil) {
        audition.privateShareLink = privateLink
        audition.status = .sent
        audition.sentDate = .now
        saveAndReload()
    }

    func saveChanges() {
        saveAndReload()
    }

    // MARK: - CRUD: Practice Scripts
    func addPracticeScript(_ script: PracticeScript) {
        modelContext?.insert(script)
        saveAndReload()
    }

    func deletePracticeScript(_ script: PracticeScript) {
        MediaStorage.cleanupFiles(for: script)
        modelContext?.delete(script)
        saveAndReload()
    }

    // MARK: - CRUD: User Profile
    func createOrUpdateProfile(
        name: String,
        email: String,
        height: String = "",
        age: Int = 0,
        basedIn: String = "",
        representation: String = "Self-represented"
    ) {
        let existingProfile = currentUser ?? (try? modelContext?.fetch(FetchDescriptor<UserProfile>()).first)
        if let existing = existingProfile {
            existing.name = name
            existing.email = email
            existing.height = height
            existing.age = age
            existing.basedIn = basedIn
            existing.representation = representation
            currentUser = existing
        } else {
            let profile = UserProfile()
            profile.name = name
            profile.email = email
            profile.height = height
            profile.age = age
            profile.basedIn = basedIn
            profile.representation = representation
            modelContext?.insert(profile)
            currentUser = profile
        }
        saveAndReload()
    }

    // MARK: - Demo Mode
    func enterDemoMode(generateMedia: Bool = true) {
        isDemoMode = true
        hasCompletedOnboarding = true
        isAuthenticated = true

        if currentUser == nil {
            let existingProfile = try? modelContext?.fetch(FetchDescriptor<UserProfile>()).first
            if let existingProfile {
                currentUser = existingProfile
            } else {
                let demoUser = MockData.sampleUser
                modelContext?.insert(demoUser)
                currentUser = demoUser
            }
        }

        let existingAuditionIDs = Set(
            ((try? modelContext?.fetch(FetchDescriptor<Audition>())) ?? auditions).map(\.id)
        )
        for demoAudition in MockData.sampleAuditions where !existingAuditionIDs.contains(demoAudition.id) {
            if let context = modelContext {
                context.insert(demoAudition)
            } else {
                auditions.append(demoAudition)
            }
        }

        let existingScriptIDs = Set(
            ((try? modelContext?.fetch(FetchDescriptor<PracticeScript>())) ?? practiceScripts).map(\.id)
        )
        for demoScript in MockData.sampleScripts where !existingScriptIDs.contains(demoScript.id) {
            if let context = modelContext {
                context.insert(demoScript)
            } else {
                practiceScripts.append(demoScript)
            }
        }

        if modelContext != nil {
            saveAndReload()
        }

        Task {
            await refreshLocalStorageUsage()
        }

        if generateMedia {
            Task {
                await generateDemoMediaIfNeeded()
            }
        }
    }

    func exitDemoMode() {
        isDemoMode = false
        removeDemoRecordsAndMedia()
        if modelContext != nil {
            saveAndReload()
        }
        Task {
            await refreshLocalStorageUsage()
        }
    }

    func resetDemoData(generateMedia: Bool = true) {
        removeDemoRecordsAndMedia()
        if modelContext != nil {
            saveAndReload()
        }
        enterDemoMode(generateMedia: generateMedia)
    }

    private func removeDemoRecordsAndMedia() {
        let demoEmail = MockData.sampleUser.email

        if let context = modelContext {
            let allAuditions = (try? context.fetch(FetchDescriptor<Audition>())) ?? auditions
            for audition in allAuditions where MockData.isDemoAudition(audition) {
                MediaStorage.cleanupFiles(for: audition)
                context.delete(audition)
            }

            let allScripts = (try? context.fetch(FetchDescriptor<PracticeScript>())) ?? practiceScripts
            for script in allScripts where MockData.isDemoScript(script) {
                MediaStorage.cleanupFiles(for: script)
                context.delete(script)
            }

            let allProfiles = (try? context.fetch(FetchDescriptor<UserProfile>())) ?? []
            for profile in allProfiles where profile.email == demoEmail {
                context.delete(profile)
            }
        } else {
            for audition in auditions where MockData.isDemoAudition(audition) {
                MediaStorage.cleanupFiles(for: audition)
            }
            auditions.removeAll { MockData.isDemoAudition($0) }

            for script in practiceScripts where MockData.isDemoScript(script) {
                MediaStorage.cleanupFiles(for: script)
            }
            practiceScripts.removeAll { MockData.isDemoScript($0) }
        }

        if currentUser?.email == demoEmail {
            currentUser = nil
        }

        let demoMediaDir = MediaStorage.documentsDirectory.appendingPathComponent("DemoMedia", isDirectory: true)
        if FileManager.default.fileExists(atPath: demoMediaDir.path) {
            try? FileManager.default.removeItem(at: demoMediaDir)
        }
    }

    private func generateDemoMediaIfNeeded() async {
        guard isDemoMode else { return }
        let docsDir = MediaStorage.documentsDirectory

        // Generate headshots and video takes for Heer Ranjha if missing.
        if let heer = auditions.first(where: { $0.id == MockData.heerRanjhaID }) {
            var generatedHeadshots: [HeadshotAsset] = []
            if heer.headshots.isEmpty {
                for angle in HeadshotAngle.allCases {
                    let image = DemoMediaGenerator.renderHeadshotImage(angle: angle.rawValue)
                    if let jpeg = image.jpegData(compressionQuality: 0.85) {
                        let rel = "DemoMedia/heer_headshot_\(angle.rawValue.lowercased()).jpg"
                        if (try? MediaStorage.saveData(jpeg, relativePath: rel, documentsDirectory: docsDir)) != nil {
                            generatedHeadshots.append(
                                HeadshotAsset(
                                    angle: angle,
                                    originalFilePath: rel,
                                    croppedFilePath: rel
                                )
                            )
                        }
                    }
                }
            }

            var generatedSlatePath: String?
            if heer.slateTakes.isEmpty {
                let rel = "DemoMedia/heer_slate.mp4"
                let url = docsDir.appendingPathComponent(rel)
                let ok = await DemoMediaGenerator.writeVideoClip(
                    DemoMediaGenerator.VideoClipSpec(
                        destinationURL: url,
                        headline: "Avery Vance · 5'8\"",
                        subheadline: "Role: Heer · Bramwell Talent",
                        badge: "DEMO SLATE",
                        accentRGB: (0.29, 0.56, 0.96),
                        durationSeconds: 2.0
                    )
                )
                if ok { generatedSlatePath = rel }
            }

            var generatedTakePath: String?
            if heer.auditionTakes.isEmpty {
                let rel = "DemoMedia/heer_take1.mp4"
                let url = docsDir.appendingPathComponent(rel)
                let ok = await DemoMediaGenerator.writeVideoClip(
                    DemoMediaGenerator.VideoClipSpec(
                        destinationURL: url,
                        headline: "Heer Ranjha — Scene 1",
                        subheadline: "Self-Tape Demo · Take 1",
                        badge: "DEMO SELF-TAPE",
                        accentRGB: (0.24, 0.78, 0.58),
                        durationSeconds: 3.0
                    )
                )
                if ok { generatedTakePath = rel }
            }

            var heerCuePaths: [Int: String] = [:]
            for idx in heer.cueLines.indices where heer.cueLines[idx].audioFilePath == nil {
                let rel = "DemoMedia/heer_cue_\(idx).m4a"
                let url = docsDir.appendingPathComponent(rel)
                let ok = await DemoMediaGenerator.writeAudioCue(
                    DemoMediaGenerator.AudioCueSpec(
                        destinationURL: url,
                        frequencyHz: 440,
                        durationSeconds: 1.5
                    )
                )
                if ok { heerCuePaths[idx] = rel }
            }

            guard isDemoMode else {
                let demoDir = docsDir.appendingPathComponent("DemoMedia", isDirectory: true)
                try? FileManager.default.removeItem(at: demoDir)
                return
            }

            if heer.headshots.isEmpty && !generatedHeadshots.isEmpty {
                heer.headshots = generatedHeadshots
            }
            if heer.slateTakes.isEmpty, let slatePath = generatedSlatePath {
                let take = VideoTake(
                    title: "Demo Slate",
                    filePath: slatePath,
                    durationSeconds: 2.0,
                    fileSizeMB: MediaStorage.fileSizeMB(at: slatePath, documentsDirectory: docsDir)
                )
                heer.slateTakes.append(take)
                heer.selectedSlateTakeID = take.id
            }
            if heer.auditionTakes.isEmpty, let takePath = generatedTakePath {
                let take = VideoTake(
                    title: "Take 1",
                    filePath: takePath,
                    durationSeconds: 3.0,
                    fileSizeMB: MediaStorage.fileSizeMB(at: takePath, documentsDirectory: docsDir)
                )
                heer.auditionTakes.append(take)
                heer.selectedAuditionTakeID = take.id
            }
            for (idx, path) in heerCuePaths where idx < heer.cueLines.count {
                heer.cueLines[idx].audioFilePath = path
            }
        }

        // Generate cue audio for The Last Summer if missing.
        if let summer = auditions.first(where: { $0.id == MockData.theLastSummerID }) {
            for idx in summer.cueLines.indices where summer.cueLines[idx].audioFilePath == nil {
                let rel = "DemoMedia/summer_cue_\(idx).m4a"
                let url = docsDir.appendingPathComponent(rel)
                let ok = await DemoMediaGenerator.writeAudioCue(
                    DemoMediaGenerator.AudioCueSpec(
                        destinationURL: url,
                        frequencyHz: 494,
                        durationSeconds: 1.5
                    )
                )
                guard isDemoMode else {
                    let demoDir = docsDir.appendingPathComponent("DemoMedia", isDirectory: true)
                    try? FileManager.default.removeItem(at: demoDir)
                    return
                }
                if ok && idx < summer.cueLines.count {
                    summer.cueLines[idx].audioFilePath = rel
                }
            }
        }

        // Generate cue audio for demo practice scripts if missing.
        for (scriptID, prefix, freq) in [
            (MockData.noahAndAllieID, "noah", 392.0),
            (MockData.nainaID, "naina", 523.25)
        ] {
            if let script = practiceScripts.first(where: { $0.id == scriptID }) {
                for idx in script.cueLines.indices where script.cueLines[idx].audioFilePath == nil {
                    let rel = "DemoMedia/\(prefix)_cue_\(idx).m4a"
                    let url = docsDir.appendingPathComponent(rel)
                    let ok = await DemoMediaGenerator.writeAudioCue(
                        DemoMediaGenerator.AudioCueSpec(
                            destinationURL: url,
                            frequencyHz: freq,
                            durationSeconds: 1.5
                        )
                    )
                    guard isDemoMode else {
                        let demoDir = docsDir.appendingPathComponent("DemoMedia", isDirectory: true)
                        try? FileManager.default.removeItem(at: demoDir)
                        return
                    }
                    if ok && idx < script.cueLines.count {
                        script.cueLines[idx].audioFilePath = rel
                    }
                }
            }
        }

        if isDemoMode {
            if modelContext != nil {
                saveAndReload()
            }
            await refreshLocalStorageUsage()
        }
    }

    // MARK: - Email Resolution
    func resolvedRecipientEmail(for audition: Audition) -> String? {
        // Check audition's direct recipientEmail first
        if !audition.recipientEmail.isEmpty {
            return audition.recipientEmail
        }
        // Fall back to scanning requirements for email pattern
        if let emailRegex = try? Regex("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}") {
            for req in audition.requirements {
                if let match = req.title.firstMatch(of: emailRegex) {
                    return String(req.title[match.range])
                }
            }
        }
        return nil
    }

    // MARK: - Search
    var searchResults: (auditions: [Audition], scripts: [PracticeScript]) {
        guard !globalSearchQuery.isEmpty else {
            return ([], [])
        }
        let query = globalSearchQuery.lowercased()

        let matchedAuditions = auditions.filter { audition in
            audition.projectName.lowercased().contains(query) ||
            audition.roleName.lowercased().contains(query) ||
            audition.statusRaw.lowercased().contains(query)
        }

        let matchedScripts = practiceScripts.filter { script in
            script.title.lowercased().contains(query) ||
            script.rawText.lowercased().contains(query)
        }

        return (matchedAuditions, matchedScripts)
    }

    // MARK: - Storage Metrics
    var totalStorageUsedMB: Double {
        var total = 0.0
        for audition in auditions {
            for headshot in audition.headshots {
                total += MediaStorage.fileSizeMB(at: headshot.originalFilePath)
                if headshot.croppedFilePath != headshot.originalFilePath {
                    total += MediaStorage.fileSizeMB(at: headshot.croppedFilePath)
                }
            }
            for take in audition.slateTakes + audition.auditionTakes {
                if MediaStorage.fileExists(at: take.filePath) {
                    total += MediaStorage.fileSizeMB(at: take.filePath)
                } else if take.fileSizeMB > 0 {
                    total += take.fileSizeMB
                }
            }
            for cue in audition.cueLines {
                total += MediaStorage.fileSizeMB(at: cue.audioFilePath)
            }
        }
        for script in practiceScripts {
            for cue in script.cueLines {
                total += MediaStorage.fileSizeMB(at: cue.audioFilePath)
            }
            for session in script.sessions {
                total += MediaStorage.fileSizeMB(at: session.audioFilePath)
            }
        }
        return total
    }

    /// Non-blocking cached filesystem usage for the app's Documents directory.
    var localAppDataUsedMB: Double {
        cachedLocalStorageMB
    }

    func refreshLocalStorageUsage() async {
        let docsDir = MediaStorage.documentsDirectory
        let megabytes = await Task.detached(priority: .utility) { () -> Double in
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(
                at: docsDir,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
            ) else {
                return 0
            }
            var bytes: Int64 = 0
            while let url = enumerator.nextObject() as? URL {
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                      values.isRegularFile == true else {
                    continue
                }
                bytes += Int64(values.fileSize ?? 0)
            }
            return Double(bytes) / 1_048_576.0
        }.value
        cachedLocalStorageMB = megabytes
    }

    func deleteAllLocalData() {
        if let context = modelContext {
            let allAuditions = (try? context.fetch(FetchDescriptor<Audition>())) ?? auditions
            for audition in allAuditions {
                MediaStorage.cleanupFiles(for: audition)
                context.delete(audition)
            }

            let allScripts = (try? context.fetch(FetchDescriptor<PracticeScript>())) ?? practiceScripts
            for script in allScripts {
                MediaStorage.cleanupFiles(for: script)
                context.delete(script)
            }

            let allProfiles = (try? context.fetch(FetchDescriptor<UserProfile>())) ?? []
            for profile in allProfiles {
                context.delete(profile)
            }
        } else {
            for audition in auditions {
                MediaStorage.cleanupFiles(for: audition)
            }
            for script in practiceScripts {
                MediaStorage.cleanupFiles(for: script)
            }
        }

        let demoMediaDir = MediaStorage.documentsDirectory.appendingPathComponent("DemoMedia", isDirectory: true)
        if FileManager.default.fileExists(atPath: demoMediaDir.path) {
            try? FileManager.default.removeItem(at: demoMediaDir)
        }

        settings.resetToDefaults()
        isDemoMode = false
        cachedLocalStorageMB = 0
        currentUser = nil
        auditions = []
        practiceScripts = []

        if modelContext != nil {
            saveAndReload()
        }
    }

    var activeAuditionsCount: Int {
        auditions.filter { $0.status == .active }.count
    }

    var sentAuditionsCount: Int {
        auditions.filter { $0.status == .sent }.count
    }

    // MARK: - Persistence Helpers
    private func saveAndReload() {
        do {
            try modelContext?.save()
            lastPersistenceError = nil
            loadData()
        } catch {
            lastPersistenceError = error.localizedDescription
            print("Failed to save: \(error)")
        }
    }

    // MARK: - Logout
    func logout() {
        if isDemoMode {
            exitDemoMode()
        }
        isAuthenticated = false
        hasCompletedOnboarding = false
        currentUser = nil
        auditions = []
        practiceScripts = []
    }
}
