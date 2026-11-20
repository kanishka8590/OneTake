import AVFoundation
import SwiftUI

struct HeadshotGuidanceView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    let audition: Audition
    /// When set, this view becomes a single-angle retake while retaining the
    /// complete guided camera experience used by the multi-angle flow.
    var retakeAngle: HeadshotAngle? = nil
    var onRetakeComplete: ((UIImage) -> Void)? = nil
    var onCompleted: () -> Void = {}

    @State private var guidanceService = HeadshotGuidanceService.shared
    @State private var currentStepIndex = 0 // 0: Front, 1: Left, 2: Right

    @State private var frontOriginal: UIImage?
    @State private var leftOriginal: UIImage?
    @State private var rightOriginal: UIImage?

    @State private var showingReviewSheet = false
    @State private var didCompleteFlow = false
    @State private var previousShutterCallback: (() -> Void)?

    // One-time "Talk to OneTake" Voice Guide Intro (shown only before Shot 1)
    @State private var showVoiceGuideIntro = true
    @State private var showingMatchGuide = false
    @State private var autoCaptureHoldTask: Task<Void, Never>?
    @State private var autoCaptureCancelTask: Task<Void, Never>?
    @State private var autoHoldProgress: Double = 0.0
    @State private var gestureHoldTask: Task<Void, Never>?
    @State private var lastGestureTriggerAt: Date = .distantPast

    private let sequence: [HeadshotAngle] = [.front, .left, .right]

    var currentAngle: HeadshotAngle {
        if let target = retakeAngle {
            return target
        }
        return sequence[min(currentStepIndex, sequence.count - 1)]
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            cameraPreviewLayer
            ovalAlignmentGuide

            VStack(spacing: 0) {
                topCameraBar
                    .padding(.top, 8)
                    .padding(.horizontal, 16)

                Spacer()

                bottomCinemaHUD
                    .padding(.bottom, 28)
                    .padding(.horizontal, 16)
            }

            if guidanceService.isCapturing && guidanceService.countdownRemaining > 0 {
                ZStack {
                    Color.black.opacity(0.45).ignoresSafeArea()
                    Text("\(guidanceService.countdownRemaining)")
                        .font(.system(size: 110, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.white)
                        .transition(.scale.combined(with: .opacity))
                }
            }

            if showVoiceGuideIntro {
                talkToOneTakeGuideOverlay
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            previousShutterCallback = guidanceService.onShutterTriggered
            bindShutterCallback()
            if showVoiceGuideIntro {
                guidanceService.voiceGuidanceEnabled = false
                guidanceService.disableVoiceTriggers()
            }
            if let target = retakeAngle, let idx = sequence.firstIndex(of: target) {
                currentStepIndex = idx
            }
            guidanceService.startSession(for: currentAngle, isDemoMode: appState.isDemoMode)
        }
        .onDisappear {
            autoCaptureHoldTask?.cancel()
            autoCaptureCancelTask?.cancel()
            gestureHoldTask?.cancel()
            guidanceService.onShutterTriggered = previousShutterCallback
            previousShutterCallback = nil
            guidanceService.stopSession()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background, .inactive:
                autoCaptureHoldTask?.cancel()
                autoCaptureCancelTask?.cancel()
                gestureHoldTask?.cancel()
                guidanceService.stopSession()
            case .active:
                if !showingReviewSheet && !didCompleteFlow {
                    bindShutterCallback()
                    guidanceService.startSession(for: currentAngle, isDemoMode: appState.isDemoMode)
                }
            @unknown default:
                break
            }
        }
        .sheet(isPresented: $showingMatchGuide) {
            referenceMatchGuideSheet
        }
        .onChange(of: guidanceService.feedback.allChecksPassed) { wasAligned, isAligned in
            if !wasAligned && isAligned && !showVoiceGuideIntro && !showingReviewSheet && !guidanceService.isCapturing {
                Haptics.alignmentReady()
            }
            if !isAligned {
                guidanceService.cancelCountdownIfAlignmentLost()
            }
            updateAutoCaptureSchedule()
        }
        .onChange(of: guidanceService.countdownRemaining) { _, remaining in
            if guidanceService.isCapturing && remaining > 0 {
                Haptics.countdownTick()
            }
        }
        .onChange(of: guidanceService.autoCaptureEnabled) { _, _ in
            updateAutoCaptureSchedule()
        }
        .onChange(of: showVoiceGuideIntro) { _, _ in
            updateAutoCaptureSchedule()
        }
        .onChange(of: showingMatchGuide) { _, _ in
            updateAutoCaptureSchedule()
        }
        .onChange(of: guidanceService.isCapturing) { _, _ in
            updateAutoCaptureSchedule()
        }
        .onChange(of: guidanceService.openPalmDetected) { _, detected in
            gestureHoldTask?.cancel()
            gestureHoldTask = nil
            guard detected,
                  guidanceService.gesturesEnabled,
                  !guidanceService.isCapturing,
                  !showVoiceGuideIntro,
                  !showingMatchGuide,
                  !showingReviewSheet else { return }

            gestureHoldTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard !Task.isCancelled,
                      guidanceService.gesturesEnabled,
                      guidanceService.openPalmDetected,
                      !guidanceService.isCapturing,
                      !showVoiceGuideIntro,
                      !showingMatchGuide,
                      !showingReviewSheet,
                      Date().timeIntervalSince(lastGestureTriggerAt) > 2.0 else { return }
                lastGestureTriggerAt = Date()
                Haptics.capture()
                triggerBatchCapture(requireAlignment: false)
            }
        }
        .sheet(isPresented: $showingReviewSheet, onDismiss: {
            if !didCompleteFlow {
                bindShutterCallback()
                guidanceService.startSession(for: currentAngle, isDemoMode: appState.isDemoMode)
            }
        }) {
            HeadshotReviewView(
                audition: audition,
                initialFront: frontOriginal,
                initialLeft: leftOriginal,
                initialRight: rightOriginal
            ) {
                didCompleteFlow = true
                onCompleted()
                dismiss()
            }
        }
    }

    private func bindShutterCallback() {
        guidanceService.onShutterTriggered = {
            if showVoiceGuideIntro {
                showVoiceGuideIntro = false
            }
            triggerBatchCapture(requireAlignment: false)
        }
    }

    private func updateAutoCaptureSchedule() {
        let eligible = guidanceService.autoCaptureEnabled
            && !guidanceService.isCapturing
            && !showVoiceGuideIntro
            && !showingMatchGuide
            && !showingReviewSheet

        guard eligible else {
            autoCaptureHoldTask?.cancel()
            autoCaptureHoldTask = nil
            autoCaptureCancelTask?.cancel()
            autoCaptureCancelTask = nil
            autoHoldProgress = 0.0
            return
        }

        if guidanceService.feedback.allChecksPassed {
            autoCaptureCancelTask?.cancel()
            autoCaptureCancelTask = nil
            guard autoCaptureHoldTask == nil else { return }

            autoCaptureHoldTask = Task { @MainActor in
                let totalSteps = 8
                for step in 1...totalSteps {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    guard !Task.isCancelled,
                          guidanceService.autoCaptureEnabled,
                          !guidanceService.isCapturing,
                          !showVoiceGuideIntro,
                          !showingMatchGuide,
                          !showingReviewSheet else {
                        autoHoldProgress = 0.0
                        autoCaptureHoldTask = nil
                        return
                    }
                    autoHoldProgress = Double(step) / Double(totalSteps)
                }
                guard guidanceService.feedback.allChecksPassed else {
                    autoHoldProgress = 0.0
                    autoCaptureHoldTask = nil
                    return
                }
                autoHoldProgress = 0.0
                autoCaptureHoldTask = nil
                Haptics.capture()
                triggerBatchCapture(requireAlignment: true, countdownSeconds: 1)
            }
        } else if autoCaptureHoldTask != nil && autoCaptureCancelTask == nil {
            autoCaptureCancelTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard !Task.isCancelled else { return }
                autoCaptureCancelTask = nil
                if !guidanceService.feedback.allChecksPassed {
                    autoCaptureHoldTask?.cancel()
                    autoCaptureHoldTask = nil
                    autoHoldProgress = 0.0
                }
            }
        }
    }

    // MARK: - Top Camera Bar (Native Liquid Glass + Top Gesture & Auto Controls)

    private var topCameraBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    guidanceService.stopSession()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .nativeGlassCircleButton()
                .background(Color.black.opacity(0.32), in: Circle())
                .accessibilityLabel("Close camera")

                Spacer(minLength: 4)

                angleSegmentedPicker

                Spacer(minLength: 4)

                Button {
                    showingMatchGuide = true
                } label: {
                    Image(systemName: "info")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .nativeGlassCircleButton()
                .background(Color.black.opacity(0.32), in: Circle())
                .disabled(guidanceService.isCapturing)
                .accessibilityLabel("Headshot guide")
            }

            HStack(spacing: 8) {
                Button {
                    guidanceService.gesturesEnabled.toggle()
                } label: {
                    Label(
                        "Gesture",
                        systemImage: guidanceService.gesturesEnabled ? "hand.raised.fill" : "hand.raised.slash"
                    )
                    .font(.system(size: 12, weight: .semibold))
                }
                .nativeGlassCapsuleButton(
                    tint: guidanceService.gesturesEnabled ? Theme.Colors.cameraGuideGold : nil
                )
                .background(Color.black.opacity(0.32), in: Capsule())
                .accessibilityLabel(guidanceService.gesturesEnabled ? "Disable open palm gesture capture" : "Enable open palm gesture capture")

                Button {
                    if guidanceService.isVoiceListening || guidanceService.voiceStatus == .starting {
                        guidanceService.disableVoiceTriggers()
                    } else {
                        guidanceService.enableVoiceTriggers()
                    }
                } label: {
                    Label(
                        voiceButtonTitle,
                        systemImage: (guidanceService.isVoiceListening || guidanceService.voiceStatus == .starting) ? "mic.fill" : "mic.slash"
                    )
                    .font(.system(size: 12, weight: .semibold))
                }
                .nativeGlassCapsuleButton(
                    tint: guidanceService.isVoiceListening ? .green : (guidanceService.voiceStatus == .starting ? Theme.Colors.cameraGuideGold : nil)
                )
                .background(Color.black.opacity(0.32), in: Capsule())
                .accessibilityLabel(guidanceService.isVoiceListening ? "Disable voice command activation" : "Enable voice command activation")

                Button {
                    guidanceService.autoCaptureEnabled.toggle()
                } label: {
                    Label(
                        "Auto",
                        systemImage: guidanceService.autoCaptureEnabled ? "sparkles" : "camera.metering.spot"
                    )
                    .font(.system(size: 12, weight: .semibold))
                }
                .nativeGlassCapsuleButton(
                    tint: guidanceService.autoCaptureEnabled ? .green : nil
                )
                .background(Color.black.opacity(0.32), in: Capsule())
                .accessibilityLabel(guidanceService.autoCaptureEnabled ? "Disable automatic capture when aligned" : "Enable automatic capture when aligned")
            }
        }
    }

    private func hasCapturedAngle(_ angle: HeadshotAngle) -> Bool {
        switch angle {
        case .front: return frontOriginal != nil
        case .left: return leftOriginal != nil
        case .right: return rightOriginal != nil
        }
    }

    private var voiceButtonTitle: String {
        switch guidanceService.voiceStatus {
        case .listening: return "Voice On"
        case .starting: return "Voice…"
        default: return "Voice"
        }
    }

    @ViewBuilder
    private var angleSegmentedPicker: some View {
        if let retakeAngle {
            Text("Retake \(retakeAngle.rawValue)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.32), in: Capsule())
                .nativeGlassCapsuleSurface()
        } else {
            HStack(spacing: 2) {
                ForEach(sequence, id: \.self) { angle in
                    let isSelected = (currentAngle == angle)
                    let isCaptured = hasCapturedAngle(angle)

                    Button {
                        guard !guidanceService.isCapturing,
                              let idx = sequence.firstIndex(of: angle),
                              idx != currentStepIndex else { return }
                        withAnimation(.snappy(duration: 0.2)) {
                            currentStepIndex = idx
                        }
                        guidanceService.startSession(for: angle, isDemoMode: appState.isDemoMode)
                        guidanceService.announceAngle(angle)
                    } label: {
                        HStack(spacing: 4) {
                            Text(angle.rawValue)
                                .font(.system(size: 12.5, weight: isSelected ? .bold : .semibold))
                                .foregroundStyle(isSelected ? .white : Color.white.opacity(0.74))

                            if isCaptured {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 5, height: 5)
                            }
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(isSelected ? Color.white.opacity(0.22) : Color.clear)
                        )
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(guidanceService.isCapturing)
                }
            }
            .padding(3)
            .background(Color.black.opacity(0.38), in: Capsule())
            .nativeGlassCapsuleSurface()
        }
    }

    // MARK: - Live Viewfinder

    private var cameraPreviewLayer: some View {
        ZStack {
            #if targetEnvironment(simulator)
            if appState.isDemoMode {
                LinearGradient(
                    colors: [Color(white: 0.18), Color(white: 0.10)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Image(systemName: "camera")
                        if retakeAngle != nil {
                            Text("Simulator Demo • \(currentAngle.rawValue.capitalized)")
                        } else {
                            Text("Simulator Demo • \(currentAngle.rawValue.capitalized) (\(currentStepIndex + 1)/3)")
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .padding(.bottom, 160)
                }
            } else {
                cameraUnavailableCard(
                    title: "Camera Unavailable in Simulator",
                    message: guidanceService.cameraErrorMessage ?? "Enable Demo Mode in Profile to simulate headshot capture, or run on a physical device.",
                    showSettingsButton: false
                )
            }
            #else
            if guidanceService.cameraPermissionDenied {
                cameraUnavailableCard(
                    title: "Camera Access Required",
                    message: guidanceService.cameraErrorMessage ?? "Allow camera access in Settings so OneTake can guide and capture your headshots.",
                    showSettingsButton: true
                )
            } else if let errorMessage = guidanceService.cameraErrorMessage {
                cameraUnavailableCard(
                    title: "Camera Unavailable",
                    message: errorMessage,
                    showSettingsButton: false
                )
            } else if let session = guidanceService.captureSession {
                LiveCameraPreview(session: session) { layer in
                    guidanceService.attachPreviewLayer(layer)
                }
                .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
                ProgressView()
                    .tint(.white)
            }
            #endif
        }
        .ignoresSafeArea()
    }

    private func cameraUnavailableCard(title: String, message: String, showSettingsButton: Bool) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: showSettingsButton ? "camera.badge.ellipsis" : "video.slash")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(Theme.Colors.cameraGuideGold)

                Text(title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.75))
                    .multilineTextAlignment(.center)

                if showSettingsButton {
                    Button {
                        VoiceAuthorizationService.openAppSettings()
                    } label: {
                        Text("Open Settings")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 10)
                            .background(Theme.Colors.primaryPlum)
                            .clipShape(Capsule())
                    }
                    .padding(.top, 4)
                }
            }
            .padding(24)
            .nativeGlassRoundedSurface(cornerRadius: 20)
            .padding(.horizontal, 28)
        }
    }

    // MARK: - Center Gold/Green Oval Alignment Guide

    private var ovalAlignmentGuide: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let ovalW = w * 0.62
            let ovalH = h * 0.44
            let centerX = w / 2.0
            let centerY = h * 0.43
            let isAligned = guidanceService.feedback.allChecksPassed

            let strokeColor = isAligned ? Color.green : Theme.Colors.cameraGuideGoldStroke.opacity(0.78)

            ZStack {
                Path { path in
                    path.addRect(CGRect(x: 0, y: 0, width: w, height: h))
                    let ovalRect = CGRect(x: centerX - ovalW / 2.0, y: centerY - ovalH / 2.0, width: ovalW, height: ovalH)
                    path.addEllipse(in: ovalRect)
                }
                .fill(Color.black.opacity(0.38), style: FillStyle(eoFill: true))

                Ellipse()
                    .stroke(strokeColor, lineWidth: isAligned ? 3 : 2.5)
                    .frame(width: ovalW, height: ovalH)
                    .shadow(color: isAligned ? Color.green.opacity(0.55) : .clear, radius: 10)
                    .position(x: centerX, y: centerY)

                let eyeY = centerY - ovalH * 0.08
                let notchInnerGap: CGFloat = 4
                let notchLength: CGFloat = 12

                Path { path in
                    let leftX = centerX - ovalW / 2.0
                    path.move(to: CGPoint(x: leftX - notchInnerGap - notchLength, y: eyeY))
                    path.addLine(to: CGPoint(x: leftX - notchInnerGap, y: eyeY))
                }
                .stroke(strokeColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))

                Path { path in
                    let rightX = centerX + ovalW / 2.0
                    path.move(to: CGPoint(x: rightX + notchInnerGap, y: eyeY))
                    path.addLine(to: CGPoint(x: rightX + notchInnerGap + notchLength, y: eyeY))
                }
                .stroke(strokeColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            .animation(.easeInOut(duration: 0.2), value: isAligned)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: - Bottom Dark-Cinema HUD

    private var bottomCinemaHUD: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(guidanceService.feedback.lighting == .good ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text("Light: \(guidanceService.feedback.lighting.rawValue)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.36), in: Capsule())
                .nativeGlassCapsuleSurface()

                if guidanceService.openPalmDetected && guidanceService.gesturesEnabled {
                    HStack(spacing: 5) {
                        Image(systemName: "hand.raised")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.green)
                        Text("Hold")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.36), in: Capsule())
                    .nativeGlassCapsuleSurface()
                }
            }

            VStack(spacing: 4) {
                Text(liveCoachingHeadline)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(
                        guidanceService.shutterStatusMessage != nil
                        ? Theme.Colors.cameraGuideGold
                        : (guidanceService.feedback.allChecksPassed ? Color.green : .white)
                    )
                    .multilineTextAlignment(.center)

                Text(captureTriggerSubtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 12)

            HStack(spacing: 0) {
                Button {
                    guidanceService.voiceGuidanceEnabled.toggle()
                } label: {
                    Image(systemName: guidanceService.voiceGuidanceEnabled ? "speaker.wave.2" : "speaker.slash")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .foregroundStyle(guidanceService.voiceGuidanceEnabled ? Color.white : Color.white.opacity(0.45))
                }
                .nativeGlassCircleButton()
                .accessibilityLabel(guidanceService.voiceGuidanceEnabled ? "Disable voice guidance" : "Enable voice guidance")

                Spacer()

                Button {
                    Haptics.capture()
                    triggerBatchCapture(requireAlignment: false)
                } label: {
                    ZStack {
                        Circle()
                            .stroke(guidanceService.feedback.allChecksPassed ? Color.green.opacity(guidanceService.autoCaptureEnabled ? 0.35 : 1.0) : Color.white, lineWidth: 4)
                            .frame(width: 78, height: 78)

                        if guidanceService.autoCaptureEnabled && autoHoldProgress > 0 {
                            Circle()
                                .trim(from: 0, to: autoHoldProgress)
                                .stroke(Color.green, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .frame(width: 82, height: 82)
                                .animation(.linear(duration: 0.1), value: autoHoldProgress)
                        }

                        Circle()
                            .fill(guidanceService.isCapturing ? Color.red : Color.white)
                            .frame(width: 64, height: 64)
                    }
                }
                .buttonStyle(.plain)
                .disabled(guidanceService.isCapturing)
                .accessibilityLabel("Capture headshot")

                Spacer()

                Button {
                    guidanceService.flipCamera()
                } label: {
                    Image(systemName: "camera.rotate")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .foregroundStyle(Color.white)
                }
                .nativeGlassCircleButton()
                .disabled(guidanceService.isCapturing)
                .accessibilityLabel("Flip camera")
            }
            .padding(.horizontal, 24)
        }
    }

    private var captureTriggerSubtitle: String {
        if guidanceService.autoCaptureEnabled && guidanceService.feedback.allChecksPassed && !guidanceService.isCapturing {
            return "Hold steady — capturing automatically"
        }
        var triggers: [String] = []
        if guidanceService.autoCaptureEnabled {
            triggers.append("Auto when aligned")
        }
        triggers.append(guidanceService.autoCaptureEnabled ? "tap shutter" : "Tap shutter")
        if guidanceService.gesturesEnabled {
            triggers.append(guidanceService.autoCaptureEnabled ? "hold palm" : "hold open palm")
        }
        if guidanceService.isVoiceListening {
            triggers.append("say \"Action\"")
        }
        return triggers.joined(separator: " · ")
    }

    private var liveCoachingHeadline: String {
        if let shutterMsg = guidanceService.shutterStatusMessage {
            return shutterMsg
        }
        if guidanceService.cameraPermissionDenied || (!appState.isDemoMode && guidanceService.cameraErrorMessage != nil) {
            return "Camera unavailable"
        }
        if let headline = guidanceService.feedback.guidanceHeadline, !headline.isEmpty {
            return headline
        }
        if guidanceService.feedback.allChecksPassed {
            return "Hold still — ready to shoot"
        } else if !guidanceService.feedback.isFaceCentered {
            return "Center your face in the guide oval"
        } else if !guidanceService.feedback.isAngleCorrect {
            switch currentAngle {
            case .front: return "Look straight at the camera"
            case .left: return "Turn head slightly to your left"
            case .right: return "Turn head slightly to your right"
            }
        } else if guidanceService.feedback.lighting != .good {
            if guidanceService.feedback.lighting == .tooDark {
                return "Lighting is too dark — add front light"
            } else if guidanceService.feedback.lighting == .uneven {
                return "Balance light evenly across face"
            } else {
                return "Lighting is too bright — reduce glare"
            }
        } else if !guidanceService.feedback.isEyeLevel {
            return "Hold phone upright at eye level"
        } else if guidanceService.feedback.background != .clean {
            return "Background busy — use a plain wall"
        } else {
            return "Align inside the guide oval"
        }
    }

    // MARK: - Minimalist "Talk to OneTake" Voice Guide Overlay

    private var talkToOneTakeGuideOverlay: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Talk to OneTake", systemImage: "waveform")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)

                    Text("Hands-free voice triggers for your session")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.7))
                }

                VStack(spacing: 12) {
                    headshotVoiceRow(
                        phrase: "\"Action\" or \"Now\"",
                        desc: "Take photo after 3s countdown",
                        icon: "camera"
                    )
                }

                VStack(spacing: 10) {
                    Button {
                        guidanceService.voiceGuidanceEnabled = true
                        guidanceService.enableVoiceTriggers()
                        withAnimation(.easeInOut(duration: 0.22)) {
                            showVoiceGuideIntro = false
                        }
                        guidanceService.announceAngle(currentAngle)
                    } label: {
                        Text("Enable Voice Commands")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .nativeProminentGlassButton(tint: Theme.Colors.primaryPlum)

                    Button {
                        guidanceService.voiceGuidanceEnabled = false
                        guidanceService.disableVoiceTriggers()
                        withAnimation(.easeInOut(duration: 0.22)) {
                            showVoiceGuideIntro = false
                        }
                    } label: {
                        Text("Not Now")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.78))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(22)
            .nativeGlassRoundedSurface(cornerRadius: 24)
            .padding(.horizontal, 28)
            .transition(.scale(scale: 0.96).combined(with: .opacity))
        }
        .zIndex(100)
    }

    private func headshotVoiceRow(phrase: String, desc: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(phrase)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)

                Text(desc)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.65))
            }

            Spacer()
        }
    }

    // MARK: - "Match this >" Reference Guide Sheet

    private var referenceMatchGuideSheet: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.cameraCanvas.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Industry Standard Headshot Guide")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)

                        Text("For theatrical and commercial submissions, casting directors look for three essential angles: Front, 3/4 Left, and 3/4 Right.")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.white.opacity(0.75))

                        VStack(spacing: 12) {
                            guideCard(
                                title: "Front Angle",
                                detail: "Face the lens squarely with eyes on the upper third horizontal notch. Soft natural key light in front.",
                                icon: "person.crop.rectangle"
                            )

                            guideCard(
                                title: "Left Profile",
                                detail: "Turn nose approximately 40° to your left while keeping your gaze on the camera lens.",
                                icon: "arrow.left.and.right.square"
                            )

                            guideCard(
                                title: "Right Profile",
                                detail: "Turn nose approximately 40° to your right, maintaining eye level and relaxed shoulders.",
                                icon: "arrow.left.and.right.square"
                            )
                        }

                        VStack(spacing: 12) {
                            Toggle("Open-Palm Gesture Shutter", isOn: Bindable(guidanceService).gesturesEnabled)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .tint(Theme.Colors.cameraGuideGold)

                            Divider().background(Color.white.opacity(0.12))

                            Toggle("Spoken Voice Guidance", isOn: Bindable(guidanceService).voiceGuidanceEnabled)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .tint(Theme.Colors.cameraGuideGold)

                            Divider().background(Color.white.opacity(0.12))

                            Toggle("Auto-Capture When Aligned", isOn: Bindable(guidanceService).autoCaptureEnabled)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .tint(Theme.Colors.cameraGuideGold)
                        }
                        .padding(14)
                        .background(Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(24)
                }
                .scrollEdgeHaptics()
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        showingMatchGuide = false
                    }
                }
            }
            .presentationDetents([.fraction(0.7), .large])
            .presentationDragIndicator(.visible)
        }
    }

    private func guideCard(title: String, detail: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(Theme.Colors.cameraGuideGold)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)

                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.7))
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
        .padding(14)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Batch Continuous Capture Trigger

    private func triggerBatchCapture(requireAlignment: Bool = false, countdownSeconds: Int = 3) {
        guidanceService.startCountdown(seconds: countdownSeconds, requireAlignment: requireAlignment) { capturedImage in
            guard let image = capturedImage else { return }

            switch currentAngle {
            case .front: self.frontOriginal = image
            case .left: self.leftOriginal = image
            case .right: self.rightOriginal = image
            }

            if retakeAngle != nil {
                Haptics.success()
                guidanceService.stopSession()
                onRetakeComplete?(image)
                dismiss()
                return
            }

            // Continuous batch: advance Front -> Left -> Right without re-showing intro guide
            if currentStepIndex < sequence.count - 1 {
                Haptics.capture()
                currentStepIndex += 1
                guidanceService.transitionToNextPose(currentAngle, isDemoMode: appState.isDemoMode)
            } else {
                Haptics.success()
                guidanceService.stopSession()
                self.showingReviewSheet = true
            }
        }
    }
}

// MARK: - Compatibility Typealias
typealias HeadshotCaptureView = HeadshotGuidanceView
