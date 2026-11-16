import SwiftUI

struct GlobalSearchView: View {
    @Environment(AppState.self) private var envAppState
    private let explicitAppState: AppState?

    init(appState: AppState? = nil) {
        self.explicitAppState = appState
    }

    private var appState: AppState {
        explicitAppState ?? envAppState
    }

    var body: some View {
        let results = appState.searchResults
        let hasResults = !results.auditions.isEmpty || !results.scripts.isEmpty

        ZStack {
            Theme.Colors.canvasBackground
                .ignoresSafeArea()

            if !hasResults {
                VStack(spacing: 16) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 48))
                        .foregroundStyle(Theme.Colors.textSecondary.opacity(0.6))
                        .accessibilityHidden(true)

                    Text("No results for \"\(appState.globalSearchQuery)\"")
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.Colors.textPrimary)

                    Text("Try searching for a project, role, character, or dialogue line.")
                        .font(Theme.Typography.bodyRegular)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    // Auditions Section
                    if !results.auditions.isEmpty {
                        Section {
                            ForEach(results.auditions) { audition in
                                NavigationLink {
                                    AuditionPackageHubView(audition: audition)
                                        .environment(appState)
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Text(audition.projectName)
                                                .font(Theme.Typography.cardTitle)
                                                .foregroundStyle(Theme.Colors.textPrimary)

                                            Spacer()

                                            Text(audition.status.rawValue)
                                                .statusBadge(color: audition.status == .sent ? Theme.Colors.successGreen : Theme.Colors.accent)
                                        }

                                        HStack(spacing: 8) {
                                            Text("Role: \(audition.roleName)")
                                                .font(Theme.Typography.bodyRegular)
                                                .foregroundStyle(Theme.Colors.textSecondary)

                                            Text("•")
                                                .foregroundStyle(Theme.Colors.textSecondary)
                                                .accessibilityHidden(true)

                                            Text(audition.production.rawValue)
                                                .font(Theme.Typography.captionBadge)
                                                .foregroundStyle(Theme.Colors.textSecondary)
                                        }
                                    }
                                    .padding(.vertical, 6)
                                }
                                .frame(minHeight: Theme.Layout.minTapTarget)
                            }
                        } header: {
                            Text("Auditions (\(results.auditions.count))")
                                .font(Theme.Typography.captionBadge)
                                .foregroundStyle(Theme.Colors.textSecondary)
                        }
                    }

                    // Script Sides Section
                    if !results.scripts.isEmpty {
                        Section {
                            ForEach(results.scripts) { script in
                                NavigationLink {
                                    MemoriseView(script: script, appState: appState)
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Text(script.title)
                                                .font(Theme.Typography.cardTitle)
                                                .foregroundStyle(Theme.Colors.textPrimary)

                                            Spacer()

                                            Text(script.language.rawValue)
                                                .statusBadge(color: Theme.Colors.accent)
                                        }

                                        if let snippet = matchingSnippet(in: script.rawText, for: appState.globalSearchQuery) {
                                            Text(snippet)
                                                .font(Theme.Typography.captionBadge)
                                                .foregroundStyle(Theme.Colors.textSecondary)
                                                .lineLimit(2)
                                                .italic()
                                        }
                                    }
                                    .padding(.vertical, 6)
                                }
                                .frame(minHeight: Theme.Layout.minTapTarget)
                            }
                        } header: {
                            Text("Script Sides (\(results.scripts.count))")
                                .font(Theme.Typography.captionBadge)
                                .foregroundStyle(Theme.Colors.textSecondary)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") {
                    appState.globalSearchQuery = ""
                }
            }
        }
    }

    private func matchingSnippet(in text: String, for query: String) -> String? {
        guard let range = text.range(of: query, options: .caseInsensitive) else {
            return text.components(separatedBy: .newlines).first
        }
        let start = text.index(range.lowerBound, offsetBy: -30, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 50, limitedBy: text.endIndex) ?? text.endIndex
        let snippet = String(text[start..<end]).replacingOccurrences(of: "\n", with: " ")
        return "..." + snippet.trimmingCharacters(in: .whitespaces) + "..."
    }
}

#Preview {
    NavigationStack {
        GlobalSearchView()
            .environment(MockData.sampleAppState)
    }
}
