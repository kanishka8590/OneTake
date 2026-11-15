import SwiftUI

// MARK: - Design System

enum Theme {

    // MARK: - Colors

    enum Colors {
        static let primaryPlum = Color(red: 78 / 255, green: 51 / 255, blue: 107 / 255)
        static let plumDark = Color(red: 54 / 255, green: 33 / 255, blue: 77 / 255)
        static let lavenderSurface = Color(red: 237 / 255, green: 232 / 255, blue: 245 / 255)
        static let lavenderTint = Color(red: 245 / 255, green: 242 / 255, blue: 250 / 255)
        static let canvasBackground = Color(red: 247 / 255, green: 246 / 255, blue: 249 / 255)
        static let cardSurface = Color.white
        static let textPrimary = Color(red: 28 / 255, green: 27 / 255, blue: 31 / 255)
        static let textSecondary = Color(red: 107 / 255, green: 104 / 255, blue: 117 / 255)
        static let successGreen = Color(red: 22 / 255, green: 163 / 255, blue: 74 / 255)
        static let warningAmber = Color(red: 217 / 255, green: 119 / 255, blue: 6 / 255)
        static let errorCrimson = Color(red: 220 / 255, green: 38 / 255, blue: 38 / 255)
    }

    // MARK: - Typography

    enum Typography {
        static let screenTitle: Font = .system(size: 28, weight: .bold, design: .default)
        static let sectionHeader: Font = .system(size: 20, weight: .semibold)
        static let cardTitle: Font = .system(size: 17, weight: .semibold)
        static let bodyRegular: Font = .system(size: 15, weight: .regular)
        static let captionBadge: Font = .system(size: 12, weight: .medium)
    }

    // MARK: - Layout Tokens

    enum Layout {
        static let screenHPadding: CGFloat = 16
        static let cardCornerRadius: CGFloat = 16
        static let innerCornerRadius: CGFloat = 12
        static let minTapTarget: CGFloat = 44
    }
}

// MARK: - View Modifiers

struct PrimaryCapsuleButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(Theme.Typography.cardTitle)
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Theme.Colors.primaryPlum)
            .clipShape(Capsule())
    }
}

struct SecondaryCapsuleButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(Theme.Typography.cardTitle)
            .foregroundStyle(Theme.Colors.primaryPlum)
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
            .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 2)
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
                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
            )
        Text(name)
            .font(Theme.Typography.captionBadge)
            .foregroundStyle(Theme.Colors.textSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}
