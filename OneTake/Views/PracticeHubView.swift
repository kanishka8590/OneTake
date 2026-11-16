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

                if !appState.globalSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    GlobalSearchView(appState: appState)
                        .environment(appState)
                } else if appState.practiceScripts.isEmpty {
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
                                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
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
            .navigationBarTitleDisplayMode(.large)
            .searchable(
                text: Bindable(appState).globalSearchQuery,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search auditions & script sides"
            )
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
            .onAppear {
                if ProcessInfo.processInfo.arguments.contains("-OpenAddSceneSheet") {
                    showingAddSheet = true
                } else if ProcessInfo.processInfo.arguments.contains("-OpenUnifiedPractice") {
                    scriptToOpen = appState.practiceScripts.first(where: { $0.title.contains("Noah") }) ?? appState.practiceScripts.first
                }
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

            Button {
                showingAddSheet = true
            } label: {
                Label("Add a Scene", systemImage: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: 200)
                    .padding(.vertical, 12)
                    .background(Theme.Colors.primaryPlum)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
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
        VStack(alignment: .leading, spacing: 12) {
            // Title & Badges
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Text(script.title)
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Colors.textSecondary.opacity(0.4))
                }

                HStack(spacing: 6) {
                    // Language badge
                    Text(script.languageRaw.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.Colors.lavenderSurface)
                        .foregroundStyle(Theme.Colors.accent)
                        .clipShape(Capsule())

                    // Cues badge
                    let cueCount = script.cueLines.count
                    Text(cueCount == 1 ? "1 CUE" : "\(cueCount) CUES")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.Colors.surfaceElevated)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .clipShape(Capsule())

                    // Accuracy badge
                    if let accuracy = accuracyPercentage {
                        HStack(spacing: 3) {
                            Image(systemName: accuracy >= 85 ? "checkmark.circle" : "chart.bar")
                                .font(.system(size: 9))
                            Text("\(accuracy)% ACCURACY")
                        }
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(accuracy >= 85 ? Theme.Colors.successGreen.opacity(0.15) : Theme.Colors.accent.opacity(0.15))
                        .foregroundStyle(accuracy >= 85 ? Theme.Colors.successGreen : Theme.Colors.accent)
                        .clipShape(Capsule())
                    }
                }
            }

            // Metadata / Runs
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 12))
                    Text(lastPracticedText(for: script.lastPracticedAt))
                        .font(Theme.Typography.captionBadge)
                }
                .foregroundStyle(Theme.Colors.textSecondary)

                if !script.sessions.isEmpty {
                    Text("•")
                        .foregroundStyle(Theme.Colors.textSecondary.opacity(0.5))

                    HStack(spacing: 4) {
                        Image(systemName: "repeat")
                            .font(.system(size: 12))
                        Text(script.sessions.count == 1 ? "1 run" : "\(script.sessions.count) runs")
                            .font(Theme.Typography.captionBadge)
                    }
                    .foregroundStyle(Theme.Colors.textSecondary)
                }

                Spacer()
            }

            Divider()
                .background(Theme.Colors.controlBorder.opacity(0.5))

            // Action Bar
            HStack(spacing: 8) {
                Button(action: onOpen) {
                    HStack(spacing: 6) {
                        Image(systemName: "book.pages")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Practice")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Theme.Colors.primaryPlum)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)

                Button(action: onRunAgain) {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Run Aloud")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Theme.Colors.lavenderSurface)
                    .foregroundStyle(Theme.Colors.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)

                if let latestSession {
                    Button {
                        onReview(latestSession)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Review")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Theme.Colors.surfaceElevated)
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.Colors.controlBorder, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(Theme.Colors.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.Colors.controlBorder, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture {
            onOpen()
        }
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
