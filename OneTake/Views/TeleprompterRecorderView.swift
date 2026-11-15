import SwiftUI
import AVFoundation
import PhotosUI

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
    @State private var scrollTimer: Timer?
    @State private var isShowingSpeedControl = false
    @State private var selectedCountdownSeconds: Int = 3
    @State private var cueTimingMode: CueTriggerMode = .afterMyLine

    // Post-recording review transition
    @State private var rawVideoOutputURL: URL?
    @State private var recordedDuration: Double = 0.0
    @State private var showingTakeReview = false

    // Upfront "Choose from Photos"
    @State private var showingVideoPhotosPicker = false
    @State private var selectedVideoItem: PhotosPickerItem?

    private var effectiveScriptLines: [String] {
        scriptLines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
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
                            .font(.system(size: 110, weight: .bold))
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
                        .disabled(recorderService.isRecording || recorderService.isCountingDown)
                    }
                }
            }
            .onAppear {
                // This is reached directly for a retake/import and is a safe fallback
                // in addition to the briefing screen's upfront request.
                VoiceAuthorizationService.shared.requestAccess()
                selectedCountdownSeconds = appState.settings.countdownSeconds
                scrollSpeed = appState.settings.teleprompterScrollSpeed
                recorderService.defaultCountdownSeconds = selectedCountdownSeconds
                if !audition.cueLines.isEmpty {
                    cueTimingMode = .afterMyLine
                }

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
                        cueEngine.startListening(cues: audition.cueLines, mode: .afterMyLine, responseDelay: appState.settings.cueDelaySeconds)
                    }
                } else {
                    stopPrompterScroll()
                    cueEngine.stopListening()
                }
            }
            .photosPicker(
                isPresented: $showingVideoPhotosPicker,
                selection: $selectedVideoItem,
                matching: .videos
            )
            .onChange(of: selectedVideoItem) { _, item in
                guard let item = item else { return }
                selectedVideoItem = nil
                loadImportedVideo(from: item)
            }
            .sheet(isPresented: $showingTakeReview) {
                if let url = rawVideoOutputURL {
                    TakeReviewView(
                        audition: audition,
                        rawVideoURL: url,
                        totalDurationSeconds: recordedDuration,
                        isSlate: isSlate
                    ) { approvedTake in
                        showingTakeReview = false
                        onTakeSaved(approvedTake)
                        dismiss()
                    } onRetake: {
                        showingTakeReview = false
                        scrollOffset = 0.0
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
                Text("Camera Active (16:9 • 1080p • Mirror On)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.35))
                    .padding(.bottom, 160)
            }
            #else
            if let session = recorderService.captureSession {
                LiveCameraPreview(session: session)
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
                        .tint(Theme.Colors.primaryPlum)
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

                ScrollViewReader { _ in
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
                        .offset(y: -scrollOffset)
                    }
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
        if line.hasPrefix("[READER]") || line.hasPrefix("[CUE]") {
            return Color(red: 0.75, green: 0.70, blue: 0.95)
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
                        Image(systemName: "forward.fill")
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

                        Image(systemName: recorderService.voiceGuidanceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
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
                .disabled(recorderService.isCountingDown)

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
                .disabled(recorderService.isRecording || recorderService.isCountingDown)
                .accessibilityLabel("Flip camera")
            }
            .padding(.horizontal, 24)
        }
    }

    // MARK: - Recording Actions

    private func startCountdownAndRecord() {
        recorderService.startCountdownAndRecord(countdownSeconds: selectedCountdownSeconds) { url, duration in
            if let outputURL = url {
                self.rawVideoOutputURL = outputURL
                self.recordedDuration = duration
                self.showingTakeReview = true
            }
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
            guard recorderService.isRecording else { return }
            scrollOffset += CGFloat(scrollSpeed * 0.9)
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

    private func loadImportedVideo(from item: PhotosPickerItem) {
        Task {
            if let movie = try? await item.loadTransferable(type: MovieTransferable.self) {
                let asset = AVURLAsset(url: movie.url)
                let dur = (try? await asset.load(.duration).seconds) ?? 15.0
                await MainActor.run {
                    stopAllOperations()
                    self.rawVideoOutputURL = movie.url
                    self.recordedDuration = dur
                    self.showingTakeReview = true
                }
            }
        }
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

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
    }

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
