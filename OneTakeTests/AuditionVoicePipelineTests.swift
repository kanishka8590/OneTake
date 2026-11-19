import XCTest
@testable import OneTake

@MainActor
final class AuditionVoicePipelineTests: XCTestCase {
    func testSlateAndAuditionActionAndCutCommands() {
        var isRecording = false
        var isCountingDown = false
        var starts = 0
        var stops = 0
        let controller = LiveVoiceCommandController(
            mode: .slate,
            state: { LiveVoiceCommandState(isRecording: isRecording, isCountingDown: isCountingDown, isCapturingPhoto: false) },
            startRecording: { starts += 1; isCountingDown = true },
            stopRecording: { stops += 1; isRecording = false }
        )

        controller.handleRecognizedTranscript("Action", isFinal: false)
        controller.handleRecognizedTranscript("Action", isFinal: true)
        XCTAssertEqual(starts, 1, "Duplicate Action must be ignored while a take is starting.")

        isCountingDown = false
        isRecording = true
        controller.handleRecognizedTranscript("Cut", isFinal: true)
        XCTAssertEqual(stops, 1)
        XCTAssertFalse(isRecording)
    }

    func testHeadshotsActionNowAndHowDoILookCommands() {
        var isCapturing = false
        var captures = 0
        var feedbacks = 0
        let controller = LiveVoiceCommandController(
            mode: .headshots,
            state: { LiveVoiceCommandState(isRecording: false, isCountingDown: false, isCapturingPhoto: isCapturing) },
            capturePhoto: { captures += 1; isCapturing = true },
            speakFramingFeedback: { feedbacks += 1 }
        )

        controller.handleRecognizedTranscript("Action", isFinal: true)
        isCapturing = false // photo completion is supplied by the hardware service
        controller.handleRecognizedTranscript("Now", isFinal: true)
        controller.handleRecognizedTranscript("How do I look?", isFinal: true)
        controller.handleRecognizedTranscript("Cut", isFinal: true)

        XCTAssertEqual(captures, 2)
        XCTAssertEqual(feedbacks, 1)
    }

    func testHowDoILookFeedbackDuringSlateAndAudition() {
        for mode in [LiveVoiceCommandMode.slate, .audition] {
            var isRecording = true
            var feedbacks = 0
            let controller = LiveVoiceCommandController(
                mode: mode,
                state: { LiveVoiceCommandState(isRecording: isRecording, isCountingDown: false, isCapturingPhoto: false) },
                stopRecording: { isRecording = false },
                speakFramingFeedback: { feedbacks += 1 }
            )
            controller.handleRecognizedTranscript("How do I look?", isFinal: false)
            XCTAssertEqual(feedbacks, 1)
            XCTAssertTrue(isRecording, "Feedback must not interrupt an active take.")
        }
    }

    func testAuditionRightTimeCuePlaybackAndSpeakerBleedProtection() {
        let cues = [
            CueLine(orderIndex: 0, speaker: "READER", cueText: "Cue one words.", precedingActorLine: "Actor line one."),
            CueLine(orderIndex: 1, speaker: "READER", cueText: "Cue two words.", precedingActorLine: "Actor line two.")
        ]
        var scheduled: [() -> Void] = []
        var delays: [TimeInterval] = []
        var fired: [Int] = []
        let coordinator = ScriptSyncedCuePlaybackCoordinator(
            cues: cues,
            responseDelay: 2,
            schedule: { delay, work in delays.append(delay); scheduled.append(work) },
            onCueReady: { fired.append($0) }
        )
        var isRecording = true
        var cuts = 0
        let auditionCommands = LiveVoiceCommandController(
            mode: .audition,
            state: { LiveVoiceCommandState(isRecording: isRecording, isCountingDown: false, isCapturingPhoto: false) },
            stopRecording: { cuts += 1; isRecording = false }
        )

        XCTAssertFalse(coordinator.handleRecognizedTranscript("Actor line", isFinal: false))
        XCTAssertTrue(fired.isEmpty, "A partial actor line must not fire its cue.")

        XCTAssertTrue(coordinator.handleRecognizedTranscript("Actor line one.", isFinal: true))
        XCTAssertTrue(coordinator.isPlayingCue, "The bleed gate begins before the response delay.")
        XCTAssertEqual(delays, [2])
        scheduled.removeFirst()()
        XCTAssertEqual(fired, [0])

        // The caller's shared transcript handler gates commands while cue audio is active.
        if !coordinator.isPlayingCue {
            auditionCommands.handleRecognizedTranscript("Cut Cue one words", isFinal: true)
        }
        XCTAssertEqual(cuts, 0)
        XCTAssertTrue(isRecording)
        XCTAssertFalse(coordinator.handleRecognizedTranscript("Cue one words Cut", isFinal: true))
        XCTAssertEqual(fired, [0])

        coordinator.cuePlaybackDidFinish()
        XCTAssertFalse(coordinator.isPlayingCue)
        XCTAssertTrue(coordinator.handleRecognizedTranscript("Actor line two.", isFinal: true))
        scheduled.removeFirst()()
        XCTAssertEqual(fired, [0, 1])
    }

    func testHowDoILookDoesNotBlockActionAndDebounces() {
        var currentTime = Date(timeIntervalSince1970: 1_000)
        var isRecording = false
        var starts = 0
        var feedbacks = 0

        let controller = LiveVoiceCommandController(
            mode: .audition,
            state: { LiveVoiceCommandState(isRecording: isRecording, isCountingDown: false, isCapturingPhoto: false) },
            startRecording: { starts += 1; isRecording = true },
            speakFramingFeedback: { feedbacks += 1 },
            framingDebounceInterval: 2.0,
            now: { currentTime }
        )

        controller.handleRecognizedTranscript("How do I look? Action", isFinal: false)
        XCTAssertEqual(feedbacks, 1)
        XCTAssertEqual(starts, 1, "\"how do i look\" must not block \"action\" later in the same transcript.")

        // Rapidly repeating "how do i look" even after cursor reset is debounced within 2s.
        controller.resetTranscriptCursor()
        currentTime = currentTime.addingTimeInterval(0.5)
        controller.handleRecognizedTranscript("How do I look?", isFinal: true)
        XCTAssertEqual(feedbacks, 1, "Repeated framing query within debounce interval must be ignored.")

        // Once debounce expires and cursor resets, framing feedback fires again.
        controller.resetTranscriptCursor()
        currentTime = currentTime.addingTimeInterval(2.5)
        controller.handleRecognizedTranscript("How do I look?", isFinal: true)
        XCTAssertEqual(feedbacks, 2)
    }

    func testActionDoesNotRetriggerAfterResetFromStaleCumulativeTranscript() {
        var isRecording = false
        var starts = 0
        let controller = LiveVoiceCommandController(
            mode: .slate,
            state: { LiveVoiceCommandState(isRecording: isRecording, isCountingDown: false, isCapturingPhoto: false) },
            startRecording: { starts += 1; isRecording = true }
        )

        controller.handleRecognizedTranscript("Action hello world", isFinal: false)
        XCTAssertEqual(starts, 1)

        // Take stops and state returns to idle, but recognizer replays cumulative transcript.
        isRecording = false
        controller.handleRecognizedTranscript("Action hello world", isFinal: true)
        XCTAssertEqual(starts, 1, "Stale cumulative transcript must not re-trigger Action after take reset.")

        // After a new task rollover resets the cursor, a fresh Action triggers normally.
        controller.resetTranscriptCursor()
        controller.handleRecognizedTranscript("Action", isFinal: true)
        XCTAssertEqual(starts, 2)
    }

    func testCutInsideDialogueDoesNotStopWhileTrailingCutDoes() {
        var isRecording = true
        var stops = 0
        let controller = LiveVoiceCommandController(
            mode: .audition,
            state: { LiveVoiceCommandState(isRecording: isRecording, isCountingDown: false, isCapturingPhoto: false) },
            stopRecording: { stops += 1; isRecording = false }
        )

        controller.handleRecognizedTranscript("You cut me deep", isFinal: true)
        XCTAssertEqual(stops, 0)
        XCTAssertTrue(isRecording)

        controller.handleRecognizedTranscript("You cut me deep. Cut.", isFinal: true)
        XCTAssertEqual(stops, 1)
        XCTAssertFalse(isRecording)
    }

    func testCueCoordinatorContractionsMisheardWordEmptyLineAndSearchReset() {
        let cues = [
            CueLine(orderIndex: 0, speaker: "READER", cueText: "Opening cue.", precedingActorLine: ""),
            CueLine(orderIndex: 1, speaker: "READER", cueText: "Cue two.", precedingActorLine: "I'm ready to go."),
            CueLine(orderIndex: 2, speaker: "READER", cueText: "Cue three.", precedingActorLine: "Please tell me the truth now.")
        ]
        var scheduled: [() -> Void] = []
        var fired: [Int] = []
        let coordinator = ScriptSyncedCuePlaybackCoordinator(
            cues: cues,
            responseDelay: 0,
            schedule: { _, work in scheduled.append(work) },
            onCueReady: { fired.append($0) }
        )

        // Manual advance handles empty precedingActorLine cleanly.
        XCTAssertEqual(coordinator.requestManualCue(), 0)
        scheduled.removeFirst()()
        XCTAssertEqual(fired, [0])
        coordinator.cuePlaybackDidFinish()

        // Contraction equivalence: "I am" matches "I'm".
        XCTAssertTrue(coordinator.handleRecognizedTranscript("I am ready to go.", isFinal: true))
        scheduled.removeFirst()()
        XCTAssertEqual(fired, [0, 1])
        coordinator.cuePlaybackDidFinish()

        // Incomplete prefix must not fire early.
        XCTAssertFalse(coordinator.handleRecognizedTranscript("Please tell me the", isFinal: false))

        // Task rollover resets search position; 1 misheard word on 4+ word line still matches.
        coordinator.resetTranscriptSearch()
        XCTAssertTrue(coordinator.handleRecognizedTranscript("Please tell him the truth now.", isFinal: true))
        scheduled.removeFirst()()
        XCTAssertEqual(fired, [0, 1, 2])
    }

    func testEmptyPrecedingActorLineAutoReadiesOnSpeechWithoutStalling() {
        let cues = [
            CueLine(orderIndex: 0, speaker: "READER", cueText: "Opening cue.", precedingActorLine: ""),
            CueLine(orderIndex: 1, speaker: "READER", cueText: "Next cue.", precedingActorLine: "Here we go.")
        ]
        var scheduled: [() -> Void] = []
        var fired: [Int] = []
        let coordinator = ScriptSyncedCuePlaybackCoordinator(
            cues: cues,
            responseDelay: 0,
            schedule: { _, work in scheduled.append(work) },
            onCueReady: { fired.append($0) }
        )

        XCTAssertFalse(coordinator.handleRecognizedTranscript("", isFinal: false))
        XCTAssertTrue(coordinator.handleRecognizedTranscript("Here we go.", isFinal: true))
        scheduled.removeFirst()()
        XCTAssertEqual(fired, [0])

        coordinator.cuePlaybackDidFinish()
        XCTAssertTrue(coordinator.handleRecognizedTranscript("Here we go.", isFinal: true))
        scheduled.removeFirst()()
        XCTAssertEqual(fired, [0, 1])
    }

    // MARK: - VoiceTeleprompterTracker Read-Along Tests

    func testVoiceTeleprompterTrackerAdvancesWordByWordAcrossRolloversAndAdLibs() {
        let tracker = VoiceTeleprompterTracker(
            scriptLines: [
                "[READER]: Are you ready to talk?",
                "I'm five′8″ tall and I live in Mumbai.",
                "Let's finish this scene together before midnight."
            ],
            cueSpeakers: ["READER"]
        )

        // Reader line has 0 speakable words so active line starts cleanly on line 1 ("I'm ...").
        XCTAssertEqual(tracker.activeLineIndex, 1)
        XCTAssertEqual(tracker.activeWordIndexInLine, 0)

        // Contraction ("I am" == "I'm") and spoken height ("five eight" == "5′8″") advance smoothly.
        tracker.ingestTranscript("I am five eight", isFinal: false)
        XCTAssertEqual(tracker.activeLineIndex, 1)
        XCTAssertTrue(tracker.isWordMatched(lineIndex: 1, wordIndex: 0))
        XCTAssertTrue(tracker.isWordMatched(lineIndex: 1, wordIndex: 1))
        XCTAssertGreaterThan(tracker.lineWordFraction(1), 0.2)

        // Task rollover (final then fresh short transcript) must NEVER move progress backward.
        let prevCount = tracker.matchedWordCount
        tracker.ingestTranscript("I am five eight tall and", isFinal: true)
        XCTAssertGreaterThan(tracker.matchedWordCount, prevCount)

        // Actor skips "live in" or ad-libs briefly -> bigram resync picks up "Mumbai" / "Let's finish".
        let countAfterFirstSentence = tracker.matchedWordCount
        tracker.ingestTranscript("Mumbai lets finish this scene", isFinal: false)
        XCTAssertGreaterThan(tracker.matchedWordCount, countAfterFirstSentence)
        XCTAssertEqual(tracker.activeLineIndex, 2)
    }

    @MainActor
    func testRecorderVoiceAndGestureTogglesGateVoiceTriggersCleanly() {
        let service = TeleprompterRecorderService.shared
        let prevTrigger = service.onVoiceActionTriggered
        let prevMic = service.onLiveMicData
        let prevVoiceEnabled = service.voiceCommandsEnabled
        let prevGesturesEnabled = service.gesturesEnabled
        defer {
            service.onVoiceActionTriggered = prevTrigger
            service.onLiveMicData = prevMic
            service.voiceCommandsEnabled = prevVoiceEnabled
            service.gesturesEnabled = prevGesturesEnabled
            service.stopSession()
        }

        var voiceTriggeredCount = 0
        var micTranscripts: [String] = []
        service.onVoiceActionTriggered = { voiceTriggeredCount += 1 }
        service.onLiveMicData = { _, transcript, _ in micTranscripts.append(transcript) }

        service.disableVoiceCommands()
        XCTAssertFalse(service.voiceCommandsEnabled)
        service.handleRecognizedTranscript("action", isFinal: true)
        XCTAssertEqual(voiceTriggeredCount, 0, "Disabled voice commands must not trigger action")
        XCTAssertEqual(micTranscripts, ["action"], "Voice sync transcript stream must still remain alive")

        service.enableVoiceCommands()
        XCTAssertTrue(service.voiceCommandsEnabled)
        service.handleRecognizedTranscript("action", isFinal: true)
        XCTAssertEqual(voiceTriggeredCount, 1, "Re-enabled voice commands must fire 'action' trigger")

        service.gesturesEnabled = false
        XCTAssertFalse(service.gesturesEnabled)
        service.gesturesEnabled = true
        XCTAssertTrue(service.gesturesEnabled)
    }

    @MainActor
    func testVoiceTeleprompterTrackerPausesAtCueBoundaryAndResumesAfterCueCompletion() {
        let cues = [
            CueLine(orderIndex: 0, speaker: "READER", cueText: "Did you lock the back door?", precedingActorLine: "I waited for your call.")
        ]
        let tracker = VoiceTeleprompterTracker(
            scriptLines: [
                "HEER: I waited for your call.",
                "[READER]: Did you lock the back door?",
                "HEER: Yes I locked it before midnight."
            ],
            cueSpeakers: ["READER"],
            cueLines: cues
        )

        XCTAssertEqual(tracker.activeLineIndex, 0)
        XCTAssertNil(tracker.activeCueOrderIndex)

        tracker.ingestTranscript("I waited for your call", isFinal: false)
        XCTAssertEqual(tracker.activeLineIndex, 1, "Should stop right on the cue line after preceding actor words finish")
        XCTAssertEqual(tracker.activeCueOrderIndex, 0)

        tracker.activateCue(orderIndex: 0)
        XCTAssertEqual(tracker.activeLineIndex, 1)

        tracker.completeCue(orderIndex: 0)
        XCTAssertNil(tracker.activeCueOrderIndex)
        XCTAssertEqual(tracker.activeLineIndex, 2, "Must resume highlighting the next actor line automatically after cue completes")

        tracker.ingestTranscript("Yes I locked it before midnight", isFinal: true)
        XCTAssertTrue(tracker.isComplete)
    }

    @MainActor
    func testScriptSyncedCoordinatorFastSyncsFromTeleprompterBoundary() {
        let cues = [
            CueLine(orderIndex: 0, speaker: "READER", cueText: "Line 0", precedingActorLine: "First"),
            CueLine(orderIndex: 1, speaker: "READER", cueText: "Line 1", precedingActorLine: "Second")
        ]
        var triggeredIndices: [Int] = []
        let coordinator = ScriptSyncedCuePlaybackCoordinator(
            cues: cues,
            responseDelay: 1.5,
            schedule: { _, work in work() },
            onCueReady: { triggeredIndices.append($0) }
        )

        XCTAssertTrue(coordinator.requestTeleprompterSyncedCue(at: 1))
        XCTAssertEqual(triggeredIndices, [1])
        coordinator.cuePlaybackDidFinish()
        XCTAssertEqual(coordinator.currentCueIndex, 2)
    }
}
