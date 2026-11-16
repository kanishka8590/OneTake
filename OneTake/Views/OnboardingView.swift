import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var envAppState
    private let explicitAppState: AppState?

    @State private var currentPage = 0

    init(appState: AppState? = nil) {
        self.explicitAppState = appState
    }

    private var appState: AppState {
        explicitAppState ?? envAppState
    }

    private struct OnboardingSlide: Identifiable {
        let id: Int
        let artwork: String
        let title: String
        let description: String
    }

    private let slides: [OnboardingSlide] = [
            OnboardingSlide(
                id: 0,
                artwork: "onboarding_auditions",
                title: "Auditions\ndone right.",
                description: "Create headshots, slates and scenes with professional tools built for actors"
            ),
            OnboardingSlide(
                id: 1,
                artwork: "onboarding_take",
                title: "Your take.\nOn your terms.",
                description: "Check your framing, lighting, and sound so every take feels studio ready"
            ),
            OnboardingSlide(
                id: 2,
                artwork: "onboarding_rehearse",
                title: "From first line\nto final take",
                description: "Rehearse with guided practice designed to make every dialogue feel effortless"
            )
        ]

    private var surfaceColor: Color { Theme.Colors.canvasBackground }
    private var primaryInk: Color { Theme.Colors.textPrimary }
    private var secondaryInk: Color { Theme.Colors.textSecondary }
    private var inactiveDot: Color { Theme.Colors.textSecondary.opacity(0.35) }

    var body: some View {
        GeometryReader { geo in
            let fullHeight = geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom

            ZStack(alignment: .topTrailing) {
                surfaceColor.ignoresSafeArea()

                // Full-bleed Paged Carousel
                TabView(selection: $currentPage) {
                    ForEach(slides) { slide in
                        slideView(
                            slide: slide,
                            width: geo.size.width,
                            fullHeight: fullHeight,
                            bottomInset: geo.safeAreaInsets.bottom
                        )
                        .tag(slide.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()

                // Native iOS Top-Trailing Skip Button
                if currentPage < slides.count - 1 {
                    Button {
                        completeOnboarding()
                    } label: {
                        Text("Skip")
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(primaryInk)
                            .frame(minWidth: Theme.Layout.minTapTarget, minHeight: Theme.Layout.minTapTarget, alignment: .trailing)
                            .contentShape(Rectangle())
                    }
                    .padding(.trailing, 20)
                    .padding(.top, geo.safeAreaInsets.top)
                    .transition(.opacity)
                }
            }
        }
        // Editorial onboarding artwork is intentionally light, full-bleed content.
        // Main application screens continue to follow the system appearance.
        .preferredColorScheme(.light)
    }

    @ViewBuilder
    private func slideView(
        slide: OnboardingSlide,
        width: CGFloat,
        fullHeight: CGFloat,
        bottomInset: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top 56%: Full-bleed artwork dissolving into the warm off-white surface
            ZStack(alignment: .bottom) {
                Image(slide.artwork)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: fullHeight * 0.56)
                    .clipped()

                LinearGradient(
                    stops: [
                        .init(color: surfaceColor.opacity(0.0), location: 0.0),
                        .init(color: surfaceColor.opacity(0.75), location: 0.65),
                        .init(color: surfaceColor, location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 110)
            }
            .accessibilityHidden(true)

            // Bottom 44%: Left-aligned editorial copy & bottom controls
            VStack(alignment: .leading, spacing: 14) {
                Text(slide.title)
                    .font(.system(size: 38, weight: .bold))
                    .tracking(-0.8)
                    .lineSpacing(-2)
                    .foregroundStyle(primaryInk)
                    .fixedSize(horizontal: false, vertical: true)

                Text(slide.description)
                    .font(.system(size: 16, weight: .regular))
                    .lineSpacing(4)
                    .foregroundStyle(secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()

                // Fixed 54pt control slot so text never shifts between slides
                ZStack {
                    if slide.id == slides.count - 1 {
                        Button {
                            completeOnboarding()
                        } label: {
                            HStack(spacing: 6) {
                                Text("Get started")
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 15, weight: .semibold))
                            }
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.Colors.onAction)
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .background(Theme.Colors.primaryPlum)
                            .clipShape(Capsule())
                        }
                        .frame(minHeight: Theme.Layout.minTapTarget)
                    } else {
                        HStack(spacing: 8) {
                            ForEach(slides) { dotSlide in
                                Circle()
                                    .fill(dotSlide.id == currentPage ? primaryInk : inactiveDot)
                                    .frame(width: 7, height: 7)
                                    .animation(.easeInOut(duration: 0.2), value: currentPage)
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Page \(currentPage + 1) of \(slides.count)")
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .padding(.bottom, max(bottomInset, 16) + 12)
            }
            .padding(.horizontal, 24)
            .padding(.top, 10)
        }
        .ignoresSafeArea()
    }

    private func completeOnboarding() {
        withAnimation {
            appState.hasCompletedOnboarding = true
        }
    }
}

#Preview {
    OnboardingView()
        .environment(MockData.sampleAppState)
}
