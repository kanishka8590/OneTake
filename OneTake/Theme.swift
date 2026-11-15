import SwiftUI
import UIKit

// MARK: - Design System

enum Theme {

    // MARK: - Colors

    enum Colors {
        /// Fixed dark plum for filled, high-emphasis actions. Its contrast with
        /// `onAction` remains strong in either system appearance.
        static let primaryPlum = Color(red: 78 / 255, green: 51 / 255, blue: 107 / 255)
        static let plumDark = Color(red: 54 / 255, green: 33 / 255, blue: 77 / 255)
        /// The app's semantic accent for links, glyphs, controls, and selected
        /// outlines. It becomes a luminous lavender on dark surfaces.
        static let accent = adaptive(
            light: UIColor(red: 78 / 255, green: 51 / 255, blue: 107 / 255, alpha: 1),
            dark: UIColor(red: 201 / 255, green: 181 / 255, blue: 255 / 255, alpha: 1)
        )
        static let onAction = Color.white
        static let lavenderSurface = adaptive(light: UIColor(red: 237 / 255, green: 232 / 255, blue: 245 / 255, alpha: 1), dark: UIColor(red: 54 / 255, green: 43 / 255, blue: 67 / 255, alpha: 1))
        static let lavenderTint = adaptive(light: UIColor(red: 245 / 255, green: 242 / 255, blue: 250 / 255, alpha: 1), dark: UIColor(red: 38 / 255, green: 31 / 255, blue: 48 / 255, alpha: 1))
        static let canvasBackground = adaptive(light: UIColor(red: 247 / 255, green: 246 / 255, blue: 249 / 255, alpha: 1), dark: UIColor(red: 18 / 255, green: 16 / 255, blue: 22 / 255, alpha: 1))
        static let cardSurface = adaptive(light: .white, dark: UIColor(red: 31 / 255, green: 28 / 255, blue: 36 / 255, alpha: 1))
        /// General-purpose adaptive surfaces for sheets, form controls, and
        /// elevated content. These deliberately never resolve to white in dark mode.
        static let surface = cardSurface
        static let surfaceElevated = adaptive(light: UIColor.white, dark: UIColor(red: 43 / 255, green: 39 / 255, blue: 49 / 255, alpha: 1))
        static let controlSurface = adaptive(light: UIColor.white, dark: UIColor(red: 47 / 255, green: 43 / 255, blue: 54 / 255, alpha: 1))
        static let controlBorder = adaptive(light: UIColor(red: 205 / 255, green: 199 / 255, blue: 211 / 255, alpha: 1), dark: UIColor(red: 100 / 255, green: 91 / 255, blue: 112 / 255, alpha: 1))
        static let textPrimary = adaptive(light: UIColor(red: 28 / 255, green: 27 / 255, blue: 31 / 255, alpha: 1), dark: UIColor(red: 245 / 255, green: 242 / 255, blue: 247 / 255, alpha: 1))
        static let textSecondary = adaptive(light: UIColor(red: 107 / 255, green: 104 / 255, blue: 117 / 255, alpha: 1), dark: UIColor(red: 207 / 255, green: 200 / 255, blue: 214 / 255, alpha: 1))
        static let successGreen = adaptive(light: UIColor(red: 22 / 255, green: 163 / 255, blue: 74 / 255, alpha: 1), dark: UIColor(red: 110 / 255, green: 231 / 255, blue: 183 / 255, alpha: 1))
        static let warningAmber = adaptive(light: UIColor(red: 217 / 255, green: 119 / 255, blue: 6 / 255, alpha: 1), dark: UIColor(red: 253 / 255, green: 186 / 255, blue: 116 / 255, alpha: 1))
        static let errorCrimson = adaptive(light: UIColor(red: 220 / 255, green: 38 / 255, blue: 38 / 255, alpha: 1), dark: UIColor(red: 255 / 255, green: 138 / 255, blue: 138 / 255, alpha: 1))
        static let studioPink = Color.pink
        static let studioOrange = Color.orange
        static let studioYellow = Color.yellow
        static let studioGreen = Color.green
        static let studioBlue = Color.cyan
        static let goldInk = Color(red: 0.58, green: 0.42, blue: 0.0)
        static let annotationBlue = Color(red: 0.35, green: 0.72, blue: 0.96)

        // These are intentionally fixed because the capture UI forces a dark
        // camera HUD regardless of the system appearance.
        static let cameraCanvas = Color(red: 0.08, green: 0.08, blue: 0.10)
        static let cameraPanel = Color(red: 0.12, green: 0.12, blue: 0.14)
        static let cameraTeleprompterHighlight = Color(red: 0.75, green: 0.70, blue: 0.95)
        static let cameraGuideGold = Color(red: 0.95, green: 0.85, blue: 0.65)
        static let cameraGuideGoldStroke = Color(red: 0.85, green: 0.72, blue: 0.42)
        static let cameraGuideGoldFill = Color(red: 0.85, green: 0.72, blue: 0.45)
        static let cameraGuideLilac = Color(red: 0.80, green: 0.70, blue: 0.98)

        private static func adaptive(light: UIColor, dark: UIColor) -> Color {
            Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark ? dark : light
            })
        }
    }

    enum Artwork {
        static let onboardingHero = "onboarding_hero"
        static let practiceBanner = "practice_banner"
        static let dramaBanner = "scene_drama_banner"
        static let auditionBanner = "scene_audition_banner"
    }

    // MARK: - Typography

    enum Typography {
        static let screenTitle: Font = .system(size: 30, weight: .bold, design: .default)
        static let sectionHeader: Font = .system(size: 21, weight: .bold)
        static let cardTitle: Font = .system(size: 17, weight: .semibold)
        static let bodyRegular: Font = .system(size: 15, weight: .regular)
        static let captionBadge: Font = .system(size: 12, weight: .medium)
    }

    // MARK: - Layout Tokens

    enum Layout {
        static let screenHPadding: CGFloat = 20
        static let cardCornerRadius: CGFloat = 20
        static let innerCornerRadius: CGFloat = 12
        static let minTapTarget: CGFloat = 44
    }
}

// MARK: - View Modifiers

struct PrimaryCapsuleButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(Theme.Typography.cardTitle)
            .foregroundStyle(Theme.Colors.onAction)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Theme.Colors.primaryPlum)
            .clipShape(Capsule())
    }
}

struct SecondaryCapsuleButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(Theme.Typography.cardTitle)
            .foregroundStyle(Theme.Colors.accent)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Theme.Colors.lavenderSurface)
            .clipShape(Capsule())
    }
}

struct StatusBadgeModifier: ViewModifier {
    let color: Color

    func body(content: Content) -> some View {
        content
            .font(Theme.Typography.captionBadge)
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }
}

struct CardStyleModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.Colors.cardSurface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Layout.cardCornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Layout.cardCornerRadius, style: .continuous).stroke(Theme.Colors.controlBorder.opacity(0.42), lineWidth: 1))
            .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 3)
    }
}

// MARK: - View Extensions

extension View {
    func primaryCapsuleButton() -> some View {
        modifier(PrimaryCapsuleButtonModifier())
    }

    func secondaryLavenderButton() -> some View {
        modifier(SecondaryCapsuleButtonModifier())
    }

    func statusBadge(color: Color) -> some View {
        modifier(StatusBadgeModifier(color: color))
    }

    func cardStyle() -> some View {
        modifier(CardStyleModifier())
    }

    func studioPill(_ color: Color) -> some View {
        font(Theme.Typography.captionBadge.bold())
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.18))
            .overlay(Capsule().stroke(color.opacity(0.55), lineWidth: 1))
            .clipShape(Capsule())
    }
}

// MARK: - Preview

#Preview("Theme Sampler") {
    ScrollView {
        VStack(spacing: 24) {

            // Title
            Text("OneTake Design System")
                .font(Theme.Typography.screenTitle)
                .foregroundStyle(Theme.Colors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Color Palette
            VStack(alignment: .leading, spacing: 12) {
                Text("Colors")
                    .font(Theme.Typography.sectionHeader)
                    .foregroundStyle(Theme.Colors.textPrimary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], spacing: 8) {
                    colorSwatch("Primary Plum", Theme.Colors.primaryPlum)
                    colorSwatch("Plum Dark", Theme.Colors.plumDark)
                    colorSwatch("Lavender", Theme.Colors.lavenderSurface)
                    colorSwatch("Lavender Tint", Theme.Colors.lavenderTint)
                    colorSwatch("Canvas BG", Theme.Colors.canvasBackground)
                    colorSwatch("Card Surface", Theme.Colors.cardSurface)
                    colorSwatch("Success", Theme.Colors.successGreen)
                    colorSwatch("Warning", Theme.Colors.warningAmber)
                    colorSwatch("Error", Theme.Colors.errorCrimson)
                }
            }
            .padding()
            .cardStyle()

            // Typography
            VStack(alignment: .leading, spacing: 8) {
                Text("Typography")
                    .font(Theme.Typography.sectionHeader)
                    .foregroundStyle(Theme.Colors.textPrimary)

                Text("Screen Title (28 Bold)")
                    .font(Theme.Typography.screenTitle)
                Text("Section Header (20 Semibold)")
                    .font(Theme.Typography.sectionHeader)
                Text("Card Title (17 Semibold)")
                    .font(Theme.Typography.cardTitle)
                Text("Body Regular (15 Regular)")
                    .font(Theme.Typography.bodyRegular)
                Text("Caption Badge (12 Medium)")
                    .font(Theme.Typography.captionBadge)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(Theme.Colors.textPrimary)
            .padding()
            .cardStyle()

            // Buttons
            VStack(spacing: 12) {
                Text("Buttons")
                    .font(Theme.Typography.sectionHeader)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("Start Recording")
                    .primaryCapsuleButton()

                Text("View Library")
                    .secondaryLavenderButton()
            }
            .padding()
            .cardStyle()

            // Badges
            VStack(alignment: .leading, spacing: 12) {
                Text("Status Badges")
                    .font(Theme.Typography.sectionHeader)
                    .foregroundStyle(Theme.Colors.textPrimary)

                HStack(spacing: 8) {
                    Text("Completed")
                        .statusBadge(color: Theme.Colors.successGreen)
                    Text("In Progress")
                        .statusBadge(color: Theme.Colors.warningAmber)
                    Text("Failed")
                        .statusBadge(color: Theme.Colors.errorCrimson)
                    Text("Draft")
                        .statusBadge(color: Theme.Colors.primaryPlum)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .cardStyle()
        }
        .padding(.horizontal, Theme.Layout.screenHPadding)
        .padding(.vertical, 24)
    }
    .background(Theme.Colors.canvasBackground)
}

// MARK: - Preview Helpers

@ViewBuilder
private func colorSwatch(_ name: String, _ color: Color) -> some View {
    VStack(spacing: 4) {
        RoundedRectangle(cornerRadius: Theme.Layout.innerCornerRadius, style: .continuous)
            .fill(color)
            .frame(height: 48)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Layout.innerCornerRadius, style: .continuous)
                    .stroke(Theme.Colors.controlBorder.opacity(0.55), lineWidth: 1)
            )
        Text(name)
            .font(Theme.Typography.captionBadge)
            .foregroundStyle(Theme.Colors.textSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}
