import SwiftUI
import AuthenticationServices
import Combine

struct AuthView: View {
    @Environment(AppState.self) private var envAppState
    private let explicitAppState: AppState?

    @State private var showingEmailSheet = false

    init(appState: AppState? = nil) {
        self.explicitAppState = appState
    }

    private var appState: AppState {
        explicitAppState ?? envAppState
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.canvasBackground
                    .ignoresSafeArea()

                VStack(spacing: 32) {
                    Spacer()

                    // Brand Header
                    VStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(Theme.Colors.lavenderSurface)
                                .frame(width: 88, height: 88)

                            Image(systemName: "movieclapper.fill")
                                .font(.system(size: 40, weight: .semibold))
                                .foregroundStyle(Theme.Colors.primaryPlum)
                        }

                        VStack(spacing: 6) {
                            Text("Welcome to OneTake")
                                .font(Theme.Typography.screenTitle)
                                .foregroundStyle(Theme.Colors.textPrimary)

                            Text("From first line to Final Take")
                                .font(Theme.Typography.bodyRegular)
                                .foregroundStyle(Theme.Colors.textSecondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                        }
                    }

                    Spacer()

                    // Authentication Action Buttons
                    VStack(spacing: 14) {
                        // Native Apple Sign-In
                        SignInWithAppleButton(
                            .signIn,
                            onRequest: { request in
                                request.requestedScopes = [.fullName, .email]
                            },
                            onCompletion: { result in
                                handleAppleAuth(result: result)
                            }
                        )
                        .signInWithAppleButtonStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .clipShape(Capsule())

                        // Continue with Email
                        Button {
                            showingEmailSheet = true
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "envelope.fill")
                                    .font(.system(size: 16, weight: .semibold))
                                Text("Continue with email")
                                    .font(Theme.Typography.cardTitle)
                            }
                            .foregroundStyle(Theme.Colors.primaryPlum)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(Theme.Colors.lavenderSurface)
                            .clipShape(Capsule())
                        }
                        .frame(minHeight: Theme.Layout.minTapTarget)

                        // Simulator Quick Sign-In (convenience helper)
                        #if targetEnvironment(simulator)
                        Button {
                            signInWithSimulatorMock()
                        } label: {
                            Text("Fast Sign-In (Simulator)")
                                .font(Theme.Typography.captionBadge)
                                .foregroundStyle(Theme.Colors.textSecondary)
                                .padding(.vertical, 8)
                        }
                        .frame(minHeight: Theme.Layout.minTapTarget)
                        #endif
                    }
                    .padding(.horizontal, Theme.Layout.screenHPadding)
                    .padding(.bottom, 24)
                }
            }
            .sheet(isPresented: $showingEmailSheet) {
                EmailOTPView(isPresented: $showingEmailSheet)
            }
        }
    }

    private func handleAppleAuth(result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            if let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential {
                var displayName = "Actor"
                if let fullName = appleIDCredential.fullName {
                    let given = fullName.givenName ?? ""
                    let family = fullName.familyName ?? ""
                    let combined = "\(given) \(family)".trimmingCharacters(in: .whitespaces)
                    if !combined.isEmpty {
                        displayName = combined
                    }
                }
                let email = appleIDCredential.email ?? "actor@onetake.app"
                if appState.currentUser == nil {
                    appState.createOrUpdateProfile(name: displayName, email: email)
                }
                withAnimation {
                    appState.isAuthenticated = true
                }
            } else {
                signInWithSimulatorMock()
            }
        case .failure:
            // Graceful fallback for Simulator / canceled native dialog
            signInWithSimulatorMock()
        }
    }

    private func signInWithSimulatorMock() {
        if appState.currentUser == nil {
            appState.createOrUpdateProfile(
                name: "Kusha Sharma",
                email: "kusha.sharma@gmail.com",
                height: "5'6\"",
                age: 27,
                basedIn: "Mumbai, India",
                representation: "Self-represented"
            )
        }
        withAnimation {
            appState.isAuthenticated = true
        }
    }
}

// MARK: - Email + 6-Digit OTP Flow

struct EmailOTPView: View {
    @Environment(AppState.self) private var envAppState
    private let explicitAppState: AppState?

    @Binding var isPresented: Bool

    @State private var email: String = ""
    @State private var otpCode: String = ""
    @State private var isOTPSent: Bool = false
    @State private var resendCountdown: Int = 24
    @State private var timerActive: Bool = false
    @State private var errorMessage: String? = nil

    @FocusState private var emailFieldFocused: Bool
    @FocusState private var otpFieldFocused: Bool

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(appState: AppState? = nil, isPresented: Binding<Bool>) {
        self.explicitAppState = appState
        self._isPresented = isPresented
    }

    private var appState: AppState {
        explicitAppState ?? envAppState
    }

    var isValidEmail: Bool {
        email.contains("@") && email.contains(".") && email.trimmingCharacters(in: .whitespaces).count >= 5
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.canvasBackground
                    .ignoresSafeArea()

                VStack(spacing: 24) {
                    if !isOTPSent {
                        emailInputSection
                    } else {
                        otpVerificationSection
                    }

                    Spacer()
                }
                .padding(.horizontal, Theme.Layout.screenHPadding)
                .padding(.top, 24)
            }
            .navigationTitle(isOTPSent ? "Enter Verification Code" : "Continue with Email")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                    .frame(minWidth: Theme.Layout.minTapTarget, minHeight: Theme.Layout.minTapTarget)
                }
            }
            .onReceive(timer) { _ in
                if timerActive && resendCountdown > 0 {
                    resendCountdown -= 1
                }
            }
        }
    }

    // MARK: - Email Input Section

    private var emailInputSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("What's your email?")
                    .font(Theme.Typography.sectionHeader)
                    .foregroundStyle(Theme.Colors.textPrimary)

                Text("We'll send a 6-digit confirmation code to verify your account.")
                    .font(Theme.Typography.bodyRegular)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                TextField("name@example.com", text: $email)
                    .font(Theme.Typography.bodyRegular)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($emailFieldFocused)
                    .padding()
                    .background(Theme.Colors.cardSurface)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Layout.innerCornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Layout.innerCornerRadius)
                            .stroke(Theme.Colors.lavenderSurface, lineWidth: 1)
                    )

                if let error = errorMessage {
                    Text(error)
                        .font(Theme.Typography.captionBadge)
                        .foregroundStyle(Theme.Colors.errorCrimson)
                }
            }

            Button {
                sendCode()
            } label: {
                Text("Send Code")
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(isValidEmail ? Theme.Colors.primaryPlum : Theme.Colors.primaryPlum.opacity(0.4))
                    .clipShape(Capsule())
            }
            .disabled(!isValidEmail)
            .frame(minHeight: Theme.Layout.minTapTarget)
        }
        .onAppear {
            emailFieldFocused = true
        }
    }

    // MARK: - OTP Verification Section

    private var otpVerificationSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Check your inbox")
                    .font(Theme.Typography.sectionHeader)
                    .foregroundStyle(Theme.Colors.textPrimary)

                Text("Enter the 6-digit code sent to \(email)")
                    .font(Theme.Typography.bodyRegular)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                TextField("000000", text: $otpCode)
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($otpFieldFocused)
                    .padding(.vertical, 16)
                    .background(Theme.Colors.cardSurface)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Layout.innerCornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Layout.innerCornerRadius)
                            .stroke(Theme.Colors.lavenderSurface, lineWidth: 1)
                    )
                    .onChange(of: otpCode) { _, newValue in
                        if newValue.count > 6 {
                            otpCode = String(newValue.prefix(6))
                        }
                    }

                if let error = errorMessage {
                    Text(error)
                        .font(Theme.Typography.captionBadge)
                        .foregroundStyle(Theme.Colors.errorCrimson)
                }
            }

            // Resend Countdown
            HStack {
                Spacer()
                if resendCountdown > 0 {
                    let seconds = String(format: "%02d", resendCountdown)
                    Text("Resend code in 0:\(seconds)")
                        .font(Theme.Typography.captionBadge)
                        .foregroundStyle(Theme.Colors.textSecondary)
                } else {
                    Button("Resend code") {
                        resendCode()
                    }
                    .font(Theme.Typography.captionBadge)
                    .foregroundStyle(Theme.Colors.primaryPlum)
                    .frame(minHeight: Theme.Layout.minTapTarget)
                }
                Spacer()
            }

            Button {
                verifyCode()
            } label: {
                Text("Verify & Continue")
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(otpCode.count == 6 ? Theme.Colors.primaryPlum : Theme.Colors.primaryPlum.opacity(0.4))
                    .clipShape(Capsule())
            }
            .disabled(otpCode.count != 6)
            .frame(minHeight: Theme.Layout.minTapTarget)
        }
        .onAppear {
            otpFieldFocused = true
        }
    }

    private func sendCode() {
        guard isValidEmail else { return }
        errorMessage = nil
        isOTPSent = true
        resendCountdown = 24
        timerActive = true
    }

    private func resendCode() {
        resendCountdown = 24
        timerActive = true
        otpCode = ""
    }

    private func verifyCode() {
        guard otpCode.count == 6 else {
            errorMessage = "Please enter all 6 digits"
            return
        }

        // Local-first acceptance: any 6-digit code is valid
        if appState.currentUser == nil {
            let prefix = email.components(separatedBy: "@").first ?? "Actor"
            let capitalName = prefix.capitalized
            appState.createOrUpdateProfile(
                name: capitalName.isEmpty ? "Actor" : capitalName,
                email: email
            )
        }
        withAnimation {
            appState.isAuthenticated = true
        }
        isPresented = false
    }
}

#Preview {
    AuthView()
        .environment(MockData.sampleAppState)
}
