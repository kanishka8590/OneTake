import SwiftUI
import SwiftData
import PhotosUI

struct ProfileView: View {
    @Environment(AppState.self) private var envAppState
    private let explicitAppState: AppState?

    init(appState: AppState? = nil) {
        self.explicitAppState = appState
    }

    private var appState: AppState {
        explicitAppState ?? envAppState
    }

    @State private var showingEditProfile = false
    @State private var showingLogoutConfirmation = false
    @State private var showingSignIn = false

    var user: UserProfile {
        appState.currentUser ?? UserProfile(
            name: "Actor Profile",
            email: ""
        )
    }

    var body: some View {
        NavigationStack {
            List {
                    // Header / Actor Card
                    Section {
                        actorHeaderCard
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }

                    // Key Audition Metrics
                    Section("Studio Metrics") {
                        HStack {
                            Label("Active Auditions", systemImage: "film")
                            Spacer()
                            Text("\(appState.activeAuditionsCount)")
                                .font(Theme.Typography.cardTitle)
                                .foregroundStyle(Theme.Colors.accent)
                        }

                        HStack {
                            Label("Submitted Auditions", systemImage: "checkmark.circle")
                            Spacer()
                            Text("\(appState.sentAuditionsCount)")
                                .font(Theme.Typography.cardTitle)
                                .foregroundStyle(Theme.Colors.successGreen)
                        }
                    }

                    // Previous Work Section
                    if !user.previousWork.isEmpty {
                        Section("Credits & Previous Work") {
                            ForEach(Array(user.previousWork.enumerated()), id: \.offset) { _, work in
                                HStack(spacing: 8) {
                                    Image(systemName: "star")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.Colors.warningAmber)
                                        .accessibilityHidden(true)
                                    Text(work)
                                        .font(Theme.Typography.bodyRegular)
                                        .foregroundStyle(Theme.Colors.textPrimary)
                                }
                            }
                        }
                    }

                    // Profile & App Settings
                    Section("Profile & settings") {
                        NavigationLink("Recording settings") { RecordingSettingsView(appState: appState) }
                        NavigationLink("Notification Preferences") { NotificationPreferencesView(appState: appState) }
                        NavigationLink("Privacy & data") { PrivacyAndDataView(appState: appState) }
                    }

                    // Demo Mode
                    Section {
                        Toggle(
                            "Demo Mode",
                            isOn: Binding(
                                get: { appState.isDemoMode },
                                set: { enabled in
                                    if enabled {
                                        appState.enterDemoMode()
                                    } else {
                                        appState.exitDemoMode()
                                    }
                                }
                            )
                        )
                        .tint(Theme.Colors.accent)

                        if appState.isDemoMode {
                            Button("Reset Demo Data") {
                                appState.resetDemoData()
                            }
                        }
                    } header: {
                        Text("Demo Mode")
                    } footer: {
                        Text(
                            appState.isDemoMode
                                ? "Demo Mode is active with sample auditions and scripts. Turning it off removes sample data while keeping your own work."
                                : "Load sample auditions, scripts, and takes to explore OneTake."
                        )
                    }

                    // Account Actions
                    Section {
                        if appState.isAuthenticated {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(user.name.isEmpty ? "Signed in" : user.name)
                                    .font(Theme.Typography.cardTitle)
                                    .foregroundStyle(Theme.Colors.textPrimary)
                                if !user.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text(user.email)
                                        .font(Theme.Typography.captionBadge)
                                        .foregroundStyle(Theme.Colors.textSecondary)
                                }
                            }

                            Button(role: .destructive) {
                                showingLogoutConfirmation = true
                            } label: {
                                HStack {
                                    Spacer()
                                    Text("Sign out")
                                        .font(Theme.Typography.cardTitle)
                                    Spacer()
                                }
                            }
                        } else {
                            Button {
                                showingSignIn = true
                            } label: {
                                HStack {
                                    Spacer()
                                    Text("Sign in")
                                        .font(Theme.Typography.cardTitle)
                                        .foregroundStyle(Theme.Colors.accent)
                                    Spacer()
                                }
                            }
                        }
                    } header: {
                        Text("Account")
                    } footer: {
                        if !appState.isAuthenticated {
                            Text("Sign-in is optional. Your auditions, scripts, and takes stay stored locally on this device.")
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .listSectionSpacing(.compact)
                .scrollContentBackground(.hidden)
                .background(Theme.Colors.canvasBackground.ignoresSafeArea())
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.large)
            .task {
                await appState.refreshLocalStorageUsage()
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") {
                        showingEditProfile = true
                    }
                    .font(Theme.Typography.bodyRegular)
                    .foregroundStyle(Theme.Colors.accent)
                }
            }
            .sheet(isPresented: $showingEditProfile) {
                EditProfileSheet(appState: appState, isPresented: $showingEditProfile)
            }
            .sheet(isPresented: $showingSignIn) {
                AuthView(appState: appState)
            }
            .confirmationDialog("Sign Out?", isPresented: $showingLogoutConfirmation) {
                Button("Sign Out", role: .destructive) {
                    withAnimation {
                        appState.logout()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Signing out keeps your local auditions, scripts, and profile on this device.")
            }
        }
    }

    // MARK: - Actor Header Card

    private var actorHeaderCard: some View {
        VStack(spacing: 12) {
            Group {
                if let data = user.avatarImageData, let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 84, height: 84)
                        .clipShape(Circle())
                } else {
                    ZStack {
                        Circle()
                            .fill(Theme.Colors.lavenderSurface)
                            .frame(width: 84, height: 84)

                        Text(userInitials)
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.Colors.accent)
                    }
                }
            }
            .accessibilityLabel("Profile photo")

            VStack(spacing: 4) {
                Text(user.name.isEmpty ? "Actor Profile" : user.name)
                    .font(Theme.Typography.screenTitle)
                    .foregroundStyle(Theme.Colors.textPrimary)

                if !user.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(user.email)
                        .font(Theme.Typography.bodyRegular)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }

                if appState.isDemoMode {
                    Text("Demo Mode")
                        .statusBadge(color: Theme.Colors.accent)
                        .padding(.top, 4)
                }
            }

            HStack(spacing: 16) {
                if !user.height.isEmpty {
                    infoPill(label: "Height", value: user.height)
                }
                if user.age > 0 {
                    infoPill(label: "Age", value: "\(user.age)")
                }
                if !user.basedIn.isEmpty {
                    infoPill(label: "Based In", value: user.basedIn)
                }
            }

            let rep = user.representation.trimmingCharacters(in: .whitespacesAndNewlines)
            Text("Representation: \(rep.isEmpty ? "Self-represented" : rep)")
                .font(Theme.Typography.captionBadge)
                .foregroundStyle(Theme.Colors.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Theme.Colors.lavenderTint)
                .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Theme.Colors.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Layout.cardCornerRadius))
        .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 2)
    }

    private func infoPill(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.Colors.textSecondary)
            Text(value)
                .font(Theme.Typography.captionBadge)
                .foregroundStyle(Theme.Colors.textPrimary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Theme.Colors.lavenderSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var userInitials: String {
        let trimmed = user.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "A" }
        let components = trimmed.split(separator: " ")
        if components.count >= 2,
           let first = components[0].first,
           let second = components[1].first {
            return "\(first)\(second)".uppercased()
        }
        return String(trimmed.prefix(2)).uppercased()
    }
}

// MARK: - Edit Profile Sheet

struct EditProfileSheet: View {
    private struct CreditItem: Identifiable {
        let id = UUID()
        var title: String
    }

    let appState: AppState
    @Binding var isPresented: Bool

    @State private var name: String = ""
    @State private var email: String = ""
    @State private var height: String = ""
    @State private var ageText: String = ""
    @State private var basedIn: String = ""
    @State private var representation: String = ""
    @State private var newCredit: String = ""
    @State private var creditItems: [CreditItem] = []
    @State private var stagedAvatarData: Data? = nil
    @State private var photoItem: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile photo") {
                    HStack(spacing: 16) {
                        if let data = stagedAvatarData, let uiImage = UIImage(data: data) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 56, height: 56)
                                .clipShape(Circle())
                        } else {
                            ZStack {
                                Circle()
                                    .fill(Theme.Colors.lavenderSurface)
                                    .frame(width: 56, height: 56)
                                Image(systemName: "person")
                                    .font(.system(size: 24))
                                    .foregroundStyle(Theme.Colors.accent)
                            }
                            .accessibilityHidden(true)
                        }

                        PhotosPicker(selection: $photoItem, matching: .images) {
                            Label(
                                stagedAvatarData == nil ? "Choose photo" : "Change photo",
                                systemImage: "person.crop.circle.badge.plus"
                            )
                        }
                    }

                    if stagedAvatarData != nil {
                        Button("Remove photo", role: .destructive) {
                            stagedAvatarData = nil
                            photoItem = nil
                        }
                    }
                }

                Section("Personal Details") {
                    LabeledContent("Name") {
                        TextField("Full Name", text: $name)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Email") {
                        TextField("Email", text: $email)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Height") {
                        TextField("e.g. 5'6\"", text: $height)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Age") {
                        TextField("Age", text: $ageText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Based In") {
                        TextField("City", text: $basedIn)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Representation") {
                        TextField("Agency or Self-represented", text: $representation)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section("Credits & Past Projects") {
                    ForEach(creditItems) { item in
                        Text(item.title)
                    }
                    .onDelete { indices in
                        creditItems.remove(atOffsets: indices)
                    }

                    HStack {
                        TextField("Add project (e.g. Film Title)", text: $newCredit)
                        Button("Add") {
                            let trimmed = newCredit.trimmingCharacters(in: .whitespaces)
                            if !trimmed.isEmpty {
                                creditItems.append(CreditItem(title: trimmed))
                                newCredit = ""
                            }
                        }
                        .disabled(newCredit.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveProfile()
                    }
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Colors.accent)
                }
            }
            .onAppear {
                if let u = appState.currentUser {
                    name = u.name
                    email = u.email
                    height = u.height
                    ageText = u.age > 0 ? "\(u.age)" : ""
                    basedIn = u.basedIn
                    representation = u.representation
                    creditItems = u.previousWork.map { CreditItem(title: $0) }
                    stagedAvatarData = u.avatarImageData
                }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        await MainActor.run {
                            stagedAvatarData = data
                        }
                    }
                }
            }
        }
    }

    private func saveProfile() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)
        let trimmedHeight = height.trimmingCharacters(in: .whitespaces)
        let age = Int(ageText) ?? 0
        let trimmedBasedIn = basedIn.trimmingCharacters(in: .whitespaces)
        let trimmedRep = representation.trimmingCharacters(in: .whitespaces)
        let resolvedRep = trimmedRep.isEmpty ? "Self-represented" : trimmedRep
        let updatedCredits = creditItems.map(\.title)

        if let current = appState.currentUser {
            current.name = trimmedName
            current.email = trimmedEmail
            current.height = trimmedHeight
            current.age = age
            current.basedIn = trimmedBasedIn
            current.representation = resolvedRep
            current.previousWork = updatedCredits
            current.avatarImageData = stagedAvatarData
            appState.saveChanges()
        } else {
            appState.createOrUpdateProfile(
                name: trimmedName,
                email: trimmedEmail,
                height: trimmedHeight,
                age: age,
                basedIn: trimmedBasedIn,
                representation: resolvedRep
            )
            if let current = appState.currentUser {
                current.previousWork = updatedCredits
                current.avatarImageData = stagedAvatarData
                appState.saveChanges()
            }
        }
        isPresented = false
    }
}

#Preview {
    ProfileView()
        .environment(MockData.sampleAppState)
}
