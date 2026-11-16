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
    @State private var autoAdvanceTask: Task<Void, Never>?
    @State private var hasMicrophonePermission = false
    @State private var recordingErrorMessage: String?
    @State private var showingErrorAlert = false

    var currentCue: CueLine? {
        guard cueLines.indices.contains(selectedIndex) else { return nil }
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

                            Text(cueLines.isEmpty ? "No Cues" : "Cue \(selectedIndex + 1) of \(cueLines.count)")
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
                                        Image(systemName: "checkmark.circle")
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
                                ForEach(0..<24, id: \.self) { i in
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
                                Image(systemName: isPlaying ? "stop.circle" : "play.circle")
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
                                Image(systemName: "arrow.counterclockwise.circle")
                                    .font(.system(size: 44))
                                    .foregroundStyle(cue.audioFilePath != nil ? Theme.Colors.warningAmber : Theme.Colors.textSecondary.opacity(0.4))
                            }
                            .disabled(cue.audioFilePath == nil || isRecording)
                        }

                        // Stepper Prev / Next
                        HStack {
                            Button {
                                if selectedIndex > 0 {
                                    autoAdvanceTask?.cancel()
                                    autoAdvanceTask = nil
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
                                    autoAdvanceTask?.cancel()
                                    autoAdvanceTask = nil
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
                        stopActiveRecordingIfNeeded()
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
                        stopActiveRecordingIfNeeded()
                        stopPlayback()
                        dismiss()
                    }
                }
            }
            .alert("Recording Error", isPresented: $showingErrorAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(recordingErrorMessage ?? "An unknown audio error occurred.")
            }
            .onDisappear {
                autoAdvanceTask?.cancel()
                autoAdvanceTask = nil
                stopActiveRecordingIfNeeded()
                stopPlayback()
                audioEngine.stopAuditionScenePartner()
            }
            .onAppear {
                if !cueLines.indices.contains(selectedIndex) {
                    selectedIndex = 0
                }
                audioEngine.requestRecordingPermission { granted in
                    hasMicrophonePermission = granted
                }
            }
        }
    }

    // MARK: - Audio Actions

    private func stopActiveRecordingIfNeeded() {
        recordTimer?.invalidate()
        recordTimer = nil
        if isRecording {
            let result = audioEngine.stopRecordingCue()
            isRecording = false
            if let tempURL = result.url {
                try? FileManager.default.removeItem(at: tempURL)
            }
        }
    }

    private func toggleRecording() {
        guard hasMicrophonePermission, cueLines.indices.contains(selectedIndex) else { return }
        autoAdvanceTask?.cancel()
        autoAdvanceTask = nil

        if isRecording {
            recordTimer?.invalidate()
            recordTimer = nil
            let result = audioEngine.stopRecordingCue()
            isRecording = false

            guard let tempURL = result.url else { return }
            guard cueLines.indices.contains(selectedIndex) else {
                try? FileManager.default.removeItem(at: tempURL)
                return
            }

            let cue = cueLines[selectedIndex]
            let relativePath = "CueAudio/\(audition.id)_\(cue.id).m4a"

            do {
                let storedPath = try MediaStorage.moveItem(from: tempURL, toRelativePath: relativePath)
                cueLines[selectedIndex].audioFilePath = storedPath
                cueLines[selectedIndex].durationSeconds = result.durationSeconds
                audition.cueLines = cueLines
                try? appState.modelContext?.save()

                let recordedIndex = selectedIndex
                if recordedIndex < cueLines.count - 1 {
                    autoAdvanceTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled,
                              selectedIndex == recordedIndex,
                              selectedIndex + 1 < cueLines.count else { return }
                        selectedIndex += 1
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at: tempURL)
                recordingErrorMessage = "Could not save cue audio: \(error.localizedDescription)"
                showingErrorAlert = true
            }
        } else {
            stopPlayback()
            do {
                _ = try audioEngine.startRecordingCue(orderIndex: selectedIndex)
                isRecording = true
                recordingDuration = 0.0
                recordTimer?.invalidate()
                recordTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                    Task { @MainActor in
                        recordingDuration += 0.1
                    }
                }
            } catch {
                recordingErrorMessage = "Could not start cue recording: \(error.localizedDescription)"
                showingErrorAlert = true
            }
        }
    }

    private func togglePlayback(for cue: CueLine) {
        if isPlaying {
            stopPlayback()
        } else if let url = MediaStorage.resolveURL(for: cue.audioFilePath),
                  FileManager.default.fileExists(atPath: url.path) {
            isPlaying = true
            audioEngine.playCue(at: url) {
                isPlaying = false
            }
        } else {
            recordingErrorMessage = "Cue audio file could not be found on disk."
            showingErrorAlert = true
        }
    }

    private func stopPlayback() {
        audioEngine.stopPlayback()
        isPlaying = false
    }

    private func deleteCurrentRecording() {
        guard cueLines.indices.contains(selectedIndex) else { return }
        stopPlayback()
        if let path = cueLines[selectedIndex].audioFilePath {
            MediaStorage.removeFile(at: path)
        }
        cueLines[selectedIndex].audioFilePath = nil
        cueLines[selectedIndex].durationSeconds = 0
        audition.cueLines = cueLines
        try? appState.modelContext?.save()
    }
}
