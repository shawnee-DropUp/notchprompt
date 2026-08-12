//
//  SpeechFollower.swift
//  notchprompt
//
//  Streams microphone audio through on-device speech recognition and publishes
//  the tail of what was heard, for TranscriptAligner to locate in the script.
//

import AVFoundation
import Foundation
import Speech

@MainActor
final class SpeechFollower: ObservableObject {
    enum Status: Equatable {
        case idle
        case starting
        case listening
        case unavailable(String)

        var isActive: Bool {
            switch self {
            case .listening, .starting: return true
            case .idle, .unavailable: return false
            }
        }
    }

    @Published private(set) var status: Status = .idle
    /// Normalized tail of the live transcript. Replaced wholesale on each update.
    @Published private(set) var transcriptTokens: [String] = []

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var restartTask: Task<Void, Never>?
    private var consecutiveFailures = 0
    private static let maxConsecutiveFailures = 3

    /// Recognition tasks have a bounded lifetime; cycle before hitting it so the
    /// follower never silently stops listening mid-script.
    private static let recycleInterval: TimeInterval = 50
    /// Only the tail matters for alignment, and this keeps tokenization O(1)
    /// instead of growing with session length.
    private static let transcriptTailCharacters = 220
    private static let keptTokens = 12
    private static let recognitionErrorDomain = "kLSRErrorDomain"
    private static let dictationDisabledCode = 201

    // MARK: - Lifecycle

    func start() async {
        guard !status.isActive else { return }
        consecutiveFailures = 0
        status = .starting

        guard await Self.requestSpeechAuthorization() else {
            status = .unavailable("Speech recognition permission denied. Enable it in System Settings › Privacy & Security › Speech Recognition.")
            return
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            status = .unavailable("Microphone permission denied. Enable it in System Settings › Privacy & Security › Microphone.")
            return
        }

        let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else {
            status = .unavailable("Speech recognition is unavailable for this language.")
            return
        }
        // Privacy Mode is a headline feature of this app; never stream audio to
        // Apple's servers as a silent fallback.
        guard recognizer.supportsOnDeviceRecognition else {
            status = .unavailable("On-device speech recognition isn't installed for this language, and Notchprompt won't send your audio off the device. Add the language in System Settings › Keyboard › Dictation.")
            return
        }
        self.recognizer = recognizer

        do {
            try beginSession()
            status = .listening
            scheduleRecycle()
        } catch {
            teardownAudio()
            status = .unavailable("Couldn't start the microphone: \(error.localizedDescription)")
        }
    }

    func stop() {
        restartTask?.cancel()
        restartTask = nil
        teardownAudio()
        transcriptTokens = []
        status = .idle
    }

    // MARK: - Audio plumbing

    private func beginSession() throws {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        // Bias the recognizer toward dictated prose rather than short commands.
        request.taskHint = .dictation
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw NSError(domain: "notchprompt.speech", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No usable audio input device."])
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }

        engine.prepare()
        try engine.start()

        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                self.handle(result: result, error: error)
            }
        }
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            consecutiveFailures = 0
            transcriptTokens = Self.tailTokens(from: result.bestTranscription.formattedString)
        }

        if let error {
            let nsError = error as NSError

            // macOS gates all speech recognition behind the Dictation switch,
            // even fully on-device. Retrying can never clear this, so say what
            // to do instead of looping.
            if nsError.domain == Self.recognitionErrorDomain,
               nsError.code == Self.dictationDisabledCode {
                teardownAudio()
                status = .unavailable("macOS Dictation is turned off, so speech recognition can't run. "
                                      + "Turn it on in System Settings › Keyboard › Dictation, then click the mic again.")
                return
            }

            consecutiveFailures += 1
            // Without this, a persistent failure restarts the engine in a tight
            // loop forever, burning CPU and never surfacing anything to the user.
            if consecutiveFailures >= Self.maxConsecutiveFailures {
                teardownAudio()
                status = .unavailable("Speech recognition kept failing: \(error.localizedDescription)")
                return
            }
        }

        guard error != nil || (result?.isFinal ?? false) else { return }
        // A finished or failed task means no further callbacks; restart so the
        // follower keeps tracking instead of freezing at the last match.
        guard status.isActive else { return }
        restartSession()
    }

    private func scheduleRecycle() {
        restartTask?.cancel()
        restartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.recycleInterval * 1_000_000_000))
            guard !Task.isCancelled, let self, self.status.isActive else { return }
            self.restartSession()
        }
    }

    private func restartSession() {
        teardownAudio()
        do {
            try beginSession()
            status = .listening
            scheduleRecycle()
        } catch {
            status = .unavailable("Microphone stopped: \(error.localizedDescription)")
        }
    }

    private func teardownAudio() {
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)
    }

    // MARK: - Helpers

    private static func tailTokens(from transcript: String) -> [String] {
        let tail = transcript.count > transcriptTailCharacters
            ? String(transcript.suffix(transcriptTailCharacters))
            : transcript
        var tokens = ScriptIndex.tokenize(tail)
        // The first token may be a word sliced in half by the suffix cut.
        if transcript.count > transcriptTailCharacters, !tokens.isEmpty {
            tokens.removeFirst()
        }
        return Array(tokens.suffix(keptTokens))
    }

    private static func requestSpeechAuthorization() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}
