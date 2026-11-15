import SwiftUI
import SwiftData

@Observable
final class AppState {
    // MARK: - App Lifecycle
    var hasCompletedOnboarding: Bool = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
        didSet {
            UserDefaults.standard.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding")
        }
    }
    
    var isAuthenticated: Bool = UserDefaults.standard.bool(forKey: "isAuthenticated") {
        didSet {
            UserDefaults.standard.set(isAuthenticated, forKey: "isAuthenticated")
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
    
    // MARK: - Settings
    let settings = AppSettings()
    
    // MARK: - ModelContext reference
    var modelContext: ModelContext?
    
    // MARK: - Initializer
    init() {}
    
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
            
            let profileDescriptor = FetchDescriptor<UserProfile>()
            currentUser = try context.fetch(profileDescriptor).first
        } catch {
            print("Failed to load data: \(error)")
        }
    }
    
    // MARK: - CRUD: Auditions
    func addAudition(_ audition: Audition) {
        modelContext?.insert(audition)
        saveAndReload()
    }
    
    func deleteAudition(_ audition: Audition) {
        // Clean up local files
        cleanupFiles(for: audition)
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
        modelContext?.delete(script)
        saveAndReload()
    }
    
    // MARK: - CRUD: User Profile
    func createOrUpdateProfile(name: String, email: String, height: String = "", age: Int = 0, basedIn: String = "", representation: String = "Self-represented") {
        if let existing = currentUser {
            existing.name = name
            existing.email = email
            existing.height = height
            existing.age = age
            existing.basedIn = basedIn
            existing.representation = representation
        } else {
            let profile = UserProfile()
            profile.name = name
            profile.email = email
            profile.height = height
            profile.age = age
            profile.basedIn = basedIn
            profile.representation = representation
            modelContext?.insert(profile)
        }
        saveAndReload()
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
    
    // MARK: - File Cleanup
    private func cleanupFiles(for audition: Audition) {
        let fm = FileManager.default
        
        // Clean headshot files
        for headshot in audition.headshots {
            try? fm.removeItem(atPath: headshot.originalFilePath)
            try? fm.removeItem(atPath: headshot.croppedFilePath)
        }
        
        // Clean video takes
        for take in audition.slateTakes + audition.auditionTakes {
            try? fm.removeItem(atPath: take.filePath)
        }
        
        // Clean cue audio files
        for cue in audition.cueLines {
            if let audioPath = cue.audioFilePath {
                try? fm.removeItem(atPath: audioPath)
            }
        }
    }
    
    // MARK: - Storage Metrics
    var totalStorageUsedMB: Double {
        let slateMB = auditions.flatMap { $0.slateTakes }.reduce(0.0) { $0 + $1.fileSizeMB }
        let auditionMB = auditions.flatMap { $0.auditionTakes }.reduce(0.0) { $0 + $1.fileSizeMB }
        return slateMB + auditionMB
    }

    /// Filesystem usage complements the take metadata, which can be approximate
    /// while a recording is still being processed.
    var localAppDataUsedMB: Double {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let documents else { return 0 }
        let enumerator = FileManager.default.enumerator(at: documents, includingPropertiesForKeys: [.fileSizeKey])
        var bytes: Int64 = 0
        while let url = enumerator?.nextObject() as? URL {
            bytes += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return Double(bytes) / 1_048_576
    }

    func deleteAllLocalData() {
        guard let context = modelContext else { return }
        auditions.forEach { cleanupFiles(for: $0); context.delete($0) }
        practiceScripts.forEach { context.delete($0) }
        if let currentUser { context.delete(currentUser) }
        saveAndReload()
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
            loadData()
        } catch {
            print("Failed to save: \(error)")
        }
    }
    
    // MARK: - Logout
    func logout() {
        isAuthenticated = false
        hasCompletedOnboarding = false
        currentUser = nil
        auditions = []
        practiceScripts = []
    }
}
