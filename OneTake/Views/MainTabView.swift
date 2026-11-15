import SwiftUI
import SwiftData

struct MainTabView: View {
    @Environment(AppState.self) private var envAppState
    private let explicitAppState: AppState?

    init(appState: AppState? = nil) {
        self.explicitAppState = appState
    }

    private var appState: AppState {
        explicitAppState ?? envAppState
    }

    var body: some View {
        TabView(selection: Bindable(appState).selectedTab) {
            AuditionsListView()
                .tabItem {
                    Label("Auditions", systemImage: "movieclapper.fill")
                }
                .tag(AppTab.auditions)

            PracticeHubView(appState: appState)
                .tabItem {
                    Label("Practice", systemImage: "theatermasks.fill")
                }
                .tag(AppTab.practice)

            ProfileView(appState: appState)
                .tabItem {
                    Label("Profile", systemImage: "person.crop.circle")
                }
                .tag(AppTab.profile)
        }
        .tint(Theme.Colors.accent)
        .searchable(
            text: Bindable(appState).globalSearchQuery,
            prompt: "Search auditions & script sides"
        )
        .overlay {
            if !appState.globalSearchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                NavigationStack {
                    GlobalSearchView(appState: appState)
                }
            }
        }
    }
}

#Preview {
    MainTabView()
        .environment(MockData.sampleAppState)
        .modelContainer(MockData.previewContainer)
}
