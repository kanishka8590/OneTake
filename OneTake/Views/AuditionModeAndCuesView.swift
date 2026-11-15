import SwiftUI
import PhotosUI
import AVFoundation
import SwiftData

struct ScriptDisplayLine: Identifiable {
    let id: Int
    let text: String
    let speaker: String
    let isAutoDetectedCue: Bool
    var isUserAddedCue: Bool = false
    var isUserRemovedCue: Bool = false

    var isCurrentlyActiveCue: Bool {
        if isAutoDetectedCue {
            return !isUserRemovedCue
        } else {
            return isUserAddedCue
        }
    }
}

struct AuditionModeAndCuesView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @Bindable var audition: Audition
    let onAuditionTakeSaved: () -> Void

    @State private var scriptLines: [ScriptDisplayLine] = []
    @State private var isDialogueDetected: Bool = false

    // Navigation and flow
    @State private var cueLines: [CueLine] = []
    @State private var showingCueRecorder = false
    @State private var showingBriefing = false
    @State private var showingTeleprompter = false

    private var hasScript: Bool {
        guard let script = audition.scriptText?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !script.isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.canvasBackground
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Title & Subtitle Header
                        headerSection

                        // Single Card with Thin Purple Border
                        scriptCardSection

                        Spacer(minLength: 28)

                        // Bottom CTA
                        Button {
                            handleContinue()
                        } label: {
                            Text(hasScript ? "Continue" : "Continue to Record")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Theme.Colors.primaryPlum)
                                .clipShape(Capsule())
                        }
                        .padding(.bottom, 24)
                    }
                    .padding(.horizontal, 20)
                }
            }
            .navigationTitle(hasScript ? "Add Cue Lines" : "Audition Take")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear {
                parseAndInitializeScript()
            }
            .sheet(isPresented: $showingCueRecorder) {
                CueRecorderView(
                    audition: audition,
                    cueLines: $cueLines
                ) {
                    // Sync binding back to audition model (cueLines already saved by CueRecorderView)
                    audition.cueLines = cueLines
                    try? appState.modelContext?.save()
                    showingCueRecorder = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        showingBriefing = true
                    }
                }
            }
            .sheet(isPresented: $showingBriefing) {
                TalkToOneTakeBriefingView(
                    audition: audition,
                    isSlate: false,
                    scriptPreview: teleprompterScriptLines.joined(separator: "\n")
                ) { _ in
                    showingBriefing = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        showingTeleprompter = true
                    }
                }
            }
            .fullScreenCover(isPresented: $showingTeleprompter) {
                TeleprompterRecorderView(
                    audition: audition,
                    modeTitle: "Audition Take",
                    scriptLines: teleprompterScriptLines,
                    isSlate: false
                ) { savedTake in
                    showingTeleprompter = false
                    audition.auditionTakes.append(savedTake)
                    audition.selectedAuditionTakeID = savedTake.id
                    for idx in audition.requirements.indices {
                        let lower = audition.requirements[idx].title.lowercased()
                        if lower.contains("audition") || lower.contains("self-tape") {
                            audition.requirements[idx].isCompleted = true
                        }
                    }
                    try? appState.modelContext?.save()
                    appState.loadData()
                    onAuditionTakeSaved()
                    dismiss()
                }
            }
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(hasScript ? "Add Cue Lines" : "Audition Take")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Theme.Colors.textPrimary)

            if !hasScript {
                Text("This audition has casting details only. Cue lines and teleprompter are hidden. You can continue directly to record your take.")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineSpacing(3)
            } else if isDialogueDetected {
                Text("Tap each scene partner line to mark it as a cue. Every unmarked line is treated as the actor's line.")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineSpacing(3)
            } else {
                Text("We couldn't find any cue lines. If another speaker says something, tap that line to make it a cue.")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineSpacing(3)
            }
        }
        .padding(.top, 12)
        .padding(.horizontal, 4)
    }

    // MARK: - Script Card with Thin Purple Border

    private var scriptCardSection: some View {
        Group {
            if !hasScript || scriptLines.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 32))
                        .foregroundStyle(Theme.Colors.primaryPlum.opacity(0.6))
                    Text("No Script Available")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Text("No sides or monologue were detected in this casting call. Recording will show a clean camera frame with quality checks and hands-free controls without cue lines or teleprompter.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .padding(.horizontal, 16)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Theme.Colors.primaryPlum.opacity(0.3), lineWidth: 1.5)
                )
                .shadow(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 2)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(scriptLines.indices, id: \.self) { index in
                        scriptLineRow(index: index)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Theme.Colors.primaryPlum.opacity(0.3), lineWidth: 1.5)
                )
                .shadow(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 2)
            }
        }
    }

    // MARK: - Script Line Row

    private func scriptLineRow(index: Int) -> some View {
        let line = scriptLines[index]
        let isActive = line.isCurrentlyActiveCue
        let isOriginalCue = line.isAutoDetectedCue

        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                if isOriginalCue {
                    scriptLines[index].isUserRemovedCue.toggle()
                } else {
                    scriptLines[index].isUserAddedCue.toggle()
                }
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                // Speaker Tag if dialogue detected
                if isDialogueDetected && !line.speaker.isEmpty {
                    Text(line.speaker.uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(isActive ? Color(red: 173/255, green: 20/255, blue: 87/255) : Theme.Colors.textSecondary)
                        .padding(.top, 2)
                        .frame(width: 58, alignment: .leading)
                }

                // Line Text
                Text(line.text)
                    .font(.system(size: 14, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // State Badge
                if isOriginalCue {
                    if isActive {
                        Text("CUE")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color(red: 173/255, green: 20/255, blue: 87/255))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.8))
                            .clipShape(Capsule())
                    } else {
                        Text("REMOVED")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.gray)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.gray.opacity(0.12))
                            .clipShape(Capsule())
                    }
                } else if isActive {
                    Text("ADDED")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(red: 173/255, green: 20/255, blue: 87/255))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.8))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                isActive
                    ? Color(red: 252/255, green: 228/255, blue: 236/255) // Soft rose/pink (#FCE4EC)
                    : Color.white
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Continue Handling

    private func handleContinue() {
        guard hasScript else {
            audition.cueLines = []
            showingBriefing = true
            return
        }

        let activeCues = scriptLines.filter { $0.isCurrentlyActiveCue }

        if !activeCues.isEmpty {
            // Every selected row is a reader cue; only the immediately preceding unselected
            // row is eligible to trigger it during the take.
            var generatedCues: [CueLine] = []

            for (index, item) in scriptLines.enumerated() {
                if item.isCurrentlyActiveCue {
                    let precedingActorLine: String
                    if index > 0, !scriptLines[index - 1].isCurrentlyActiveCue {
                        precedingActorLine = scriptLines[index - 1].text
                    } else {
                        precedingActorLine = ""
                    }
                    generatedCues.append(CueLine(
                        orderIndex: generatedCues.count,
                        speaker: item.speaker.isEmpty ? "READER" : item.speaker,
                        cueText: item.text,
                        precedingActorLine: precedingActorLine,
                        isAutoDetected: false
                    ))
                }
            }

            self.cueLines = generatedCues
            audition.cueLines = generatedCues
            showingCueRecorder = true
        } else {
            // 0 Cues Selected -> Direct to TalkToOneTakeBriefingView
            audition.cueLines = []
            showingBriefing = true
        }
    }

    // MARK: - Parsing Script

    private func parseAndInitializeScript() {
        guard hasScript, let script = audition.scriptText else {
            // Strictly empty when scriptText is empty — NO fallback to rawCastingCallText, casting call notes, or character descriptions
            self.scriptLines = []
            self.isDialogueDetected = false
            return
        }

        let rawText = script
        let rawParagraphs = rawText.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        var lines: [ScriptDisplayLine] = []
        var detectedSpeakers: Set<String> = []

        for (idx, p) in rawParagraphs.enumerated() {
            var speaker = ""
            var cleanText = p

            if let colonIndex = p.firstIndex(of: ":") {
                let candidateSpeaker = String(p[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                if candidateSpeaker.count <= 25 && !candidateSpeaker.contains(" ") {
                    speaker = candidateSpeaker
                    detectedSpeakers.insert(candidateSpeaker.uppercased())
                    cleanText = String(p[p.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                }
            }

            lines.append(ScriptDisplayLine(
                id: idx,
                text: cleanText.isEmpty ? p : cleanText,
                speaker: speaker,
                isAutoDetectedCue: false
            ))
        }

        self.isDialogueDetected = detectedSpeakers.count >= 2
        self.scriptLines = lines
    }

    private var teleprompterScriptLines: [String] {
        guard hasScript else {
            return []
        }
        return scriptLines.map { line in
            line.speaker.isEmpty ? line.text : "\(line.speaker): \(line.text)"
        }
    }
}
