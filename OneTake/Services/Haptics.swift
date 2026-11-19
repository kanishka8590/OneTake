import SwiftUI
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
        /// Everyday tactile polish: scroll edges, filters, mode chips, clues, checklists.
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

    static func scrollEdge() {
        impact(.soft, tier: .tactile)
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

/// Tracks active user scroll position relative to top/bottom bounds so `.rich`
/// edge haptics fire cleanly once per boundary reach or overscroll pull.
nonisolated struct ScrollEdgeTracker: Sendable {
    private let edgeTolerance: Double = 1.5
    private let rearmDistance: Double = 16.0
    private let overscrollThreshold: Double = 10.0
    private let cooldownSeconds: TimeInterval = 0.20

    private var isTopReachArmed = false
    private var isBottomReachArmed = false
    private var isTopBounceLatched = false
    private var isBottomBounceLatched = false
    private var lastFireTime: Date = .distantPast

    mutating func update(
        offsetY: Double,
        topEdge: Double,
        bottomEdge: Double,
        isActiveScroll: Bool,
        now: Date = .now
    ) -> Bool {
        let hasScrollableRange = (bottomEdge - topEdge) > 1.0

        guard isActiveScroll else {
            isTopBounceLatched = false
            isBottomBounceLatched = false
            isTopReachArmed = offsetY > topEdge + rearmDistance
            isBottomReachArmed = hasScrollableRange && offsetY < bottomEdge - rearmDistance
            return false
        }

        if offsetY > topEdge + rearmDistance {
            isTopReachArmed = true
        }
        if hasScrollableRange, offsetY < bottomEdge - rearmDistance {
            isBottomReachArmed = true
        }
        if offsetY > topEdge - 2.0 {
            isTopBounceLatched = false
        }
        if offsetY < bottomEdge + 2.0 {
            isBottomBounceLatched = false
        }

        let canFire = now.timeIntervalSince(lastFireTime) >= cooldownSeconds

        let hitTop = isTopReachArmed && offsetY <= topEdge + edgeTolerance
        let bouncedTop = !isTopBounceLatched && offsetY <= topEdge - overscrollThreshold
        if hitTop || bouncedTop {
            isTopReachArmed = false
            isTopBounceLatched = true
            if canFire {
                lastFireTime = now
                return true
            }
        }

        let hitBottom = hasScrollableRange && isBottomReachArmed && offsetY >= bottomEdge - edgeTolerance
        let bouncedBottom = !isBottomBounceLatched && offsetY >= bottomEdge + overscrollThreshold
        if hitBottom || bouncedBottom {
            isBottomReachArmed = false
            isBottomBounceLatched = true
            if canFire {
                lastFireTime = now
                return true
            }
        }

        return false
    }
}

private struct ScrollEdgeHapticsModifier: ViewModifier {
    private struct GeometrySnapshot: Equatable {
        let offsetY: Double
        let topEdge: Double
        let bottomEdge: Double
    }

    @State private var isUserScrolling = false
    @State private var tracker = ScrollEdgeTracker()

    func body(content: Content) -> some View {
        content
            .onScrollPhaseChange { _, newPhase in
                isUserScrolling = (newPhase == .interacting || newPhase == .decelerating)
            }
            .onScrollGeometryChange(for: GeometrySnapshot.self) { geo in
                let topEdge = -geo.contentInsets.top
                let rawBottom = geo.contentSize.height + geo.contentInsets.bottom - geo.containerSize.height
                return GeometrySnapshot(
                    offsetY: geo.contentOffset.y,
                    topEdge: topEdge,
                    bottomEdge: max(topEdge, rawBottom)
                )
            } action: { _, snapshot in
                if tracker.update(
                    offsetY: snapshot.offsetY,
                    topEdge: snapshot.topEdge,
                    bottomEdge: snapshot.bottomEdge,
                    isActiveScroll: isUserScrolling
                ) {
                    Haptics.scrollEdge()
                }
            }
    }
}

extension View {
    /// Emits a subtle `.soft` haptic in Rich mode when actively scrolling to or
    /// pulling past the top or bottom edge of a screen or sheet.
    func scrollEdgeHaptics() -> some View {
        modifier(ScrollEdgeHapticsModifier())
    }
}
