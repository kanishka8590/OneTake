import UIKit

/// Centralized haptic feedback coordinator for OneTake.
///
/// Respects `HapticFeedbackLevel` (`Selective`, `Rich`, `Off`) and automatically
/// suppresses Taptic Engine vibrations while active microphone capture is running
/// so mechanical vibrations never bleed into self-tapes or rehearsal recordings.
@MainActor
enum Haptics {
    enum Tier: Sendable {
        /// Key milestones: framing ready, countdown ticks, shutter/take capture,
        /// AI parse/compression/export completion, and warning/error states.
        case essential
        /// Everyday tactile polish: tab switches, filters, mode chips, clues, checklists.
        case tactile
    }

    private static let defaultsKey = "onetake.hapticFeedbackLevelRaw"
    private static var cachedLevel: HapticFeedbackLevel = {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let parsed = HapticFeedbackLevel(rawValue: raw) else {
            return .selective
        }
        return parsed
    }()
    private static var activeMicSources: Set<String> = []

    private static let selectionGenerator = UISelectionFeedbackGenerator()
    private static let notificationGenerator = UINotificationFeedbackGenerator()
    private static let softImpactGenerator = UIImpactFeedbackGenerator(style: .soft)
    private static let lightImpactGenerator = UIImpactFeedbackGenerator(style: .light)
    private static let mediumImpactGenerator = UIImpactFeedbackGenerator(style: .medium)
    private static let heavyImpactGenerator = UIImpactFeedbackGenerator(style: .heavy)
    private static let rigidImpactGenerator = UIImpactFeedbackGenerator(style: .rigid)

    static var currentLevel: HapticFeedbackLevel { cachedLevel }

    static var isMicCaptureActive: Bool { !activeMicSources.isEmpty }

    static func setLevel(_ level: HapticFeedbackLevel) {
        cachedLevel = level
    }

    static func setMicCaptureActive(_ active: Bool, source: String = "default") {
        if active {
            activeMicSources.insert(source)
        } else {
            activeMicSources.remove(source)
        }
    }

    static func resetMicCaptureStateForTesting() {
        activeMicSources.removeAll()
    }

    static func shouldPlay(
        _ tier: Tier,
        level: HapticFeedbackLevel? = nil,
        isMicActive: Bool? = nil
    ) -> Bool {
        let effectiveMicActive = isMicActive ?? isMicCaptureActive
        let effectiveLevel = level ?? cachedLevel
        guard !effectiveMicActive else { return false }
        switch effectiveLevel {
        case .off:
            return false
        case .selective:
            return tier == .essential
        case .rich:
            return true
        }
    }

    static func selection(_ tier: Tier = .tactile) {
        guard shouldPlay(tier) else { return }
        selectionGenerator.prepare()
        selectionGenerator.selectionChanged()
    }

    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium, tier: Tier = .essential) {
        guard shouldPlay(tier) else { return }
        let generator = impactGenerator(for: style)
        generator.prepare()
        generator.impactOccurred()
    }

    static func notification(_ type: UINotificationFeedbackGenerator.FeedbackType, tier: Tier = .essential) {
        guard shouldPlay(tier) else { return }
        notificationGenerator.prepare()
        notificationGenerator.notificationOccurred(type)
    }

    // MARK: - Semantic Conveniences

    static func alignmentReady() {
        impact(.soft, tier: .essential)
    }

    static func countdownTick() {
        impact(.light, tier: .essential)
    }

    static func capture() {
        impact(.medium, tier: .essential)
    }

    static func success() {
        notification(.success, tier: .essential)
    }

    static func warning() {
        notification(.warning, tier: .essential)
    }

    static func error() {
        notification(.error, tier: .essential)
    }

    static func selectionTick() {
        selection(.tactile)
    }

    static func tap() {
        impact(.light, tier: .tactile)
    }

    private static func impactGenerator(for style: UIImpactFeedbackGenerator.FeedbackStyle) -> UIImpactFeedbackGenerator {
        switch style {
        case .light: return lightImpactGenerator
        case .medium: return mediumImpactGenerator
        case .heavy: return heavyImpactGenerator
        case .soft: return softImpactGenerator
        case .rigid: return rigidImpactGenerator
        @unknown default: return mediumImpactGenerator
        }
    }
}
