//
//  OneTakeApp.swift
//  OneTake
//
//  The entry point for OneTake — "From first take to final cut"
//  A native iOS self-tape audition and scene-rehearsal app.
//

import SwiftUI
import SwiftData

@main
struct OneTakeApp: App {
    @State private var appState = AppState()
    @State private var showSplash = true

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            UserProfile.self,
            Audition.self,
            PracticeScript.self,
        ])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false
        )

        do {
            return try ModelContainer(
                for: schema,
                configurations: [modelConfiguration]
            )
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootContentView(showSplash: $showSplash)
                .environment(appState)
        }
        .modelContainer(sharedModelContainer)
    }
}

struct RootContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Binding var showSplash: Bool

    var body: some View {
        Group {
            if showSplash {
                SplashView {
                    showSplash = false
                }
            } else if !appState.hasCompletedOnboarding {
                OnboardingView()
            } else if !appState.isAuthenticated {
                AuthView()
            } else {
                MainTabView()
            }
        }
        .onAppear {
            appState.configure(with: modelContext)
        }
    }
}
