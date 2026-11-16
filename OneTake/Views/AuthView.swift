import SwiftUI
import AuthenticationServices

struct AuthView: View {
    @Environment(AppState.self) private var envAppState
    @Environment(\.colorScheme) private var colorScheme
    private let explicitAppState: AppState?

    @State private var showingEmailSheet = false
    @State private var authErrorMessage: String?

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
                                .frame(width: 140, height: 140)

                            Image(systemName: "movieclapper.fill")
                                .font(.system(size: 60, weight: .semibold))
                                .foregroundStyle(Theme.Colors.accent)
                                .padding(.bottom, 5)
                        }
                        .accessibilityHidden(true)
                        .padding(.bottom, 20)

                        VStack(spacing: 10) {
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
                        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
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
                                    .accessibilityHidden(true)
                                Text("Continue with email")
                                    .font(Theme.Typography.cardTitle)
                            }
                            .foregroundStyle(Theme.Colors.accent)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(Theme.Colors.lavenderSurface)
                            .clipShape(Capsule())
                        }
                        .frame(minHeight: Theme.Layout.minTapTarget)

                        // Explicit Demo Mode Entry
                        Button {
                            withAnimation {
                                appState.enterDemoMode()
                            }
                        } label: {
                            VStack(spacing: 2) {
                                Text("Try Demo Mode")
                                    .font(Theme.Typography.cardTitle)
                                    .foregroundStyle(Theme.Colors.textPrimary)
                                Text("Loads sample auditions & scripts")
                                    .font(Theme.Typography.captionBadge)
                                    .foregroundStyle(Theme.Colors.textSecondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: Theme.Layout.minTapTarget)
                            .padding(.vertical, 6)
                        }
                    }
                    .padding(.horizontal, Theme.Layout.screenHPadding)
                    .padding(.bottom, 24)
                }
            }
            .sheet(isPresented: $showingEmailSheet) {
                EmailOTPView(appState: appState, isPresented: $showingEmailSheet)
            }
            .alert(
                "Sign In Failed",
                isPresented: Binding(
                    get: { authErrorMessage != nil },
                    set: { if !$0 { authErrorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {
                    authErrorMessage = nil
                }
            } message: {
                Text(authErrorMessage ?? "Unable to complete sign in.")
            }
        }
    }

    private func handleAppleAuth(result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                authErrorMessage = "Unable to verify Apple ID credentials. Please try again or use Demo Mode."
                return
            }

            let existing = appState.currentUser
            var displayName = existing?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let fullName = appleIDCredential.fullName {
                let given = fullName.givenName ?? ""
                let family = fullName.familyName ?? ""
                let combined = "\(given) \(family)".trimmingCharacters(in: .whitespaces)
                if !combined.isEmpty {
                    displayName = combined
                }
            }
            if displayName.isEmpty {
                displayName = "Actor"
            }

            let resolvedEmail: String
            if let credentialEmail = appleIDCredential.email?.trimmingCharacters(in: .whitespacesAndNewlines),
               !credentialEmail.isEmpty {
                resolvedEmail = credentialEmail
            } else if let existingEmail = existing?.email.trimmingCharacters(in: .whitespacesAndNewlines),
                      !existingEmail.isEmpty {
                resolvedEmail = existingEmail
            } else {
                resolvedEmail = ""
            }

            appState.createOrUpdateProfile(
                name: displayName,
                email: resolvedEmail,
                height: existing?.height ?? "",
                age: existing?.age ?? 0,
                basedIn: existing?.basedIn ?? "",
                representation: existing?.representation ?? "Self-represented"
            )

            withAnimation {
                appState.isAuthenticated = true
            }

        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled {
                return
            }
            authErrorMessage = error.localizedDescription
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
    @State private var errorMessage: String? = nil

    @FocusState private var emailFieldFocused: Bool
    @FocusState private var otpFieldFocused: Bool

    private static let emailPattern = #"^[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#

    init(appState: AppState? = nil, isPresented: Binding<Bool>) {
        self.explicitAppState = appState
        self._isPresented = isPresented
    }

    private var appState: AppState {
        explicitAppState ?? envAppState
    }

    var isValidEmail: Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.range(of: Self.emailPattern, options: .regularExpression) != nil
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.canvasBackground
                    .ignoresSafeArea()

                VStack(spacing: 24) {
                    demoServerBanner

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
                }
            }
            .task(id: isOTPSent ? resendCountdown : -1) {
                guard isOTPSent, resendCountdown > 0 else { return }
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, isOTPSent, resendCountdown > 0 else { return }
                resendCountdown -= 1
            }
        }
    }

    private var demoServerBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(Theme.Colors.accent)
                .accessibilityHidden(true)

            Text("Email OTP delivery requires a live auth server. Use Demo Mode to preview this flow, or sign in with Apple.")
                .font(Theme.Typography.captionBadge)
                .foregroundStyle(Theme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.lavenderSurface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Layout.innerCornerRadius))
    }

    // MARK: - Email Input Section

    private var emailInputSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("What's your email?")
                    .font(Theme.Typography.sectionHeader)
                    .foregroundStyle(Theme.Colors.textPrimary)

                Text("Preview the 6-digit verification step before trying Demo Mode.")
                    .font(Theme.Typography.bodyRegular)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                TextField("name@example.com", text: $email)
                    .font(Theme.Typography.bodyRegular)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($emailFieldFocused)
                    .padding()
                    .background(Theme.Colors.controlSurface)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Layout.innerCornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Layout.innerCornerRadius)
                            .stroke(Theme.Colors.controlBorder, lineWidth: 1)
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
                    .foregroundStyle(Theme.Colors.onAction)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(isValidEmail ? Theme.Colors.primaryPlum : Theme.Colors.primaryPlum.opacity(0.4))
                    .clipShape(Capsule())
            }
            .disabled(!isValidEmail)
            .frame(minHeight: Theme.Layout.minTapTarget)

            Button {
                enterDemoFromOTP(requireCode: false)
            } label: {
                Text("Continue in Demo Mode")
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Colors.accent)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Theme.Colors.lavenderSurface)
                    .clipShape(Capsule())
            }
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
                Text("Demo verification preview")
                    .font(Theme.Typography.sectionHeader)
                    .foregroundStyle(Theme.Colors.textPrimary)

                Text("Enter any 6-digit demo code for \(email.trimmingCharacters(in: .whitespacesAndNewlines))")
                    .font(Theme.Typography.bodyRegular)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                TextField("000000", text: $otpCode)
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .multilineTextAlignment(.center)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($otpFieldFocused)
                    .padding(.vertical, 16)
                    .background(Theme.Colors.controlSurface)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Layout.innerCornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Layout.innerCornerRadius)
                            .stroke(Theme.Colors.controlBorder, lineWidth: 1)
                    )
                    .onChange(of: otpCode) { _, newValue in
                        let digitsOnly = newValue.filter { $0.isASCII && $0.isNumber }
                        let capped = String(digitsOnly.prefix(6))
                        if capped != newValue {
                            otpCode = capped
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
                    .foregroundStyle(Theme.Colors.accent)
                    .frame(minHeight: Theme.Layout.minTapTarget)
                }
                Spacer()
            }

            Button {
                verifyCode()
            } label: {
                Text("Continue in Demo Mode")
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Colors.onAction)
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
    }

    private func resendCode() {
        resendCountdown = 24
        otpCode = ""
    }

    private func verifyCode() {
        enterDemoFromOTP(requireCode: true)
    }

    private func enterDemoFromOTP(requireCode: Bool) {
        if requireCode {
            guard otpCode.count == 6, otpCode.allSatisfy({ $0.isASCII && $0.isNumber }) else {
                errorMessage = "Please enter all 6 digits"
                return
            }
        }
        errorMessage = nil
        withAnimation {
            appState.enterDemoMode()
        }
        isPresented = false
    }
}

#Preview {
    AuthView()
        .environment(MockData.sampleAppState)
}
