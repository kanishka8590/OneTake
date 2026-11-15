import SwiftUI
import AVFoundation
import SwiftData

struct CueRecorderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    let audition: Audition
    @Binding var cueLines: [CueLine]
    let onFinished: () -> Void

    @State private var audioEngine = CuePartnerAudioEngine.shared
    @State private var selectedIndex: Int = 0
    @State private var isRecording: Bool = false
    @State private var isPlaying: Bool = false
    @State private var recordingDuration: Double = 0.0
    @State private var recordTimer: Timer?
    @State private var hasMicrophonePermission = false

    var currentCue: CueLine? {
        guard !cueLines.isEmpty, selectedIndex < cueLines.count else { return nil }
        return cueLines[selectedIndex]
    }

    var recordedCount: Int {
        cueLines.filter { $0.audioFilePath != nil }.count
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.canvasBackground
                    .ignoresSafeArea()

                VStack(spacing: 20) {
                    // Progress Header: 0 of N -> N of N Recordings Completed
                    VStack(spacing: 6) {
                        HStack {
                            Text("\(recordedCount) of \(cueLines.count) Recorded")
                                .font(Theme.Typography.captionBadge)
                                .foregroundStyle(recordedCount == cueLines.count ? Theme.Colors.successGreen : Theme.Colors.accent)

                            Spacer()

                            Text("Cue \(selectedIndex + 1) of \(cueLines.count)")
                                .font(Theme.Typography.captionBadge)
                                .foregroundStyle(Theme.Colors.textSecondary)
                        }

                        // Progress bar
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Theme.Colors.lavenderSurface)
                                    .frame(height: 6)

                                Capsule()
                                    .fill(recordedCount == cueLines.count ? Theme.Colors.successGreen : Theme.Colors.accent)
                                    .frame(width: cueLines.isEmpty ? 0 : geo.size.width * CGFloat(recordedCount) / CGFloat(cueLines.count), height: 6)
                            }
                        }
                        .frame(height: 6)
                    }
                    .padding(.horizontal, Theme.Layout.screenHPadding)
                    .padding(.top, 12)

                    if let cue = currentCue {
                        // Cue Card Display
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text("Speaker: \(cue.speaker)")
                                    .font(Theme.Typography.captionBadge)
                                    .foregroundStyle(Theme.Colors.accent)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Theme.Colors.lavenderSurface)
                                    .clipShape(Capsule())

                                Spacer()

                                if cue.audioFilePath != nil {
                                    HStack(spacing: 4) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Theme.Colors.successGreen)
                                        Text("Audio Ready (\(String(format: "%.1fs", cue.durationSeconds)))").monospacedDigit()
                                            .font(Theme.Typography.captionBadge)
                                            .foregroundStyle(Theme.Colors.successGreen)
                                    }
                                }
                            }

                            if !cue.precedingActorLine.isEmpty {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Actor's Preceding Line:")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(Theme.Colors.textSecondary)
                                    Text("\"\(cue.precedingActorLine)\"")
                                        .font(Theme.Typography.bodyRegular)
                                        .foregroundStyle(Theme.Colors.textSecondary)
                                        .italic()
                                }
                                .padding(10)
                                .background(Theme.Colors.lavenderTint)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Cue Dialogue to Read:")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Theme.Colors.textSecondary)

                                Text("\"\(cue.cueText)\"")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(Theme.Colors.textPrimary)
                            }
                        }
                        .padding(16)
                        .cardStyle()
                        .padding(.horizontal, Theme.Layout.screenHPadding)

                        // Live dB Waveform Indicator
                        VStack(spacing: 8) {
                            HStack(spacing: 3) {
                                ForEach(0..<24) { i in
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(isRecording ? Theme.Colors.errorCrimson : (isPlaying ? Theme.Colors.accent : Theme.Colors.lavenderSurface))
                                        .frame(width: 4, height: max(6, CGFloat(audioEngine.currentAudioLevel * 50.0) * sin(Double(i) * 0.3 + (isRecording ? Double(recordingDuration * 5) : 1.0))))
                                        .animation(.linear(duration: 0.05), value: audioEngine.currentAudioLevel)
                                }
                            }
                            .frame(height: 50)

                            if isRecording {
                                Text(String(format: "Recording... %.1fs", recordingDuration))
                                    .font(Theme.Typography.captionBadge)
                                    .foregroundStyle(Theme.Colors.errorCrimson)
                            }
                        }
                        .frame(height: 70)

                        // Recording & Playback Controls
                        HStack(spacing: 24) {
                            // Listen / Playback button
                            Button {
                                togglePlayback(for: cue)
                            } label: {
                                Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                                    .font(.system(size: 44))
                                    .foregroundStyle(cue.audioFilePath != nil ? Theme.Colors.accent : Theme.Colors.textSecondary.opacity(0.4))
                            }
                            .disabled(cue.audioFilePath == nil || isRecording)

                            // Main Record / Stop Button
                            Button {
                                toggleRecording()
                            } label: {
                                ZStack {
                                    Circle()
                                        .stroke(Theme.Colors.errorCrimson, lineWidth: 3)
                                        .frame(width: 72, height: 72)

                                    if isRecording {
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(Theme.Colors.errorCrimson)
                                            .frame(width: 28, height: 28)
                                    } else {
                                        Circle()
                                            .fill(Theme.Colors.errorCrimson)
                                            .frame(width: 58, height: 58)
                                    }
                                }
                            }
                            .disabled(isPlaying || !hasMicrophonePermission)

                            // Retake / Delete button
                            Button {
                                deleteCurrentRecording()
                            } label: {
                                Image(systemName: "arrow.counterclockwise.circle.fill")
                                    .font(.system(size: 44))
                                    .foregroundStyle(cue.audioFilePath != nil ? Theme.Colors.warningAmber : Theme.Colors.textSecondary.opacity(0.4))
                            }
                            .disabled(cue.audioFilePath == nil || isRecording)
                        }

                        // Stepper Prev / Next
                        HStack {
                            Button {
                                if selectedIndex > 0 {
                                    stopPlayback()
                                    selectedIndex -= 1
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "chevron.left")
                                    Text("Previous Cue")
                                }
                                .font(Theme.Typography.captionBadge)
                                .foregroundStyle(selectedIndex > 0 ? Theme.Colors.accent : Theme.Colors.textSecondary.opacity(0.4))
                            }
                            .disabled(selectedIndex == 0 || isRecording)

                            Spacer()

                            Button {
                                if selectedIndex < cueLines.count - 1 {
                                    stopPlayback()
                                    selectedIndex += 1
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text("Next Cue")
                                    Image(systemName: "chevron.right")
                                }
                                .font(Theme.Typography.captionBadge)
                                .foregroundStyle(selectedIndex < cueLines.count - 1 ? Theme.Colors.accent : Theme.Colors.textSecondary.opacity(0.4))
                            }
                            .disabled(selectedIndex >= cueLines.count - 1 || isRecording)
                        }
                        .padding(.horizontal, 28)
                    }

                    Spacer()

                    // Done & Save button
                    Button {
                        stopPlayback()
                        onFinished()
                        dismiss()
                    } label: {
                        Text(recordedCount == cueLines.count ? "Complete Scene Partner Setup" : "Save & Continue")
                            .primaryCapsuleButton()
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Reader Cue Recorder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        stopPlayback()
                        dismiss()
                    }
                }
            }
            .onDisappear {
                stopPlayback()
                audioEngine.stopAuditionScenePartner()
            }
            .onAppear {
                audioEngine.requestRecordingPermission { granted in
                    hasMicrophonePermission = granted
                }
            }
        }
    }

    // MARK: - Audio Actions

    private func toggleRecording() {
        guard hasMicrophonePermission else { return }
        if isRecording {
            // Stop recording
            recordTimer?.invalidate()
            recordTimer = nil
            let result = audioEngine.stopRecordingCue()
            isRecording = false

            if let tempURL = result.url {
                // Save to deterministic path: Documents/CueAudio/<audition.id>_<cue.id>.m4a
                let cue = cueLines[selectedIndex]
                let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let cueAudioDir = docsDir.appendingPathComponent("CueAudio", isDirectory: true)
                try? FileManager.default.createDirectory(at: cueAudioDir, withIntermediateDirectories: true)

                let deterministicName = "\(audition.id)_\(cue.id).m4a"
                let deterministicURL = cueAudioDir.appendingPathComponent(deterministicName)

                // Remove any previous recording at this deterministic path
                try? FileManager.default.removeItem(at: deterministicURL)
                // Move the temp recording to the deterministic path
                do {
                    try FileManager.default.moveItem(at: tempURL, to: deterministicURL)
                } catch {
                    print("Failed to move cue recording to deterministic path: \(error)")
                }

                // Mutate audition.cueLines[index] directly with saved path
                cueLines[selectedIndex].audioFilePath = deterministicURL.path
                cueLines[selectedIndex].durationSeconds = result.durationSeconds
                audition.cueLines = cueLines
                try? appState.modelContext?.save()

                // Auto-advance to next cue if available
                if selectedIndex < cueLines.count - 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        selectedIndex += 1
                    }
                }
            }
        } else {
            // Start recording
            stopPlayback()
            do {
                _ = try audioEngine.startRecordingCue(orderIndex: selectedIndex)
                isRecording = true
                recordingDuration = 0.0
                recordTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                    recordingDuration += 0.1
                }
            } catch {
                print("Recording cue error: \(error)")
            }
        }
    }

    private func togglePlayback(for cue: CueLine) {
        if isPlaying {
            stopPlayback()
        } else if let path = cue.audioFilePath {
            let url = URL(fileURLWithPath: path)
            isPlaying = true
            audioEngine.playCue(at: url) {
                isPlaying = false
            }
        }
    }

    private func stopPlayback() {
        audioEngine.stopPlayback()
        isPlaying = false
    }

    private func deleteCurrentRecording() {
        stopPlayback()
        if let path = cueLines[selectedIndex].audioFilePath {
            try? FileManager.default.removeItem(atPath: path)
        }
        cueLines[selectedIndex].audioFilePath = nil
        cueLines[selectedIndex].durationSeconds = 0
        audition.cueLines = cueLines
        try? appState.modelContext?.save()
    }
}
