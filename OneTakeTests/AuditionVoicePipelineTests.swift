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
}
