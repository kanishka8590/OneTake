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
        XCTAssertTrue(session.annotations.contains { $0.kind == .hesitated && $0.text.contains("1.8") })
        XCTAssertEqual(session.notInScriptCount, 1)
        XCTAssertTrue(session.annotations.contains { $0.kind == .notInScript && $0.text == "improvised" })
    }
}
