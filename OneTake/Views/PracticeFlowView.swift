import SwiftUI
import AVFoundation

// MARK: - Script source and cue editor

struct PracticeASceneSheet: View {
    let appState: AppState
    @Binding var isPresented: Bool
    let onScriptReady: (PracticeScript) -> Void
    @State private var showingEntry = false
    @State private var entryTitle = ""
    @State private var entryText = ""
    @State private var showingCueSelection = false

    var body: some View {
        NavigationStack {
            List {
                Section("Practice a scene") {
                    sourceButton("Photos", icon: "photo.on.rectangle")
                    sourceButton("Scan pages", icon: "doc.viewfinder")
                    sourceButton("PDF or file", icon: "doc.badge.plus")
                    sourceButton("Type it in", icon: "keyboard")
                }
                Section("From an audition") {
                    if appState.auditions.filter({ !$0.scriptLines.isEmpty }).isEmpty { Text("No recent sides").foregroundStyle(Theme.Colors.textSecondary) }
                    ForEach(appState.auditions.filter { !$0.scriptLines.isEmpty }) { audition in
                        Button {
                            // Audition-side cues were already explicitly configured;
                            // do not run heuristic detection over them again.
                            let script = PracticeScript(title: "\(audition.projectName) — \(audition.roleName)", sourceAuditionID: audition.id, rawText: audition.scriptText ?? "", cueLines: audition.cueLines)
                            appState.addPracticeScript(script)
                            isPresented = false
                            onScriptReady(script)
                        } label: { Label(audition.projectName, systemImage: "film") }
                    }
                }
            }
            .navigationTitle("Practice a scene").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { isPresented = false } } }
            .sheet(isPresented: $showingEntry) { entrySheet }
            .sheet(isPresented: $showingCueSelection) { cueSelectionSheet }
        }
    }
    private func sourceButton(_ title: String, icon: String) -> some View {
        Button { entryTitle = title == "Type it in" ? "" : "New scene"; entryText = ""; showingEntry = true } label: { Label(title, systemImage: icon) }
    }
    private var entrySheet: some View {
        NavigationStack {
            Form { TextField("Scene title", text: $entryTitle); TextField("Paste or type script", text: $entryText, axis: .vertical).lineLimit(8...16) }
                .navigationTitle("Add practice script")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingEntry = false } }; ToolbarItem(placement: .confirmationAction) { Button("Continue") { showingEntry = false; showingCueSelection = true }.disabled(entryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } }
        }
    }
    private var cueSelectionSheet: some View {
        PracticeAuditionCueSelectionView(scriptText: entryText) { cues in
            let script = PracticeScript(title: entryTitle.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled scene" : entryTitle, rawText: entryText, cueLines: cues)
            appState.addPracticeScript(script)
            showingCueSelection = false; isPresented = false; onScriptReady(script)
        }
    }
}

/// The practice entry point intentionally reuses the Audition tab's script-card
/// selection treatment: the same speaker labels, pink selected rows, and cue
/// badges, but its Continue action stops before CueRecorderView.
struct PracticeAuditionCueSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    let scriptText: String
    let initialCues: [CueLine]
    let onContinue: ([CueLine]) -> Void
    @State private var scriptLines: [ScriptDisplayLine] = []
    @State private var isDialogueDetected = false

    init(scriptText: String, initialCues: [CueLine] = [], onContinue: @escaping ([CueLine]) -> Void) {
        self.scriptText = scriptText; self.initialCues = initialCues; self.onContinue = onContinue
    }
    var body: some View {
        NavigationStack {
            ZStack { Theme.Colors.canvasBackground.ignoresSafeArea(); ScrollView { VStack(alignment: .leading, spacing: 20) { header; scriptCard; Button("Continue") { onContinue(makeCues()); dismiss() }.primaryCapsuleButton().padding(.bottom, 24) }.padding(.horizontal, 20) } }
            .navigationTitle("Add Cue Lines").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear { parseAndInitializeScript() }
        }
    }
    private var header: some View { VStack(alignment: .leading, spacing: 6) { Text("Add Cue Lines").font(.system(size: 24, weight: .bold)); Text(isDialogueDetected ? "Tap each scene partner line to mark it as a cue. Every unmarked line is treated as the actor's line." : "Tap any line another speaker reads to make it a cue.").font(.system(size: 14)).foregroundStyle(Theme.Colors.textSecondary) }.padding(.top, 12).padding(.horizontal, 4) }
    private var scriptCard: some View { VStack(alignment: .leading, spacing: 10) { ForEach(scriptLines.indices, id: \.self) { index in lineRow(index) } }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.white).clipShape(RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.Colors.primaryPlum.opacity(0.3), lineWidth: 1.5)) }
    private func lineRow(_ index: Int) -> some View { let line = scriptLines[index]; let active = line.isCurrentlyActiveCue; let original = line.isAutoDetectedCue; return Button { withAnimation(.easeInOut(duration: 0.18)) { if original { scriptLines[index].isUserRemovedCue.toggle() } else { scriptLines[index].isUserAddedCue.toggle() } } } label: { HStack(alignment: .top, spacing: 10) { if isDialogueDetected && !line.speaker.isEmpty { Text(line.speaker.uppercased()).font(.system(size: 11, weight: .bold)).foregroundStyle(active ? Color(red: 173/255, green: 20/255, blue: 87/255) : Theme.Colors.textSecondary).padding(.top, 2).frame(width: 58, alignment: .leading) }; Text(line.text).font(.system(size: 14, weight: active ? .semibold : .regular)).foregroundStyle(Theme.Colors.textPrimary).lineSpacing(3).frame(maxWidth: .infinity, alignment: .leading); if active { Text(original ? "CUE" : "ADDED").font(.system(size: 10, weight: .bold)).foregroundStyle(Color(red: 173/255, green: 20/255, blue: 87/255)).padding(.horizontal, 7).padding(.vertical, 3).background(.white.opacity(0.8)).clipShape(Capsule()) } }.padding(.horizontal, 12).padding(.vertical, 10).background(active ? Color(red: 252/255, green: 228/255, blue: 236/255) : .white).clipShape(RoundedRectangle(cornerRadius: 12)).contentShape(Rectangle()) }.buttonStyle(.plain) }
    private func parseAndInitializeScript() { let paragraphs = scriptText.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }; var speakers: [String] = []; scriptLines = paragraphs.enumerated().map { index, paragraph in var speaker = ""; var text = paragraph; if let colon = paragraph.firstIndex(of: ":") { let candidate = String(paragraph[..<colon]).trimmingCharacters(in: .whitespaces); if candidate.count <= 25 && !candidate.contains(" ") { speaker = candidate; text = String(paragraph[paragraph.index(after: colon)...]).trimmingCharacters(in: .whitespaces); if !speakers.contains(candidate.uppercased()) { speakers.append(candidate.uppercased()) } } }; let existing = initialCues.contains { $0.cueText.trimmingCharacters(in: .whitespacesAndNewlines) == text.trimmingCharacters(in: .whitespacesAndNewlines) }; let autoCue = !existing && speakers.count > 1 && speaker.uppercased() != speakers.first; return ScriptDisplayLine(id: index, text: text.isEmpty ? paragraph : text, speaker: speaker, isAutoDetectedCue: existing || autoCue) }; isDialogueDetected = speakers.count >= 2 }
    private func makeCues() -> [CueLine] { var cues: [CueLine] = []; for (index, line) in scriptLines.enumerated() where line.isCurrentlyActiveCue { let previous = index > 0 && !scriptLines[index - 1].isCurrentlyActiveCue ? scriptLines[index - 1].text : ""; cues.append(CueLine(orderIndex: cues.count, speaker: line.speaker.isEmpty ? "READER" : line.speaker, cueText: line.text, precedingActorLine: previous, isAutoDetected: false)) }; return cues }
}

// MARK: - Script model and memorise levels

struct MemoriseView: View {
    let script: PracticeScript; let appState: AppState
    @State private var level = 1
    @State private var revealedTokens: Set<Int> = []
    @State private var test = false
    @State private var editCues = false
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("Level \(level) of 3 — \(level == 1 ? "READ" : level == 2 ? "RECALL" : "RECONSTRUCT")").font(Theme.Typography.sectionHeader).foregroundStyle(Theme.Colors.primaryPlum)
                ScriptPracticeCard(model: PracticeScriptModel(script: script), mode: level, revealedTokenIDs: $revealedTokens, clueTokenIDs: .constant([]), recordRevealAsClue: false, onClueTokenRequested: { _ in })
                Button { if level < 3 { level += 1 } else { test = true } } label: { Text(level < 3 ? "Continue" : "Test Yourself").primaryCapsuleButton() }
            }.padding(16)
        }
        .background(Theme.Colors.canvasBackground).navigationTitle(script.title).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Edit") { editCues = true } } }
        .navigationDestination(isPresented: $test) { TestYourselfView(script: script, appState: appState) }
        .sheet(isPresented: $editCues) {
            PracticeAuditionCueSelectionView(scriptText: script.rawText, initialCues: script.cueLines) { cues in
                script.cueLines = cues; appState.saveChanges(); editCues = false
            }
        }
    }
}

private struct ScriptPracticeCard: View {
    let model: PracticeScriptModel
    let mode: Int // 0 nothing, 1 full, 2 gaps, 3 letters
    @Binding var revealedTokenIDs: Set<Int>
    @Binding var clueTokenIDs: Set<Int>
    let recordRevealAsClue: Bool
    let onClueTokenRequested: (Int) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(model.lines) { line in
                if line.isHeader { Text(line.text).font(.system(size: 13, weight: .bold)).frame(maxWidth: .infinity).foregroundStyle(Theme.Colors.primaryPlum) }
                else if model.cueLineIDs.contains(line.id) { cueLine(line).id(line.id) }
                else if mode != 0 { actorLine(line).id(line.id) }
            }
        }.padding(18).cardStyle()
    }
    private func cueLine(_ line: PracticeLine) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text("CUE").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.Colors.primaryPlum)
            Text(line.text).font(Theme.Typography.bodyRegular).foregroundStyle(Theme.Colors.primaryPlum)
        }.padding(9).frame(maxWidth: .infinity, alignment: .leading).background(Theme.Colors.lavenderSurface).clipShape(RoundedRectangle(cornerRadius: 10))
    }
    private func actorLine(_ line: PracticeLine) -> some View {
        let tokens = model.tokens.filter { $0.lineID == line.id }
        return FlowLayout(spacing: 4) {
            ForEach(Array(tokens.enumerated()), id: \.element.id) { index, token in
                Button { reveal(token) } label: {
                    Text(display(token, position: index, count: tokens.count)).font(Theme.Typography.bodyRegular).fontWeight(revealedTokenIDs.contains(token.id) ? .bold : .regular).foregroundStyle(Theme.Colors.textPrimary)
                }.buttonStyle(.plain).accessibilityLabel(revealedTokenIDs.contains(token.id) || mode == 1 ? token.word : "Hidden word")
            }
        }
    }
    private func reveal(_ token: PracticeToken) { guard mode > 1 else { return }; revealedTokenIDs.insert(token.id); if recordRevealAsClue { clueTokenIDs.insert(token.id); onClueTokenRequested(token.id) } }
    private func display(_ token: PracticeToken, position: Int, count: Int) -> String {
        guard mode > 1, !revealedTokenIDs.contains(token.id) else { return token.word }
        if mode == 2, !shouldMask(position, count: count) { return token.word }
        let bare = token.word.trimmingCharacters(in: .punctuationCharacters)
        let punctuation = token.word.replacingOccurrences(of: bare, with: "")
        return mode == 2 ? String(repeating: "_", count: max(6, bare.count)) + punctuation : (bare.first.map { String($0) + punctuation } ?? token.word)
    }
    /// Four non-adjacent blanks per nine words keeps approximately 55% visible.
    private func shouldMask(_ index: Int, count: Int) -> Bool { guard index > 0 && index < count - 1 else { return false }; return [1, 3, 6, 8].contains(index % 9) }
}

// MARK: - Test and live delivery

struct TestYourselfView: View {
    let script: PracticeScript; let appState: AppState
    @State private var help = HelpLevel.nothing
    @State private var enteredRun = false
    var body: some View {
        Group {
            if enteredRun { SayItAloudView(script: script, appState: appState, help: help) }
            else { VStack(spacing: 22) { Text("Test Yourself!").font(Theme.Typography.screenTitle); Text("Choose how much help you want before you start.").foregroundStyle(Theme.Colors.textSecondary); Picker("Show", selection: $help) { ForEach(HelpLevel.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.inline); Button { enteredRun = true } label: { Text("Continue").primaryCapsuleButton() } }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.Colors.canvasBackground) }
        }.navigationTitle(enteredRun ? "Say It Aloud!" : "Test Yourself!").navigationBarTitleDisplayMode(.inline)
    }
}

struct SayItAloudView: View {
    let script: PracticeScript; let appState: AppState; let help: HelpLevel
    @State private var recorder = PracticeSpeechRecorder()
    @State private var clueTracker: PracticeSpeechClueTracker
    @State private var revealed: Set<Int> = []
    @State private var clueTokenIDs: Set<Int> = []
    @State private var didStart = false
    @State private var paused = false
    @State private var hintLineID: Int?
    @State private var reviewSession: PracticeSession?
    @State private var showReview = false
    private var model: PracticeScriptModel { clueTracker.model }
    private var mode: Int { help == .nothing ? 0 : help == .fullScript ? 1 : help == .gaps ? 2 : 3 }
    private var nextActorLine: PracticeLine? { clueTracker.nextSentence.flatMap { range in model.actorLines.first(where: { $0.id == range.lineID }) } }

    init(script: PracticeScript, appState: AppState, help: HelpLevel) {
        self.script = script
        self.appState = appState
        self.help = help
        _clueTracker = State(initialValue: PracticeSpeechClueTracker(script: script))
    }

    var body: some View {
        VStack(spacing: 14) {
            ScrollViewReader { proxy in
                ScrollView {
                    ScriptPracticeCard(model: model, mode: mode, revealedTokenIDs: $revealed, clueTokenIDs: $clueTokenIDs, recordRevealAsClue: didStart, onClueTokenRequested: requestClueForToken)
                        .padding(.horizontal, 2)
                }
                .scrollIndicators(.visible)
                .frame(maxHeight: .infinity)
                .onChange(of: clueTracker.currentActorLineIndex) { _, _ in if let id = nextActorLine?.id { withAnimation(.easeInOut(duration: 0.5)) { proxy.scrollTo(id, anchor: .center) } } }
            }
            Button { requestNextSentence() } label: { Label("Need a clue?", systemImage: "lightbulb.fill").secondaryLavenderButton() }
            if let hintLineID, let line = model.actorLines.first(where: { $0.id == hintLineID }) { Text("Next sentence: \"\(line.text)\"").font(.caption).foregroundStyle(Theme.Colors.primaryPlum).frame(maxWidth: .infinity, alignment: .leading) }
            ZStack { Circle().fill(Theme.Colors.primaryPlum.opacity(0.16)).frame(width: 148, height: 148); Circle().fill(Theme.Colors.primaryPlum.opacity(0.28)).frame(width: 112, height: 112); Button { toggleStart() } label: { Image(systemName: recorder.isRecording ? "mic.fill" : "mic.fill").font(.system(size: 42)).foregroundStyle(.white).frame(width: 82, height: 82).background(Theme.Colors.primaryPlum).clipShape(Circle()) }.accessibilityLabel(didStart ? "Recording microphone" : "Start recording") }
            WaveformBars(level: recorder.audioLevel).frame(height: 28)
            Text(recorder.transcript.isEmpty ? recorder.statusText : recorder.transcript).font(.caption).foregroundStyle(Theme.Colors.textSecondary).lineLimit(2)
            HStack { Button(didStart ? (paused ? "Resume" : "Pause") : "Start") { didStart ? togglePause() : toggleStart() }.secondaryLavenderButton(); Button("Stop") { stopAndReview() }.primaryCapsuleButton().disabled(!didStart) }
        }.padding(16).background(Theme.Colors.canvasBackground)
        .onChange(of: recorder.recognizedWords) { _, segments in clueTracker.processRecognizedSpeech(segments: segments) }
        .onDisappear { recorder.stop() }
        .navigationDestination(isPresented: $showReview) { if let reviewSession { PracticeReviewView(script: script, session: reviewSession, appState: appState) } }
    }
    private func toggleStart() { if !didStart { didStart = true; recorder.start(language: script.language, script: script) } else if paused { paused = false; recorder.resume() } }
    private func togglePause() { paused.toggle(); paused ? recorder.pause() : recorder.resume() }
    private func requestNextSentence() { guard let range = clueTracker.requestNextSentence() else { return }; hintLineID = range.lineID; clueTokenIDs.formUnion(range.tokenIDs) }
    private func requestClueForToken(_ tokenID: Int) { guard let range = clueTracker.requestClue(containingTokenID: tokenID) else { return }; clueTokenIDs.formUnion(range.tokenIDs) }
    private func stopAndReview() {
        recorder.stop()
        reviewSession = PracticeSpeechDeliveryAnalyzer.makeSession(script: script, transcript: recorder.transcript, words: recorder.recognizedWords, clueRequestedRanges: clueTracker.clueRequestedRanges, duration: recorder.duration, help: help, audioURL: recorder.recordedAudioURL)
        showReview = true
    }
}

private struct WaveformBars: View { let level: CGFloat; var body: some View { HStack(spacing: 4) { ForEach(0..<12, id: \.self) { index in RoundedRectangle(cornerRadius: 2).fill(Theme.Colors.primaryPlum).frame(width: 4, height: max(6, 8 + CGFloat((index % 4) + 1) * level * 22)) } }.animation(.easeInOut(duration: 0.15), value: level) } }

// MARK: - Review and playback

struct PracticeReviewView: View {
    let script: PracticeScript; let session: PracticeSession; let appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var playback = PracticeAudioPlayback()
    @State private var saveConfirmation = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Practice \(session.sessionNumber)").font(Theme.Typography.screenTitle)
                playbackPanel
                TimelineMarkers(session: session)
                Text("\(Int(session.durationSeconds))s total · Skipped \(session.skippedCount) · Forgot \(session.forgotCount) · Hesitated \(session.hesitatedCount)").font(.caption).foregroundStyle(Theme.Colors.textSecondary)
                ForEach(session.annotations) { annotation in Text(annotation.text).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(color(annotation.kind).opacity(0.14)).clipShape(RoundedRectangle(cornerRadius: 12)).overlay(alignment: .topTrailing) { Text(annotationLabel(annotation.kind)).font(.system(size: 9, weight: .bold)).foregroundStyle(color(annotation.kind)).padding(8) } }
                HStack { Button("Retry") { dismiss() }.secondaryLavenderButton(); Button("Save") { save() }.primaryCapsuleButton() }
            }.padding(16)
        }.background(Theme.Colors.canvasBackground).navigationTitle("Your delivery").navigationBarTitleDisplayMode(.inline)
        .onAppear { playback.load(url: session.audioFilePath.map(URL.init(fileURLWithPath:))) }
        .onDisappear { playback.stop() }
        .alert("Practice saved", isPresented: $saveConfirmation) { Button("Done") { dismiss() } }
    }
    private var playbackPanel: some View {
        VStack(spacing: 8) {
            HStack { Button { playback.toggle() } label: { Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").frame(width: 42, height: 42).background(Theme.Colors.lavenderSurface).clipShape(Circle()) }; Text(playback.available ? "Listen to your take" : "No audio recording available").font(Theme.Typography.bodyRegular); Spacer(); Text("\(Int(playback.currentTime))s").font(.caption).foregroundStyle(Theme.Colors.textSecondary) }
            Slider(value: Binding(get: { playback.currentTime }, set: { playback.seek($0) }), in: 0...max(1, playback.duration)).tint(Theme.Colors.primaryPlum).disabled(!playback.available)
        }.padding(14).cardStyle()
    }
    private func save() { if !script.sessions.contains(where: { $0.id == session.id }) { script.sessions.append(session); script.lastPracticedAt = .now; appState.saveChanges() }; saveConfirmation = true }
    private func color(_ kind: AnnotationKind) -> Color { switch kind { case .skipped: .orange; case .forgot: .red; case .hesitated: .purple; case .notInScript: .green; default: Theme.Colors.textSecondary } }
    private func annotationLabel(_ kind: AnnotationKind) -> String { kind == .notInScript ? "NOT IN THE SCRIPT" : kind.rawValue.uppercased() }
}

private struct TimelineMarkers: View { let session: PracticeSession; var body: some View { GeometryReader { proxy in ZStack(alignment: .leading) { Capsule().fill(Theme.Colors.lavenderSurface).frame(height: 10); HStack(spacing: 2) { ForEach(Array(session.annotations.enumerated()), id: \.offset) { _, annotation in Rectangle().fill(color(annotation.kind)).frame(width: max(5, proxy.size.width / CGFloat(max(1, session.annotations.count)) - 2), height: 10) } } } }.frame(height: 10).accessibilityLabel("Annotated delivery timeline") }; private func color(_ kind: AnnotationKind) -> Color { switch kind { case .skipped: .orange; case .forgot: .red; case .hesitated: .purple; case .notInScript: .green; default: .clear } } }

struct PracticeHistoryView: View { let scripts: [PracticeScript]; let appState: AppState; @Environment(\.dismiss) private var dismiss; var body: some View { NavigationStack { List { ForEach(scripts) { script in Section(script.title) { ForEach(script.sessions.sorted { $0.sessionNumber > $1.sessionNumber }) { session in NavigationLink("Practice \(session.sessionNumber) · \(session.date.formatted(date: .abbreviated, time: .omitted))") { PracticeReviewView(script: script, session: session, appState: appState) } } } } }.navigationTitle("Practice history").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } } } } }

@Observable private final class PracticeAudioPlayback: NSObject, AVAudioPlayerDelegate {
    var currentTime = 0.0; var duration = 0.0; var isPlaying = false; var available = false
    private var player: AVAudioPlayer?; private var timer: Timer?
    func load(url: URL?) { stop(); guard let url, let player = try? AVAudioPlayer(contentsOf: url) else { available = false; return }; self.player = player; player.delegate = self; duration = player.duration; available = true }
    func toggle() { guard let player else { return }; if player.isPlaying { player.pause(); isPlaying = false } else { player.play(); isPlaying = true; startTimer() } }
    func seek(_ time: Double) { player?.currentTime = time; currentTime = time }
    func stop() { player?.stop(); timer?.invalidate(); timer = nil; isPlaying = false; currentTime = 0 }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { stop() }
    private func startTimer() { timer?.invalidate(); timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.currentTime = self?.player?.currentTime ?? 0 } }
}

// MARK: - Analyzer and layout

private struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { let width = proposal.width ?? 300; var x: CGFloat = 0; var y: CGFloat = 0; var row: CGFloat = 0; for view in subviews { let size = view.sizeThatFits(.unspecified); if x + size.width > width { x = 0; y += row + spacing; row = 0 }; x += size.width + spacing; row = max(row, size.height) }; return CGSize(width: width, height: y + row) }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) { var x = bounds.minX; var y = bounds.minY; var row: CGFloat = 0; for view in subviews { let size = view.sizeThatFits(.unspecified); if x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }; view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size)); x += size.width + spacing; row = max(row, size.height) } }
}

#Preview { NavigationStack { MemoriseView(script: MockData.noahAndAllie, appState: MockData.sampleAppState) }.environment(MockData.sampleAppState) }
