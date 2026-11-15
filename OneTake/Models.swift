import SwiftUI
import SwiftData

// MARK: - Enums

enum AppTab: String, Codable, Hashable {
    case auditions = "Auditions"
    case practice = "Practice"
    case profile = "Profile"
}

enum AuditionStatus: String, Codable, Hashable, CaseIterable {
    case active = "Active"
    case sent = "Sent"
}

enum ProductionType: String, Codable, Hashable, CaseIterable {
    case featureFilm = "Feature Film"
    case series = "Series"
    case adFilm = "Ad Film"
    case shortFilm = "Short Film"
    case webSeries = "Web Series"
    case theater = "Theater"
}

enum HeadshotAngle: String, Codable, Hashable, CaseIterable {
    case front = "Front"
    case left = "Left"
    case right = "Right"
}

enum HeadshotAspectRatio: String, Codable, Hashable, CaseIterable {
    case ratio4x5 = "4:5"
    case ratio2x3 = "2:3"
    case ratio1x1 = "1:1"
    case free = "Free"
}

enum HeadshotCropPreset: String, Codable, Hashable, CaseIterable {
    case cardSlotFit = "Card Slot Fit"
    case theatrical = "Theatrical (4:5)"
    case commercial = "Commercial (3:4)"
    case square = "Square (1:1)"
    case tightCloseUp = "Tight Close-Up"
    case headAndShoulders = "Head & Shoulders"
}

enum ScriptLanguage: String, Codable, Hashable, CaseIterable {
    case english = "English"
    case hindi = "Hindi"
}

enum HelpLevel: String, Codable, Hashable, CaseIterable {
    case nothing = "Nothing"
    case letters = "First Letters"
    case gaps = "Fill Gaps"
    case fullScript = "Full Script"
}

enum AnnotationKind: String, Codable, Hashable, CaseIterable {
    case normal = "Normal"
    case skipped = "Skipped"
    case forgot = "Forgot"
    case hesitated = "Hesitated"
    case notInScript = "Not In Script"
    case cue = "Cue"
}

enum CueTriggerMode: String, Codable, Hashable, CaseIterable {
    case afterMyLine = "After My Line (2s)"
    case fixedDelay = "Fixed Delay"
}

enum TeleprompterTextSize: String, Codable, Hashable, CaseIterable {
    case regular = "Regular"
    case large = "Large"
    case bigPrint = "Big Print"
}

enum VideoQuality: String, Codable, Hashable, CaseIterable {
    case p720 = "720p"
    case p1080 = "1080p"
}

// MARK: - Codable Structs

nonisolated struct SubmissionRequirement: Codable, Sendable, Hashable, Identifiable {
    var id: UUID = UUID()
    var title: String
    var isCompleted: Bool = false
}

nonisolated struct HeadshotAsset: Codable, Sendable, Hashable {
    var angle: HeadshotAngle
    var originalFilePath: String
    var croppedFilePath: String
    var aspectRatio: HeadshotAspectRatio = .ratio4x5
    var cropPreset: HeadshotCropPreset? = nil
    var lightingPassed: Bool = false
    var backgroundPassed: Bool = false
    var alignmentPassed: Bool = false
    var eyeLevelPassed: Bool = false
    var capturedAt: Date = .now
}

nonisolated struct VideoTake: Codable, Sendable, Hashable, Identifiable {
    var id: UUID = UUID()
    var title: String
    var filePath: String
    var durationSeconds: Double
    var fileSizeMB: Double
    var aspectRatioString: String = "16:9"
    var isPortrait: Bool = false
    var isMirrored: Bool = false
    var noiseCleaned: Bool = false
    var trimStartSeconds: Double = 0
    var trimEndSeconds: Double = 0
    var lightingPassed: Bool = false
    var framingPassed: Bool = false
    var soundPassed: Bool = false
    var createdAt: Date = .now
}

nonisolated struct CueLine: Codable, Sendable, Hashable, Identifiable {
    var id: UUID = UUID()
    var orderIndex: Int
    var speaker: String
    var cueText: String
    var precedingActorLine: String = ""
    var audioFilePath: String? = nil
    var durationSeconds: Double = 0
    var isAutoDetected: Bool = false
}

nonisolated struct ValidationRules: Codable, Sendable, Hashable {
    var isFromNotice: Bool = false
    var requiredHeadshotRatio: HeadshotAspectRatio = .ratio4x5
    var maxSlateSeconds: Double = 45.0
    var maxClipSeconds: Double = 180.0
    var requiredPortrait: Bool? = nil
    var fileNamePattern: String = "ActorName_Role"
    var maxPerClipSizeMB: Double = 100.0
}

nonisolated struct PrivateShareLink: Codable, Sendable, Hashable {
    var urlString: String
    var createdAt: Date = .now
    var expiresAt: Date
}

nonisolated struct DeliveryAnnotation: Codable, Sendable, Hashable, Identifiable {
    var id: UUID = UUID()
    var text: String
    var kind: AnnotationKind = .normal
}

/// Timestamped recognizer output retained with a saved practice run.
nonisolated struct RecognizedPracticeWord: Codable, Sendable, Hashable, Identifiable {
    var id: UUID = UUID()
    var text: String
    var timestamp: Double
    var duration: Double
}

nonisolated struct PracticeSession: Codable, Sendable, Hashable, Identifiable {
    var id: UUID = UUID()
    var sessionNumber: Int
    var date: Date = Date()
    var durationSeconds: Double = 0
    var helpLevelRaw: String = HelpLevel.nothing.rawValue
    var skippedCount: Int = 0
    var forgotCount: Int = 0
    var hesitatedCount: Int = 0
    var notInScriptCount: Int = 0
    var annotations: [DeliveryAnnotation] = []
    var transcript: String = ""
    var recognizedWords: [RecognizedPracticeWord] = []
    /// Token IDs are a Codable replacement for String.Index ranges.
    var clueTokenIDs: [Int] = []
    var audioFilePath: String? = nil

    var helpLevel: HelpLevel {
        get { HelpLevel(rawValue: helpLevelRaw) ?? .nothing }
        set { helpLevelRaw = newValue.rawValue }
    }
}

// MARK: - SwiftData @Model Classes

@Model
final class UserProfile {
    var id: UUID = UUID()
    var name: String = ""
    var email: String = ""
    var height: String = ""
    var age: Int = 0
    var basedIn: String = ""
    var representation: String = "Self-represented"
    var previousWork: [String] = []
    @Attribute(.externalStorage)
    var avatarImageData: Data? = nil

    init(
        id: UUID = UUID(),
        name: String = "",
        email: String = "",
        height: String = "",
        age: Int = 0,
        basedIn: String = "",
        representation: String = "Self-represented",
        previousWork: [String] = [],
        avatarImageData: Data? = nil
    ) {
        self.id = id
        self.name = name
        self.email = email
        self.height = height
        self.age = age
        self.basedIn = basedIn
        self.representation = representation
        self.previousWork = previousWork
        self.avatarImageData = avatarImageData
    }
}

@Model
final class Audition {
    var id: UUID = UUID()
    var projectName: String = ""
    var productionType: String = ProductionType.featureFilm.rawValue
    var roleName: String = ""
    var roleDescription: String = ""
    var deadline: Date = Date()
    var reminderOffsetMinutes: Int = 60
    var recipientEmail: String = ""
    var statusRaw: String = AuditionStatus.active.rawValue
    var requirements: [SubmissionRequirement] = []
    var scriptText: String? = nil
    var scriptFileName: String? = nil

    /// When audition.scriptText (trimmed) is empty, scriptLines is strictly empty ([]).
    /// No fallback to rawCastingCallText, casting call notes, or character descriptions.
    var scriptLines: [String] {
        guard let script = scriptText?.trimmingCharacters(in: .whitespacesAndNewlines), !script.isEmpty else {
            return []
        }
        return script
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
    var headshots: [HeadshotAsset] = []
    var slateTakes: [VideoTake] = []
    var selectedSlateTakeID: UUID? = nil
    var auditionTakes: [VideoTake] = []
    var selectedAuditionTakeID: UUID? = nil
    var cueLines: [CueLine] = []
    var validationRules: ValidationRules = ValidationRules()
    var privateShareLink: PrivateShareLink? = nil
    var sentDate: Date? = nil
    var createdAt: Date = Date()

    var status: AuditionStatus {
        get { AuditionStatus(rawValue: statusRaw) ?? .active }
        set { statusRaw = newValue.rawValue }
    }

    var production: ProductionType {
        get { ProductionType(rawValue: productionType) ?? .featureFilm }
        set { productionType = newValue.rawValue }
    }

    func headshot(for angle: HeadshotAngle) -> HeadshotAsset? {
        headshots.first { $0.angle == angle }
    }

    var isOverdue: Bool {
        deadline < Date.now && status == .active
    }

    var daysUntilDeadline: Int {
        Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: .now), to: Calendar.current.startOfDay(for: deadline)).day ?? 0
    }

    var selectedSlateTake: VideoTake? {
        slateTakes.first { $0.id == selectedSlateTakeID } ?? slateTakes.last
    }

    var selectedAuditionTake: VideoTake? {
        auditionTakes.first { $0.id == selectedAuditionTakeID } ?? auditionTakes.last
    }

    var isHeadshotsReady: Bool {
        headshots.count >= 3
    }

    var isSlateReady: Bool {
        selectedSlateTake != nil
    }

    var isAuditionReady: Bool {
        selectedAuditionTake != nil
    }

    var packageReadyCount: Int {
        var count = 0
        if isHeadshotsReady { count += 1 }
        if isSlateReady { count += 1 }
        if isAuditionReady { count += 1 }
        return count
    }

    init(
        id: UUID = UUID(),
        projectName: String = "",
        productionType: String = ProductionType.featureFilm.rawValue,
        roleName: String = "",
        roleDescription: String = "",
        deadline: Date = Date(),
        reminderOffsetMinutes: Int = 60,
        recipientEmail: String = "",
        statusRaw: String = AuditionStatus.active.rawValue,
        requirements: [SubmissionRequirement] = [],
        scriptText: String? = nil,
        scriptFileName: String? = nil,
        headshots: [HeadshotAsset] = [],
        slateTakes: [VideoTake] = [],
        selectedSlateTakeID: UUID? = nil,
        auditionTakes: [VideoTake] = [],
        selectedAuditionTakeID: UUID? = nil,
        cueLines: [CueLine] = [],
        validationRules: ValidationRules = ValidationRules(),
        privateShareLink: PrivateShareLink? = nil,
        sentDate: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.projectName = projectName
        self.productionType = productionType
        self.roleName = roleName
        self.roleDescription = roleDescription
        self.deadline = deadline
        self.reminderOffsetMinutes = reminderOffsetMinutes
        self.recipientEmail = recipientEmail
        self.statusRaw = statusRaw
        self.requirements = requirements
        self.scriptText = scriptText
        self.scriptFileName = scriptFileName
        self.headshots = headshots
        self.slateTakes = slateTakes
        self.selectedSlateTakeID = selectedSlateTakeID
        self.auditionTakes = auditionTakes
        self.selectedAuditionTakeID = selectedAuditionTakeID
        self.cueLines = cueLines
        self.validationRules = validationRules
        self.privateShareLink = privateShareLink
        self.sentDate = sentDate
        self.createdAt = createdAt
    }
}

@Model
final class PracticeScript {
    var id: UUID = UUID()
    var title: String = ""
    var sourceAuditionID: UUID? = nil
    var languageRaw: String = ScriptLanguage.english.rawValue
    var rawText: String = ""
    var cueLines: [CueLine] = []
    var sessions: [PracticeSession] = []
    var lastPracticedAt: Date? = nil

    var language: ScriptLanguage {
        get { ScriptLanguage(rawValue: languageRaw) ?? .english }
        set { languageRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        title: String = "",
        sourceAuditionID: UUID? = nil,
        languageRaw: String = ScriptLanguage.english.rawValue,
        rawText: String = "",
        cueLines: [CueLine] = [],
        sessions: [PracticeSession] = [],
        lastPracticedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.sourceAuditionID = sourceAuditionID
        self.languageRaw = languageRaw
        self.rawText = rawText
        self.cueLines = cueLines
        self.sessions = sessions
        self.lastPracticedAt = lastPracticedAt
    }
}

// MARK: - AppSettings (UserDefaults-backed)

@Observable
final class AppSettings {

    private let defaults = UserDefaults.standard
    private let prefix = "onetake."

    // MARK: Private Helpers

    private func key(_ name: String) -> String { prefix + name }

    private func getValue<T>(_ name: String, fallback: T) -> T {
        let k = key(name)
        guard defaults.object(forKey: k) != nil else { return fallback }
        let obj = defaults.object(forKey: k)
        return (obj as? T) ?? fallback
    }

    private func setValue<T>(_ name: String, value: T) {
        defaults.set(value, forKey: key(name))
    }

    // MARK: Recording

    var countdownSeconds: Int {
        get { getValue("countdownSeconds", fallback: 3) }
        set { setValue("countdownSeconds", value: newValue) }
    }

    var autoTrimSilence: Bool {
        get { getValue("autoTrimSilence", fallback: false) }
        set { setValue("autoTrimSilence", value: newValue) }
    }

    var noiseReductionDefault: Bool {
        get { getValue("noiseReductionDefault", fallback: false) }
        set { setValue("noiseReductionDefault", value: newValue) }
    }

    // MARK: Cue

    var cueTriggerModeRaw: String {
        get { getValue("cueTriggerModeRaw", fallback: CueTriggerMode.afterMyLine.rawValue) }
        set { setValue("cueTriggerModeRaw", value: newValue) }
    }

    var cueTriggerMode: CueTriggerMode {
        get { CueTriggerMode(rawValue: cueTriggerModeRaw) ?? .afterMyLine }
        set { cueTriggerModeRaw = newValue.rawValue }
    }

    var cueDelaySeconds: Double {
        get { getValue("cueDelaySeconds", fallback: 2.0) }
        set { setValue("cueDelaySeconds", value: newValue) }
    }

    var cueVolume: Double {
        get { getValue("cueVolume", fallback: 0.8) }
        set { setValue("cueVolume", value: newValue) }
    }

    // MARK: Teleprompter

    var teleprompterTextSizeRaw: String {
        get { getValue("teleprompterTextSizeRaw", fallback: TeleprompterTextSize.regular.rawValue) }
        set { setValue("teleprompterTextSizeRaw", value: newValue) }
    }

    var teleprompterTextSize: TeleprompterTextSize {
        get { TeleprompterTextSize(rawValue: teleprompterTextSizeRaw) ?? .regular }
        set { teleprompterTextSizeRaw = newValue.rawValue }
    }

    var teleprompterScrollSpeed: Double {
        get { getValue("teleprompterScrollSpeed", fallback: 1.0) }
        set { setValue("teleprompterScrollSpeed", value: newValue) }
    }

    // MARK: Camera

    var mirrorFrontCamera: Bool {
        get { getValue("mirrorFrontCamera", fallback: true) }
        set { setValue("mirrorFrontCamera", value: newValue) }
    }

    var videoQualityRaw: String {
        get { getValue("videoQualityRaw", fallback: VideoQuality.p1080.rawValue) }
        set { setValue("videoQualityRaw", value: newValue) }
    }

    var videoQuality: VideoQuality {
        get { VideoQuality(rawValue: videoQualityRaw) ?? .p1080 }
        set { videoQualityRaw = newValue.rawValue }
    }

    var frameRate: Int {
        get { getValue("frameRate", fallback: 30) }
        set { setValue("frameRate", value: newValue) }
    }

    // MARK: Notifications

    var notifyAuditions: Bool {
        get { getValue("notifyAuditions", fallback: true) }
        set { setValue("notifyAuditions", value: newValue) }
    }

    var notifySubmissions: Bool {
        get { getValue("notifySubmissions", fallback: true) }
        set { setValue("notifySubmissions", value: newValue) }
    }

    var notifyPractice: Bool {
        get { getValue("notifyPractice", fallback: true) }
        set { setValue("notifyPractice", value: newValue) }
    }

    var notifyProductUpdates: Bool {
        get { getValue("notifyProductUpdates", fallback: false) }
        set { setValue("notifyProductUpdates", value: newValue) }
    }
}
