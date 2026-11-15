import XCTest
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
        let firstSentence = segments(["Sentence", "one", "is", "spoken"])

        tracker.processRecognizedSpeech(segments: firstSentence)
        XCTAssertEqual(tracker.nextSentence?.text, "Sentence two needs a clue.", "A CUE line must be skipped when finding the next clue.")

        let clue = tracker.requestNextSentence()
        XCTAssertEqual(clue?.text, "Sentence two needs a clue.")

        // Sentence two is requested as a clue; sentence three and the CUE are never spoken.
        // The final improvised word arrives after a 1.8s timestamp gap.
        let finalWords = firstSentence + [
            RecognizedPracticeWord(text: "improvised", timestamp: 2.73, duration: 0.18)
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

        XCTAssertEqual(session.forgotCount, 5)
        XCTAssertTrue(session.annotations.contains { $0.kind == .forgot && $0.text == "Sentence two needs a clue." })
        XCTAssertTrue(session.annotations.contains { $0.kind == .skipped && $0.text == "Sentence three is skipped." })
        XCTAssertFalse(session.annotations.contains { $0.kind == .skipped && $0.text.contains("Cue partner") })
        XCTAssertEqual(session.hesitatedCount, 1)
        XCTAssertTrue(session.annotations.contains { $0.kind == .hesitated && $0.text == "Sentence" })
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

        XCTAssertTrue(omitted.annotations.contains {
            $0.kind == .forgot && $0.text == "Luke’s wouldn't say she'll leave."
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
}
