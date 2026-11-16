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

    private static func outlineTabIcon(systemName: String) -> UIImage {
        let config = UIImage.SymbolConfiguration(pointSize: 19, weight: .regular)
        guard let symbol = UIImage(systemName: systemName, withConfiguration: config) else {
            return UIImage()
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3.0
        format.opaque = false
        let rendered = UIGraphicsImageRenderer(size: symbol.size, format: format).image { _ in
            symbol.withTintColor(.black, renderingMode: .alwaysOriginal)
                .draw(in: CGRect(origin: .zero, size: symbol.size))
        }
        return rendered.withRenderingMode(.alwaysTemplate)
    }

    var body: some View {
        TabView(selection: Bindable(appState).selectedTab) {
            AuditionsListView(appState: appState)
                .tabItem {
                    Label {
                        Text("Auditions")
                    } icon: {
                        Image(uiImage: Self.outlineTabIcon(systemName: "movieclapper"))
                    }
                }
                .tag(AppTab.auditions)

            PracticeHubView(appState: appState)
                .tabItem {
                    Label {
                        Text("Practice")
                    } icon: {
                        Image(uiImage: Self.outlineTabIcon(systemName: "theatermasks"))
                    }
                }
                .tag(AppTab.practice)

            ProfileView(appState: appState)
                .tabItem {
                    Label {
                        Text("Profile")
                    } icon: {
                        Image(uiImage: Self.outlineTabIcon(systemName: "person.crop.circle"))
                    }
                }
                .tag(AppTab.profile)
        }
        .environment(\.symbolVariants, .none)
        .tint(Theme.Colors.accent)
    }
}

#Preview {
    MainTabView()
        .environment(MockData.sampleAppState)
        .modelContainer(MockData.previewContainer)
}
