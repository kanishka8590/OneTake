import SwiftUI
import PhotosUI
import AVFoundation
import SwiftData

private struct AuditionRecorderRoute: Identifiable {
    let id = UUID()
}

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
    @State private var shouldOpenBriefingAfterCueRecorder = false
    @State private var showingBriefing = false
    @State private var shouldOpenRecorderAfterBriefing = false
    @State private var auditionRecorderRoute: AuditionRecorderRoute?

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
                        headerSection
                        scriptCardSection
                    }
                    .padding(.horizontal, Theme.Layout.screenHPadding)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle(hasScript ? "Add Cue Lines" : "Audition Take")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") {
                        handleContinue()
                    }
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Colors.accent)
                    .accessibilityLabel(hasScript ? "Continue" : "Continue to Record")
                }
            }
            .onAppear {
                parseAndInitializeScript()
            }
            .sheet(isPresented: $showingCueRecorder, onDismiss: {
                guard shouldOpenBriefingAfterCueRecorder else { return }
                shouldOpenBriefingAfterCueRecorder = false
                showingBriefing = true
            }) {
                CueRecorderView(
                    audition: audition,
                    cueLines: $cueLines
                ) {
                    audition.cueLines = cueLines
                    appState.saveChanges()
                    shouldOpenBriefingAfterCueRecorder = true
                    showingCueRecorder = false
                }
            }
            .sheet(isPresented: $showingBriefing, onDismiss: {
                guard shouldOpenRecorderAfterBriefing else { return }
                shouldOpenRecorderAfterBriefing = false
                auditionRecorderRoute = AuditionRecorderRoute()
            }) {
                TalkToOneTakeBriefingView(
                    audition: audition,
                    isSlate: false,
                    scriptPreview: teleprompterScriptLines.joined(separator: "\n")
                ) { _ in
                    shouldOpenRecorderAfterBriefing = true
                    showingBriefing = false
                }
            }
            .fullScreenCover(item: $auditionRecorderRoute) { _ in
                TeleprompterRecorderView(
                    audition: audition,
                    modeTitle: "Audition Take",
                    scriptLines: teleprompterScriptLines,
                    isSlate: false
                ) { savedTake in
                    auditionRecorderRoute = nil
                    var normalizedTake = savedTake
                    normalizedTake.filePath = MediaStorage.storedRelativePath(for: savedTake.filePath)
                    audition.auditionTakes.append(normalizedTake)
                    audition.selectedAuditionTakeID = normalizedTake.id
                    for idx in audition.requirements.indices {
                        let lower = audition.requirements[idx].title.lowercased()
                        if lower.contains("audition") || lower.contains("self-tape") {
                            audition.requirements[idx].isCompleted = true
                        }
                    }
                    appState.saveChanges()
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
                .font(.title2.bold())
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

    // MARK: - Script Card

    private var scriptCardSection: some View {
        Group {
            if !hasScript || scriptLines.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 32))
                        .foregroundStyle(Theme.Colors.accent.opacity(0.75))
                    Text("No Script Available")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Text("No sides or monologue were detected in this casting call. Recording will show a clean camera frame with quality checks and hands-free controls without cue lines or teleprompter.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(20)
                .background(Theme.Colors.cardSurface)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 2)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(scriptLines.indices, id: \.self) { index in
                        scriptLineRow(index: index)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Colors.cardSurface)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
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
                if isDialogueDetected && !line.speaker.isEmpty {
                    Text(line.speaker.uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(isActive ? Theme.Colors.accent : Theme.Colors.textSecondary)
                        .padding(.top, 2)
                        .frame(minWidth: 58, maxWidth: 88, alignment: .leading)
                        .lineLimit(2)
                }

                Text(line.text)
                    .font(.system(size: 19, weight: isActive ? .semibold : .regular))
                    .italic(line.text.trimmingCharacters(in: .whitespaces).hasPrefix("("))
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isOriginalCue {
                    if isActive {
                        Text("CUE")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.Colors.accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Theme.Colors.accent.opacity(0.16))
                            .overlay(Capsule().stroke(Theme.Colors.accent.opacity(0.5), lineWidth: 1))
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
                        .foregroundStyle(Theme.Colors.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Theme.Colors.accent.opacity(0.16))
                        .overlay(Capsule().stroke(Theme.Colors.accent.opacity(0.5), lineWidth: 1))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                isActive
                    ? Theme.Colors.accent.opacity(0.12)
                    : Theme.Colors.cardSurface
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Continue Handling

    private func handleContinue() {
        let previousCues = audition.cueLines

        guard hasScript else {
            removeOrphanedCueAudio(previousCues: previousCues, keptCues: [])
            audition.cueLines = []
            appState.saveChanges()
            showingBriefing = true
            return
        }

        let activeCues = scriptLines.filter { $0.isCurrentlyActiveCue }

        if !activeCues.isEmpty {
            var remainingExisting = previousCues
            var generatedCues: [CueLine] = []

            for (index, item) in scriptLines.enumerated() where item.isCurrentlyActiveCue {
                let precedingActorLine: String
                if index > 0, !scriptLines[index - 1].isCurrentlyActiveCue {
                    precedingActorLine = scriptLines[index - 1].text
                } else {
                    precedingActorLine = ""
                }

                let resolvedSpeaker = item.speaker.isEmpty ? "READER" : item.speaker
                let matchedIndex = Self.findMatchingCueIndex(
                    in: remainingExisting,
                    speaker: resolvedSpeaker,
                    text: item.text
                )

                if let matchedIndex {
                    var preserved = remainingExisting.remove(at: matchedIndex)
                    preserved.orderIndex = generatedCues.count
                    preserved.speaker = resolvedSpeaker
                    preserved.cueText = item.text
                    preserved.precedingActorLine = precedingActorLine
                    preserved.isAutoDetected = item.isAutoDetectedCue || preserved.isAutoDetected
                    generatedCues.append(preserved)
                } else {
                    generatedCues.append(CueLine(
                        orderIndex: generatedCues.count,
                        speaker: resolvedSpeaker,
                        cueText: item.text,
                        precedingActorLine: precedingActorLine,
                        isAutoDetected: item.isAutoDetectedCue
                    ))
                }
            }

            removeOrphanedCueAudio(previousCues: previousCues, keptCues: generatedCues)
            self.cueLines = generatedCues
            audition.cueLines = generatedCues
            appState.saveChanges()
            showingCueRecorder = true
        } else {
            removeOrphanedCueAudio(previousCues: previousCues, keptCues: [])
            audition.cueLines = []
            appState.saveChanges()
            showingBriefing = true
        }
    }

    private func removeOrphanedCueAudio(previousCues: [CueLine], keptCues: [CueLine]) {
        let keptPaths = Set(keptCues.compactMap { cue -> String? in
            guard let path = cue.audioFilePath else { return nil }
            return MediaStorage.storedRelativePath(for: path)
        })
        for oldCue in previousCues {
            guard let path = oldCue.audioFilePath else { continue }
            let normalized = MediaStorage.storedRelativePath(for: path)
            if !keptPaths.contains(normalized) {
                MediaStorage.removeFile(at: path)
            }
        }
    }

    // MARK: - Parsing Script

    private func parseAndInitializeScript() {
        guard hasScript, let script = audition.scriptText else {
            self.scriptLines = []
            self.isDialogueDetected = false
            return
        }

        let result = Self.buildDisplayLines(
            from: script,
            roleName: audition.roleName,
            existingCueLines: audition.cueLines
        )
        self.isDialogueDetected = result.isDialogueDetected
        self.scriptLines = result.lines
    }

    /// Parses `"SPEAKER: line"`, `"SPEAKER:\ndialogue"`, multi-word character names (`"LADY MACBETH"`),
    /// and colonless screenplay format while reconciling saved `CueLine` selections.
    nonisolated static func buildDisplayLines(
        from script: String,
        roleName: String,
        existingCueLines: [CueLine]
    ) -> (lines: [ScriptDisplayLine], isDialogueDetected: Bool) {
        let parsedTurns = parseScriptTurns(from: script)
        guard !parsedTurns.isEmpty else { return ([], false) }

        var speakerCounts: [String: Int] = [:]
        for turn in parsedTurns where !turn.speaker.isEmpty {
            speakerCounts[turn.speaker.uppercased(), default: 0] += 1
        }
        let isDialogueDetected = speakerCounts.count >= 2

        let actorRole: String? = {
            guard isDialogueDetected else { return nil }
            let normalizedRole = roleName.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if !normalizedRole.isEmpty {
                if let exact = speakerCounts.keys.first(where: { $0 == normalizedRole }) {
                    return exact
                }
                if let partial = speakerCounts.keys.first(where: { $0.contains(normalizedRole) || normalizedRole.contains($0) }) {
                    return partial
                }
            }
            return speakerCounts.sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }.first?.key
        }()

        var remainingExisting = existingCueLines
        let hasExistingAutoCues = existingCueLines.contains(where: \.isAutoDetected)
        let hasExistingAnyCues = !existingCueLines.isEmpty

        let displayLines = parsedTurns.enumerated().map { idx, turn -> ScriptDisplayLine in
            let autoCandidate = isDialogueDetected
                && !turn.speaker.isEmpty
                && turn.speaker.uppercased() != actorRole

            if let matchIdx = findMatchingCueIndex(
                in: remainingExisting,
                speaker: turn.speaker,
                text: turn.text
            ) {
                let matched = remainingExisting.remove(at: matchIdx)
                let isAuto = matched.isAutoDetected || autoCandidate
                return ScriptDisplayLine(
                    id: idx,
                    text: turn.text,
                    speaker: turn.speaker,
                    isAutoDetectedCue: isAuto,
                    isUserAddedCue: !isAuto,
                    isUserRemovedCue: false
                )
            } else if autoCandidate {
                let wasPreviouslyRemoved = hasExistingAutoCues || hasExistingAnyCues
                return ScriptDisplayLine(
                    id: idx,
                    text: turn.text,
                    speaker: turn.speaker,
                    isAutoDetectedCue: true,
                    isUserAddedCue: false,
                    isUserRemovedCue: wasPreviouslyRemoved
                )
            } else {
                return ScriptDisplayLine(
                    id: idx,
                    text: turn.text,
                    speaker: turn.speaker,
                    isAutoDetectedCue: false
                )
            }
        }

        return (displayLines, isDialogueDetected)
    }

    private nonisolated static func findMatchingCueIndex(
        in cues: [CueLine],
        speaker: String,
        text: String
    ) -> Int? {
        let normText = normalizedLine(text)
        let normSpeaker = speaker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        if !normSpeaker.isEmpty,
           let exactIdx = cues.firstIndex(where: {
               $0.speaker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == normSpeaker
                   && normalizedLine($0.cueText) == normText
           }) {
            return exactIdx
        }
        return cues.firstIndex { normalizedLine($0.cueText) == normText }
    }

    private nonisolated static func normalizedLine(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
    }

    private nonisolated static func parseScriptTurns(from script: String) -> [(speaker: String, text: String)] {
        let rawLines = script
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        let colonRegex = try? NSRegularExpression(
            pattern: #"^([A-Z0-9][A-Z0-9\s.'#-]{1,29}?)(?:\s*\([^)]*\))?\s*:(.*)$"#,
            options: []
        )

        var turns: [(speaker: String, text: String)] = []
        var activeSpeaker: String?
        var activeLines: [String] = []

        func flushActive() {
            let joined = activeLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                turns.append((speaker: activeSpeaker ?? "", text: joined))
            }
            activeSpeaker = nil
            activeLines = []
        }

        for index in rawLines.indices {
            let line = rawLines[index]
            if line.isEmpty {
                if !activeLines.isEmpty {
                    flushActive()
                }
                continue
            }

            // 1. Colon format: "SPEAKER: dialogue" or "SPEAKER:\ndialogue"
            let nsRange = NSRange(line.startIndex..., in: line)
            if let match = colonRegex?.firstMatch(in: line, range: nsRange),
               let speakerRange = Range(match.range(at: 1), in: line),
               let bodyRange = Range(match.range(at: 2), in: line) {
                let candidateSpeaker = String(line[speakerRange]).trimmingCharacters(in: .whitespaces).uppercased()
                let wordCount = candidateSpeaker.split(whereSeparator: \.isWhitespace).count
                if wordCount <= 4 {
                    flushActive()
                    activeSpeaker = candidateSpeaker
                    let initialBody = String(line[bodyRange]).trimmingCharacters(in: .whitespaces)
                    if !initialBody.isEmpty {
                        activeLines.append(initialBody)
                    }
                    continue
                }
            }

            // 2. Screenplay format without colons: "LADY MACBETH\nOut, damned spot!"
            if let screenplaySpeaker = detectColonlessSpeaker(at: index, in: rawLines) {
                flushActive()
                activeSpeaker = screenplaySpeaker
                continue
            }

            // 3. Skip standalone parenthetical between speaker header and dialogue
            if activeSpeaker != nil && activeLines.isEmpty && line.hasPrefix("(") && line.hasSuffix(")") {
                continue
            }

            if activeSpeaker != nil {
                activeLines.append(line)
            } else {
                turns.append((speaker: "", text: line))
            }
        }

        flushActive()
        return turns
    }

    private nonisolated static func detectColonlessSpeaker(at index: Int, in lines: [String]) -> String? {
        let trimmed = lines[index]
        let clean = trimmed.replacingOccurrences(
            of: #"\s*\((?:V\.O\.|O\.S\.|O\.C\.|CONT'D|CONTD|FILTERED|OFF)\)\s*$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        ).trimmingCharacters(in: .whitespaces)

        guard (2...30).contains(clean.count),
              !clean.contains(":"),
              !clean.hasPrefix("INT."),
              !clean.hasPrefix("EXT."),
              !clean.hasPrefix("INT/EXT"),
              !clean.hasSuffix("?"),
              !clean.hasSuffix("!"),
              !clean.hasSuffix("."),
              clean.rangeOfCharacter(from: .lowercaseLetters) == nil,
              clean.rangeOfCharacter(from: .letters) != nil else {
            return nil
        }

        let words = clean.split(whereSeparator: \.isWhitespace)
        guard (1...4).contains(words.count) else { return nil }

        // Must be followed before a blank line by dialogue (optionally after a parenthetical)
        var lookahead = index + 1
        while lookahead < lines.count {
            let next = lines[lookahead]
            if next.isEmpty { return nil }
            if next.hasPrefix("(") && next.hasSuffix(")") {
                lookahead += 1
                continue
            }
            if next.contains(":") { return nil }
            return clean.uppercased()
        }
        return nil
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
