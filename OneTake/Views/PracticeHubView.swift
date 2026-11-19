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
            List {
                ForEach(appState.practiceScripts) { script in
                    NavigationLink {
                        MemoriseView(script: script, appState: appState)
                            .toolbar(.hidden, for: .tabBar)
                    } label: {
                        PracticeScriptRow(script: script)
                    }
                    .contextMenu {
                        Button {
                            scriptToOpen = script
                        } label: {
                            Label("Memorise & Practice", systemImage: "book.pages")
                        }

                        Button {
                            scriptToRunAgain = script
                        } label: {
                            Label("Run Scene Aloud", systemImage: "waveform")
                        }

                        if let latest = script.sessions.sorted(by: { $0.date > $1.date }).first {
                            Button {
                                reviewTarget = ScriptReviewTarget(script: script, session: latest)
                            } label: {
                                Label("Review Latest Run", systemImage: "doc.text.magnifyingglass")
                            }
                        }

                        Divider()

                        Button(role: .destructive) {
                            scriptToDelete = script
                            showingDeleteAlert = true
                        } label: {
                            Label("Delete Script", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            scriptToDelete = script
                            showingDeleteAlert = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }

                        Button {
                            scriptToRunAgain = script
                        } label: {
                            Label("Run Aloud", systemImage: "waveform")
                        }
                        .tint(Theme.Colors.accent)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.Colors.canvasBackground.ignoresSafeArea())
            .overlay {
                if appState.practiceScripts.isEmpty {
                    emptyStateView
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
            }
            .navigationTitle("Practice")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingHistory = true
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Theme.Colors.accent)
                        }
                        .accessibilityLabel("Practice History")
                    }
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingAddSheet = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Theme.Colors.accent)
                        }
                        .accessibilityLabel("Practice a new scene")
                    }
                } else {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            showingHistory = true
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Theme.Colors.accent)
                        }
                        .accessibilityLabel("Practice History")

                        Button {
                            showingAddSheet = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Theme.Colors.accent)
                        }
                        .accessibilityLabel("Practice a new scene")
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
                    .toolbar(.hidden, for: .tabBar)
            }
            .navigationDestination(item: $scriptToRunAgain) { script in
                SayItAloudView(script: script, appState: appState, help: .nothing)
                    .toolbar(.hidden, for: .tabBar)
            }
            .navigationDestination(item: $reviewTarget) { target in
                PracticeReviewView(script: target.script, session: target.session, appState: appState, isSavedReview: true)
                    .toolbar(.hidden, for: .tabBar)
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
            .onAppear {
                if ProcessInfo.processInfo.arguments.contains("-OpenAddSceneSheet") {
                    showingAddSheet = true
                } else if ProcessInfo.processInfo.arguments.contains("-OpenUnifiedPractice") {
                    scriptToOpen = appState.practiceScripts.first(where: { $0.title.contains("Noah") }) ?? appState.practiceScripts.first
                }
            }
        }
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

                Text("Add your sides, monologues, or scenes using the + button above to memorize and rehearse your script.")
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

// MARK: - Practice Script List Row

struct PracticeScriptRow: View {
    let script: PracticeScript

    private var latestSession: PracticeSession? {
        script.sessions.sorted {
            if $0.date != $1.date {
                return $0.date > $1.date
            }
            return $0.sessionNumber > $1.sessionNumber
        }.first
    }

    private var accuracyPercentage: Int? {
        guard let session = latestSession else { return nil }
        let scriptModel = PracticeScriptModel(script: script)
        let totalTargetWords = scriptModel.actorTokens.count
        guard totalTargetWords > 0 else { return nil }
        let errors = session.skippedCount + session.forgotCount
        let correct = max(0, totalTargetWords - errors)
        let pct = Int(round(Double(correct) / Double(totalTargetWords) * 100.0))
        return min(100, max(0, pct))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Text(script.title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1)

                Spacer()

                if let accuracy = accuracyPercentage {
                    Text("\(accuracy)% accuracy")
                        .statusBadge(color: accuracy >= 85 ? Theme.Colors.successGreen : Theme.Colors.accent)
                } else {
                    let cueCount = script.cueLines.count
                    Text(cueCount == 1 ? "1 cue" : "\(cueCount) cues")
                        .statusBadge(color: Theme.Colors.accent)
                }
            }

            HStack(spacing: 6) {
                Text(script.languageRaw)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1)

                Text("•")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Colors.textSecondary)

                let cueCount = script.cueLines.count
                Text(cueCount == 1 ? "1 Cue" : "\(cueCount) Cues")
                    .font(.system(size: 13, weight: .medium))
                    .italic()
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(1)

                if !script.sessions.isEmpty {
                    Text("•")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.Colors.textSecondary)

                    Text(script.sessions.count == 1 ? "1 run" : "\(script.sessions.count) runs")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .lineLimit(1)
                }
            }

            HStack(spacing: 5) {
                Image(systemName: "clock")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textSecondary)

                Text(lastPracticedText(for: script.lastPracticedAt))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
        .padding(.vertical, 8)
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
