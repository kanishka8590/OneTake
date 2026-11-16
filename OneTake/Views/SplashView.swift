import SwiftUI

struct SplashView: View {
    @State private var isAnimating = false
    var onFinished: (() -> Void)? = nil

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Theme.Colors.primaryPlum, Theme.Colors.plumDark],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 140, height: 140)

                    Image(systemName: "movieclapper")
                        .font(.system(size: 56, weight: .semibold))
                        .foregroundStyle(Color.white)
                }
                .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("OneTake")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)
                        .tracking(0.5)

                    Text("From first take to final cut")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.85))
                }
            }
            .scaleEffect(isAnimating ? 1.0 : 0.82)
            .opacity(isAnimating ? 1.0 : 0.0)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.8)) {
                isAnimating = true
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(1.1))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.35)) {
                onFinished?()
            }
        }
    }
}

#Preview {
    SplashView()
}
