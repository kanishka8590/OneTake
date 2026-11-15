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
            email: "actor@onetake.app"
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
                            Text(String(format: "%.1f MB", appState.totalStorageUsedMB))
                                .font(Theme.Typography.bodyRegular)
                                .foregroundStyle(Theme.Colors.textSecondary)
                        }
                        .frame(minHeight: Theme.Layout.minTapTarget)
                    }

                    // Previous Work Section
                    if !user.previousWork.isEmpty {
                        Section("Credits & Previous Work") {
                            ForEach(user.previousWork, id: \.self) { work in
                                HStack(spacing: 8) {
                                    Image(systemName: "star.fill")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.Colors.warningAmber)
                                    Text(work)
                                        .font(Theme.Typography.bodyRegular)
                                        .foregroundStyle(Theme.Colors.textPrimary)
                                }
                                .frame(minHeight: Theme.Layout.minTapTarget)
                            }
                        }
                    }

                    // App Settings
                    Section("Profile & settings") {
                        Button("Edit slate") { showingEditProfile = true }
                        NavigationLink("Recording settings") { RecordingSettingsView(appState: appState) }
                        NavigationLink("Notification Preferences") { NotificationPreferencesView(appState: appState) }
                        NavigationLink("Privacy & data") { PrivacyAndDataView(appState: appState) }
                    }

                    // Existing quick controls remain here for actors who prefer
                    // adjusting a take without leaving their profile.
                    Section("Recording & Self-Tape Settings") {
                        Picker("Countdown Timer", selection: Bindable(appState.settings).countdownSeconds) {
                            Text("3 seconds").tag(3)
                            Text("5 seconds").tag(5)
                            Text("10 seconds").tag(10)
                        }
                        .frame(minHeight: Theme.Layout.minTapTarget)

                        Toggle("Auto-Trim Silence", isOn: Bindable(appState.settings).autoTrimSilence)
                            .tint(Theme.Colors.accent)
                            .frame(minHeight: Theme.Layout.minTapTarget)

                        Toggle("Noise Reduction by Default", isOn: Bindable(appState.settings).noiseReductionDefault)
                            .tint(Theme.Colors.accent)
                            .frame(minHeight: Theme.Layout.minTapTarget)

                        Toggle("Mirror Front Camera", isOn: Bindable(appState.settings).mirrorFrontCamera)
                            .tint(Theme.Colors.accent)
                            .frame(minHeight: Theme.Layout.minTapTarget)

                        Picker("Video Quality", selection: Bindable(appState.settings).videoQuality) {
                            ForEach(VideoQuality.allCases, id: \.self) { q in
                                Text(q.rawValue).tag(q)
                            }
                        }
                        .frame(minHeight: Theme.Layout.minTapTarget)
                    }

                    // Teleprompter & Rehearsal Settings
                    Section("Rehearsal & Teleprompter") {
                        Picker("Prompt Text Size", selection: Bindable(appState.settings).teleprompterTextSize) {
                            ForEach(TeleprompterTextSize.allCases, id: \.self) { size in
                                Text(size.rawValue).tag(size)
                            }
                        }
                        .frame(minHeight: Theme.Layout.minTapTarget)

                        Picker("Cue Trigger Mode", selection: Bindable(appState.settings).cueTriggerMode) {
                            ForEach(CueTriggerMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .frame(minHeight: Theme.Layout.minTapTarget)
                    }

                    // Notifications
                    Section("Notifications") {
                        Toggle("Audition Deadlines", isOn: Bindable(appState.settings).notifyAuditions)
                            .tint(Theme.Colors.accent)
                            .frame(minHeight: Theme.Layout.minTapTarget)

                        Toggle("Practice Reminders", isOn: Bindable(appState.settings).notifyPractice)
                            .tint(Theme.Colors.accent)
                            .frame(minHeight: Theme.Layout.minTapTarget)
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
            .confirmationDialog("Log Out?", isPresented: $showingLogoutConfirmation) {
                Button("Log Out", role: .destructive) {
                    withAnimation {
                        appState.logout()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Are you sure you want to log out of OneTake?")
            }
        }
    }

    // MARK: - Actor Header Card

    private var actorHeaderCard: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Theme.Colors.lavenderSurface)
                    .frame(width: 84, height: 84)

                Text(userInitials)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.Colors.accent)
            }

            VStack(spacing: 4) {
                Text(user.name.isEmpty ? "Actor Profile" : user.name)
                    .font(Theme.Typography.screenTitle)
                    .foregroundStyle(Theme.Colors.textPrimary)

                Text(user.email)
                    .font(Theme.Typography.bodyRegular)
                    .foregroundStyle(Theme.Colors.textSecondary)
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

            Text("Representation: \(user.representation)")
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
        let components = user.name.components(separatedBy: " ")
        if components.count >= 2,
           let first = components[0].first,
           let second = components[1].first {
            return "\(first)\(second)".uppercased()
        }
        return user.name.prefix(2).uppercased()
    }
}

// MARK: - Edit Profile Sheet

struct EditProfileSheet: View {
    let appState: AppState
    @Binding var isPresented: Bool

    @State private var name: String = ""
    @State private var email: String = ""
    @State private var height: String = ""
    @State private var ageText: String = ""
    @State private var basedIn: String = ""
    @State private var representation: String = ""
    @State private var newCredit: String = ""
    @State private var credits: [String] = []
    @State private var photoItem: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile photo") {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("Choose photo", systemImage: "person.crop.circle.badge.plus")
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
                    ForEach(credits, id: \.self) { credit in
                        Text(credit)
                    }
                    .onDelete { indices in
                        credits.remove(atOffsets: indices)
                    }

                    HStack {
                        TextField("Add project (e.g. Film Title)", text: $newCredit)
                        Button("Add") {
                            let trimmed = newCredit.trimmingCharacters(in: .whitespaces)
                            if !trimmed.isEmpty {
                                credits.append(trimmed)
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
                    credits = u.previousWork
                }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        await MainActor.run { appState.currentUser?.avatarImageData = data }
                    }
                }
            }
        }
    }

    private func saveProfile() {
        let age = Int(ageText) ?? 0
        appState.createOrUpdateProfile(
            name: name.trimmingCharacters(in: .whitespaces),
            email: email.trimmingCharacters(in: .whitespaces),
            height: height.trimmingCharacters(in: .whitespaces),
            age: age,
            basedIn: basedIn.trimmingCharacters(in: .whitespaces),
            representation: representation.trimmingCharacters(in: .whitespaces)
        )
        if let current = appState.currentUser {
            current.previousWork = credits
        }
        appState.saveChanges()
        isPresented = false
    }
}

#Preview {
    ProfileView()
        .environment(MockData.sampleAppState)
}
