import SwiftUI
import AVFoundation
import PhotosUI

struct HeadshotGuidanceView: View {
    @Environment(\.dismiss) private var dismiss

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
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showingPhotosPicker = false

    // One-time "Talk to OneTake" Voice Guide Intro (shown only before Shot 1)
    @State private var showVoiceGuideIntro = true
    @State private var showingMatchGuide = false

    private let sequence: [HeadshotAngle] = [.front, .left, .right]

    var currentAngle: HeadshotAngle {
        if let target = retakeAngle {
            return target
        }
        return sequence[min(currentStepIndex, sequence.count - 1)]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                cameraPreviewLayer
                ovalAlignmentGuide

                VStack(spacing: 0) {
                    Spacer().frame(height: 8)
                    Spacer()
                    bottomCinemaHUD
                        .padding(.bottom, 28)
                        .padding(.horizontal, 20)
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
            .navigationBarBackButtonHidden()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        guidanceService.stopSession()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.black.opacity(0.55))
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                    }
                    .disabled(guidanceService.isCapturing)
                }

                ToolbarItem(placement: .principal) {
                    angleSegmentedPicker
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingMatchGuide = true
                    } label: {
                        HStack(spacing: 4) {
                            Text("Match this")
                                .font(.system(size: 11, weight: .semibold))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .foregroundStyle(Theme.Colors.cameraGuideGold)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.55))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Theme.Colors.cameraGuideGoldStroke.opacity(0.4), lineWidth: 1))
                    }
                    .disabled(guidanceService.isCapturing)
                }
            }
            .onAppear {
                // Ask as soon as this workflow opens, before any camera/audio setup.
                VoiceAuthorizationService.shared.requestAccess()
                guidanceService.onShutterTriggered = {
                    if showVoiceGuideIntro {
                        showVoiceGuideIntro = false
                    }
                    triggerBatchCapture()
                }
                if let target = retakeAngle, let idx = sequence.firstIndex(of: target) {
                    currentStepIndex = idx
                }
                guidanceService.startSession(for: currentAngle)
            }
            .onDisappear {
                guidanceService.onShutterTriggered = nil
                guidanceService.stopSession()
            }
            .sheet(isPresented: $showingMatchGuide) {
                referenceMatchGuideSheet
            }
            .photosPicker(
                isPresented: $showingPhotosPicker,
                selection: $selectedPhotoItems,
                maxSelectionCount: 3,
                matching: .images
            )
            .onChange(of: selectedPhotoItems) { _, items in
                guard !items.isEmpty else { return }
                loadSelectedPhotos(items)
            }
            .onChange(of: guidanceService.feedback.allChecksPassed) { _, isAligned in
                // The service also checks each live frame. Observing the published
                // state here covers any other alignment input while the countdown
                // overlay is visible and lets it reset before a bad capture.
                if !isAligned {
                    guidanceService.cancelCountdownIfAlignmentLost()
                }
            }
            .sheet(isPresented: $showingReviewSheet) {
                HeadshotReviewView(
                    audition: audition,
                    initialFront: frontOriginal,
                    initialLeft: leftOriginal,
                    initialRight: rightOriginal
                ) {
                    onCompleted()
                    dismiss()
                }
            }
        }
    }

    // MARK: - Extracted Angle Segmented Picker

    @ViewBuilder
    private var angleSegmentedPicker: some View {
        if let retakeAngle {
            Text("Retake \(retakeAngle.rawValue)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.55))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
        } else {
            HStack(spacing: 2) {
                ForEach(sequence, id: \.self) { angle in
                    let isSelected = (currentAngle == angle)
                    Button {
                        if let idx = sequence.firstIndex(of: angle) {
                            currentStepIndex = idx
                            guidanceService.startSession(for: angle)
                            guidanceService.announceAngle(angle)
                        }
                    } label: {
                        Text(angle.rawValue.capitalized)
                            .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                            .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.5))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(isSelected ? Color.white.opacity(0.25) : Color.clear)
                            .clipShape(Capsule())
                    }
                    .disabled(guidanceService.isCapturing)
                }
            }
            .padding(3)
            .background(Color.black.opacity(0.55))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
        }
    }

    // MARK: - Live Viewfinder

    private var cameraPreviewLayer: some View {
        ZStack {
            #if targetEnvironment(simulator)
            LinearGradient(
                colors: [Color(white: 0.18), Color(white: 0.10)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack {
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: "camera.fill")
                    Text("Simulator Active • \(currentAngle.rawValue.capitalized) (\(currentStepIndex + 1)/3)")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.4))
                .padding(.bottom, 160)
            }
            #else
            if let session = guidanceService.captureSession {
                LiveCameraPreview(session: session)
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }
            #endif
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

            let strokeColor = isAligned ? Color.green : Theme.Colors.cameraGuideGoldStroke.opacity(0.75)

            ZStack {
                Path { path in
                    path.addRect(CGRect(x: 0, y: 0, width: w, height: h))
                    let ovalRect = CGRect(x: centerX - ovalW / 2.0, y: centerY - ovalH / 2.0, width: ovalW, height: ovalH)
                    path.addEllipse(in: ovalRect)
                }
                .fill(Color.black.opacity(0.38), style: FillStyle(eoFill: true))

                Ellipse()
                    .stroke(strokeColor, lineWidth: 2.5)
                    .frame(width: ovalW, height: ovalH)
                    .position(x: centerX, y: centerY)

                let eyeY = centerY - ovalH * 0.08
                let notchLength: CGFloat = 18

                Path { path in
                    let leftX = centerX - ovalW / 2.0
                    path.move(to: CGPoint(x: leftX - 4, y: eyeY))
                    path.addLine(to: CGPoint(x: leftX + notchLength, y: eyeY))
                }
                .stroke(strokeColor, lineWidth: 2)

                Path { path in
                    let rightX = centerX + ovalW / 2.0
                    path.move(to: CGPoint(x: rightX + 4, y: eyeY))
                    path.addLine(to: CGPoint(x: rightX - notchLength, y: eyeY))
                }
                .stroke(strokeColor, lineWidth: 2)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Bottom Dark-Cinema HUD

    private var bottomCinemaHUD: some View {
        VStack(spacing: 14) {
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
                .background(Color.black.opacity(0.6))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))

                HStack(spacing: 5) {
                    Circle()
                        .fill(guidanceService.feedback.isAngleCorrect ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(anglePillTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.6))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))

                HStack(spacing: 5) {
                    Circle()
                        .fill(guidanceService.isVoiceListening ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(guidanceService.voiceStatus.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.6))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
            }

            VStack(spacing: 4) {
                Text(liveCoachingHeadline)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text("Tap, or say \"Action\" or \"Now\"")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.65))
            }
            .padding(.horizontal, 16)

            HStack(spacing: 0) {
                Button {
                    guidanceService.voiceGuidanceEnabled.toggle()
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.black.opacity(0.55))
                            .frame(width: 50, height: 50)
                            .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))

                        Image(systemName: guidanceService.voiceGuidanceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(guidanceService.voiceGuidanceEnabled ? Color.white : Color.white.opacity(0.45))
                    }
                }
                .accessibilityLabel(guidanceService.voiceGuidanceEnabled ? "Disable voice guidance" : "Enable voice guidance")

                Spacer()

                Button {
                    triggerBatchCapture()
                } label: {
                    ZStack {
                        Circle()
                            .stroke(Color.white, lineWidth: 4)
                            .frame(width: 78, height: 78)

                        Circle()
                            .fill(guidanceService.isCapturing ? Color.red : Color.white)
                            .frame(width: 64, height: 64)
                    }
                }
                .disabled(guidanceService.isCapturing)

                Spacer()

                Button {
                    guidanceService.flipCamera()
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.black.opacity(0.55))
                            .frame(width: 50, height: 50)
                            .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))

                        Image(systemName: "camera.rotate")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.white)
                    }
                }
                .disabled(guidanceService.isCapturing)
                .accessibilityLabel("Flip camera")
            }
            .padding(.horizontal, 24)
        }
    }

    private var anglePillTitle: String {
        switch currentAngle {
        case .front: return "Face forward"
        case .left: return "Turn left"
        case .right: return "Turn right"
        }
    }

    private var liveCoachingHeadline: String {
        if guidanceService.feedback.allChecksPassed {
            return "Framing and lighting look great — hold steady"
        } else if !guidanceService.feedback.isFaceCentered {
            return "Center your face in the guide oval"
        } else if !guidanceService.feedback.isAngleCorrect {
            switch currentAngle {
            case .front: return "Face the camera directly"
            case .left: return "Turn head slightly to your left"
            case .right: return "Turn head slightly to your right"
            }
        } else if guidanceService.feedback.lighting != .good {
            if guidanceService.feedback.lighting == .tooDark {
                return "Lighting is too dark — add key light"
            } else if guidanceService.feedback.lighting == .uneven {
                return "Balance light evenly across face"
            } else {
                return "Lighting is too bright — reduce glare"
            }
        } else if !guidanceService.feedback.isEyeLevel {
            return "Hold phone at eye level"
        } else if guidanceService.feedback.background != .clean {
            return "Background busy — use a plain wall"
        } else {
            return "Align inside the guide oval"
        }
    }

    // MARK: - One-Time "Talk to OneTake" Voice Guide Card Overlay

    private var talkToOneTakeGuideOverlay: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(Theme.Colors.cameraGuideGoldFill.opacity(0.2))
                            .frame(width: 58, height: 58)

                        Image(systemName: "waveform.badge.mic")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(Theme.Colors.cameraGuideGold)
                    }

                    Text("Talk to OneTake")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)

                    Text("Hands-free voice commands for your headshot session")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 4)

                VStack(spacing: 14) {
                    headshotVoiceRow(
                        phrase: "\"How do I look?\"",
                        desc: "Check live framing, angle & lighting aloud",
                        icon: "waveform",
                        iconColor: Theme.Colors.cameraGuideLilac
                    )

                    Divider().background(Color.white.opacity(0.12))

                    headshotVoiceRow(
                        phrase: "\"Action\" or \"Now\"",
                        desc: "Hands-free shutter capture with 3s countdown",
                        icon: "camera.fill",
                        iconColor: Color.green
                    )
                }
                .padding(16)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.12), lineWidth: 1))

                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        showVoiceGuideIntro = false
                    }
                    guidanceService.announceAngle(currentAngle)
                } label: {
                    Text("Got It")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(
                            LinearGradient(
                                colors: [Theme.Colors.primaryPlum, Theme.Colors.primaryPlum.opacity(0.85)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .clipShape(Capsule())
                        .shadow(color: Theme.Colors.primaryPlum.opacity(0.4), radius: 10, y: 4)
                }
            }
            .padding(24)
            .background(Theme.Colors.cameraPanel)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.white.opacity(0.15), lineWidth: 1))
            .shadow(color: Color.black.opacity(0.5), radius: 30, x: 0, y: 15)
            .padding(.horizontal, 24)
            .transition(.scale(scale: 0.95).combined(with: .opacity))
        }
        .zIndex(100)
    }

    private func headshotVoiceRow(phrase: String, desc: String, icon: String, iconColor: Color) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.16))
                    .frame(width: 38, height: 38)

                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(iconColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(phrase)
                    .font(.system(size: 15, weight: .bold))
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
                                title: "1. Front Angle",
                                detail: "Face the lens squarely with eyes on the upper third horizontal notch. Soft natural key light in front.",
                                icon: "person.crop.rectangle"
                            )

                            guideCard(
                                title: "2. 3/4 Left Profile",
                                detail: "Turn nose approximately 40° to your left while keeping your gaze on the camera lens.",
                                icon: "arrow.left.and.right.square"
                            )

                            guideCard(
                                title: "3. 3/4 Right Profile",
                                detail: "Turn nose approximately 40° to your right, maintaining eye level and relaxed shoulders.",
                                icon: "arrow.left.and.right.square"
                            )
                        }

                        Button {
                            showingMatchGuide = false
                        } label: {
                            Text("Done")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Theme.Colors.primaryPlum)
                                .clipShape(Capsule())
                        }
                        .padding(.top, 10)
                    }
                    .padding(24)
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
        }
        .padding(14)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Batch Continuous Capture Trigger

    private func triggerBatchCapture() {
        guidanceService.startCountdown(seconds: 3) { capturedImage in
            guard let image = capturedImage else { return }

            switch currentStepIndex {
            case 0: self.frontOriginal = image
            case 1: self.leftOriginal = image
            case 2: self.rightOriginal = image
            default: break
            }

            if retakeAngle != nil {
                guidanceService.stopSession()
                onRetakeComplete?(image)
                dismiss()
                return
            }

            // Continuous batch: advance Front -> Left -> Right without re-showing intro guide
            if currentStepIndex < sequence.count - 1 {
                currentStepIndex += 1
                guidanceService.transitionToNextPose(currentAngle)
            } else {
                guidanceService.stopSession()
                self.showingReviewSheet = true
            }
        }
    }

    // MARK: - Load Selected Photos

    private func loadSelectedPhotos(_ items: [PhotosPickerItem]) {
        Task {
            var images: [UIImage] = []
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    images.append(image)
                }
            }

            guard !images.isEmpty else { return }

            await MainActor.run {
                if images.count >= 1 { self.frontOriginal = images[0] }
                if images.count >= 2 { self.leftOriginal = images[1] } else if let front = self.frontOriginal { self.leftOriginal = front }
                if images.count >= 3 { self.rightOriginal = images[2] } else if let left = self.leftOriginal { self.rightOriginal = left }

                self.showingPhotosPicker = false
                self.showingReviewSheet = true
            }
        }
    }
}

// MARK: - Compatibility Typealias
typealias HeadshotCaptureView = HeadshotGuidanceView
