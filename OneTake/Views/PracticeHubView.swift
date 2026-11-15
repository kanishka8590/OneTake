import SwiftUI
import SwiftData

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
                        if let latest = appState.practiceScripts.flatMap(\.sessions).sorted(by: { $0.date > $1.date }).first,
                           let latestScript = appState.practiceScripts.first(where: { $0.sessions.contains(where: { $0.id == latest.id }) }) {
                            Section("LAST RUN") {
                                NavigationLink {
                                    PracticeReviewView(script: latestScript, session: latest, appState: appState)
                                } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(latestScript.title).font(Theme.Typography.cardTitle)
                                        Text("\(latestScript.sessions.count) completed session\(latestScript.sessions.count == 1 ? "" : "s")")
                                            .font(Theme.Typography.captionBadge).foregroundStyle(Theme.Colors.textSecondary)
                                        HStack { Text("Review"); Spacer(); Text("Run it again").foregroundStyle(Theme.Colors.primaryPlum) }
                                            .font(.system(size: 14, weight: .semibold))
                                    }
                                }
                            }
                        }
                        Section {
                            ForEach(appState.practiceScripts) { script in
                                NavigationLink {
                                    MemoriseView(script: script, appState: appState)
                                } label: {
                                    PracticeScriptCardRow(script: script)
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
                                .foregroundStyle(Theme.Colors.primaryPlum)
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

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Theme.Colors.lavenderSurface)
                    .frame(width: 80, height: 80)

                Image(systemName: "text.book.closed")
                    .font(.system(size: 36))
                    .foregroundStyle(Theme.Colors.primaryPlum)
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

      //
            .padding(.top, 8)
        }
        .padding(.horizontal, 24)
    }
}

// MARK: - Script Card Row

struct PracticeScriptCardRow: View {
    let script: PracticeScript

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(script.title)
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1)

                Spacer()

                Text(script.language.rawValue)
                    .statusBadge(color: Theme.Colors.primaryPlum)
            }

            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Image(systemName: "waveform")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.textSecondary)
                    Text("\(script.cueLines.count) cue lines")
                        .font(Theme.Typography.captionBadge)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }

                Text("•")
                    .foregroundStyle(Theme.Colors.textSecondary)

                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.textSecondary)
                    if let last = script.lastPracticedAt {
                        Text("Practiced \(last.formatted(date: .abbreviated, time: .shortened))")
                            .font(Theme.Typography.captionBadge)
                            .foregroundStyle(Theme.Colors.textSecondary)
                    } else {
                        Text("Never practiced")
                            .font(Theme.Typography.captionBadge)
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .frame(minHeight: Theme.Layout.minTapTarget)
    }
}

// MARK: - Add Practice Script Sheet

struct AddPracticeScriptSheet: View {
    let appState: AppState
    @Binding var isPresented: Bool

    @State private var title = ""
    @State private var language = ScriptLanguage.english
    @State private var rawText = ""

    var isValid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty &&
        !rawText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Script Details") {
                    TextField("Script Title (e.g., Noah & Allie)", text: $title)

                    Picker("Language", selection: $language) {
                        ForEach(ScriptLanguage.allCases, id: \.self) { lang in
                            Text(lang.rawValue).tag(lang)
                        }
                    }
                }

                Section("Dialogue Sides") {
                    TextField("Paste scene text with character names in ALL CAPS...", text: $rawText, axis: .vertical)
                        .lineLimit(6...12)
                }
            }
            .navigationTitle("New Practice Script")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                    .frame(minWidth: Theme.Layout.minTapTarget, minHeight: Theme.Layout.minTapTarget)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveScript()
                    }
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(isValid ? Theme.Colors.primaryPlum : Theme.Colors.textSecondary)
                    .disabled(!isValid)
                    .frame(minWidth: Theme.Layout.minTapTarget, minHeight: Theme.Layout.minTapTarget)
                }
            }
        }
    }

    private func saveScript() {
        let script = PracticeScript(
            title: title.trimmingCharacters(in: .whitespaces),
            languageRaw: language.rawValue,
            rawText: rawText.trimmingCharacters(in: .whitespaces)
        )
        appState.addPracticeScript(script)
        isPresented = false
    }
}

#Preview {
    PracticeHubView()
        .environment(MockData.sampleAppState)
}
