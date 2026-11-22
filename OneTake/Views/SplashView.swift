import SwiftUI

struct SplashView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lampLit = false
    @State private var beamProgress: CGFloat = 0
    @State private var revealTitle = false
    var onFinished: (() -> Void)? = nil

    private let iconPlum = Color(red: 56 / 255, green: 16 / 255, blue: 54 / 255)
    private let beamCream = Color(red: 255 / 255, green: 243 / 255, blue: 204 / 255)
    private let beamViolet = Color(red: 112 / 255, green: 62 / 255, blue: 158 / 255)

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Theme.Colors.primaryPlum, Theme.Colors.plumDark],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                SpotlightAppLogo(
                    lampLit: lampLit,
                    beamProgress: beamProgress,
                    iconPlum: iconPlum,
                    beamCream: beamCream,
                    beamViolet: beamViolet
                )
                .frame(width: 120, height: 120)
                .accessibilityHidden(true)

                VStack(spacing: 6) {
                    Text("OneTake")
                        .font(.system(size: 36, weight: .bold))
                        .tracking(-0.6)
                        .foregroundStyle(Color.white)

                    Text("From first take to final cut")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.white.opacity(0.78))
                }
                .opacity(revealTitle ? 1 : 0)
                .offset(y: revealTitle ? 0 : 8)
            }
        }
        .task {
            if reduceMotion {
                lampLit = true
                beamProgress = 1
                revealTitle = true
                try? await Task.sleep(for: .seconds(0.55))
            } else {
                withAnimation(.easeOut(duration: 0.14)) {
                    lampLit = true
                }
                withAnimation(.timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.38).delay(0.06)) {
                    beamProgress = 1
                }
                withAnimation(.easeOut(duration: 0.28).delay(0.18)) {
                    revealTitle = true
                }
                try? await Task.sleep(for: .seconds(0.85))
            }
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.22)) {
                onFinished?()
            }
        }
    }
}

private struct SpotlightAppLogo: View {
    let lampLit: Bool
    let beamProgress: CGFloat
    let iconPlum: Color
    let beamCream: Color
    let beamViolet: Color

    var body: some View {
        ZStack(alignment: .topLeading) {
            iconPlum

            // Wide secondary violet spill cone from the stage lamp
            SpotlightBeamShape(spread: 0.94)
                .fill(
                    LinearGradient(
                        colors: [beamViolet.opacity(0.85), beamViolet.opacity(0.35)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .scaleEffect(
                    x: 0.2 + 0.8 * beamProgress,
                    y: 0.2 + 0.8 * beamProgress,
                    anchor: UnitPoint(x: 0.21, y: 0.18)
                )
                .opacity(lampLit ? Double(beamProgress) : 0)

            // Primary warm cream spotlight cone
            SpotlightBeamShape(spread: 0.72)
                .fill(
                    LinearGradient(
                        colors: [beamCream, beamCream.opacity(0.94)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .scaleEffect(
                    x: 0.15 + 0.85 * beamProgress,
                    y: 0.15 + 0.85 * beamProgress,
                    anchor: UnitPoint(x: 0.21, y: 0.18)
                )
                .opacity(lampLit ? min(1, Double(beamProgress * 1.15)) : 0)

            // Iconic bold serif "1" illuminated inside the spotlight beam
            Text("1")
                .font(.system(size: 56, weight: .black, design: .serif))
                .foregroundStyle(iconPlum)
                .offset(x: 68, y: 49)
                .opacity(beamProgress > 0.35 ? Double((beamProgress - 0.35) / 0.65) : 0)
                .scaleEffect(0.92 + 0.08 * beamProgress)

            // Hanging theater spotlight fixture in top-left corner
            SpotlightFixture(isLit: lampLit, beamCream: beamCream, outlineColor: iconPlum)
                .offset(x: 7, y: -2)
        }
        .clipShape(RoundedRectangle(cornerRadius: 27, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 27, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.32), radius: 18, y: 10)
    }
}

private struct SpotlightBeamShape: Shape {
    var spread: CGFloat

    func path(in rect: CGRect) -> Path {
        let originTop = CGPoint(x: rect.width * 0.25, y: rect.height * 0.14)
        let originBottom = CGPoint(x: rect.width * 0.17, y: rect.height * 0.22)

        let upperRight = CGPoint(x: rect.width * 1.18, y: rect.height * (0.58 - spread * 0.22))
        let lowerLeft = CGPoint(x: rect.width * (0.48 - spread * 0.14), y: rect.height * 1.18)

        var path = Path()
        path.move(to: originTop)
        path.addLine(to: upperRight)
        path.addLine(to: CGPoint(x: rect.width * 1.18, y: rect.height * 1.18))
        path.addLine(to: lowerLeft)
        path.addLine(to: originBottom)
        path.closeSubpath()
        return path
    }
}

private struct SpotlightFixture: View {
    let isLit: Bool
    let beamCream: Color
    let outlineColor: Color

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Mounting yoke arms from top edge
            HStack(spacing: 10) {
                Capsule()
                    .fill(Color(white: 0.38))
                    .frame(width: 4, height: 18)
                Capsule()
                    .fill(Color(white: 0.38))
                    .frame(width: 4, height: 15)
            }
            .offset(x: 6, y: 0)

            // Angled lamp housing + illuminated lens
            ZStack {
                Capsule()
                    .fill(Color(white: 0.35))
                    .frame(width: 24, height: 18)
                    .overlay(Capsule().stroke(outlineColor, lineWidth: 2))

                Ellipse()
                    .fill(isLit ? beamCream : Color(white: 0.55))
                    .frame(width: 11, height: 16)
                    .overlay(Ellipse().stroke(outlineColor, lineWidth: 2))
                    .offset(x: 8)
            }
            .rotationEffect(.degrees(38))
            .offset(x: 2, y: 10)
        }
    }
}

#Preview {
    SplashView()
}
