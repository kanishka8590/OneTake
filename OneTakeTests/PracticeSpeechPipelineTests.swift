import XCTest
import AVFoundation
@testable import OneTake

@MainActor
final class PracticeSpeechPipelineTests: XCTestCase {
    private func makeScript() -> PracticeScript {
        PracticeScript(
            title: "Pipeline test",
            rawText: """
            ACTOR
            Sentence one is spoken.
            CUE
            Cue partner says wait.
            ACTOR
            Sentence two needs a clue.
            Sentence three is skipped.
            """,
            cueLines: [CueLine(orderIndex: 0, speaker: "CUE", cueText: "Cue partner says wait.")]
        )
    }

    private func segments(_ words: [String], startingAt timestamp: Double = 0, gapBeforeLast: Double? = nil) -> [RecognizedPracticeWord] {
        words.enumerated().map { index, word in
            let gap = gapBeforeLast != nil && index == words.count - 1 ? gapBeforeLast! : 0
            return RecognizedPracticeWord(text: word, timestamp: timestamp + Double(index) * 0.25 + gap, duration: 0.18)
        }
    }

    func testLiveClueProgressionAndDeliveryAnalysis() {
        let script = makeScript()
        let tracker = PracticeSpeechClueTracker(script: script)
        let firstSentence = segments(["Sentence", "one", "is", "spoken"], gapBeforeLast: 1.8)

        tracker.processRecognizedSpeech(segments: firstSentence)
        XCTAssertEqual(tracker.nextSentence?.text, "Sentence two needs a clue.", "A CUE line must be skipped when finding the next clue.")

        let clue = tracker.requestNextSentence()
        XCTAssertEqual(clue?.text, "Sentence two needs a clue.")

        // Sentence two is requested as a clue; sentence three and the CUE are never spoken.
        // The final improvised word follows directly; hesitation occurred before "spoken".
        let finalWords = firstSentence + [
            RecognizedPracticeWord(text: "improvised", timestamp: 2.98, duration: 0.18)
        ]
        let session = PracticeSpeechDeliveryAnalyzer.makeSession(
            script: script,
            transcript: finalWords.map(\.text).joined(separator: " "),
            words: finalWords,
            clueRequestedRanges: tracker.clueRequestedRanges,
            duration: 3,
            help: .nothing,
            audioURL: nil
        )

        XCTAssertEqual(session.forgotCount, 0)
        XCTAssertEqual(session.skippedCount, 9)
        XCTAssertFalse(session.annotations.contains { $0.kind == .forgot })
        XCTAssertTrue(session.annotations.contains { $0.kind == .skipped && $0.text == "Sentence two needs a clue." })
        XCTAssertTrue(session.annotations.contains { $0.kind == .skipped && $0.text == "Sentence three is skipped." })
        XCTAssertFalse(session.annotations.contains { $0.kind == .skipped && $0.text.contains("Cue partner") })
        XCTAssertEqual(session.hesitatedCount, 1)
        XCTAssertTrue(session.annotations.contains { $0.kind == .hesitated && $0.text == "spoken." })
        XCTAssertEqual(session.notInScriptCount, 1)
        XCTAssertTrue(session.annotations.contains { $0.kind == .notInScript && $0.text == "improvised" })
    }

    func testContractionsStageDirectionsAndVerbatimAnnotations() {
        let script = PracticeScript(
            title: "Annotation spans",
            rawText: """
            ACTOR
            Luke’s wouldn't say she'll leave. I’m ready.
            (beat)
            We will not wait.
            CUE
            This cue is never analysed.
            """,
            cueLines: [CueLine(orderIndex: 0, speaker: "CUE", cueText: "This cue is never analysed.")]
        )
        let model = PracticeScriptModel(script: script)

        XCTAssertEqual(model.actorLines.map(\.text), ["Luke’s wouldn't say she'll leave. I’m ready.", "We will not wait."])
        XCTAssertFalse(model.actorTokens.contains { $0.word.contains("beat") })

        let expandedTranscript = "Luke's would not say she will leave. I am ready. We won't wait."
        let equivalent = PracticeSpeechDeliveryAnalyzer.makeSession(
            script: script,
            transcript: expandedTranscript,
            words: [],
            clueRequestedRanges: [],
            duration: 5,
            help: .nothing,
            audioURL: nil
        )
        XCTAssertEqual(equivalent.skippedCount, 0)
        XCTAssertEqual(equivalent.notInScriptCount, 0)

        let clueToken = model.actorTokens.first { $0.word.contains("wouldn't") }!
        let clue = model.range(containingTokenID: clueToken.id)!
        let omitted = PracticeSpeechDeliveryAnalyzer.makeSession(
            script: script,
            transcript: "Luke’s say she'll leave. I’m ready.",
            words: [],
            clueRequestedRanges: [clue],
            duration: 3,
            help: .gaps,
            audioURL: nil
        )

        XCTAssertEqual(omitted.forgotCount, 0)
        XCTAssertTrue(omitted.annotations.contains {
            $0.kind == .skipped && $0.text == "wouldn't"
        })
        XCTAssertTrue(omitted.annotations.contains {
            $0.kind == .skipped && $0.text == "We will not wait."
        })
        XCTAssertFalse(omitted.annotations.contains { $0.text.contains("beat") || $0.text.contains("This cue") })
    }

    func testSkippedFinalWordUsesAHalfOpenStringRange() {
        let script = PracticeScript(
            title: "Final word range",
            rawText: """
            ACTOR
            The final word is safe.
            """
        )

        let session = PracticeSpeechDeliveryAnalyzer.makeSession(
            script: script,
            transcript: "",
            words: [],
            clueRequestedRanges: [],
            duration: 0,
            help: .nothing,
            audioURL: nil
        )

        XCTAssertTrue(session.annotations.contains {
            $0.kind == .skipped && $0.text == "The final word is safe."
        })
    }

    func testAutoDetectedCueRoleIsNeverTreatedAsActorText() {
        let script = PracticeScript(
            title: "Labeled dialogue",
            rawText: """
            ACTOR:
            I am ready for this.
            READER:
            Tell us where you are based.
            And what is your availability?
            """,
            cueLines: [
                CueLine(
                    orderIndex: 0,
                    speaker: "READER",
                    cueText: "Tell us where you are based.",
                    isAutoDetected: true
                )
            ]
        )
        let model = PracticeScriptModel(script: script)

        XCTAssertEqual(
            model.lines.filter(\.isCue).map(\.text),
            ["Tell us where you are based.", "And what is your availability?"],
            "The detected cue speaker must keep every one of its lines visible."
        )
        XCTAssertEqual(model.actorLines.map(\.text), ["I am ready for this."])
        XCTAssertFalse(model.actorTokens.contains { $0.word.contains("availability") })
    }

    func testColonsInDialogueNotMisparsedAndSingleMarkedCueDoesNotHideOtherLines() {
        let script = PracticeScript(
            title: "Colon safety",
            rawText: """
            ACTOR:
            Wait: what?
            Note: I'm leaving now.
            ALICE: First line by Alice.
            ALICE: Second line by Alice.
            """,
            cueLines: [
                CueLine(orderIndex: 0, speaker: "ACTOR", cueText: "Note: I'm leaving now.", isAutoDetected: false),
                CueLine(orderIndex: 1, speaker: "ALICE", cueText: "First line by Alice.", isAutoDetected: false)
            ]
        )
        let model = PracticeScriptModel(script: script)

        XCTAssertTrue(model.actorLines.contains { $0.text == "Wait: what?" && $0.speaker == "ACTOR" })
        XCTAssertTrue(model.actorLines.contains { $0.text == "Second line by Alice." && $0.speaker == "ALICE" })
        XCTAssertEqual(model.lines.filter(\.isCue).map(\.text), ["Note: I'm leaving now.", "First line by Alice."])
    }

    func testClueTrackerToleratesSingleSlipAndMarksOnlyTargetedSentence() {
        let script = PracticeScript(
            title: "Multi-sentence clue tracking",
            rawText: """
            ACTOR
            First sentence has four words. Second sentence comes next.
            Third sentence closes scene.
            """
        )
        let tracker = PracticeSpeechClueTracker(script: script)

        // Mishear "four" -> "for" on sentence 1: tracking must still advance to sentence 2.
        tracker.processRecognizedSpeech(segments: segments(["First", "sentence", "has", "for", "words"]))
        XCTAssertEqual(tracker.nextSentence?.text, "Second sentence comes next.")

        // Requesting clue for a token in sentence 2 must only mark sentence 2, not the whole line.
        let tokenInSecond = tracker.model.actorTokens.first { $0.word == "comes" }!
        let clueRange = tracker.requestClue(containingTokenID: tokenInSecond.id)
        XCTAssertEqual(clueRange?.text, "Second sentence comes next.")
        XCTAssertEqual(clueRange?.tokenIDs.count, 4)
        XCTAssertEqual(tracker.clueRequestedRanges.count, 1)
    }

    func testDeliveryAnalyzerCannotPartialSplitTokensContractionsShortImprovisationsAndNoSkippedHesitation() {
        let script = PracticeScript(
            title: "Analyzer precision",
            rawText: """
            ACTOR
            I cannot stay. He's well-known and would've helped. It's here.
            Skipped ending line.
            """
        )

        // Saying "can" instead of "cannot" must NOT falsely satisfy "cannot".
        let partialCannot = PracticeSpeechDeliveryAnalyzer.makeSession(
            script: script,
            transcript: "I can stay. He is well known and would have helped. It is here. Skipped ending line.",
            words: [],
            clueRequestedRanges: [],
            duration: 6,
            help: .nothing,
            audioURL: nil
        )
        XCTAssertEqual(partialCannot.skippedCount, 1)
        XCTAssertTrue(partialCannot.annotations.contains { $0.kind == .skipped && $0.text == "cannot" })

        // Split recognizer tokens ("it" + "'s"), contractions, and hyphenated words all match;
        // meaningful short improvisations ("no", "ok") are retained while filler ("um") is ignored;
        // skipped words after a gap with an improvised word are NOT marked .hesitated.
        let splitWords: [RecognizedPracticeWord] = [
            RecognizedPracticeWord(text: "I", timestamp: 0.0, duration: 0.15),
            RecognizedPracticeWord(text: "cannot", timestamp: 0.2, duration: 0.2),
            RecognizedPracticeWord(text: "stay", timestamp: 0.45, duration: 0.2),
            RecognizedPracticeWord(text: "he's", timestamp: 0.7, duration: 0.2),
            RecognizedPracticeWord(text: "well", timestamp: 0.95, duration: 0.2),
            RecognizedPracticeWord(text: "known", timestamp: 1.2, duration: 0.2),
            RecognizedPracticeWord(text: "and", timestamp: 1.45, duration: 0.15),
            RecognizedPracticeWord(text: "would've", timestamp: 1.65, duration: 0.2),
            RecognizedPracticeWord(text: "helped", timestamp: 1.9, duration: 0.2),
            RecognizedPracticeWord(text: "it", timestamp: 2.15, duration: 0.12),
            RecognizedPracticeWord(text: "'s", timestamp: 2.27, duration: 0.1),
            RecognizedPracticeWord(text: "here", timestamp: 2.42, duration: 0.2),
            RecognizedPracticeWord(text: "um", timestamp: 4.3, duration: 0.15),
            RecognizedPracticeWord(text: "no", timestamp: 4.5, duration: 0.15),
            RecognizedPracticeWord(text: "ok", timestamp: 4.7, duration: 0.15)
        ]

        let session = PracticeSpeechDeliveryAnalyzer.makeSession(
            script: script,
            transcript: splitWords.map(\.text).joined(separator: " "),
            words: splitWords,
            clueRequestedRanges: [],
            duration: 5.0,
            help: .nothing,
            audioURL: nil
        )

        XCTAssertEqual(session.skippedCount, 3, "Only 'Skipped ending line.' should be skipped.")
        XCTAssertEqual(session.hesitatedCount, 0, "A skipped word must not be marked .hesitated via priorIndex + 1.")
        XCTAssertEqual(session.notInScriptCount, 2)
        XCTAssertTrue(session.annotations.contains { $0.kind == .notInScript && $0.text == "no ok" })
    }

    func testRecorderDenialWithoutDemoModeDoesNotSimulateAndPausePreservesRealTranscript() async throws {
        let script = makeScript()

        let deniedRecorder = PracticeSpeechRecorder(requestAccess: { completion in
            completion(false)
        })
        deniedRecorder.start(language: .english, script: script, isDemoMode: false)

        XCTAssertTrue(deniedRecorder.permissionDenied)
        XCTAssertFalse(deniedRecorder.isRecording)
        XCTAssertTrue(deniedRecorder.transcript.isEmpty)
        XCTAssertTrue(deniedRecorder.recognizedWords.isEmpty)

        // Verify pause/resume preserves real transcripts and freezes duration while paused.
        let realRecorder = PracticeSpeechRecorder(requestAccess: { $0(true) })
        let words = segments(["Sentence", "one", "is", "spoken"])
        realRecorder.isRecording = true
        realRecorder.processRecognizedSpeech(segments: words)
        realRecorder.pause()

        XCTAssertFalse(realRecorder.isRecording)
        XCTAssertEqual(realRecorder.transcript, "Sentence one is spoken")
        XCTAssertEqual(realRecorder.recognizedWords.count, 4)

        let pausedDuration = realRecorder.duration
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(realRecorder.duration, pausedDuration, accuracy: 0.001)

        realRecorder.resume()
        XCTAssertTrue(realRecorder.isRecording)
        XCTAssertEqual(realRecorder.transcript, "Sentence one is spoken")
        XCTAssertEqual(realRecorder.recognizedWords.count, 4)
        realRecorder.stop()
    }

    func testPauseThresholdAt1Point2SecondsAndCueBoundaryExemption() {
        let script = PracticeScript(
            title: "Threshold & Cue test",
            rawText: """
            ACTOR
            Hold steady now.
            CUE
            Partner interrupts briefly.
            ACTOR
            Answer clearly please.
            """,
            cueLines: [CueLine(orderIndex: 0, speaker: "CUE", cueText: "Partner interrupts briefly.")]
        )

        // 1.10s gap before "steady" is <= 1.2s (no hesitation);
        // 2.60s gap across CUE before "Answer" is partner wait (no hesitation);
        // 1.35s gap before "please" is > 1.2s inside actor turn (1 hesitation).
        let words: [RecognizedPracticeWord] = [
            RecognizedPracticeWord(text: "Hold", timestamp: 0.0, duration: 0.2),
            RecognizedPracticeWord(text: "steady", timestamp: 1.30, duration: 0.2),
            RecognizedPracticeWord(text: "now", timestamp: 1.60, duration: 0.2),
            RecognizedPracticeWord(text: "Answer", timestamp: 4.40, duration: 0.2),
            RecognizedPracticeWord(text: "clearly", timestamp: 4.70, duration: 0.2),
            RecognizedPracticeWord(text: "please", timestamp: 6.25, duration: 0.2)
        ]

        let session = PracticeSpeechDeliveryAnalyzer.makeSession(
            script: script,
            transcript: words.map(\.text).joined(separator: " "),
            words: words,
            clueRequestedRanges: [],
            duration: 6.6,
            help: .nothing,
            audioURL: nil
        )

        XCTAssertEqual(session.skippedCount, 0)
        XCTAssertEqual(session.hesitatedCount, 1)
        XCTAssertEqual(session.annotations.filter { $0.kind == .hesitated }.map(\.text), ["please."])
    }

    func testFillerDisfluenciesFalseStartsAlternativeSubstringsAndNotInScript() {
        let script = PracticeScript(
            title: "Stumble & Recovery",
            rawText: """
            ACTOR
            Four friends waited inside.
            """
        )

        // - "for" recovers "Four" via alternativeSubstrings
        // - "uh" before "friends" marks "friends" as .hesitated (without entering Not in Script)
        // - "wa" (false-start prefix) before "waited" marks "waited" as .hesitated (without entering Not in Script)
        // - "right outside" is a genuine Not in Script addition
        let words: [RecognizedPracticeWord] = [
            RecognizedPracticeWord(
                text: "for",
                timestamp: 0.0,
                duration: 0.2,
                confidence: 0.65,
                alternativeSubstrings: ["four"]
            ),
            RecognizedPracticeWord(text: "uh", timestamp: 0.25, duration: 0.15),
            RecognizedPracticeWord(text: "friends", timestamp: 0.45, duration: 0.25),
            RecognizedPracticeWord(text: "wa", timestamp: 0.75, duration: 0.12),
            RecognizedPracticeWord(text: "waited", timestamp: 0.90, duration: 0.25),
            RecognizedPracticeWord(text: "inside", timestamp: 1.25, duration: 0.25),
            RecognizedPracticeWord(text: "right", timestamp: 1.55, duration: 0.2),
            RecognizedPracticeWord(text: "outside", timestamp: 1.80, duration: 0.25)
        ]

        let session = PracticeSpeechDeliveryAnalyzer.makeSession(
            script: script,
            transcript: words.map(\.text).joined(separator: " "),
            words: words,
            clueRequestedRanges: [],
            duration: 2.2,
            help: .nothing,
            audioURL: nil
        )

        XCTAssertEqual(session.skippedCount, 0)
        XCTAssertEqual(session.hesitatedCount, 2)
        XCTAssertEqual(
            Set(session.annotations.filter { $0.kind == .hesitated }.map(\.text)),
            Set(["friends", "waited"])
        )
        XCTAssertEqual(session.notInScriptCount, 2)
        XCTAssertTrue(session.annotations.contains { $0.kind == .notInScript && $0.text == "right outside" })
    }

    func testAcousticSilenceAnalyzerDetectsPauseEvenWhenSpeechDurationStretches() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("practice_silence_test_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let sampleRate: Double = 16_000
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            XCTFail("Failed to build audio format")
            return
        }
        // Timeline: 0.0-0.5s tone | 0.5-1.95s silence (1.45s > 1.2s) | 1.95-2.45s tone | 2.45-3.25s silence (0.80s <= 1.2s) | 3.25-3.75s tone
        let totalSamples = Int(3.75 * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalSamples)),
              let ptr = buffer.floatChannelData?.pointee else {
            XCTFail("Failed to allocate PCM buffer")
            return
        }
        buffer.frameLength = AVAudioFrameCount(totalSamples)
        for sample in 0..<totalSamples {
            let t = Double(sample) / sampleRate
            let isTone = (t < 0.50) || (t >= 1.95 && t < 2.45) || (t >= 3.25)
            ptr[sample] = isTone ? Float(0.35 * sin(2.0 * .pi * 240.0 * t)) : Float(0.0002)
        }
        do {
            let audioFile = try AVAudioFile(forWriting: tempURL, settings: format.settings)
            try audioFile.write(from: buffer)
        }

        let silences = PracticeAudioSilenceAnalyzer.detectSilences(in: tempURL, minimumDuration: 1.2)
        XCTAssertEqual(silences.count, 1)
        let firstSilence = try XCTUnwrap(silences.first)
        XCTAssertEqual(firstSilence.start, 0.50, accuracy: 0.10)
        XCTAssertEqual(firstSilence.duration, 1.45, accuracy: 0.15)

        let script = PracticeScript(
            title: "Acoustic silence test",
            rawText: """
            ACTOR
            Wait here please.
            """
        )
        // Simulate ASR stretching "Wait" duration across the 1.45s silence so ASR gap is 0.0s.
        let stretchedWords: [RecognizedPracticeWord] = [
            RecognizedPracticeWord(text: "Wait", timestamp: 0.05, duration: 1.90),
            RecognizedPracticeWord(text: "here", timestamp: 1.95, duration: 0.45),
            RecognizedPracticeWord(text: "please", timestamp: 3.25, duration: 0.40)
        ]

        let session = PracticeSpeechDeliveryAnalyzer.makeSession(
            script: script,
            transcript: "Wait here please",
            words: stretchedWords,
            clueRequestedRanges: [],
            duration: 3.75,
            help: .nothing,
            audioURL: tempURL,
            silenceIntervals: silences
        )

        XCTAssertEqual(session.hesitatedCount, 1)
        XCTAssertEqual(session.annotations.filter { $0.kind == .hesitated }.map(\.text), ["here"])
    }
}
