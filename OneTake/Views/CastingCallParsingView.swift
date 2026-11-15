import SwiftUI

struct CastingCallParsingView: View {
    let sourceTitle: String
    let onParsed: (ParsedCastingCall) -> Void
    let onCancel: () -> Void

    @State private var progressStep = 0
    @State private var isPulsing = false
    @State private var parsedResult: ParsedCastingCall?

    private let statusMessages = [
        "Analyzing casting document layout...",
        "Running optical character recognition...",
        "Detecting character roles and dialogue...",
        "Extracting submission deadline & email...",
        "Building audition breakdown..."
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.canvasBackground
                    .ignoresSafeArea()

                VStack(spacing: 32) {
                    Spacer()

                    // Radar pulse animation
                    ZStack {
                        Circle()
                            .stroke(Theme.Colors.primaryPlum.opacity(0.15), lineWidth: 2)
                            .frame(width: isPulsing ? 170 : 110, height: isPulsing ? 170 : 110)
                            .scaleEffect(isPulsing ? 1.15 : 0.95)
                            .opacity(isPulsing ? 0.3 : 0.8)

                        Circle()
                            .fill(Theme.Colors.lavenderSurface)
                            .frame(width: 100, height: 100)

                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 42))
                            .foregroundStyle(Theme.Colors.primaryPlum)
                    }
                    .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: isPulsing)

                    VStack(spacing: 8) {
                        Text("Reading the Call...")
                            .font(Theme.Typography.screenTitle)
                            .foregroundStyle(Theme.Colors.textPrimary)

                        Text(statusMessages[min(progressStep, statusMessages.count - 1)])
                            .font(Theme.Typography.bodyRegular)
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .animation(.easeInOut, value: progressStep)

                        if !sourceTitle.isEmpty {
                            Text(sourceTitle)
                                .font(Theme.Typography.captionBadge)
                                .foregroundStyle(Theme.Colors.primaryPlum)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)
                                .background(Theme.Colors.lavenderTint)
                                .clipShape(Capsule())
                                .padding(.top, 4)
                        }
                    }

                    // Progress indicators
                    HStack(spacing: 6) {
                        ForEach(0..<statusMessages.count, id: \.self) { idx in
                            Capsule()
                                .fill(idx <= progressStep ? Theme.Colors.primaryPlum : Theme.Colors.lavenderSurface)
                                .frame(width: idx == progressStep ? 24 : 12, height: 6)
                                .animation(.spring(), value: progressStep)
                        }
                    }

                    Spacer()

                    Button("Cancel") {
                        onCancel()
                    }
                    .font(Theme.Typography.bodyRegular)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .padding(.bottom, 24)
                }
                .padding(.horizontal, 24)
            }
            .navigationBarBackButtonHidden()
            .onAppear {
                isPulsing = true
                runStepSimulation()
            }
        }
    }

    private func runStepSimulation() {
        // Step through feedback messages cleanly
        for i in 1..<statusMessages.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.45) {
                progressStep = i
            }
        }
    }
}
