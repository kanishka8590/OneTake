import SwiftUI
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers
import UIKit

// MARK: - Script source and cue editor

func autoDetectCueLines(from scriptText: String) -> [CueLine] {
    let parsedLines = PracticeScriptModel.parse(scriptText)
    let dialogueLines = parsedLines.filter { !$0.isHeader && !$0.text.isEmpty }
    var speakers: [String] = []
    for line in dialogueLines {
        let normalized = line.speaker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !normalized.isEmpty && normalized != "SCRIPT" && !speakers.contains(normalized) {
            speakers.append(normalized)
        }
    }
    guard speakers.count >= 2 else { return [] }
    let primarySpeaker = speakers.first
    var cues: [CueLine] = []
    for (index, line) in dialogueLines.enumerated() {
        let speaker = line.speaker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !speaker.isEmpty && speaker != "SCRIPT" && speaker != primarySpeaker {
            let previous = index > 0 && dialogueLines[index - 1].speaker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == primarySpeaker ? dialogueLines[index - 1].text : ""
            cues.append(CueLine(
                orderIndex: cues.count,
                speaker: line.speaker.isEmpty ? "READER" : line.speaker,
                cueText: line.text,
                precedingActorLine: previous,
                isAutoDetected: true
            ))
        }
    }
    return cues
}

struct PracticeASceneSheet: View {
    let appState: AppState
    @Binding var isPresented: Bool
    let onScriptReady: (PracticeScript) -> Void

    @State private var sceneTitle = ""
    @State private var dialogueText = ""
    @State private var language: ScriptLanguage = .english
    @State private var autoDetectCues = true
    @State private var customCues: [CueLine]? = nil
    @State private var showingCueCustomizer = false

    @State private var showingPhotoPicker = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showingDocumentScanner = false
    @State private var pendingScannedImages: [UIImage] = []
    @State private var showingFileImporter = false

    @State private var isImporting = false
    @State private var importingSourceTitle = ""
    @State private var importErrorMessage: String?
    @State private var showingImportError = false

    private var detectedCuesCount: Int {
        if let custom = customCues {
            return custom.count
        }
        if autoDetectCues {
            return autoDetectCueLines(from: dialogueText).count
        }
        return 0
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.canvasBackground
                    .ignoresSafeArea()

                Form {
                    Section {
                        TextField("Scene Title, e.g. Succession S2E10", text: $sceneTitle)
                            .font(.system(size: 16))

                        Picker("Language", selection: $language) {
                            ForEach(ScriptLanguage.allCases, id: \.self) { lang in
                                Text(lang.rawValue).tag(lang)
                            }
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        Text("Scene Details")
                    }

                    Section {
                        HStack(spacing: 8) {
                            quickImportButton(title: "Photos", icon: "photo.on.rectangle") {
                                showingPhotoPicker = true
                            }
                            quickImportButton(title: "Scan", icon: "doc.viewfinder") {
                                showingDocumentScanner = true
                            }
                            quickImportButton(title: "File", icon: "doc.badge.plus") {
                                showingFileImporter = true
                            }
                            quickImportButton(title: "Paste", icon: "doc.on.clipboard") {
                                pasteFromClipboard()
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 14, trailing: 8))
                        .listRowBackground(Color.clear)

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Script Dialogue")
                                    .font(Theme.Typography.captionBadge)
                                    .foregroundStyle(Theme.Colors.textSecondary)

                                Spacer()

                                if !dialogueText.isEmpty {
                                    Text("\(dialogueText.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count) lines")
                                        .font(Theme.Typography.captionBadge)
                                        .foregroundStyle(Theme.Colors.textSecondary)

                                    Button("Clear") {
                                        dialogueText = ""
                                        customCues = nil
                                    }
                                    .font(Theme.Typography.captionBadge)
                                    .foregroundStyle(Theme.Colors.accent)
                                    .padding(.leading, 4)
                                }
                            }

                            TextEditor(text: $dialogueText)
                                .frame(minHeight: 160, maxHeight: 220)
                                .overlay(alignment: .topLeading) {
                                    if dialogueText.isEmpty {
                                        Text("Paste or type dialogue here…\n\nLOGAN\nYou have to be a killer.\n\nKENDALL\nI'm not a killer.")
                                            .font(.system(size: 15))
                                            .foregroundStyle(Theme.Colors.textSecondary.opacity(0.6))
                                            .padding(6)
                                            .allowsHitTesting(false)
                                    }
                                }
                        }
                    } header: {
                        Text("Script & Import")
                    } footer: {
                        Text("Include character names in ALL CAPS before dialogue lines to enable automatic cue detection.")
                            .font(Theme.Typography.captionBadge)
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }

                    Section {
                        Toggle("Auto-detect Scene Partner Cues", isOn: $autoDetectCues)
                            .tint(Theme.Colors.accent)
                            .onChange(of: autoDetectCues) { _, _ in
                                customCues = nil
                            }

                        if autoDetectCues || customCues != nil {
                            HStack {
                                Image(systemName: "person.2.wave.2")
                                    .foregroundStyle(Theme.Colors.accent)
                                Text(customCues != nil ? "\(customCues!.count) customized cues" : "\(detectedCuesCount) partner cues detected")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Theme.Colors.textSecondary)

                                Spacer()

                                Button("Customize") {
                                    showingCueCustomizer = true
                                }
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.Colors.accent)
                                .disabled(dialogueText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                    } header: {
                        Text("Scene Partner Cues")
                    }

                    let auditionsWithSides = appState.auditions.filter { !$0.scriptLines.isEmpty }
                    if !auditionsWithSides.isEmpty {
                        Section("From an Audition") {
                            ForEach(auditionsWithSides) { audition in
                                Button {
                                    sceneTitle = "\(audition.projectName) — \(audition.roleName)"
                                    dialogueText = audition.scriptText ?? ""
                                    customCues = audition.cueLines
                                } label: {
                                    HStack {
                                        Image(systemName: "film")
                                            .foregroundStyle(Theme.Colors.accent)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(audition.projectName)
                                                .font(.system(size: 15, weight: .semibold))
                                                .foregroundStyle(Theme.Colors.textPrimary)
                                            Text("Role: \(audition.roleName)")
                                                .font(.system(size: 13))
                                                .foregroundStyle(Theme.Colors.textSecondary)
                                        }
                                        Spacer()
                                        Image(systemName: "arrow.down.doc")
                                            .font(.system(size: 13))
                                            .foregroundStyle(Theme.Colors.textSecondary)
                                    }
                                }
                            }
                        }
                    }
                }

                if isImporting {
                    ZStack {
                        Color.black.opacity(0.25).ignoresSafeArea()
                        VStack(spacing: 12) {
                            ProgressView().controlSize(.large).tint(Theme.Colors.accent)
                            Text("Extracting Script…")
                                .font(Theme.Typography.sectionHeader)
                                .foregroundStyle(Theme.Colors.textPrimary)
                            Text(importingSourceTitle)
                                .font(Theme.Typography.captionBadge)
                                .foregroundStyle(Theme.Colors.textSecondary)
                                .lineLimit(1)
                        }
                        .padding(24)
                        .background(Theme.Colors.cardSurface, in: RoundedRectangle(cornerRadius: 20))
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .scrollEdgeHaptics()
            .navigationTitle("Add Scene")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveScene()
                    }
                    .fontWeight(.bold)
                    .disabled(dialogueText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .photosPicker(
                isPresented: $showingPhotoPicker,
                selection: $selectedPhotoItems,
                maxSelectionCount: 10,
                matching: .images
            )
            .onChange(of: selectedPhotoItems) { _, newItems in
                guard !newItems.isEmpty else { return }
                let items = newItems
                selectedPhotoItems = []
                loadSelectedPhotos(items)
            }
            .sheet(isPresented: $showingDocumentScanner, onDismiss: processPendingScannedImages) {
                DocumentScannerRepresentable { scannedImages in
                    pendingScannedImages = scannedImages
                    showingDocumentScanner = false
                } onCancel: {
                    pendingScannedImages = []
                    showingDocumentScanner = false
                } onError: { error in
                    pendingScannedImages = []
                    showingDocumentScanner = false
                    presentImportError(error.localizedDescription)
                }
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.pdf, .plainText, .data],
                allowsMultipleSelection: true
            ) { result in
                handleFileImport(result)
            }
            .sheet(isPresented: $showingCueCustomizer) {
                let initial = customCues ?? (autoDetectCues ? autoDetectCueLines(from: dialogueText) : [])
                PracticeAuditionCueSelectionView(
                    scriptText: dialogueText,
                    initialCues: initial
                ) { cues in
                    customCues = cues
                    showingCueCustomizer = false
                }
            }
            .alert("Import Failed", isPresented: $showingImportError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importErrorMessage ?? "Unable to extract script text from the selected source.")
            }
        }
    }

    private func quickImportButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.Colors.accent)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Colors.textPrimary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Theme.Colors.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.Colors.controlBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func pasteFromClipboard() {
        if let text = UIPasteboard.general.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            dialogueText = text
            customCues = nil
            if sceneTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let firstLine = text.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first(where: { !$0.isEmpty }) ?? ""
                if firstLine.count <= 36 && !firstLine.isEmpty {
                    sceneTitle = firstLine
                } else {
                    sceneTitle = "Pasted Scene"
                }
            }
        }
    }

    private func saveScene() {
        let trimmedTitle = sceneTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmedTitle.isEmpty ? "Untitled Scene" : trimmedTitle
        let text = dialogueText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let finalCues: [CueLine]
        if let custom = customCues {
            finalCues = custom
        } else if autoDetectCues {
            finalCues = autoDetectCueLines(from: text)
        } else {
            finalCues = []
        }

        let script = PracticeScript(
            title: title,
            languageRaw: language.rawValue,
            rawText: text,
            cueLines: finalCues
        )
        appState.addPracticeScript(script)
        isPresented = false
        onScriptReady(script)
    }

    private func loadSelectedPhotos(_ items: [PhotosPickerItem]) {
        Task {
            await MainActor.run {
                importingSourceTitle = items.count > 1 ? "\(items.count) Photos" : "Photo"
                isImporting = true
            }
            do {
                var images: [UIImage] = []
                for item in items {
                    if let data = try await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        images.append(image)
                    }
                }
                guard !images.isEmpty else {
                    await MainActor.run {
                        isImporting = false
                        presentImportError("Could not load any images from the selected photos.")
                    }
                    return
                }
                let parsed = try await CastingCallParserService.shared.parseImages(images)
                await MainActor.run {
                    finishImport(with: parsed, fallbackTitle: "Photo Scene")
                }
            } catch {
                await MainActor.run {
                    isImporting = false
                    presentImportError(error.localizedDescription)
                }
            }
        }
    }

    private func processPendingScannedImages() {
        let images = pendingScannedImages
        pendingScannedImages = []
        guard !images.isEmpty else { return }
        Task {
            await MainActor.run {
                importingSourceTitle = images.count > 1 ? "\(images.count) Scanned Pages" : "Scanned Page"
                isImporting = true
            }
            do {
                let parsed = try await CastingCallParserService.shared.parseImages(images)
                await MainActor.run {
                    finishImport(with: parsed, fallbackTitle: "Scanned Scene")
                }
            } catch {
                await MainActor.run {
                    isImporting = false
                    presentImportError(error.localizedDescription)
                }
            }
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }
            let fallbackTitle = urls.first?.deletingPathExtension().lastPathComponent ?? "Imported Scene"
            importingSourceTitle = urls.count > 1 ? "\(urls.count) Files" : (urls.first?.lastPathComponent ?? "File")
            isImporting = true

            Task {
                do {
                    let parsed = try await CastingCallParserService.shared.parseMultipleFiles(urls: urls)
                    await MainActor.run {
                        finishImport(with: parsed, fallbackTitle: fallbackTitle)
                    }
                } catch {
                    await MainActor.run {
                        isImporting = false
                        presentImportError(error.localizedDescription)
                    }
                }
            }
        case .failure(let error):
            presentImportError(error.localizedDescription)
        }
    }

    @MainActor
    private func finishImport(with parsed: ParsedCastingCall, fallbackTitle: String) {
        isImporting = false
        let extracted = (parsed.detectedScriptText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? (parsed.detectedScriptText ?? "")
            : parsed.rawExtractedText
        let trimmed = extracted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            presentImportError("No readable script text was detected.")
            return
        }
        let suggestedTitle = parsed.projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        sceneTitle = (!suggestedTitle.isEmpty && suggestedTitle != "Untitled Audition") ? suggestedTitle : fallbackTitle
        dialogueText = trimmed
        customCues = nil
    }

    @MainActor
    private func presentImportError(_ message: String) {
        importErrorMessage = message
        showingImportError = true
    }
}

/// The practice entry point intentionally reuses the Audition tab's script-card
/// selection treatment: the same speaker labels, purple selected rows, and cue
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
            ZStack { Theme.Colors.canvasBackground.ignoresSafeArea(); ScrollView { VStack(alignment: .leading, spacing: 20) { header; scriptCard }.padding(.horizontal, 20).padding(.bottom, 24) }.scrollEdgeHaptics() }
            .navigationTitle("Add Cue Lines").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .floatingBottomActionBar {
                Button {
                    onContinue(makeCues())
                    dismiss()
                } label: {
                    Text("Continue").primaryCapsuleButton()
                }
                .buttonStyle(.plain)
            }
            .onAppear { parseAndInitializeScript() }
        }
    }
    private var header: some View { VStack(alignment: .leading, spacing: 6) { Text("Add Cue Lines").font(.system(size: 24, weight: .bold)); Text(isDialogueDetected ? "Tap each scene partner line to mark it as a cue. Every unmarked line is treated as the actor's line." : "Tap any line another speaker reads to make it a cue.").font(.system(size: 14)).foregroundStyle(Theme.Colors.textSecondary) }.padding(.top, 12).padding(.horizontal, 4) }
    private var scriptCard: some View { VStack(alignment: .leading, spacing: 10) { ForEach(scriptLines.indices, id: \.self) { index in lineRow(index) } }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Theme.Colors.surfaceElevated).clipShape(RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.Colors.accent.opacity(0.42), lineWidth: 1.5)) }
    private func lineRow(_ index: Int) -> some View {
        let line = scriptLines[index]
        let active = line.isCurrentlyActiveCue
        let original = line.isAutoDetectedCue
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                if original { scriptLines[index].isUserRemovedCue.toggle() }
                else { scriptLines[index].isUserAddedCue.toggle() }
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                if isDialogueDetected && !line.speaker.isEmpty {
                    Text(line.speaker.uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(active ? Theme.Colors.accent : Theme.Colors.textSecondary)
                        .frame(width: 58, alignment: .leading)
                }
                Text(line.text)
                    .font(.system(size: 19, weight: active ? .semibold : .regular))
                    .italic(line.text.trimmingCharacters(in: .whitespaces).hasPrefix("("))
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineSpacing(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if active {
                    Text(original ? "CUE" : "ADDED")
                        .studioPill(Theme.Colors.accent)
                }
            }
            .padding(14)
            .background(active ? Theme.Colors.accent.opacity(0.16) : Theme.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    private func parseAndInitializeScript() {
        let parsedLines = PracticeScriptModel.parse(scriptText)
        let dialogueLines = parsedLines.filter { !$0.isHeader && !$0.text.isEmpty }
        var speakers: [String] = []
        for line in dialogueLines {
            let normalized = line.speaker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if !normalized.isEmpty && normalized != "SCRIPT" && !speakers.contains(normalized) {
                speakers.append(normalized)
            }
        }
        isDialogueDetected = speakers.count >= 2
        let shouldAutoDetect = initialCues.isEmpty && isDialogueDetected

        scriptLines = dialogueLines.enumerated().map { index, line in
            let speakerLabel = line.speaker == "SCRIPT" ? "" : line.speaker
            let existing = initialCues.contains {
                $0.cueText.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(line.text.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
            }
            let autoCue = shouldAutoDetect && !speakerLabel.isEmpty && speakerLabel.uppercased() != speakers.first
            return ScriptDisplayLine(
                id: index,
                text: line.text,
                speaker: speakerLabel,
                isAutoDetectedCue: existing || autoCue
            )
        }
    }

    private func makeCues() -> [CueLine] {
        var cues: [CueLine] = []
        for (index, line) in scriptLines.enumerated() where line.isCurrentlyActiveCue {
            let previous = index > 0 && !scriptLines[index - 1].isCurrentlyActiveCue ? scriptLines[index - 1].text : ""
            cues.append(CueLine(
                orderIndex: cues.count,
                speaker: line.speaker.isEmpty ? "READER" : line.speaker,
                cueText: line.text,
                precedingActorLine: previous,
                isAutoDetected: false
            ))
        }
        return cues
    }
}

// MARK: - Script model and memorise levels

private struct CueSpeakButton: View {
    let isSpeaking: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: isSpeaking ? "stop.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text(isSpeaking ? "Stop" : "Read Cue")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(isSpeaking ? .white : Theme.Colors.accent)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(isSpeaking ? Theme.Colors.primaryPlum : Theme.Colors.lavenderSurface)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct MemoriseView: View {
    let script: PracticeScript
    let appState: AppState

    @State private var selectedMode: PracticeDisplayMode = ProcessInfo.processInfo.arguments.contains("-PracticeModeHidden") ? .hideLines : (ProcessInfo.processInfo.arguments.contains("-PracticeModeLetters") ? .firstLetters : .full)
    @State private var revealedTokens: Set<Int> = []
    @State private var revealedLineIDs: Set<Int> = []
    @State private var editCues = false
    @State private var navigateToSayItAloud = false
    @State private var cueSpeaker = PracticeCueSpeaker()

    private var scriptModel: PracticeScriptModel {
        PracticeScriptModel(script: script)
    }

    private var modeInt: Int {
        switch selectedMode {
        case .full: return 1
        case .gaps: return 2
        case .firstLetters: return 3
        case .hideLines: return 0
        }
    }

    private var hasReveals: Bool {
        !revealedTokens.isEmpty || !revealedLineIDs.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top Mode Selector Bar
            VStack(spacing: 10) {
                Picker("Practice Mode", selection: $selectedMode) {
                    ForEach(PracticeDisplayMode.allCases) { mode in
                        Text(mode.shortTitle).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: selectedMode) { _, _ in
                    Haptics.selectionTick()
                }

                // Instruction & Hint Reset
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: selectedMode == .hideLines || selectedMode == .gaps || selectedMode == .firstLetters ? "hand.tap" : "book")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Colors.accent)

                    Text(selectedMode.instruction)
                        .font(Theme.Typography.captionBadge)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .lineLimit(2)

                    Spacer(minLength: 4)

                    if hasReveals {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                revealedTokens.removeAll()
                                revealedLineIDs.removeAll()
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 10, weight: .bold))
                                Text("Reset")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundStyle(Theme.Colors.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Theme.Colors.lavenderSurface, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .background(Theme.Colors.cardSurface)
            .overlay(Divider(), alignment: .bottom)

            // Scrollable Script Practice Card
            ScrollView {
                VStack(spacing: 16) {
                    ScriptPracticeCard(
                        model: scriptModel,
                        mode: modeInt,
                        revealedTokenIDs: $revealedTokens,
                        revealedLineIDs: $revealedLineIDs,
                        clueTokenIDs: .constant([]),
                        allowLinePeek: true,
                        recordRevealAsClue: false,
                        speakingCueLineID: cueSpeaker.activeCueLineID,
                        onReadCue: { line in
                            toggleMemoriseCueSpeech(for: line)
                        },
                        onClueTokenRequested: { _ in },
                        scriptCues: script.cueLines
                    )
                }
                .padding(16)
                .padding(.bottom, 12)
            }
            .scrollEdgeHaptics()
        }
        .floatingBottomActionBar(horizontalPadding: 16) {
            Button {
                cueSpeaker.stop()
                navigateToSayItAloud = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.system(size: 16, weight: .bold))
                    Text("Practice Aloud")
                        .font(.system(size: 16, weight: .bold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.Colors.primaryPlum)
                .foregroundStyle(.white)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .background(Theme.Colors.canvasBackground)
        .onDisappear {
            cueSpeaker.stop()
        }
        .navigationTitle(script.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        editCues = true
                    } label: {
                        Label("Customize Cues", systemImage: "pencil.line")
                    }

                    if hasReveals {
                        Button {
                            withAnimation {
                                revealedTokens.removeAll()
                                revealedLineIDs.removeAll()
                            }
                        } label: {
                            Label("Reset Hints", systemImage: "arrow.counterclockwise")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.Colors.accent)
                }
            }
        }
        .navigationDestination(isPresented: $navigateToSayItAloud) {
            SayItAloudView(script: script, appState: appState, help: selectedMode.helpLevel)
        }
        .sheet(isPresented: $editCues) {
            PracticeAuditionCueSelectionView(scriptText: script.rawText, initialCues: script.cueLines) { cues in
                script.cueLines = cues
                appState.saveChanges()
                editCues = false
            }
        }
    }

    private func toggleMemoriseCueSpeech(for line: PracticeLine) {
        if cueSpeaker.isSpeaking && cueSpeaker.activeCueLineID == line.id {
            cueSpeaker.stop()
        } else {
            cueSpeaker.speak(text: line.text, lineID: line.id, scriptLanguage: script.language)
        }
    }
}

private struct ScriptPracticeCard: View {
    let model: PracticeScriptModel
    let mode: Int // 0 nothing/hidden, 1 full, 2 gaps, 3 letters
    @Binding var revealedTokenIDs: Set<Int>
    @Binding var revealedLineIDs: Set<Int>
    @Binding var clueTokenIDs: Set<Int>
    var allowLinePeek: Bool = false
    var activeLineID: Int? = nil
    let recordRevealAsClue: Bool
    var speakingCueLineID: Int? = nil
    var onReadCue: ((PracticeLine) -> Void)? = nil
    var onLinePeeked: ((Int) -> Void)? = nil
    let onClueTokenRequested: (Int) -> Void
    var scriptCues: [CueLine] = []

    init(
        model: PracticeScriptModel,
        mode: Int,
        revealedTokenIDs: Binding<Set<Int>>,
        revealedLineIDs: Binding<Set<Int>> = .constant([]),
        clueTokenIDs: Binding<Set<Int>>,
        allowLinePeek: Bool = false,
        activeLineID: Int? = nil,
        recordRevealAsClue: Bool,
        speakingCueLineID: Int? = nil,
        onReadCue: ((PracticeLine) -> Void)? = nil,
        onLinePeeked: ((Int) -> Void)? = nil,
        onClueTokenRequested: @escaping (Int) -> Void,
        scriptCues: [CueLine] = []
    ) {
        self.model = model
        self.mode = mode
        self._revealedTokenIDs = revealedTokenIDs
        self._revealedLineIDs = revealedLineIDs
        self._clueTokenIDs = clueTokenIDs
        self.allowLinePeek = allowLinePeek
        self.activeLineID = activeLineID
        self.recordRevealAsClue = recordRevealAsClue
        self.speakingCueLineID = speakingCueLineID
        self.onReadCue = onReadCue
        self.onLinePeeked = onLinePeeked
        self.onClueTokenRequested = onClueTokenRequested
        self.scriptCues = scriptCues
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(model.lines.enumerated()), id: \.element.id) { index, line in
                if line.isHeader {
                    if !isRedundantSpeakerHeader(at: index, line: line) {
                        Text(line.text)
                            .font(.system(size: 13, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(Theme.Colors.accent)
                            .padding(.vertical, 6)
                    }
                } else if line.isCue || model.cueLineIDs.contains(line.id) {
                    // Cue lines are always visible: they are the actor's prompt
                    cueLine(line)
                        .id(line.id)
                } else if mode != 0 {
                    actorLineBlock(line)
                        .id(line.id)
                } else if allowLinePeek {
                    hiddenActorLine(line)
                        .id(line.id)
                } else {
                    // Keep a zero-height anchor so .nothing mode still auto-scrolls past cue lines in SayItAloudView.
                    Color.clear
                        .frame(height: 0)
                        .id(line.id)
                }
            }
        }
        .padding(18)
        .cardStyle()
    }

    private func isRedundantSpeakerHeader(at index: Int, line: PracticeLine) -> Bool {
        let nextNonHeader = model.lines.dropFirst(index + 1).first(where: { !$0.isHeader })
        guard let nextLine = nextNonHeader else { return true }
        return !line.speaker.isEmpty && nextLine.speaker.caseInsensitiveCompare(line.speaker) == .orderedSame
    }

    private func cueLine(_ line: PracticeLine) -> some View {
        let isThisCueSpeaking = speakingCueLineID == line.id

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Text(line.speaker.isEmpty ? "READER CUE" : "\(line.speaker.uppercased()) · CUE")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.Colors.accent)
                    .studioPill(Theme.Colors.accent)

                Spacer()

                if let onReadCue {
                    CueSpeakButton(isSpeaking: isThisCueSpeaking) {
                        onReadCue(line)
                    }
                }
            }

            Text(line.text)
                .font(.system(size: 19))
                .foregroundStyle(Theme.Colors.textPrimary)
                .lineSpacing(7)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.accent.opacity(isThisCueSpeaking ? 0.22 : 0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.Colors.accent.opacity(isThisCueSpeaking ? 0.9 : 0.4), lineWidth: isThisCueSpeaking ? 1.75 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func actorLineBlock(_ line: PracticeLine) -> some View {
        let isActive = activeLineID == line.id
        return VStack(alignment: .leading, spacing: 4) {
            if !line.speaker.isEmpty && line.speaker != "SCRIPT" {
                Text("\(line.speaker.uppercased()) · YOU")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.Colors.accent)
                    .padding(.bottom, 2)
            }
            actorLine(line)
        }
        .padding(.horizontal, isActive ? 10 : 0)
        .padding(.vertical, isActive ? 8 : 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isActive ? Theme.Colors.accent.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isActive ? Theme.Colors.accent.opacity(0.35) : Color.clear, lineWidth: 1)
        )
    }

    private func hiddenActorLine(_ line: PracticeLine) -> some View {
        let isActive = activeLineID == line.id
        return Group {
            if revealedLineIDs.contains(line.id) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(line.speaker.isEmpty ? "YOU" : "\(line.speaker.uppercased()) · YOU")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.Colors.accent)

                        Spacer()

                        Button {
                            revealedLineIDs.remove(line.id)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "eye.slash")
                                    .font(.system(size: 10))
                                Text("Hide")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Theme.Colors.surface, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    actorLine(line)
                }
                .padding(12)
                .background(Theme.Colors.accent.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.Colors.accent.opacity(isActive ? 0.65 : 0.25), lineWidth: isActive ? 1.5 : 1))
            } else {
                Button {
                    revealedLineIDs.insert(line.id)
                    if recordRevealAsClue {
                        onLinePeeked?(line.id)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.Colors.accent)
                        Text(line.speaker.isEmpty ? "Tap to peek your line" : "Tap to peek \(line.speaker.uppercased()) line")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(isActive ? Theme.Colors.textPrimary : Theme.Colors.textSecondary)
                        Spacer()
                        Image(systemName: "hand.tap")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Colors.textSecondary.opacity(0.6))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(isActive ? Theme.Colors.accent.opacity(0.10) : Theme.Colors.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(isActive ? Theme.Colors.accent.opacity(0.45) : Theme.Colors.controlBorder, lineWidth: isActive ? 1.25 : 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    private func actorLine(_ line: PracticeLine) -> some View {
        let tokens = model.tokens.filter { $0.lineID == line.id }
        return FlowLayout(spacing: 4) {
            ForEach(Array(tokens.enumerated()), id: \.element.id) { index, token in
                Button { reveal(token) } label: {
                    Text(display(token, position: index, count: tokens.count))
                        .font(.system(size: 19))
                        .fontWeight(revealedTokenIDs.contains(token.id) ? .bold : .regular)
                        .italic(line.text.trimmingCharacters(in: .whitespaces).hasPrefix("("))
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(revealedTokenIDs.contains(token.id) || mode == 1 ? token.word : "Hidden word")
            }
        }
    }

    private func reveal(_ token: PracticeToken) {
        guard mode > 1 else { return }
        revealedTokenIDs.insert(token.id)
        if recordRevealAsClue {
            clueTokenIDs.insert(token.id)
            onClueTokenRequested(token.id)
        }
    }

    private func display(_ token: PracticeToken, position: Int, count: Int) -> String {
        guard mode > 1, !revealedTokenIDs.contains(token.id) else { return token.word }
        if mode == 2, !shouldMask(position, count: count) { return token.word }
        let bare = token.word.trimmingCharacters(in: .punctuationCharacters)
        let punctuation = token.word.replacingOccurrences(of: bare, with: "")
        return mode == 2 ? String(repeating: "_", count: max(6, bare.count)) + punctuation : (bare.first.map { String($0) + punctuation } ?? token.word)
    }

    /// Four non-adjacent blanks per nine words keeps approximately 55% visible.
    private func shouldMask(_ index: Int, count: Int) -> Bool {
        guard index > 0 && index < count - 1 else { return false }
        return [1, 3, 6, 8].contains(index % 9)
    }
}

// MARK: - Test and live delivery

struct TestYourselfView: View {
    let script: PracticeScript; let appState: AppState
    @State private var help = HelpLevel.nothing
    @State private var enteredRun = false
    var body: some View {
        Group {
            if enteredRun { SayItAloudView(script: script, appState: appState, help: help) }
            else {
                VStack(spacing: 22) {
                    Text("Test Yourself!").font(Theme.Typography.screenTitle)
                    Text("Choose how much help you want before you start.").foregroundStyle(Theme.Colors.textSecondary)
                    Picker("Show", selection: $help) {
                        ForEach(HelpLevel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .floatingBottomActionBar {
                    Button { enteredRun = true } label: { Text("Continue").primaryCapsuleButton() }
                        .buttonStyle(.plain)
                }
                .background(Theme.Colors.canvasBackground)
            }
        }.navigationTitle(enteredRun ? "Say It Aloud!" : "Test Yourself!").navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
    }
}

struct SayItAloudView: View {
    let script: PracticeScript
    let appState: AppState
    let help: HelpLevel

    @Environment(\.dismiss) private var dismiss
    @State private var recorder = PracticeSpeechRecorder()
    @State private var cueSpeaker = PracticeCueSpeaker()
    @State private var clueTracker: PracticeSpeechClueTracker
    @State private var selectedMode: PracticeDisplayMode
    @State private var autoReadCues: Bool
    @State private var revealed: Set<Int> = []
    @State private var revealedLineIDs: Set<Int> = []
    @State private var clueTokenIDs: Set<Int> = []
    @State private var didStart = false
    @State private var paused = false
    @State private var hintLineID: Int?
    @State private var hintText: String?
    @State private var discardedAudioURL: URL?
    @State private var reviewSession: PracticeSession?
    @State private var showReview = false
    @State private var isFinalizingReview = false
    @State private var pendingExitAfterReview = false
    @State private var finalizeTask: Task<Void, Never>?
    @State private var spokenCueLineIDs: Set<Int> = []
    @State private var pendingCueQueue: [PracticeLine] = []
    @State private var didCheckOpeningCues = false

    private var model: PracticeScriptModel { clueTracker.model }
    private var activeHelp: HelpLevel { selectedMode.helpLevel }
    private var mode: Int {
        switch selectedMode {
        case .hideLines: return 0
        case .full: return 1
        case .gaps: return 2
        case .firstLetters: return 3
        }
    }
    private var hasCueLines: Bool {
        model.lines.contains(where: \.isCue)
    }
    private var nextActorLine: PracticeLine? {
        clueTracker.nextSentence.flatMap { range in
            model.actorLines.first(where: { $0.id == range.lineID })
        }
    }

    init(script: PracticeScript, appState: AppState, help: HelpLevel) {
        self.script = script
        self.appState = appState
        self.help = help
        _clueTracker = State(initialValue: PracticeSpeechClueTracker(script: script))
        let initialMode: PracticeDisplayMode = switch help {
        case .fullScript: .full
        case .gaps: .gaps
        case .letters: .firstLetters
        case .nothing: .hideLines
        }
        _selectedMode = State(initialValue: initialMode)
        _autoReadCues = State(initialValue: !script.cueLines.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            topControlHeader

            if !appState.isDemoMode && recorder.permissionDenied {
                permissionDeniedCard
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 12) {
                        ScriptPracticeCard(
                            model: model,
                            mode: mode,
                            revealedTokenIDs: $revealed,
                            revealedLineIDs: $revealedLineIDs,
                            clueTokenIDs: $clueTokenIDs,
                            allowLinePeek: true,
                            activeLineID: didStart ? nextActorLine?.id : nil,
                            recordRevealAsClue: didStart,
                            speakingCueLineID: cueSpeaker.activeCueLineID,
                            onReadCue: { line in
                                handleManualCueTap(line)
                            },
                            onLinePeeked: { lineID in
                                requestClueForLine(lineID)
                            },
                            onClueTokenRequested: requestClueForToken,
                            scriptCues: script.cueLines
                        )

                        if let hintText {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "lightbulb.fill")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Theme.Colors.accent)
                                    .padding(.top, 2)
                                Text(hintText)
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.Colors.textPrimary)
                                Spacer(minLength: 4)
                                Button {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        self.hintText = nil
                                        self.hintLineID = nil
                                    }
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(Theme.Colors.textSecondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(12)
                            .background(Theme.Colors.lavenderSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                    .padding(16)
                    .padding(.bottom, 12)
                }
                .scrollEdgeHaptics()
                .scrollIndicators(.visible)
                .frame(maxHeight: .infinity)
                .onChange(of: clueTracker.currentActorLineIndex) { oldIndex, newIndex in
                    if let activeID = nextActorLine?.id {
                        withAnimation(.easeInOut(duration: 0.45)) {
                            proxy.scrollTo(activeID, anchor: .center)
                        }
                    }
                    if let hintLineID, clueTracker.nextSentence?.lineID != hintLineID {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            self.hintText = nil
                            self.hintLineID = nil
                        }
                    }
                    triggerAutomaticCueLinesIfNeeded(previousActorIndex: oldIndex, newActorIndex: newIndex, proxy: proxy)
                }
                .onChange(of: recorder.isRecording) { wasRecording, isNowRecording in
                    if !wasRecording && isNowRecording && !didCheckOpeningCues {
                        didCheckOpeningCues = true
                        triggerOpeningCuesIfNeeded(proxy: proxy)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomTransportDock
        }
        .background(Theme.Colors.canvasBackground)
        .navigationTitle(script.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusDotColor)
                        .frame(width: 7, height: 7)
                    Text(formattedElapsedTime)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.Colors.textPrimary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Theme.Colors.lavenderSurface, in: Capsule())
            }
        }
        .onChange(of: recorder.recognizedWords) { _, segments in
            clueTracker.processRecognizedSpeech(segments: segments)
        }
        .onChange(of: recorder.permissionDenied) { _, denied in
            if denied && !appState.isDemoMode {
                didStart = false
                paused = false
            }
        }
        .onChange(of: recorder.errorMessage) { _, message in
            if message != nil && !recorder.isRecording && !paused && !appState.isDemoMode {
                didStart = false
            }
        }
        .onChange(of: showReview) { wasShowing, isShowing in
            if wasShowing && !isShowing {
                deleteDiscardedAudioIfUnsaved()
                let shouldExit = pendingExitAfterReview
                pendingExitAfterReview = false
                resetSessionState()
                if shouldExit {
                    dismiss()
                }
            }
        }
        .onDisappear {
            if !showReview {
                finalizeTask?.cancel()
                finalizeTask = nil
                stopCuePlaybackAndUnmute()
                recorder.stop()
            }
        }
        .navigationDestination(isPresented: $showReview) {
            if let reviewSession {
                PracticeReviewView(
                    script: script,
                    session: reviewSession,
                    appState: appState,
                    onRetake: {
                        pendingExitAfterReview = false
                        deleteDiscardedAudioIfUnsaved()
                    },
                    onDone: {
                        pendingExitAfterReview = true
                    }
                )
            }
        }
    }

    private var topControlHeader: some View {
        VStack(spacing: 8) {
            Picker("Visibility", selection: $selectedMode) {
                ForEach(PracticeDisplayMode.allCases) { item in
                    Text(item.shortTitle).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isFinalizingReview)
            .onChange(of: selectedMode) { _, _ in
                Haptics.selectionTick()
            }

            if hasCueLines {
                HStack(spacing: 8) {
                    Label(
                        autoReadCues ? "Synthetic cue voice active" : "Synthetic cue voice off",
                        systemImage: autoReadCues ? "speaker.wave.2.fill" : "speaker.slash"
                    )
                    .font(Theme.Typography.captionBadge)
                    .foregroundStyle(Theme.Colors.textSecondary)

                    Spacer()

                    Button {
                        Haptics.selectionTick()
                        autoReadCues.toggle()
                        if !autoReadCues {
                            stopCuePlaybackAndUnmute()
                        }
                    } label: {
                        Text(autoReadCues ? "Auto Cues On" : "Auto Cues Off")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(autoReadCues ? .white : Theme.Colors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(autoReadCues ? Theme.Colors.primaryPlum : Theme.Colors.lavenderSurface, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isFinalizingReview)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.Colors.cardSurface)
        .overlay(Divider(), alignment: .bottom)
    }

    private var bottomTransportDock: some View {
        VStack(spacing: 10) {
            Divider()

            // Fixed-height live feedback strip so the layout stays rock steady.
            HStack(spacing: 10) {
                if isFinalizingReview {
                    ProgressView()
                        .controlSize(.small)
                    Text("Analyzing delivery…")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.Colors.textSecondary)
                    Spacer()
                } else if cueSpeaker.isSpeaking {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.Colors.accent)
                    Text("Cue: “\(cueSpeaker.currentCueText)”")
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.accent)
                        .lineLimit(1)
                    Spacer()
                } else if !appState.isDemoMode, let errorMessage = recorder.errorMessage, !recorder.permissionDenied {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.warningAmber)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.warningAmber)
                        .lineLimit(1)
                    Spacer()
                } else {
                    CompactWaveformBars(level: didStart && !paused ? recorder.audioLevel : 0.08)
                        .frame(width: 44, height: 18)

                    Text(recorder.transcript.isEmpty ? recorder.statusText : recorder.transcript)
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)

                    Spacer(minLength: 0)
                }
            }
            .frame(height: 24)

            if !didStart {
                Button {
                    toggleStart()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 16, weight: .bold))
                        Text("Start Run")
                            .font(.system(size: 16, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.Colors.primaryPlum)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isFinalizingReview)
            } else {
                HStack(spacing: 10) {
                    if activeHelp != .fullScript {
                        Button {
                            requestNextSentence()
                        } label: {
                            Image(systemName: "lightbulb.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Theme.Colors.accent)
                                .frame(width: 48, height: 48)
                                .background(Theme.Colors.lavenderSurface, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isFinalizingReview)
                        .accessibilityLabel("Need a clue")
                    }

                    Button {
                        togglePause()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: paused ? "play.fill" : "pause.fill")
                                .font(.system(size: 14, weight: .bold))
                            Text(paused ? "Resume" : "Pause")
                                .font(.system(size: 15, weight: .semibold))
                        }
                    }
                    .secondaryLavenderButton()
                    .disabled(isFinalizingReview)
                    .accessibilityLabel(paused ? "Resume recording" : "Pause recording")

                    Button {
                        stopAndReview()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 12, weight: .bold))
                            Text(isFinalizingReview ? "Analyzing…" : "Finish")
                                .font(.system(size: 15, weight: .bold))
                        }
                    }
                    .primaryCapsuleButton()
                    .disabled(isFinalizingReview)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .background(Theme.Colors.cardSurface)
    }

    private var statusDotColor: Color {
        if isFinalizingReview { return Theme.Colors.accent }
        if !didStart { return Theme.Colors.textSecondary.opacity(0.45) }
        return paused ? Theme.Colors.warningAmber : Theme.Colors.studioGreen
    }

    private var formattedElapsedTime: String {
        let total = max(0, Int(recorder.duration.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var permissionDeniedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Microphone & Speech Access Needed", systemImage: "mic.slash")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.Colors.textPrimary)
            Text("Enable Microphone and Speech Recognition in Settings to record and analyze your practice run.")
                .font(.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
            Button("Open Settings") {
                VoiceAuthorizationService.openAppSettings()
            }
            .secondaryLavenderButton()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func toggleStart() {
        guard !didStart && !isFinalizingReview else { return }
        Haptics.selectionTick()
        didStart = true
        paused = false
        didCheckOpeningCues = false
        spokenCueLineIDs = []
        pendingCueQueue = []
        recorder.start(language: script.language, script: script, isDemoMode: appState.isDemoMode)
    }

    private func togglePause() {
        guard didStart && !isFinalizingReview else { return }
        Haptics.selectionTick()
        paused.toggle()
        if paused {
            stopCuePlaybackAndUnmute()
            recorder.pause()
        } else {
            recorder.resume()
        }
    }

    private func handleManualCueTap(_ line: PracticeLine) {
        if cueSpeaker.isSpeaking && cueSpeaker.activeCueLineID == line.id {
            stopCuePlaybackAndUnmute()
            return
        }
        speakCueLinesSequentially([line], proxy: nil, allowReplay: true)
    }

    private func triggerOpeningCuesIfNeeded(proxy: ScrollViewProxy) {
        guard autoReadCues, didStart, !paused,
              let firstActorLineID = model.actorLines.first?.id else { return }
        let openingCues = model.lines.filter {
            $0.isCue && $0.id < firstActorLineID && !spokenCueLineIDs.contains($0.id)
        }
        guard !openingCues.isEmpty else { return }
        speakCueLinesSequentially(openingCues, proxy: proxy)
    }

    private func triggerAutomaticCueLinesIfNeeded(previousActorIndex: Int, newActorIndex: Int, proxy: ScrollViewProxy) {
        guard autoReadCues, didStart, !paused, newActorIndex > previousActorIndex else { return }
        let actorLines = model.actorLines
        guard actorLines.indices.contains(previousActorIndex) else { return }
        let prevLineID = actorLines[previousActorIndex].id
        let nextLineID = actorLines.indices.contains(newActorIndex) ? actorLines[newActorIndex].id : Int.max

        let dueCues = model.lines.filter {
            $0.isCue && $0.id > prevLineID && $0.id < nextLineID && !spokenCueLineIDs.contains($0.id)
        }
        guard !dueCues.isEmpty else { return }
        speakCueLinesSequentially(dueCues, proxy: proxy)
    }

    private func speakCueLinesSequentially(
        _ lines: [PracticeLine],
        proxy: ScrollViewProxy?,
        allowReplay: Bool = false
    ) {
        let filtered = allowReplay ? lines : lines.filter { !spokenCueLineIDs.contains($0.id) }
        guard !filtered.isEmpty else { return }
        pendingCueQueue.append(contentsOf: filtered)
        if !cueSpeaker.isSpeaking {
            speakNextQueuedCue(proxy: proxy)
        }
    }

    private func speakNextQueuedCue(proxy: ScrollViewProxy?) {
        guard !pendingCueQueue.isEmpty else {
            recorder.setCuePlaybackMuted(false)
            return
        }
        let nextCue = pendingCueQueue.removeFirst()
        spokenCueLineIDs.insert(nextCue.id)
        if let proxy {
            withAnimation(.easeInOut(duration: 0.35)) {
                proxy.scrollTo(nextCue.id, anchor: .center)
            }
        }
        if didStart && !paused {
            recorder.setCuePlaybackMuted(true)
        }
        cueSpeaker.speak(
            text: nextCue.text,
            lineID: nextCue.id,
            scriptLanguage: script.language,
            ensureAudioSession: !didStart || paused
        ) {
            if self.pendingCueQueue.isEmpty {
                self.recorder.setCuePlaybackMuted(false)
            } else {
                self.speakNextQueuedCue(proxy: proxy)
            }
        }
    }

    private func stopCuePlaybackAndUnmute() {
        pendingCueQueue.removeAll()
        cueSpeaker.stop()
        recorder.setCuePlaybackMuted(false)
    }

    private func requestNextSentence() {
        guard let range = clueTracker.requestNextSentence() else { return }
        Haptics.selectionTick()
        hintLineID = range.lineID
        hintText = range.text
        clueTokenIDs.formUnion(range.tokenIDs)
        if selectedMode == .hideLines {
            revealedLineIDs.insert(range.lineID)
        }
    }

    private func requestClueForLine(_ lineID: Int) {
        guard let range = model.range(forLineID: lineID) else { return }
        Haptics.selectionTick()
        clueTokenIDs.formUnion(range.tokenIDs)
        clueTracker.requestClue(containingTokenID: range.tokenIDs.first ?? -1)
    }

    private func requestClueForToken(_ tokenID: Int) {
        guard let range = clueTracker.requestClue(containingTokenID: tokenID) else { return }
        Haptics.selectionTick()
        clueTokenIDs.formUnion(range.tokenIDs)
    }

    private func stopAndReview() {
        guard !isFinalizingReview else { return }
        isFinalizingReview = true
        stopCuePlaybackAndUnmute()
        Haptics.success()

        finalizeTask?.cancel()
        finalizeTask = Task { @MainActor in
            let capture = await recorder.stopAndFinalizeForAnalysis()
            guard !Task.isCancelled else {
                isFinalizingReview = false
                return
            }
            discardedAudioURL = capture.audioURL
            reviewSession = PracticeSpeechDeliveryAnalyzer.makeSession(
                script: script,
                transcript: capture.transcript,
                words: capture.words,
                clueRequestedRanges: clueTracker.clueRequestedRanges,
                duration: capture.duration,
                help: activeHelp,
                audioURL: capture.audioURL,
                silenceIntervals: capture.silenceIntervals
            )
            isFinalizingReview = false
            finalizeTask = nil
            showReview = true
        }
    }

    private func deleteDiscardedAudioIfUnsaved() {
        guard let session = reviewSession else {
            if let url = discardedAudioURL {
                try? FileManager.default.removeItem(at: url)
                discardedAudioURL = nil
            }
            return
        }
        let isSaved = script.sessions.contains { $0.id == session.id }
        if !isSaved {
            if let url = discardedAudioURL ?? MediaStorage.resolveURL(for: session.audioFilePath) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        discardedAudioURL = nil
    }

    private func resetSessionState() {
        finalizeTask?.cancel()
        finalizeTask = nil
        stopCuePlaybackAndUnmute()
        isFinalizingReview = false
        didStart = false
        paused = false
        didCheckOpeningCues = false
        spokenCueLineIDs = []
        pendingCueQueue = []
        clueTracker = PracticeSpeechClueTracker(script: script)
        revealed = []
        revealedLineIDs = []
        clueTokenIDs = []
        hintLineID = nil
        hintText = nil
        reviewSession = nil
        discardedAudioURL = nil
        recorder.reset()
    }
}

private struct CompactWaveformBars: View {
    let level: CGFloat
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<8, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Theme.Colors.primaryPlum)
                    .frame(width: 3, height: max(4, 5 + CGFloat((index % 4) + 1) * level * 4))
            }
        }
        .animation(.easeInOut(duration: 0.12), value: level)
    }
}

// MARK: - Review and playback

struct PracticeReviewView: View {
    let script: PracticeScript; let session: PracticeSession; let appState: AppState
    let isSavedReview: Bool
    let onRetake: (() -> Void)?
    let onDone: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var playback = PracticeAudioPlayback()
    @State private var saveConfirmation = false

    init(
        script: PracticeScript,
        session: PracticeSession,
        appState: AppState,
        isSavedReview: Bool = false,
        onRetake: (() -> Void)? = nil,
        onDone: (() -> Void)? = nil
    ) {
        self.script = script
        self.session = session
        self.appState = appState
        self.isSavedReview = isSavedReview
        self.onRetake = onRetake
        self.onDone = onDone
    }

    private var scriptModel: PracticeScriptModel {
        PracticeScriptModel(script: script)
    }

    private var inlineAnnotations: [DeliveryAnnotation] {
        session.annotations.filter { $0.kind == .skipped || $0.kind == .forgot || $0.kind == .hesitated }
    }

    private var notInScriptAnnotations: [DeliveryAnnotation] {
        session.annotations.filter { $0.kind == .notInScript }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                playbackPanel
                highlightedScriptCard
            }
            .padding(16)
        }
        .scrollEdgeHaptics()
        .floatingBottomActionBar(isPresented: !isSavedReview, horizontalPadding: 16) {
            HStack(spacing: 12) {
                Button("Retake") {
                    onRetake?()
                    dismiss()
                }
                .secondaryLavenderButton()
                Button("Save") { save() }
                    .primaryCapsuleButton()
            }
        }
        .background(Theme.Colors.canvasBackground)
        .navigationTitle("Your delivery")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .onAppear { playback.load(url: MediaStorage.resolveURL(for: session.audioFilePath)) }
        .onDisappear { playback.stop() }
        .alert("Practice saved", isPresented: $saveConfirmation) {
            Button("Done") {
                onDone?()
                dismiss()
            }
        }
    }

    // MARK: Playback & Timeline Legend

    private var playbackPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Button { playback.toggle() } label: {
                    Image(systemName: playback.isPlaying ? "pause" : "play")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Theme.Colors.primaryPlum)
                        .clipShape(Circle())
                }
                .disabled(!playback.available)

                TimelineScrubber(
                    currentTime: playback.currentTime,
                    duration: max(1, playback.available ? playback.duration : session.durationSeconds),
                    annotations: session.annotations,
                    recognizedWords: session.recognizedWords,
                    scriptModel: scriptModel,
                    isInteractive: playback.available,
                    onSeek: { playback.seek($0) }
                )

                Text(formatDuration(playback.available ? playback.duration : session.durationSeconds))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Colors.accent)
            }

            HStack(spacing: 18) {
                legendItem(color: Theme.Colors.studioYellow, title: "Skipped")
                legendItem(color: Theme.Colors.studioOrange, title: "Hesitated")
                legendItem(color: Theme.Colors.studioGreen, title: "Not in Script")
                Spacer()
            }
            .padding(.leading, 4)
        }
        .padding(16)
        .cardStyle()
    }

    private func legendItem(color: Color, title: String) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(color)
                .frame(width: 5, height: 14)
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.Colors.textPrimary)
        }
    }

    // MARK: Unified Inline Script Card

    private var highlightedScriptCard: some View {
        let lines = scriptModel.lines
        let lastActorLineID = lines.last(where: { !$0.isHeader && !scriptModel.cueLineIDs.contains($0.id) })?.id

        return VStack(spacing: 14) {
            ForEach(lines) { line in
                if line.isHeader {
                    Text(line.text.uppercased())
                        .font(.system(size: 13, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, line.id == lines.first?.id ? 0 : 4)
                } else if scriptModel.cueLineIDs.contains(line.id) {
                    cueBanner(for: line)
                } else {
                    Text(highlightedAttributedText(for: line))
                        .font(.system(size: 16, design: .monospaced))
                        .lineSpacing(6)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .center)

                    if line.id == lastActorLineID {
                        ForEach(notInScriptAnnotations) { extra in
                            notInScriptCallout(extra.text)
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(Theme.Colors.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Theme.Colors.accent.opacity(0.45), lineWidth: 1.5)
        )
    }

    private func cueBanner(for line: PracticeLine) -> some View {
        let matchedCue = script.cueLines.first {
            $0.cueText.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(line.text.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        }
        let speaker = (matchedCue?.speaker ?? "CUE").uppercased()

        return VStack(spacing: 4) {
            ZStack {
                Text(speaker)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.Colors.textPrimary)
                HStack {
                    Spacer()
                    Text("CUE")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.Colors.studioPink)
                }
            }

            Text(line.text)
                .font(.system(size: 15, design: .monospaced))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.Colors.textPrimary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Theme.Colors.studioPink.opacity(0.22))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func notInScriptCallout(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NOT IN THE SCRIPT")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.Colors.textPrimary.opacity(0.75))

            Text(text)
                .font(.system(size: 15, design: .monospaced))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.Colors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Theme.Colors.studioGreen.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func highlightedAttributedText(for line: PracticeLine) -> AttributedString {
        let lineText = line.text
        var attributed = AttributedString(lineText)
        let nsRange = NSRange(lineText.startIndex..., in: lineText)
        let lineTokenRanges = scriptModel.tokenRanges(forLineID: line.id)

        for annotation in inlineAnnotations {
            if !annotation.tokenIDs.isEmpty {
                guard annotation.lineID == nil || annotation.lineID == line.id else { continue }
                let targetSet = Set(annotation.tokenIDs)
                let matchedIndices = lineTokenRanges.indices.filter { targetSet.contains(lineTokenRanges[$0].tokenID) }
                guard !matchedIndices.isEmpty else { continue }

                var runStart = matchedIndices[0]
                var runEnd = matchedIndices[0]
                for index in matchedIndices.dropFirst() {
                    if index == runEnd + 1 {
                        runEnd = index
                    } else {
                        applyHighlight(
                            from: lineTokenRanges[runStart].range.lowerBound,
                            to: lineTokenRanges[runEnd].range.upperBound,
                            in: &attributed,
                            color: highlightColor(annotation.kind)
                        )
                        runStart = index
                        runEnd = index
                    }
                }
                applyHighlight(
                    from: lineTokenRanges[runStart].range.lowerBound,
                    to: lineTokenRanges[runEnd].range.upperBound,
                    in: &attributed,
                    color: highlightColor(annotation.kind)
                )
                continue
            }

            // Legacy saved sessions without stored token IDs fall back to phrase regex matching.
            let needle = annotation.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty else { continue }

            let escaped = NSRegularExpression.escapedPattern(for: needle)
            let startsWithWordChar = needle.unicodeScalars.first.map { CharacterSet.alphanumerics.contains($0) } ?? false
            let endsWithWordChar = needle.unicodeScalars.last.map { CharacterSet.alphanumerics.contains($0) } ?? false
            let prefix = startsWithWordChar ? "(?<![\\p{L}\\p{N}])" : ""
            let suffix = endsWithWordChar ? "(?![\\p{L}\\p{N}])" : ""

            guard let regex = try? NSRegularExpression(pattern: prefix + escaped + suffix, options: [.caseInsensitive]) else {
                continue
            }
            for match in regex.matches(in: lineText, range: nsRange) {
                if let stringRange = Range(match.range, in: lineText) {
                    applyHighlight(
                        from: stringRange.lowerBound,
                        to: stringRange.upperBound,
                        in: &attributed,
                        color: highlightColor(annotation.kind)
                    )
                }
            }
        }
        return attributed
    }

    private func applyHighlight(
        from lower: String.Index,
        to upper: String.Index,
        in attributed: inout AttributedString,
        color: Color
    ) {
        if let attrRange = Range(lower..<upper, in: attributed) {
            attributed[attrRange].backgroundColor = color
        }
    }

    private func highlightColor(_ kind: AnnotationKind) -> Color {
        switch kind {
        case .skipped, .forgot:
            return Theme.Colors.studioYellow.opacity(0.65)
        case .hesitated:
            return Theme.Colors.studioOrange.opacity(0.65)
        case .notInScript:
            return Theme.Colors.studioGreen.opacity(0.55)
        default:
            return .clear
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let mins = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func save() {
        if !script.sessions.contains(where: { $0.id == session.id }) {
            script.sessions.append(session)
            script.lastPracticedAt = .now
            appState.saveChanges()
        }
        saveConfirmation = true
    }
}

private struct TimelineScrubber: View {
    let currentTime: Double
    let duration: Double
    let annotations: [DeliveryAnnotation]
    let recognizedWords: [RecognizedPracticeWord]
    let scriptModel: PracticeScriptModel
    let isInteractive: Bool
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let safeDuration = max(1.0, duration)
            let progress = min(1, max(0, currentTime / max(0.1, duration)))
            let visibleMarkers = annotations.filter { color($0.kind) != .clear }
            let markerFractions = computeMarkerFractions(for: visibleMarkers, duration: safeDuration)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.Colors.lavenderSurface)
                    .frame(height: 5)

                Capsule()
                    .fill(Theme.Colors.primaryPlum.opacity(0.6))
                    .frame(width: width * progress, height: 5)

                ForEach(Array(zip(visibleMarkers, markerFractions).enumerated()), id: \.offset) { _, pair in
                    let (annotation, fraction) = pair
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(color(annotation.kind))
                        .frame(width: 5, height: 14)
                        .offset(x: width * fraction - 2.5)
                }

                if isInteractive {
                    Circle()
                        .fill(Theme.Colors.primaryPlum)
                        .frame(width: 12, height: 12)
                        .offset(x: width * progress - 6)
                }
            }
            .frame(height: 18)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isInteractive else { return }
                        let ratio = min(1, max(0, value.location.x / width))
                        onSeek(Double(ratio) * duration)
                    }
            )
        }
        .frame(height: 18)
        .accessibilityLabel("Annotated delivery timeline")
    }

    private func computeMarkerFractions(for markers: [DeliveryAnnotation], duration: Double) -> [CGFloat] {
        guard !markers.isEmpty else { return [] }
        let safeDuration = max(1.0, duration)
        let actorWords = scriptModel.actorTokens.map { PracticeSpeechDeliveryAnalyzer.normalize($0.word) }

        return markers.enumerated().map { index, annotation in
            if let timestamp = annotation.timestamp, timestamp >= 0 {
                let ratio = timestamp / safeDuration
                return CGFloat(min(0.98, max(0.02, ratio)))
            }

            let firstNeedle = annotation.text
                .split(whereSeparator: \.isWhitespace)
                .first
                .map { PracticeSpeechDeliveryAnalyzer.normalize(String($0)) } ?? ""

            if !recognizedWords.isEmpty, !firstNeedle.isEmpty {
                if annotation.kind == .hesitated {
                    // Prefer the occurrence that followed a hesitation gap (> 1.2s).
                    for idx in recognizedWords.indices.dropFirst() {
                        let gap = recognizedWords[idx].timestamp - (recognizedWords[idx - 1].timestamp + recognizedWords[idx - 1].duration)
                        if gap > PracticeSpeechDeliveryAnalyzer.hesitationPauseThresholdSeconds,
                           PracticeSpeechDeliveryAnalyzer.normalize(recognizedWords[idx].text) == firstNeedle {
                            let ratio = recognizedWords[idx].timestamp / safeDuration
                            return CGFloat(min(0.98, max(0.02, ratio)))
                        }
                    }
                }
                if let matched = recognizedWords.first(where: {
                    PracticeSpeechDeliveryAnalyzer.normalize($0.text) == firstNeedle
                }) {
                    let ratio = matched.timestamp / safeDuration
                    return CGFloat(min(0.98, max(0.02, ratio)))
                }
            }

            if !actorWords.isEmpty, !firstNeedle.isEmpty,
               let scriptIdx = actorWords.firstIndex(of: firstNeedle) {
                let ratio = Double(scriptIdx) / Double(max(1, actorWords.count))
                return CGFloat(min(0.98, max(0.02, ratio)))
            }

            return CGFloat(index + 1) / CGFloat(markers.count + 1)
        }
    }

    private func color(_ kind: AnnotationKind) -> Color {
        switch kind {
        case .skipped, .forgot: return Theme.Colors.studioYellow
        case .hesitated: return Theme.Colors.studioOrange
        case .notInScript: return Theme.Colors.studioGreen
        default: return .clear
        }
    }
}

struct PracticeHistoryView: View {
    let scripts: [PracticeScript]
    let appState: AppState
    @Environment(\.dismiss) private var dismiss

    private var scriptsWithSessions: [PracticeScript] {
        scripts.filter { !$0.sessions.isEmpty }
    }

    var body: some View {
        NavigationStack {
            Group {
                if scriptsWithSessions.isEmpty {
                    ContentUnavailableView(
                        "No Practice Runs Yet",
                        systemImage: "mic",
                        description: Text("Complete a Say It Aloud session to review past runs here.")
                    )
                } else {
                    List {
                        ForEach(scriptsWithSessions) { script in
                            Section(script.title) {
                                ForEach(script.sessions.sorted { $0.sessionNumber > $1.sessionNumber }) { session in
                                    NavigationLink("Practice \(session.sessionNumber) · \(session.date.formatted(date: .abbreviated, time: .omitted))") {
                                        PracticeReviewView(script: script, session: session, appState: appState, isSavedReview: true)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    .scrollEdgeHaptics()
                    .background(Theme.Colors.canvasBackground.ignoresSafeArea())
                }
            }
            .background(Theme.Colors.canvasBackground.ignoresSafeArea())
            .navigationTitle("Practice History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

@Observable private final class PracticeAudioPlayback: NSObject, AVAudioPlayerDelegate {
    var currentTime = 0.0; var duration = 0.0; var isPlaying = false; var available = false
    private var player: AVAudioPlayer?; private var timer: Timer?
    func load(url: URL?) { stop(); guard let url, let player = try? AVAudioPlayer(contentsOf: url) else { available = false; return }; self.player = player; player.delegate = self; duration = player.duration; available = true }
    func toggle() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            timer?.invalidate()
            timer = nil
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
            startTimer()
        }
    }
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
