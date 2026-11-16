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

    private let sharedModelContainer: ModelContainer
    private let containerInitWarning: String?

    init() {
        let schema = Schema([
            UserProfile.self,
            Audition.self,
            PracticeScript.self,
        ])
        let persistentConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false
        )

        do {
            sharedModelContainer = try ModelContainer(
                for: schema,
                configurations: [persistentConfiguration]
            )
            containerInitWarning = nil
        } catch {
            print("Could not open persistent ModelContainer: \(error). Falling back to in-memory storage.")
            let fallbackConfiguration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true
            )
            do {
                sharedModelContainer = try ModelContainer(
                    for: schema,
                    configurations: [fallbackConfiguration]
                )
                containerInitWarning = "Unable to open on-device storage. Using temporary in-memory storage for this session."
            } catch {
                preconditionFailure("Could not create even an in-memory ModelContainer: \(error)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootContentView(
                showSplash: $showSplash,
                containerInitWarning: containerInitWarning
            )
            .environment(appState)
        }
        .modelContainer(sharedModelContainer)
    }
}

struct RootContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Binding var showSplash: Bool
    var containerInitWarning: String? = nil

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
        .task {
            appState.configure(with: modelContext)
            if let containerInitWarning {
                appState.lastPersistenceError = containerInitWarning
            }
            await appState.refreshLocalStorageUsage()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                appState.saveChanges()
            }
        }
    }
}
