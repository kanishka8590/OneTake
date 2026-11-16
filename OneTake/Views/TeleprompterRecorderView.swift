import SwiftUI
import AVFoundation

private struct TakeReviewRoute: Identifiable {
    let id = UUID()
    let videoURL: URL
    let duration: Double
    let qualityMetrics: PreTakeQualityMetrics
    let usedFrontCamera: Bool
}

struct TeleprompterRecorderView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let audition: Audition
    let modeTitle: String // "Slate Video" or "Audition Take"
    let scriptLines: [String]
    let isSlate: Bool
    let onTakeSaved: (VideoTake) -> Void
    var onRecorderCancelled: (() -> Void)? = nil

    @State private var recorderService = TeleprompterRecorderService.shared
    @State private var cueEngine = CuePartnerAudioEngine.shared

    // Teleprompter Scroll State
    @State private var scrollSpeed: Double = 1.0
    @State private var scrollOffset: CGFloat = 0.0
    @State private var prompterViewportHeight: CGFloat = 0.0
    @State private var prompterContentHeight: CGFloat = 0.0
    @State private var scrollTimer: Timer?
    @State private var isShowingSpeedControl = false
    @State private var selectedCountdownSeconds: Int = 3
    @State private var cueTimingMode: CueTriggerMode = .afterMyLine

    // Post-recording review transition
    @State private var takeReviewRoute: TakeReviewRoute?
    @State private var didSaveApprovedTake = false

    private var effectiveScriptLines: [String] {
        scriptLines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var maxScrollOffset: CGFloat {
        max(0, prompterContentHeight - prompterViewportHeight)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                // Live Camera Viewfinder
                cameraViewfinder

                VStack(spacing: 0) {
                    Spacer().frame(height: 8)

                    // Scrolling Teleprompter Overlay (hidden if empty)
                    if !effectiveScriptLines.isEmpty {
                        teleprompterOverlay
                            .frame(maxHeight: 280)
                            .padding(.horizontal, 16)
                            .padding(.top, 10)
                    }

                    if let cameraError = recorderService.cameraErrorMessage {
                        Text(cameraError)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.red.opacity(0.75))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .padding(.horizontal, 20)
                            .padding(.top, 10)
                    }

                    Spacer()

                    // Bottom Dark-Cinema HUD
                    bottomCinemaHUD
                        .padding(.bottom, 28)
                        .padding(.horizontal, 20)
                }

                // Spoken Countdown Fullscreen Overlay
                if recorderService.isCountingDown && recorderService.countdownRemaining > 0 {
                    ZStack {
                        Color.black.opacity(0.45).ignoresSafeArea()
                        Text("\(recorderService.countdownRemaining)")
                            .font(.system(size: 110, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color.white)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            }
            .preferredColorScheme(.dark)
            .navigationBarBackButtonHidden()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        stopAllOperations()
                        scrollOffset = 0.0
                        dismiss()
                        onRecorderCancelled?()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.black.opacity(0.55))
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                    }
                    .disabled(recorderService.isRecording || recorderService.isCountingDown)
                }

                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        Text(modeTitle)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)

                        if recorderService.isRecording {
                            HStack(spacing: 5) {
                                Circle().fill(Color.red).frame(width: 8, height: 8)
                                Text(formattedDuration(recorderService.recordingDurationSeconds))
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 8) {
                        Button {
                            recorderService.cycleZoom()
                        } label: {
                            Text(String(format: "%.1fx", recorderService.currentZoomFactor))
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.black.opacity(0.55))
                                .clipShape(Capsule())
                                .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
                        }
                        .disabled(recorderService.isRecording || recorderService.isCountingDown || recorderService.cameraPermissionDenied)
                    }
                }
            }
            .onAppear {
                didSaveApprovedTake = false
                // This is reached directly for a retake/import and is a safe fallback
                // in addition to the briefing screen's upfront request.
                VoiceAuthorizationService.shared.requestAccess()
                selectedCountdownSeconds = appState.settings.countdownSeconds
                scrollSpeed = appState.settings.teleprompterScrollSpeed
                cueTimingMode = appState.settings.cueTriggerMode
                recorderService.defaultCountdownSeconds = selectedCountdownSeconds
                recorderService.voiceGuidanceEnabled = appState.settings.framingTipsOutLoud
                recorderService.countdownOutLoud = appState.settings.countdownOutLoud
                recorderService.isDemoMode = appState.isDemoMode
                recorderService.mirrorFrontCamera = appState.settings.mirrorFrontCamera
                recorderService.applyVideoSettings(
                    quality: appState.settings.videoQuality,
                    frameRate: appState.settings.frameRate
                )
                cueEngine.cueVolume = Float(appState.settings.cueVolume)

                recorderService.onVoiceActionTriggered = {
                    startCountdownAndRecord()
                }

                recorderService.onLiveMicData = { rms, transcript, isFinal in
                    cueEngine.ingestLiveMicInput(rms: rms, transcript: transcript, isFinal: isFinal)
                }
                recorderService.shouldIgnoreRecognizedTranscript = { cueEngine.isCuePlaying }

                recorderService.startSession()
            }
            .onDisappear {
                recorderService.onVoiceActionTriggered = nil
                recorderService.onLiveMicData = nil
                recorderService.shouldIgnoreRecognizedTranscript = nil
                stopAllOperations()
            }
            .onChange(of: recorderService.isRecording) { _, isRecording in
                if isRecording {
                    if !effectiveScriptLines.isEmpty {
                        startPrompterScroll()
                    }
                    if !isSlate && !audition.cueLines.isEmpty {
                        cueEngine.startListening(
                            cues: audition.cueLines,
                            mode: cueTimingMode,
                            responseDelay: appState.settings.cueDelaySeconds,
                            cueVolume: appState.settings.cueVolume
                        )
                    }
                } else {
                    stopPrompterScroll()
                    cueEngine.stopListening()
                }
            }
            .fullScreenCover(item: $takeReviewRoute, onDismiss: {
                if !didSaveApprovedTake && !recorderService.isSessionRunning {
                    scrollOffset = 0.0
                    recorderService.startSession()
                }
            }) { route in
                TakeReviewView(
                    audition: audition,
                    rawVideoURL: route.videoURL,
                    totalDurationSeconds: route.duration,
                    isSlate: isSlate,
                    qualityMetrics: route.qualityMetrics,
                    usedFrontCamera: route.usedFrontCamera,
                    autoTrimSilence: appState.settings.autoTrimSilence
                ) { approvedTake in
                    didSaveApprovedTake = true
                    takeReviewRoute = nil
                    onTakeSaved(approvedTake)
                } onRetake: {
                    takeReviewRoute = nil
                    scrollOffset = 0.0
                    if !recorderService.isSessionRunning {
                        recorderService.startSession()
                    }
                }
            }
        }
    }

    // MARK: - Viewfinder

    private var cameraViewfinder: some View {
        ZStack {
            #if targetEnvironment(simulator)
            LinearGradient(
                colors: [Color(white: 0.16), Color(white: 0.08)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack {
                Spacer()
                Text(appState.isDemoMode
                     ? "Camera Simulated (Demo Mode • 16:9 • 1080p)"
                     : "Simulator Camera Unavailable (Enable Demo Mode in Profile)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .padding(.bottom, 160)
            }
            #else
            if recorderService.cameraPermissionDenied {
                VStack(spacing: 12) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 40))
                        .foregroundStyle(.white.opacity(0.75))
                    Text("Camera Access Required")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Enable Camera access in Settings to record your take.")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            } else if let session = recorderService.captureSession {
                LiveCameraPreview(session: session) { previewLayer in
                    recorderService.attachPreviewLayer(previewLayer)
                }
                .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }
            #endif
        }
    }

    // MARK: - Scrolling Teleprompter Overlay

    private var teleprompterOverlay: some View {
        VStack(spacing: 6) {
            HStack {
                Button {
                    scrollOffset = 0.0
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.backward")
                        Text("Reset")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.8))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.5))
                    .clipShape(Capsule())
                }
                .disabled(recorderService.isCountingDown)

                Spacer()

                Button {
                    withAnimation { isShowingSpeedControl.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "speedometer")
                        Text(String(format: "%.1fx Speed", scrollSpeed))
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.5))
                    .clipShape(Capsule())
                }
            }

            if isShowingSpeedControl {
                HStack(spacing: 12) {
                    Text("0.5x").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    Slider(value: $scrollSpeed, in: 0.5...2.5, step: 0.1)
                        .tint(Theme.Colors.accent)
                    Text("2.5x").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.75))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.black.opacity(0.55))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12), lineWidth: 1))

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(effectiveScriptLines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(prompterFont)
                                .foregroundStyle(lineColor(for: line))
                                .lineSpacing(6)
                                .id(idx)
                        }
                        Spacer().frame(height: 120)
                    }
                    .padding(16)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { newHeight in
                        prompterContentHeight = newHeight
                        scrollOffset = min(scrollOffset, max(0, newHeight - prompterViewportHeight))
                    }
                    .offset(y: -scrollOffset)
                }
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { newHeight in
                    prompterViewportHeight = newHeight
                    scrollOffset = min(scrollOffset, max(0, prompterContentHeight - newHeight))
                }
            }
        }
    }

    private var prompterFont: Font {
        switch appState.settings.teleprompterTextSize {
        case .regular: return .system(size: 17, weight: .medium)
        case .large: return .system(size: 21, weight: .semibold)
        case .bigPrint: return .system(size: 26, weight: .bold)
        }
    }

    private func lineColor(for line: String) -> Color {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[READER]") || trimmed.hasPrefix("[CUE]") {
            return Theme.Colors.cameraTeleprompterHighlight
        }
        let upper = trimmed.uppercased()
        let cueSpeakers = Set(
            audition.cueLines
                .map { $0.speaker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
                .filter { !$0.isEmpty }
        )
        for speaker in cueSpeakers {
            if upper.hasPrefix("\(speaker):") || upper.hasPrefix("[\(speaker)]") {
                return Theme.Colors.cameraTeleprompterHighlight
            }
        }
        return Color.white
    }

    // MARK: - Dark-Cinema Studio Bottom HUD

    private var bottomCinemaHUD: some View {
        VStack(spacing: 14) {
            if recorderService.isRecording && !isSlate && !audition.cueLines.isEmpty {
                Button {
                    cueEngine.playNextCue()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "forward")
                            .font(.system(size: 11, weight: .bold))
                        Text("Play Next Cue")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        Capsule()
                            .fill(Color.purple.opacity(cueEngine.isCuePlaying ? 0.35 : 0.8))
                    )
                }
                .disabled(cueEngine.isCuePlaying || cueEngine.currentCueIndex >= audition.cueLines.count)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(recorderService.qualityMetrics.isLightPassed ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text("Light: \(recorderService.qualityMetrics.lightStatus)")
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
                        .fill(recorderService.qualityMetrics.isAlignmentPassed ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text("Framing")
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
                        .fill(recorderService.isVoiceListening ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(recorderService.voiceStatus.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.6))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
            }

            HStack(spacing: 0) {
                Button {
                    recorderService.voiceGuidanceEnabled.toggle()
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.black.opacity(0.55))
                            .frame(width: 50, height: 50)
                            .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))

                        Image(systemName: recorderService.voiceGuidanceEnabled ? "speaker.wave.2" : "speaker.slash")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(recorderService.voiceGuidanceEnabled ? Color.white : Color.white.opacity(0.45))
                    }
                }
                .accessibilityLabel(recorderService.voiceGuidanceEnabled ? "Disable voice guidance" : "Enable voice guidance")

                Spacer()

                Button {
                    if recorderService.isRecording {
                        stopRecordingAndReview()
                    } else if !recorderService.isCountingDown {
                        startCountdownAndRecord()
                    }
                } label: {
                    ZStack {
                        Circle()
                            .stroke(Color.white, lineWidth: 4)
                            .frame(width: 80, height: 80)

                        if recorderService.isRecording {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.red)
                                .frame(width: 32, height: 32)
                        } else {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 66, height: 66)
                        }
                    }
                }
                .disabled(recorderService.isCountingDown || recorderService.cameraPermissionDenied)

                Spacer()

                Button {
                    recorderService.flipCamera()
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
                .disabled(recorderService.isRecording || recorderService.isCountingDown || recorderService.cameraPermissionDenied)
                .accessibilityLabel("Flip camera")
            }
            .padding(.horizontal, 24)
        }
    }

    // MARK: - Recording Actions

    private func startCountdownAndRecord() {
        let frontUsed = recorderService.isUsingFrontCamera
        recorderService.startCountdownAndRecord(
            countdownSeconds: selectedCountdownSeconds,
            isDemoMode: appState.isDemoMode
        ) { url, duration in
            guard let outputURL = url else { return }
            stopAllOperations()
            self.takeReviewRoute = TakeReviewRoute(
                videoURL: outputURL,
                duration: duration,
                qualityMetrics: recorderService.qualityMetrics,
                usedFrontCamera: frontUsed
            )
        }
    }

    private func stopRecordingAndReview() {
        stopPrompterScroll()
        cueEngine.stopListening()
        recorderService.stopRecording()
    }

    private func startPrompterScroll() {
        guard !effectiveScriptLines.isEmpty else { return }
        scrollTimer?.invalidate()
        scrollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            Task { @MainActor in
                guard recorderService.isRecording else { return }
                let nextOffset = scrollOffset + CGFloat(scrollSpeed * 0.9)
                scrollOffset = min(maxScrollOffset, nextOffset)
            }
        }
    }

    private func stopPrompterScroll() {
        scrollTimer?.invalidate()
        scrollTimer = nil
    }

    private func stopAllOperations() {
        stopPrompterScroll()
        cueEngine.stopListening()
        recorderService.stopSession()
    }

    private func formattedDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}

// MARK: - Live Camera Preview Representable

struct LiveCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var onLayerReady: ((AVCaptureVideoPreviewLayer) -> Void)? = nil

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        onLayerReady?(view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
        onLayerReady?(uiView.previewLayer)
    }

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
