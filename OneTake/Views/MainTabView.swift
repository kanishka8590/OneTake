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
            AuditionsListView(appState: appState)
                .tabItem {
                    Label("Auditions", systemImage: "movieclapper")
                }
                .tag(AppTab.auditions)

            PracticeHubView(appState: appState)
                .tabItem {
                    Label("Practice", systemImage: "theatermasks")
                }
                .tag(AppTab.practice)

            ProfileView(appState: appState)
                .tabItem {
                    Label("Profile", systemImage: "person.crop.circle")
                }
                .tag(AppTab.profile)
        }
        .tint(Theme.Colors.accent)
    }
}

#Preview {
    MainTabView()
        .environment(MockData.sampleAppState)
        .modelContainer(MockData.previewContainer)
}
