import AVFoundation
import Speech

/// The state shown by recording screens.  A green listening indicator now means
/// the recognizer task was actually created, not merely that permission exists.
enum LiveSpeechStatus: Equatable {
    case idle
    case starting
    case listening
    case unavailable
    case interrupted
    case failed

    var label: String {
        switch self {
        case .idle: return "Voice off"
        case .starting: return "Starting voice…"
        case .listening: return "Listening"
        case .unavailable: return "Speech unavailable"
        case .interrupted: return "Voice interrupted"
        case .failed: return "Voice unavailable"
        }
    }
}

/// Keeps every capture, recognition, playback, and synthesis path on the same
/// active audio-session contract.  Services deliberately do not deactivate it:
/// another OneTake feature can still be using it when a view disappears.
final class VoiceAudioSessionCoordinator {
    static let shared = VoiceAudioSessionCoordinator()

    @discardableResult
    func activate() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord,
                                    mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            return true
        } catch {
            print("Unable to activate OneTake audio session: \(error)")
            return false
        }
    }
}

/// Owns the user-visible microphone and speech-recognition authorization flow.
/// Keeping this outside capture services prevents a camera/session lifecycle from
/// accidentally making permission prompts unreachable.
@Observable
final class VoiceAuthorizationService {
    static let shared = VoiceAuthorizationService()

    enum State: Equatable {
        case idle
        case requesting
        case authorized
        case microphoneDenied
        case speechDenied
    }

    private(set) var state: State = .idle
    private var pendingCompletions: [(Bool) -> Void] = []

    var isAuthorized: Bool { state == .authorized }

    func requestAccess(completion: @escaping (Bool) -> Void = { _ in }) {
        if state == .requesting {
            pendingCompletions.append(completion)
            return
        }

        if AVAudioApplication.shared.recordPermission == .granted,
           SFSpeechRecognizer.authorizationStatus() == .authorized {
            finish(.authorized, completion: completion)
            return
        }

        state = .requesting
        pendingCompletions.append(completion)

        requestMicrophone { [weak self] microphoneGranted in
            guard let self else { return }
            guard microphoneGranted else {
                self.finish(.microphoneDenied)
                return
            }

            let currentSpeechStatus = SFSpeechRecognizer.authorizationStatus()
            if currentSpeechStatus == .authorized {
                self.finish(.authorized)
                return
            }

            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.finish(status == .authorized ? .authorized : .speechDenied)
                }
            }
        }
    }

    private func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            completion(true)
        case .denied:
            completion(false)
        case .undetermined:
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        @unknown default:
            completion(false)
        }
    }

    private func finish(_ newState: State, completion: ((Bool) -> Void)? = nil) {
        state = newState
        let isAuthorized = newState == .authorized
        completion?(isAuthorized)
        let callbacks = pendingCompletions
        pendingCompletions.removeAll()
        callbacks.forEach { $0(isAuthorized) }
    }
}
