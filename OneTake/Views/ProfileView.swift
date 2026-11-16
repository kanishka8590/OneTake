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

    var user: UserProfile {
        appState.currentUser ?? UserProfile(
            name: "Actor Profile",
            email: ""
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.canvasBackground
                    .ignoresSafeArea()

                List {
                    // Header / Actor Card
                    Section {
                        actorHeaderCard
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }

                    // Key Audition & Storage Metrics
                    Section("Studio Metrics") {
                        HStack {
                            Label("Active Auditions", systemImage: "film")
                            Spacer()
                            Text("\(appState.activeAuditionsCount)")
                                .font(Theme.Typography.cardTitle)
                                .foregroundStyle(Theme.Colors.accent)
                        }
                        .frame(minHeight: Theme.Layout.minTapTarget)

                        HStack {
                            Label("Submitted Auditions", systemImage: "checkmark.circle")
                            Spacer()
                            Text("\(appState.sentAuditionsCount)")
                                .font(Theme.Typography.cardTitle)
                                .foregroundStyle(Theme.Colors.successGreen)
                        }
                        .frame(minHeight: Theme.Layout.minTapTarget)

                        HStack {
                            Label("Storage Used", systemImage: "internaldrive")
                            Spacer()
                            Text(String(format: "%.1f MB", max(appState.totalStorageUsedMB, appState.localAppDataUsedMB)))
                                .font(Theme.Typography.bodyRegular)
                                .foregroundStyle(Theme.Colors.textSecondary)
                        }
                        .frame(minHeight: Theme.Layout.minTapTarget)
                    }

                    // Previous Work Section
                    if !user.previousWork.isEmpty {
                        Section("Credits & Previous Work") {
                            ForEach(Array(user.previousWork.enumerated()), id: \.offset) { _, work in
                                HStack(spacing: 8) {
                                    Image(systemName: "star.fill")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.Colors.warningAmber)
                                        .accessibilityHidden(true)
                                    Text(work)
                                        .font(Theme.Typography.bodyRegular)
                                        .foregroundStyle(Theme.Colors.textPrimary)
                                }
                                .frame(minHeight: Theme.Layout.minTapTarget)
                            }
                        }
                    }

                    // Profile & App Settings
                    Section("Profile & settings") {
                        Button("Edit profile") { showingEditProfile = true }
                            .frame(minHeight: Theme.Layout.minTapTarget)
                        NavigationLink("Recording settings") { RecordingSettingsView(appState: appState) }
                            .frame(minHeight: Theme.Layout.minTapTarget)
                        NavigationLink("Notification Preferences") { NotificationPreferencesView(appState: appState) }
                            .frame(minHeight: Theme.Layout.minTapTarget)
                        NavigationLink("Privacy & data") { PrivacyAndDataView(appState: appState) }
                            .frame(minHeight: Theme.Layout.minTapTarget)
                    }

                    // Demo Mode
                    Section {
                        HStack {
                            Label("Demo Mode", systemImage: "sparkles")
                            Spacer()
                            Text(appState.isDemoMode ? "Active" : "Off")
                                .statusBadge(color: appState.isDemoMode ? Theme.Colors.accent : Theme.Colors.textSecondary)
                        }
                        .frame(minHeight: Theme.Layout.minTapTarget)

                        if appState.isDemoMode {
                            Button("Reset Demo Data") {
                                appState.resetDemoData()
                            }
                            .frame(minHeight: Theme.Layout.minTapTarget)

                            Button("Exit Demo Mode", role: .destructive) {
                                appState.exitDemoMode()
                            }
                            .frame(minHeight: Theme.Layout.minTapTarget)
                        } else {
                            Button("Enable Demo Mode") {
                                appState.enterDemoMode()
                            }
                            .frame(minHeight: Theme.Layout.minTapTarget)
                        }
                    } header: {
                        Text("Demo Mode")
                    } footer: {
                        Text(
                            appState.isDemoMode
                                ? "Demo Mode is active with sample auditions and scripts. Exiting removes sample data while keeping your own work."
                                : "Load sample auditions, scripts, and takes to explore OneTake."
                        )
                    }

                    // Account Actions
                    Section {
                        Button(role: .destructive) {
                            showingLogoutConfirmation = true
                        } label: {
                            HStack {
                                Spacer()
                                Text("Sign out")
                                    .font(Theme.Typography.cardTitle)
                                Spacer()
                            }
                            .frame(minHeight: Theme.Layout.minTapTarget)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Profile")
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
                    .frame(minWidth: Theme.Layout.minTapTarget, minHeight: Theme.Layout.minTapTarget)
                }
            }
            .sheet(isPresented: $showingEditProfile) {
                EditProfileSheet(appState: appState, isPresented: $showingEditProfile)
            }
            .confirmationDialog("Sign Out?", isPresented: $showingLogoutConfirmation) {
                Button("Sign Out", role: .destructive) {
                    withAnimation {
                        appState.logout()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Are you sure you want to sign out of OneTake?")
            }
        }
    }

    // MARK: - Actor Header Card

    private var actorHeaderCard: some View {
        VStack(spacing: 16) {
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
        .padding(.vertical, 20)
        .background(Theme.Colors.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Layout.cardCornerRadius))
        .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 2)
        .padding(.horizontal, 4)
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
                                Image(systemName: "person.fill")
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
                    TextField("Full Name", text: $name)
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                    TextField("Height (e.g. 5'6\")", text: $height)
                    TextField("Age", text: $ageText)
                        .keyboardType(.numberPad)
                    TextField("Based In (e.g. Mumbai, India)", text: $basedIn)
                    TextField("Representation (e.g. Agency Name or Self-represented)", text: $representation)
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
                        .frame(minWidth: Theme.Layout.minTapTarget, minHeight: Theme.Layout.minTapTarget)
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
                    .frame(minWidth: Theme.Layout.minTapTarget, minHeight: Theme.Layout.minTapTarget)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveProfile()
                    }
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Colors.accent)
                    .frame(minWidth: Theme.Layout.minTapTarget, minHeight: Theme.Layout.minTapTarget)
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
