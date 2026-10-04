import Foundation
import SwiftUI
import StrandDesign
#if canImport(UIKit)
import UIKit
import Speech
#endif

/// K4: On-device speech-to-text wrapper for the Coach composer (iOS only).
///
/// Design contract (see PRD-K4):
/// - **No raw audio egress.** Recognition is requested with `requiresOnDeviceRecognition = true`
///   wherever the locale supports it. If a locale ONLY supports server recognition, voice is
///   **disabled** for that locale rather than falling back to server transcription — server
///   transcription would ship audio off-device, breaking the offline posture.
/// - The microphone button lives in the shared `CoachView` composer; on macOS this type is a
///   no-op (`isSupported` is `false`, all methods are inert) so the shared file keeps compiling.
/// - Only the resulting TEXT ever reaches the provider, via the same channel a typed question
///   already uses. No new network path is introduced.
///
/// Usage from `CoachView`:
/// 1. `voice.isSupported` gates whether the mic button is shown at all.
/// 2. `voice.authorizationStatus` drives the button's enabled / "open Settings" state.
/// 3. `voice.startTranscribing(partial:)` begins a session; `partial` is called on the main
///    actor with the live transcript.
/// 4. `voice.stopTranscribing(completion:)` finalizes and returns the final text.
@MainActor
final class CoachVoiceInput: ObservableObject {

    /// Whether voice input is available on this device + locale at all.
    static var isSupported: Bool {
        #if canImport(UIKit)
        return SFSpeechRecognizer.authorizationStatus() != .restricted
            && SFSpeechRecognizer.self != nil
            && SFSpeechRecognizer(locale: Locale.current) != nil
        #else
        return false
        #endif
    }

    #if canImport(UIKit)
    /// Current Speech framework authorization status, mapped to a simple enum the UI can switch on.
    var authorization: AuthorizationState {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .unavailable
        case .notDetermined: return .notDetermined
        @unknown default: return .unavailable
        }
    }
    #else
    var authorization: AuthorizationState { .unavailable }
    #endif

    /// Whether a recognition session is currently recording.
    @Published private(set) var isRecording: Bool = false

    /// The latest partial transcript (live, while recording).
    @Published var partialTranscript: String = ""

    /// A short human-readable status for the disabled-state tooltip (e.g. "On-device speech not
    /// available for en-GB"). `nil` when voice is fully available.
    @Published var statusMessage: String?

    /// On-device support for the current locale. If `false`, voice is disabled rather than
    /// falling back to server recognition (which would be raw-audio egress).
    private static var localeSupportsOnDevice: Bool {
        #if canImport(UIKit)
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) else { return false }
        return recognizer.supportsOnDeviceRecognition
        #else
        return false
        #endif
    }

    /// True when voice can be used right now: supported, authorized, and locale supports on-device.
    var canUseVoice: Bool {
        guard Self.isSupported, authorization == .authorized, Self.localeSupportsOnDevice else {
            return false
        }
        return true
    }

    /// Request Speech + Microphone authorization. Safe to call repeatedly; the system no-ops if
    /// already decided. `completion` fires on the main actor.
    func requestAuthorization(completion: @escaping (AuthorizationState) -> Void) {
        #if canImport(UIKit)
        // Speech auth first; mic auth piggybacks on the same prompt flow but is a separate grant.
        SFSpeechRecognizer.requestAuthorization { speechStatus in
            Task { @MainActor in
                if speechStatus != .authorized {
                    completion(self.mapSpeech(speechStatus))
                    return
                }
                // Mic permission is requested lazily by AVAudioEngine on iOS — but we ask up front
                // so the user sees one consolidated prompt and the button state is correct before
                // the first tap.
                self.requestMicPermission { micGranted in
                    completion(micGranted ? .authorized : .denied)
                }
            }
        }
        #else
        completion(.unavailable)
        #endif
    }

    /// Begin a recognition session. `partial` is invoked on the main actor with the live transcript
    /// as it streams in. No-op (calls `partial` with "") on macOS / unsupported locales.
    func startTranscribing(partial: @escaping (String) -> Void) {
        #if canImport(UIKit)
        guard canUseVoice else {
            statusMessage = Self.localeSupportsOnDevice
                ? String(localized: "Voice input unavailable. Check microphone permission in Settings.")
                : String(localized: "On-device speech not available for \(Locale.current.identifier).")
            return
        }
        stopTranscribing(completion: { _ in })
        partialTranscript = ""
        statusMessage = nil
        beginSession(partial: partial)
        #else
        partial("")
        #endif
    }

    /// Stop the active session and return the finalized transcript via `completion` (main actor).
    func stopTranscribing(completion: @escaping (String) -> Void) {
        #if canImport(UIKit)
        guard isRecording else {
            completion(partialTranscript)
            return
        }
        finishSession(completion: completion)
        #else
        completion("")
        #endif
    }

    // MARK: - Private (iOS only)

    #if canImport(UIKit)
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    private func mapSpeech(_ status: SFSpeechRecognizerAuthorizationStatus) -> AuthorizationState {
        switch status {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .unavailable
        case .notDetermined: return .notDetermined
        @unknown default: return .unavailable
        }
    }

    private func requestMicPermission(completion: @escaping (Bool) -> Void) {
        let session = AVAudioSession.sharedInstance()
        session.requestRecordPermission { granted in
            Task { @MainActor in completion(granted) }
        }
    }

    private func beginSession(partial: @escaping (String) -> Void) {
        let audioEngine = AVAudioEngine()
        self.audioEngine = audioEngine

        let request = SFSpeechAudioBufferRecognitionRequest()
        // K4 hard constraint: on-device ONLY. If the locale doesn't support it, voice is disabled
        // upstream — but we set the flag defensively here too so a regression can't slip audio out.
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        self.recognitionRequest = request

        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) else {
            statusMessage = String(localized: "On-device speech not available for \(Locale.current.identifier).")
            return
        }

        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    self.partialTranscript = text
                    partial(text)
                }
                if error != nil || (result?.isFinal ?? false) {
                    self.finishSession(completion: { _ in })
                }
            }
        }
        self.recognitionTask = task

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                request.append(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
        } catch {
            statusMessage = String(localized: "Couldn't start the microphone: \(error.localizedDescription)")
            finishSession(completion: { _ in })
        }
    }

    private func finishSession(completion: @escaping (String) -> Void) {
        if let audioEngine {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
            self.audioEngine = nil
        }
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )
        let final = partialTranscript
        isRecording = false
        completion(final)
    }
    #endif

    /// Simplified authorization state the UI switches on (decoupled from SFSpeech symbols on macOS).
    enum AuthorizationState {
        case notDetermined
        case authorized
        case denied
        case unavailable
    }
}

/// The v2 composer mic: starts/stops on-device speech recognition into `draft`. Disabled when the
/// locale lacks on-device support or permission is denied; tapping when permission is not yet
/// determined triggers the system prompt. Shared by the Coach composer and the Quick ask sheet.
struct CoachMicButton: View {
    @Binding var draft: String
    /// The caller's own reason to refuse input (a reply in flight).
    var disabled: Bool = false
    @StateObject private var voiceInput = CoachVoiceInput()

    var body: some View {
        Button(action: toggleVoice) {
            Group {
                if voiceInput.isRecording {
                    PhIcon("stop-circle", weight: .fill, size: 22)
                        .foregroundStyle(NoopGlow.low.tint)
                } else {
                    PhIcon("microphone", size: 20)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .opacity(voiceInput.canUseVoice ? 0.7 : 0.35)
                }
            }
            .frame(width: 30, height: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(voiceInput.statusMessage ?? "Ask out loud")
        .accessibilityLabel(voiceInput.isRecording ? "Stop voice input" : "Voice input")
        .accessibilityHint(voiceInput.statusMessage ?? "Transcribes your question on-device")
        .task {
            // Pre-check on appear so the button reflects the right state without a tap.
            if voiceInput.authorization == .notDetermined {
                voiceInput.requestAuthorization { _ in }
            }
        }
    }

    /// Tappable only if voice is either already usable or permission hasn't been asked yet (the first
    /// tap triggers the prompt).
    private var enabled: Bool {
        !disabled && (voiceInput.canUseVoice || voiceInput.authorization == .notDetermined)
    }

    private func toggleVoice() {
        if voiceInput.isRecording {
            voiceInput.stopTranscribing { finalText in
                let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    // Append to the draft (not replace) so a user can speak into existing text.
                    draft = draft.isEmpty ? trimmed : "\(draft) \(trimmed)"
                }
            }
        } else if voiceInput.authorization == .notDetermined {
            // First tap with undetermined permission triggers the system prompt; if granted, start
            // transcribing straight away.
            voiceInput.requestAuthorization { state in
                if state == .authorized {
                    voiceInput.startTranscribing { partial in draft = partial }
                }
            }
        } else {
            voiceInput.startTranscribing { partial in draft = partial }
        }
    }
}
