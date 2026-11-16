import SwiftUI
import SwiftData

private struct ScriptReviewTarget: Identifiable, Hashable {
    let id = UUID()
    let script: PracticeScript
    let session: PracticeSession

    static func == (lhs: ScriptReviewTarget, rhs: ScriptReviewTarget) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct PracticeHubView: View {
    @Environment(AppState.self) private var envAppState
    private let explicitAppState: AppState?

    init(appState: AppState? = nil) {
        self.explicitAppState = appState
    }

    private var appState: AppState {
        explicitAppState ?? envAppState
    }

    @State private var showingAddSheet = false
    @State private var showingHistory = false
    @State private var scriptToOpen: PracticeScript?
    @State private var scriptToRunAgain: PracticeScript?
    @State private var reviewTarget: ScriptReviewTarget?
    @State private var scriptToDelete: PracticeScript?
    @State private var showingDeleteAlert = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.canvasBackground
                    .ignoresSafeArea()

                if appState.practiceScripts.isEmpty {
                    emptyStateView
                } else {
                    List {
                        Section {
                            practiceHero
                                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                                .listRowBackground(Color.clear)
                        }
                        Section {
                            ForEach(appState.practiceScripts) { script in
                                PracticeScriptCardRow(script: script) {
                                    scriptToOpen = script
                                } onReview: { session in
                                    reviewTarget = ScriptReviewTarget(script: script, session: session)
                                } onRunAgain: {
                                    scriptToRunAgain = script
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        scriptToDelete = script
                                        showingDeleteAlert = true
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        } header: {
                            Text("Rehearsal Scripts (\(appState.practiceScripts.count))")
                                .font(Theme.Typography.captionBadge)
                                .foregroundStyle(Theme.Colors.textSecondary)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Practice")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 4) {
                        Button { showingHistory = true } label: { Image(systemName: "clock.arrow.circlepath").frame(minWidth: Theme.Layout.minTapTarget, minHeight: Theme.Layout.minTapTarget) }
                        Button { showingAddSheet = true } label: {
                            Image(systemName: "plus.circle.fill").font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(Theme.Colors.accent)
                                .frame(minWidth: Theme.Layout.minTapTarget, minHeight: Theme.Layout.minTapTarget)
                        }
                    }
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                PracticeASceneSheet(appState: appState, isPresented: $showingAddSheet) { script in
                    scriptToOpen = script
                }
            }
            .navigationDestination(item: $scriptToOpen) { script in
                MemoriseView(script: script, appState: appState)
            }
            .navigationDestination(item: $scriptToRunAgain) { script in
                SayItAloudView(script: script, appState: appState, help: .nothing)
            }
            .navigationDestination(item: $reviewTarget) { target in
                PracticeReviewView(script: target.script, session: target.session, appState: appState, isSavedReview: true)
            }
            .sheet(isPresented: $showingHistory) { PracticeHistoryView(scripts: appState.practiceScripts, appState: appState) }
            .confirmationDialog(
                "Delete Script?",
                isPresented: $showingDeleteAlert,
                presenting: scriptToDelete
            ) { script in
                Button("Delete \"\(script.title)\"", role: .destructive) {
                    appState.deletePracticeScript(script)
                }
                Button("Cancel", role: .cancel) {}
            } message: { script in
                Text("This will delete the script and its practice history.")
            }
        }
    }

    private var practiceHero: some View {
        ZStack(alignment: .bottomLeading) {
            Image(Theme.Artwork.practiceBanner)
                .resizable()
                .scaledToFill()
                .frame(height: 190)
                .overlay(LinearGradient(colors: [.clear, Theme.Colors.plumDark.opacity(0.9)], startPoint: .top, endPoint: .bottom))
            VStack(alignment: .leading, spacing: 5) {
                Text("The rehearsal room")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Text("Make the words feel like your own.")
                    .font(.subheadline.italic())
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(20)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.15), lineWidth: 1))
    }

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Theme.Colors.lavenderSurface)
                    .frame(width: 80, height: 80)

                Image(systemName: "text.book.closed")
                    .font(.system(size: 36))
                    .foregroundStyle(Theme.Colors.accent)
            }

            VStack(spacing: 6) {
                Text("No practice routine")
                    .font(Theme.Typography.sectionHeader)
                    .foregroundStyle(Theme.Colors.textPrimary)

                Text("Add your sides, monologues, or scenes to memorize and rehearse your script.")
                    .font(Theme.Typography.bodyRegular)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 24)
    }
}

// MARK: - Script Card Row

struct PracticeScriptCardRow: View {
    let script: PracticeScript
    let onOpen: () -> Void
    let onReview: (PracticeSession) -> Void
    let onRunAgain: () -> Void

    private var latestSession: PracticeSession? {
        script.sessions.sorted {
            if $0.date != $1.date {
                return $0.date > $1.date
            }
            return $0.sessionNumber > $1.sessionNumber
        }.first
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(script.title)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(Theme.Colors.textPrimary)
                            .lineLimit(1)

                        HStack(spacing: 5) {
                            Image(systemName: "clock")
                                .font(.system(size: 12, weight: .medium))
                            Text(lastPracticedText(for: script.lastPracticedAt))
                                .font(.system(size: 17, weight: .medium))
                        }
                        .foregroundStyle(Theme.Colors.textSecondary)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let latestSession {
                VStack(alignment: .trailing, spacing: 7) {
                    Button {
                        onReview(latestSession)
                    } label: {
                        Text("Review")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.Colors.accent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Theme.Colors.lavenderSurface)
                            .clipShape(Capsule())
                    }

                    Button(action: onRunAgain) {
                        Text("Run again")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Theme.Colors.primaryPlum)
                            .clipShape(Capsule())
                    }
                }
                .buttonStyle(.borderless)
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textSecondary.opacity(0.5))
                    .allowsHitTesting(false)
            }
        }
        .padding(.vertical, 8)
        .frame(minHeight: Theme.Layout.minTapTarget)
    }

    private func lastPracticedText(for date: Date?) -> String {
        guard let date else { return "Never practiced" }
        let calendar = Calendar.current
        let startOfThen = calendar.startOfDay(for: date)
        let startOfNow = calendar.startOfDay(for: Date())
        let days = calendar.dateComponents([.day], from: startOfThen, to: startOfNow).day ?? 0

        if days <= 0 {
            return "Practiced today"
        } else if days == 1 {
            return "Practiced yesterday"
        } else {
            return "Practiced \(days) days ago"
        }
    }
}

#Preview {
    PracticeHubView()
        .environment(MockData.sampleAppState)
}
