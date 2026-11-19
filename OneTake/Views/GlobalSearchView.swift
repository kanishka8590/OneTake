import SwiftUI

struct GlobalSearchSections: View {
    let appState: AppState

    private var trimmedQuery: String {
        appState.globalSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        let results = appState.searchResults
        let hasResults = !results.auditions.isEmpty || !results.scripts.isEmpty

        if trimmedQuery.isEmpty {
            Section {
                Color.clear
                    .frame(height: 1)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        } else if !hasResults {
            Section {
                Color.clear
                    .frame(height: 1)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        } else {
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
                                .toolbar(.hidden, for: .tabBar)
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

struct GlobalSearchView: View {
    @Environment(AppState.self) private var envAppState
    private let explicitAppState: AppState?

    init(appState: AppState? = nil) {
        self.explicitAppState = appState
    }

    private var appState: AppState {
        explicitAppState ?? envAppState
    }

    private var trimmedQuery: String {
        appState.globalSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        let results = appState.searchResults
        let hasResults = !results.auditions.isEmpty || !results.scripts.isEmpty

        List {
            GlobalSearchSections(appState: appState)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.Colors.canvasBackground.ignoresSafeArea())
        .overlay {
            if trimmedQuery.isEmpty {
                ContentUnavailableView(
                    "Search OneTake",
                    systemImage: "magnifyingglass",
                    description: Text("Find casting calls, roles, characters, or dialogue lines.")
                )
            } else if !hasResults {
                ContentUnavailableView(
                    "No results for \"\(trimmedQuery)\"",
                    systemImage: "magnifyingglass",
                    description: Text("Try searching for a project, role, character, or dialogue line.")
                )
            }
        }
    }
}

#Preview {
    NavigationStack {
        GlobalSearchView()
            .environment(MockData.sampleAppState)
    }
}
