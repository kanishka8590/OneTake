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
        let icon: String
        let title: String
        let description: String
    }

    private let slides: [OnboardingSlide] = [
        OnboardingSlide(
            id: 0,
            icon: "movieclapper.fill",
            title: "Auditions done right.",
            description: "Record self-tapes, organise casting calls and submit — all from your phone."
        ),
        OnboardingSlide(
            id: 1,
            icon: "video.fill.badge.checkmark",
            title: "The Spotlight stays on you.",
            description: "From Teleprompter and cue reader to pre-take quality checks, all you need for effortless self-tapes"
        ),
        OnboardingSlide(
            id: 2,
            icon: "theatermasks.fill",
            title: "Practice. Perfect. Perform.",
            description: "Memorize scripts with adaptive prompts, practice your delivery, and nail every performance."
        )
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Theme.Colors.primaryPlum, Theme.Colors.plumDark],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Top Bar with Skip Button
                HStack {
                    Spacer()
                    if currentPage < slides.count - 1 {
                        Button {
                            completeOnboarding()
                        } label: {
                            Text("Skip")
                                .font(Theme.Typography.bodyRegular)
                                .fontWeight(.medium)
                                .foregroundStyle(Color.white.opacity(0.85))
                                .frame(minWidth: Theme.Layout.minTapTarget, minHeight: Theme.Layout.minTapTarget)
                                .padding(.horizontal, 8)
                        }
                    } else {
                        Color.clear
                            .frame(width: Theme.Layout.minTapTarget, height: Theme.Layout.minTapTarget)
                    }
                }
                .padding(.horizontal, Theme.Layout.screenHPadding)
                .padding(.top, 8)

                // Paged Carousel
                TabView(selection: $currentPage) {
                    ForEach(slides) { slide in
                        VStack(spacing: 28) {
                            Spacer()

                            ZStack {
                                Circle()
                                    .fill(Color.white.opacity(0.12))
                                    .frame(width: 140, height: 140)

                                Image(systemName: slide.icon)
                                    .font(.system(size: 64, weight: .semibold))
                                    .foregroundStyle(Color.white)
                            }

                            VStack(spacing: 12) {
                                Text(slide.title)
                                    .font(Theme.Typography.screenTitle)
                                    .foregroundStyle(Color.white)
                                    .multilineTextAlignment(.center)

                                Text(slide.description)
                                    .font(Theme.Typography.bodyRegular)
                                    .foregroundStyle(Color.white.opacity(0.8))
                                    .multilineTextAlignment(.center)
                                    .lineSpacing(4)
                                    .padding(.horizontal, 24)
                            }

                            Spacer()
                        }
                        .tag(slide.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))

                // Bottom Action Area
                VStack(spacing: 16) {
                    if currentPage == slides.count - 1 {
                        Button {
                            completeOnboarding()
                        } label: {
                            Text("Get started")
                                .font(Theme.Typography.cardTitle)
                                .foregroundStyle(Theme.Colors.primaryPlum)
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .background(Color.white)
                                .clipShape(Capsule())
                        }
                        .frame(minHeight: Theme.Layout.minTapTarget)
                    } else {
                        Button {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                currentPage = min(currentPage + 1, slides.count - 1)
                            }
                        } label: {
                            Text("Continue")
                                .font(Theme.Typography.cardTitle)
                                .foregroundStyle(Color.white)
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .background(Color.white.opacity(0.2))
                                .clipShape(Capsule())
                        }
                        .frame(minHeight: Theme.Layout.minTapTarget)
                    }
                }
                .padding(.horizontal, Theme.Layout.screenHPadding)
                .padding(.bottom, 36)
            }
        }
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
