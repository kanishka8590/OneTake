import XCTest
import SwiftData
@testable import OneTake

@MainActor
final class PracticeFlowRedesignTests: XCTestCase {

    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema([
            UserProfile.self,
            Audition.self,
            PracticeScript.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    func testPracticeDisplayModesAndHelpLevelMapping() {
        XCTAssertEqual(PracticeDisplayMode.allCases.count, 4)

        XCTAssertEqual(PracticeDisplayMode.full.helpLevel, .fullScript)
        XCTAssertEqual(PracticeDisplayMode.firstLetters.helpLevel, .letters)
        XCTAssertEqual(PracticeDisplayMode.gaps.helpLevel, .gaps)
        XCTAssertEqual(PracticeDisplayMode.hideLines.helpLevel, .nothing)

        XCTAssertEqual(PracticeDisplayMode.full.shortTitle, "Full")
        XCTAssertEqual(PracticeDisplayMode.firstLetters.shortTitle, "Letters")
        XCTAssertEqual(PracticeDisplayMode.gaps.shortTitle, "Gaps")
        XCTAssertEqual(PracticeDisplayMode.hideLines.shortTitle, "Hidden")

        for mode in PracticeDisplayMode.allCases {
            XCTAssertFalse(mode.instruction.isEmpty, "Instruction for \(mode) should not be empty")
            XCTAssertEqual(mode.id, mode.rawValue)
        }
    }

    func testAutoDetectCueLinesMultiSpeakerDialogue() {
        let dialogue = """
        LOGAN
        You have to be a killer.

        KENDALL
        I'm not a killer, dad.

        LOGAN
        Then you're out.
        """

        let cues = autoDetectCueLines(from: dialogue)
        XCTAssertEqual(cues.count, 1, "Kendall's line should be detected as the scene partner cue")
        XCTAssertEqual(cues.first?.speaker, "KENDALL")
        XCTAssertEqual(cues.first?.cueText, "I'm not a killer, dad.")
        XCTAssertEqual(cues.first?.precedingActorLine, "You have to be a killer.")
        XCTAssertTrue(cues.first?.isAutoDetected == true)
    }

    func testAutoDetectCueLinesSingleSpeakerMonologue() {
        let monologue = """
        HAMLET
        To be, or not to be, that is the question:
        Whether 'tis nobler in the mind to suffer
        The slings and arrows of outrageous fortune.
        """

        let cues = autoDetectCueLines(from: monologue)
        XCTAssertTrue(cues.isEmpty, "Monologue with single speaker should have 0 cues detected")
    }

    func testAutoDetectCueLinesPlainUnlabeledText() {
        let plainText = """
        Once upon a time in a faraway rehearsal studio.
        An actor was memorising their lines with peace of mind.
        """

        let cues = autoDetectCueLines(from: plainText)
        XCTAssertTrue(cues.isEmpty, "Unlabeled text should not generate false positive cues")
    }

    func testPracticeScriptCreationAndAppStateLifecycle() throws {
        let appState = AppState()
        let container = try makeInMemoryContainer()
        appState.configure(with: container.mainContext)

        let script = PracticeScript(
            title: "Succession S2 Finale",
            languageRaw: ScriptLanguage.english.rawValue,
            rawText: """
            LOGAN
            You have to be a killer.
            KENDALL
            I'm not a killer, dad.
            """,
            cueLines: [
                CueLine(orderIndex: 0, speaker: "KENDALL", cueText: "I'm not a killer, dad.")
            ]
        )

        appState.addPracticeScript(script)
        XCTAssertTrue(appState.practiceScripts.contains(where: { $0.id == script.id }))

        // Verify search finds this script
        appState.globalSearchQuery = "Succession"
        let searchResults = appState.searchResults.scripts
        XCTAssertTrue(searchResults.contains(where: { $0.id == script.id }))

        // Verify cue count
        XCTAssertEqual(script.cueLines.count, 1)

        // Delete script
        appState.deletePracticeScript(script)
        XCTAssertFalse(appState.practiceScripts.contains(where: { $0.id == script.id }))
    }

    func testPracticeScriptCardAccuracyCalculation() {
        let script = PracticeScript(
            title: "Accuracy Test",
            rawText: """
            ACTOR
            One two three four five six seven eight nine ten.
            """
        )

        let session = PracticeSession(
            sessionNumber: 1,
            date: Date(),
            durationSeconds: 15,
            helpLevelRaw: HelpLevel.nothing.rawValue,
            skippedCount: 1,
            forgotCount: 1
        )
        script.sessions.append(session)

        let scriptModel = PracticeScriptModel(script: script)
        let totalTargetWords = scriptModel.actorTokens.count
        XCTAssertEqual(totalTargetWords, 10)

        let errors = session.skippedCount + session.forgotCount
        let correct = max(0, totalTargetWords - errors)
        let accuracy = Int(round(Double(correct) / Double(totalTargetWords) * 100.0))
        XCTAssertEqual(accuracy, 80)
    }

    func testScriptPracticeModelTokenVisibilityAndMasking() {
        let script = PracticeScript(
            title: "Token Test",
            rawText: """
            ACTOR
            I will remember every single word on this line.
            CUE
            And this is your partner cue.
            """,
            cueLines: [
                CueLine(orderIndex: 0, speaker: "CUE", cueText: "And this is your partner cue.")
            ]
        )

        let model = PracticeScriptModel(script: script)
        XCTAssertEqual(model.actorLines.count, 1)
        XCTAssertTrue(model.lines.contains(where: { $0.isCue }))

        // Cue lines never appear in actorTokens
        for token in model.actorTokens {
            XCTAssertFalse(token.isCue)
            XCTAssertFalse(token.word.contains("partner"))
        }
    }
}
