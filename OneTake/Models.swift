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

nonisolated enum PracticeDisplayMode: String, Codable, Hashable, CaseIterable, Identifiable, Sendable {
    case full = "Full Script"
    case firstLetters = "First Letters"
    case gaps = "Fill Gaps"
    case hideLines = "Hide Lines"

    public var id: String { rawValue }

    public var helpLevel: HelpLevel {
        switch self {
        case .full: return .fullScript
        case .firstLetters: return .letters
        case .gaps: return .gaps
        case .hideLines: return .nothing
        }
    }

    public var shortTitle: String {
        switch self {
        case .full: return "Full"
        case .firstLetters: return "Letters"
        case .gaps: return "Gaps"
        case .hideLines: return "Hidden"
        }
    }

    public var instruction: String {
        switch self {
        case .full:
            return "Read your lines naturally to build familiarity."
        case .firstLetters:
            return "Only the first letter of each word is shown. Tap any word to reveal."
        case .gaps:
            return "Key words are blanked out. Tap any blank to reveal."
        case .hideLines:
            return "Your lines are hidden. Tap any hidden line to reveal."
        }
    }
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

nonisolated enum VideoQuality: String, Codable, Hashable, CaseIterable, Sendable {
    case p720 = "720p"
    case p1080 = "1080p"
}

// MARK: - Codable Structs

nonisolated struct SubmissionRequirement: Codable, Sendable, Hashable, Identifiable {
    var id: UUID = UUID()
    var title: String
    var isCompleted: Bool = false

    init(
        id: UUID = UUID(),
        title: String,
        isCompleted: Bool = false
    ) {
        self.id = id
        self.title = title
        self.isCompleted = isCompleted
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        isCompleted = try c.decodeIfPresent(Bool.self, forKey: .isCompleted) ?? false
    }
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

    var originalURL: URL? { MediaStorage.resolveURL(for: originalFilePath) }
    var croppedURL: URL? { MediaStorage.resolveURL(for: croppedFilePath) }

    init(
        angle: HeadshotAngle,
        originalFilePath: String,
        croppedFilePath: String,
        aspectRatio: HeadshotAspectRatio = .ratio4x5,
        cropPreset: HeadshotCropPreset? = nil,
        lightingPassed: Bool = false,
        backgroundPassed: Bool = false,
        alignmentPassed: Bool = false,
        eyeLevelPassed: Bool = false,
        capturedAt: Date = .now
    ) {
        self.angle = angle
        self.originalFilePath = originalFilePath
        self.croppedFilePath = croppedFilePath
        self.aspectRatio = aspectRatio
        self.cropPreset = cropPreset
        self.lightingPassed = lightingPassed
        self.backgroundPassed = backgroundPassed
        self.alignmentPassed = alignmentPassed
        self.eyeLevelPassed = eyeLevelPassed
        self.capturedAt = capturedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        angle = try c.decodeIfPresent(HeadshotAngle.self, forKey: .angle) ?? .front
        originalFilePath = try c.decodeIfPresent(String.self, forKey: .originalFilePath) ?? ""
        croppedFilePath = try c.decodeIfPresent(String.self, forKey: .croppedFilePath) ?? ""
        aspectRatio = try c.decodeIfPresent(HeadshotAspectRatio.self, forKey: .aspectRatio) ?? .ratio4x5
        cropPreset = try c.decodeIfPresent(HeadshotCropPreset.self, forKey: .cropPreset)
        lightingPassed = try c.decodeIfPresent(Bool.self, forKey: .lightingPassed) ?? false
        backgroundPassed = try c.decodeIfPresent(Bool.self, forKey: .backgroundPassed) ?? false
        alignmentPassed = try c.decodeIfPresent(Bool.self, forKey: .alignmentPassed) ?? false
        eyeLevelPassed = try c.decodeIfPresent(Bool.self, forKey: .eyeLevelPassed) ?? false
        capturedAt = try c.decodeIfPresent(Date.self, forKey: .capturedAt) ?? .now
    }
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

    var fileURL: URL? { MediaStorage.resolveURL(for: filePath) }

    init(
        id: UUID = UUID(),
        title: String,
        filePath: String,
        durationSeconds: Double,
        fileSizeMB: Double,
        aspectRatioString: String = "16:9",
        isPortrait: Bool = false,
        isMirrored: Bool = false,
        noiseCleaned: Bool = false,
        trimStartSeconds: Double = 0,
        trimEndSeconds: Double = 0,
        lightingPassed: Bool = false,
        framingPassed: Bool = false,
        soundPassed: Bool = false,
        createdAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.filePath = filePath
        self.durationSeconds = durationSeconds
        self.fileSizeMB = fileSizeMB
        self.aspectRatioString = aspectRatioString
        self.isPortrait = isPortrait
        self.isMirrored = isMirrored
        self.noiseCleaned = noiseCleaned
        self.trimStartSeconds = trimStartSeconds
        self.trimEndSeconds = trimEndSeconds
        self.lightingPassed = lightingPassed
        self.framingPassed = framingPassed
        self.soundPassed = soundPassed
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        filePath = try c.decodeIfPresent(String.self, forKey: .filePath) ?? ""
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
        fileSizeMB = try c.decodeIfPresent(Double.self, forKey: .fileSizeMB) ?? 0
        aspectRatioString = try c.decodeIfPresent(String.self, forKey: .aspectRatioString) ?? "16:9"
        isPortrait = try c.decodeIfPresent(Bool.self, forKey: .isPortrait) ?? false
        isMirrored = try c.decodeIfPresent(Bool.self, forKey: .isMirrored) ?? false
        noiseCleaned = try c.decodeIfPresent(Bool.self, forKey: .noiseCleaned) ?? false
        trimStartSeconds = try c.decodeIfPresent(Double.self, forKey: .trimStartSeconds) ?? 0
        trimEndSeconds = try c.decodeIfPresent(Double.self, forKey: .trimEndSeconds) ?? 0
        lightingPassed = try c.decodeIfPresent(Bool.self, forKey: .lightingPassed) ?? false
        framingPassed = try c.decodeIfPresent(Bool.self, forKey: .framingPassed) ?? false
        soundPassed = try c.decodeIfPresent(Bool.self, forKey: .soundPassed) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
    }
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

    var audioURL: URL? { MediaStorage.resolveURL(for: audioFilePath) }

    init(
        id: UUID = UUID(),
        orderIndex: Int,
        speaker: String,
        cueText: String,
        precedingActorLine: String = "",
        audioFilePath: String? = nil,
        durationSeconds: Double = 0,
        isAutoDetected: Bool = false
    ) {
        self.id = id
        self.orderIndex = orderIndex
        self.speaker = speaker
        self.cueText = cueText
        self.precedingActorLine = precedingActorLine
        self.audioFilePath = audioFilePath
        self.durationSeconds = durationSeconds
        self.isAutoDetected = isAutoDetected
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        orderIndex = try c.decodeIfPresent(Int.self, forKey: .orderIndex) ?? 0
        speaker = try c.decodeIfPresent(String.self, forKey: .speaker) ?? ""
        cueText = try c.decodeIfPresent(String.self, forKey: .cueText) ?? ""
        precedingActorLine = try c.decodeIfPresent(String.self, forKey: .precedingActorLine) ?? ""
        audioFilePath = try c.decodeIfPresent(String.self, forKey: .audioFilePath)
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
        isAutoDetected = try c.decodeIfPresent(Bool.self, forKey: .isAutoDetected) ?? false
    }
}

nonisolated struct ValidationRules: Codable, Sendable, Hashable {
    var isFromNotice: Bool = false
    var requiredHeadshotRatio: HeadshotAspectRatio = .ratio4x5
    var maxSlateSeconds: Double = 45.0
    var maxClipSeconds: Double = 180.0
    var requiredPortrait: Bool? = nil
    var fileNamePattern: String = "ActorName_Role"
    var maxPerClipSizeMB: Double = 100.0

    init(
        isFromNotice: Bool = false,
        requiredHeadshotRatio: HeadshotAspectRatio = .ratio4x5,
        maxSlateSeconds: Double = 45.0,
        maxClipSeconds: Double = 180.0,
        requiredPortrait: Bool? = nil,
        fileNamePattern: String = "ActorName_Role",
        maxPerClipSizeMB: Double = 100.0
    ) {
        self.isFromNotice = isFromNotice
        self.requiredHeadshotRatio = requiredHeadshotRatio
        self.maxSlateSeconds = maxSlateSeconds
        self.maxClipSeconds = maxClipSeconds
        self.requiredPortrait = requiredPortrait
        self.fileNamePattern = fileNamePattern
        self.maxPerClipSizeMB = maxPerClipSizeMB
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isFromNotice = try c.decodeIfPresent(Bool.self, forKey: .isFromNotice) ?? false
        requiredHeadshotRatio = try c.decodeIfPresent(HeadshotAspectRatio.self, forKey: .requiredHeadshotRatio) ?? .ratio4x5
        maxSlateSeconds = try c.decodeIfPresent(Double.self, forKey: .maxSlateSeconds) ?? 45.0
        maxClipSeconds = try c.decodeIfPresent(Double.self, forKey: .maxClipSeconds) ?? 180.0
        requiredPortrait = try c.decodeIfPresent(Bool.self, forKey: .requiredPortrait)
        fileNamePattern = try c.decodeIfPresent(String.self, forKey: .fileNamePattern) ?? "ActorName_Role"
        maxPerClipSizeMB = try c.decodeIfPresent(Double.self, forKey: .maxPerClipSizeMB) ?? 100.0
    }
}

nonisolated struct PrivateShareLink: Codable, Sendable, Hashable {
    var urlString: String
    var createdAt: Date = .now
    var expiresAt: Date

    init(
        urlString: String,
        createdAt: Date = .now,
        expiresAt: Date
    ) {
        self.urlString = urlString
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        urlString = try c.decodeIfPresent(String.self, forKey: .urlString) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt) ?? .now
    }
}

nonisolated struct DeliveryAnnotation: Codable, Sendable, Hashable, Identifiable {
    var id: UUID = UUID()
    var text: String
    var kind: AnnotationKind = .normal

    init(
        id: UUID = UUID(),
        text: String,
        kind: AnnotationKind = .normal
    ) {
        self.id = id
        self.text = text
        self.kind = kind
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        kind = try c.decodeIfPresent(AnnotationKind.self, forKey: .kind) ?? .normal
    }
}

/// Timestamped recognizer output retained with a saved practice run.
nonisolated struct RecognizedPracticeWord: Codable, Sendable, Hashable, Identifiable {
    var id: UUID = UUID()
    var text: String
    var timestamp: Double
    var duration: Double

    init(
        id: UUID = UUID(),
        text: String,
        timestamp: Double,
        duration: Double
    ) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.duration = duration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        timestamp = try c.decodeIfPresent(Double.self, forKey: .timestamp) ?? 0
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
    }
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

    var audioURL: URL? { MediaStorage.resolveURL(for: audioFilePath) }

    var helpLevel: HelpLevel {
        get { HelpLevel(rawValue: helpLevelRaw) ?? .nothing }
        set { helpLevelRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        sessionNumber: Int,
        date: Date = Date(),
        durationSeconds: Double = 0,
        helpLevelRaw: String = HelpLevel.nothing.rawValue,
        skippedCount: Int = 0,
        forgotCount: Int = 0,
        hesitatedCount: Int = 0,
        notInScriptCount: Int = 0,
        annotations: [DeliveryAnnotation] = [],
        transcript: String = "",
        recognizedWords: [RecognizedPracticeWord] = [],
        clueTokenIDs: [Int] = [],
        audioFilePath: String? = nil
    ) {
        self.id = id
        self.sessionNumber = sessionNumber
        self.date = date
        self.durationSeconds = durationSeconds
        self.helpLevelRaw = helpLevelRaw
        self.skippedCount = skippedCount
        self.forgotCount = forgotCount
        self.hesitatedCount = hesitatedCount
        self.notInScriptCount = notInScriptCount
        self.annotations = annotations
        self.transcript = transcript
        self.recognizedWords = recognizedWords
        self.clueTokenIDs = clueTokenIDs
        self.audioFilePath = audioFilePath
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        sessionNumber = try c.decodeIfPresent(Int.self, forKey: .sessionNumber) ?? 0
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
        helpLevelRaw = try c.decodeIfPresent(String.self, forKey: .helpLevelRaw) ?? HelpLevel.nothing.rawValue
        skippedCount = try c.decodeIfPresent(Int.self, forKey: .skippedCount) ?? 0
        forgotCount = try c.decodeIfPresent(Int.self, forKey: .forgotCount) ?? 0
        hesitatedCount = try c.decodeIfPresent(Int.self, forKey: .hesitatedCount) ?? 0
        notInScriptCount = try c.decodeIfPresent(Int.self, forKey: .notInScriptCount) ?? 0
        annotations = try c.decodeIfPresent([DeliveryAnnotation].self, forKey: .annotations) ?? []
        transcript = try c.decodeIfPresent(String.self, forKey: .transcript) ?? ""
        recognizedWords = try c.decodeIfPresent([RecognizedPracticeWord].self, forKey: .recognizedWords) ?? []
        clueTokenIDs = try c.decodeIfPresent([Int].self, forKey: .clueTokenIDs) ?? []
        audioFilePath = try c.decodeIfPresent(String.self, forKey: .audioFilePath)
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
        if let id = selectedSlateTakeID {
            return slateTakes.first { $0.id == id }
        }
        return slateTakes.last
    }

    var selectedAuditionTake: VideoTake? {
        if let id = selectedAuditionTakeID {
            return auditionTakes.first { $0.id == id }
        }
        return auditionTakes.last
    }

    var isHeadshotsReady: Bool {
        HeadshotAngle.allCases.allSatisfy { angle in
            guard let h = headshot(for: angle) else { return false }
            return MediaStorage.fileExists(at: h.croppedFilePath) || MediaStorage.fileExists(at: h.originalFilePath)
        }
    }

    var isSlateReady: Bool {
        guard let take = selectedSlateTake else { return false }
        return MediaStorage.fileExists(at: take.filePath)
    }

    var isAuditionReady: Bool {
        guard let take = selectedAuditionTake else { return false }
        return MediaStorage.fileExists(at: take.filePath)
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

@MainActor
@Observable
final class AppSettings {

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let prefix = "onetake."

    @ObservationIgnored private static let settingKeys: [String] = [
        "countdownSeconds",
        "autoTrimSilence",
        "noiseReductionDefault",
        "cueTriggerModeRaw",
        "cueDelaySeconds",
        "cueVolume",
        "teleprompterTextSizeRaw",
        "teleprompterScrollSpeed",
        "mirrorFrontCamera",
        "videoQualityRaw",
        "frameRate",
        "notifyAuditions",
        "notifySubmissions",
        "notifyPractice",
        "notifyProductUpdates",
        "framingTipsOutLoud",
        "countdownOutLoud"
    ]

    // MARK: Private Helpers

    private func key(_ name: String) -> String { prefix + name }

    private static func readValue<T>(_ name: String, from defaults: UserDefaults, prefix: String, fallback: T) -> T {
        let k = prefix + name
        guard let obj = defaults.object(forKey: k) else { return fallback }
        return (obj as? T) ?? fallback
    }

    private func setValue<T>(_ name: String, value: T) {
        defaults.set(value, forKey: key(name))
    }

    // MARK: Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let p = "onetake."
        self.countdownSeconds = Self.readValue("countdownSeconds", from: defaults, prefix: p, fallback: 3)
        self.autoTrimSilence = Self.readValue("autoTrimSilence", from: defaults, prefix: p, fallback: false)
        self.noiseReductionDefault = Self.readValue("noiseReductionDefault", from: defaults, prefix: p, fallback: false)
        self.cueTriggerModeRaw = Self.readValue("cueTriggerModeRaw", from: defaults, prefix: p, fallback: CueTriggerMode.afterMyLine.rawValue)
        self.cueDelaySeconds = Self.readValue("cueDelaySeconds", from: defaults, prefix: p, fallback: 2.0)
        self.cueVolume = Self.readValue("cueVolume", from: defaults, prefix: p, fallback: 0.8)
        self.teleprompterTextSizeRaw = Self.readValue("teleprompterTextSizeRaw", from: defaults, prefix: p, fallback: TeleprompterTextSize.regular.rawValue)
        self.teleprompterScrollSpeed = Self.readValue("teleprompterScrollSpeed", from: defaults, prefix: p, fallback: 1.0)
        self.mirrorFrontCamera = Self.readValue("mirrorFrontCamera", from: defaults, prefix: p, fallback: true)
        self.videoQualityRaw = Self.readValue("videoQualityRaw", from: defaults, prefix: p, fallback: VideoQuality.p1080.rawValue)
        self.frameRate = Self.readValue("frameRate", from: defaults, prefix: p, fallback: 30)
        self.notifyAuditions = Self.readValue("notifyAuditions", from: defaults, prefix: p, fallback: true)
        self.notifySubmissions = Self.readValue("notifySubmissions", from: defaults, prefix: p, fallback: true)
        self.notifyPractice = Self.readValue("notifyPractice", from: defaults, prefix: p, fallback: true)
        self.notifyProductUpdates = Self.readValue("notifyProductUpdates", from: defaults, prefix: p, fallback: false)
        self.framingTipsOutLoud = Self.readValue("framingTipsOutLoud", from: defaults, prefix: p, fallback: true)
        self.countdownOutLoud = Self.readValue("countdownOutLoud", from: defaults, prefix: p, fallback: true)
    }

    func resetToDefaults() {
        countdownSeconds = 3
        autoTrimSilence = false
        noiseReductionDefault = false
        cueTriggerModeRaw = CueTriggerMode.afterMyLine.rawValue
        cueDelaySeconds = 2.0
        cueVolume = 0.8
        teleprompterTextSizeRaw = TeleprompterTextSize.regular.rawValue
        teleprompterScrollSpeed = 1.0
        mirrorFrontCamera = true
        videoQualityRaw = VideoQuality.p1080.rawValue
        frameRate = 30
        notifyAuditions = true
        notifySubmissions = true
        notifyPractice = true
        notifyProductUpdates = false
        framingTipsOutLoud = true
        countdownOutLoud = true

        for name in Self.settingKeys {
            defaults.removeObject(forKey: key(name))
        }
    }

    // MARK: Recording

    var countdownSeconds: Int {
        didSet { setValue("countdownSeconds", value: countdownSeconds) }
    }

    var autoTrimSilence: Bool {
        didSet { setValue("autoTrimSilence", value: autoTrimSilence) }
    }

    var noiseReductionDefault: Bool {
        didSet { setValue("noiseReductionDefault", value: noiseReductionDefault) }
    }

    // MARK: Cue

    var cueTriggerModeRaw: String {
        didSet { setValue("cueTriggerModeRaw", value: cueTriggerModeRaw) }
    }

    var cueTriggerMode: CueTriggerMode {
        get { CueTriggerMode(rawValue: cueTriggerModeRaw) ?? .afterMyLine }
        set { cueTriggerModeRaw = newValue.rawValue }
    }

    var cueDelaySeconds: Double {
        didSet { setValue("cueDelaySeconds", value: cueDelaySeconds) }
    }

    var cueVolume: Double {
        didSet { setValue("cueVolume", value: cueVolume) }
    }

    // MARK: Teleprompter

    var teleprompterTextSizeRaw: String {
        didSet { setValue("teleprompterTextSizeRaw", value: teleprompterTextSizeRaw) }
    }

    var teleprompterTextSize: TeleprompterTextSize {
        get { TeleprompterTextSize(rawValue: teleprompterTextSizeRaw) ?? .regular }
        set { teleprompterTextSizeRaw = newValue.rawValue }
    }

    var teleprompterScrollSpeed: Double {
        didSet { setValue("teleprompterScrollSpeed", value: teleprompterScrollSpeed) }
    }

    // MARK: Camera

    var mirrorFrontCamera: Bool {
        didSet { setValue("mirrorFrontCamera", value: mirrorFrontCamera) }
    }

    var videoQualityRaw: String {
        didSet { setValue("videoQualityRaw", value: videoQualityRaw) }
    }

    var videoQuality: VideoQuality {
        get { VideoQuality(rawValue: videoQualityRaw) ?? .p1080 }
        set { videoQualityRaw = newValue.rawValue }
    }

    var frameRate: Int {
        didSet { setValue("frameRate", value: frameRate) }
    }

    // MARK: Notifications

    var notifyAuditions: Bool {
        didSet { setValue("notifyAuditions", value: notifyAuditions) }
    }

    var notifySubmissions: Bool {
        didSet { setValue("notifySubmissions", value: notifySubmissions) }
    }

    var notifyPractice: Bool {
        didSet { setValue("notifyPractice", value: notifyPractice) }
    }

    var notifyProductUpdates: Bool {
        didSet { setValue("notifyProductUpdates", value: notifyProductUpdates) }
    }

    // MARK: Briefing / Voice Feedback

    var framingTipsOutLoud: Bool {
        didSet { setValue("framingTipsOutLoud", value: framingTipsOutLoud) }
    }

    var countdownOutLoud: Bool {
        didSet { setValue("countdownOutLoud", value: countdownOutLoud) }
    }
}
