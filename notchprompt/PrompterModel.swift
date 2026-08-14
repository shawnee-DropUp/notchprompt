//
//  PrompterModel.swift
//  notchprompt
//
//  Created by Saif on 2026-02-08.
//

import Foundation
import Combine
import CoreGraphics

@MainActor
final class PrompterModel: ObservableObject {
    enum ScrollMode: String, CaseIterable {
        case infinite
        case stopAtEnd
    }
    
    enum CountdownBehavior: String, CaseIterable {
        case always
        case freshStartOnly
        case never
        
        var label: String {
            switch self {
            case .always:
                return "Always"
            case .freshStartOnly:
                return "Fresh start only"
            case .never:
                return "Never"
            }
        }
    }

    static let shared = PrompterModel()

    @Published var script: String = """
Paste your script here.

Tip: Use the menu bar icon to start/pause or reset the scroll.
"""

    @Published var isRunning: Bool = false
    @Published var manualScrollEnabled: Bool = false
    @Published var isOverlayVisible: Bool = true
    @Published var privacyModeEnabled: Bool = true
    @Published private(set) var hasStartedSession: Bool = false
    @Published private(set) var isCountingDown: Bool = false
    @Published var countdownSeconds: Int = 3
    @Published var countdownBehavior: CountdownBehavior = .freshStartOnly
    @Published private(set) var countdownRemaining: Int = 0
    @Published private(set) var didReachEndInStopMode: Bool = false

    // Visual / behavior tuning
    @Published var speedPointsPerSecond: Double = 80
    @Published var fontSize: Double = 20
    @Published var overlayWidth: Double = 600
    @Published var overlayHeight: Double = 150
    // Deprecated user setting: keep as a fixed constant unless changed explicitly in code.
    @Published var backgroundOpacity: Double = 1.0
    @Published var scrollMode: ScrollMode = .stopAtEnd
    /// 0 means "auto" (prefer built-in display)
    @Published var selectedScreenID: CGDirectDisplayID = 0
    /// Bare arrow keys drive speed and reset globally. This takes the arrow keys
    /// away from every other app while Notchprompt runs, so it must be escapable.
    @Published var captureArrowKeys: Bool = true
    // Fraction of the viewport height to fade at top and bottom.
    let edgeFadeFraction: Double = 0.20

    // MARK: Voice follow
    @Published private(set) var voiceFollowEnabled: Bool = false
    /// Non-nil when voice follow can't run; surfaced to the user.
    @Published private(set) var voiceStatusMessage: String?
    /// True while the aligner is confidently locked onto the script.
    @Published private(set) var voiceIsTracking: Bool = false
    /// Target position as a fraction of content height, so the view can rescale
    /// it against the height SwiftUI actually laid out.
    @Published private(set) var voiceTargetRelativeY: CGFloat?
    /// Character range of the word being spoken, for live highlighting.
    @Published private(set) var voiceHighlightRange: NSRange?
    /// Position of the next line of text after the spoken word. The scroll keeps
    /// this line readable, otherwise reading deadlocks: the view only advances on
    /// words you speak, so text you cannot see is text you can never reach.
    @Published private(set) var voiceLookAheadRelativeY: CGFloat?
    /// True when the spoken word is the last one on its line. Only then is it
    /// safe to scroll it away in favour of what comes next.
    @Published private(set) var voiceCurrentWordEndsLine: Bool = false
    /// When the last confident match happened, so the view can tell a pause from
    /// a genuine loss of the lock.
    @Published private(set) var voiceLastMatchAt: Date?
    /// Measured reading pace in relative-height units per second, used to keep
    /// creeping forward while off-script instead of stalling outright.
    @Published private(set) var voiceRecoveryPace: CGFloat?

    private let speechFollower = SpeechFollower()
    private let aligner = TranscriptAligner()
    private var scriptIndex: ScriptIndex = .empty
    private var scriptTokens: [String] = []
    private var currentWordIndex: Int = 0
    private var lastConfidentMatch: Date?
    /// Recent (time, position) matches, for estimating reading pace.
    private var paceSamples: [(at: Date, relativeY: CGFloat)] = []
    private var voiceCancellables = Set<AnyCancellable>()
    private var layoutWidth: CGFloat = 0

    /// Backward jumps need more evidence than forward ones — a repeated word
    /// shouldn't yank the script backwards mid-sentence.
    private static let backwardJumpConfidence: Double = 0.8
    /// Hold position if the speaker goes off-script or falls silent this long.
    private static let trackingTimeout: TimeInterval = 2.5
    /// Ceiling on inferred pace, as a fraction of the script per second.
    private static let maximumRecoveryPace: CGFloat = 0.05
    /// Quiet period after which the local window is presumed wrong and the whole
    /// script is searched. Long enough that ordinary pauses do not trigger it.
    private static let resyncDelay: TimeInterval = 5.0

    /// Signals AppDelegate to open Settings. Routed through the model because
    /// SwiftUI's delegate adaptor wraps AppDelegate in its own class, so views
    /// cannot reach it by casting NSApp.delegate.
    @Published private(set) var openSettingsToken: UUID = UUID()

    // Used to signal an immediate reset to the scrolling view.
    @Published private(set) var resetToken: UUID = UUID()
    @Published private(set) var jumpBackToken: UUID = UUID()
    @Published private(set) var jumpBackDistancePoints: CGFloat = 0
    @Published private(set) var manualScrollToken: UUID = UUID()
    @Published private(set) var manualScrollDeltaPoints: CGFloat = 0
    private(set) var savedScrollPhaseForResume: CGFloat?

    private var countdownTask: Task<Void, Never>?
    private var shouldUseCountdownOnNextStart: Bool = true

    static let speedRange: ClosedRange<Double> = 10...300
    static let speedStep: Double = 5
    static let speedPresetSlow: Double = 55
    static let speedPresetNormal: Double = 85
    static let speedPresetFast: Double = 125

    private enum DefaultsKey {
        static let hasSavedSession = "hasSavedSession"
        static let script = "script"
        static let isRunning = "isRunning"
        static let isOverlayVisible = "isOverlayVisible"
        static let privacyModeEnabled = "privacyModeEnabled"
        static let speed = "speedPointsPerSecond"
        static let fontSize = "fontSize"
        static let overlayWidth = "overlayWidth"
        static let overlayHeight = "overlayHeight"
        static let countdownSeconds = "countdownSeconds"
        static let countdownBehavior = "countdownBehavior"
        static let scrollMode = "scrollMode"
        static let selectedScreenID = "selectedScreenID"
        static let captureArrowKeys = "captureArrowKeys"
        static let didMigrateToSinglePass = "didMigrateToSinglePass"
    }

    private init() {}

    deinit {
        countdownTask?.cancel()
    }

    func pasteScript(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        script = text
        // Always reveal the new script. Previously this only fired when the old
        // script was empty, so pasting over existing text left the overlay stuck
        // on "Ready to prompt" and the paste looked like it had failed.
        hasStartedSession = true
    }

    /// Live edits from the Settings script box.
    func updateScript(_ text: String) {
        script = text
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            hasStartedSession = true
        }
    }

    func resetScroll() {
        didReachEndInStopMode = false
        shouldUseCountdownOnNextStart = true
        savedScrollPhaseForResume = nil
        currentWordIndex = 0
        voiceTargetRelativeY = nil
        voiceHighlightRange = nil
        voiceLookAheadRelativeY = nil
        voiceCurrentWordEndsLine = false
        voiceIsTracking = false
        lastConfidentMatch = nil
        voiceLastMatchAt = nil
        voiceRecoveryPace = nil
        paceSamples.removeAll()
        resetToken = UUID()
    }

    func saveScrollPhaseForResume(_ phase: CGFloat) {
        savedScrollPhaseForResume = phase
    }

    func jumpBack(seconds: Double = 5) {
        guard seconds > 0 else { return }
        didReachEndInStopMode = false
        jumpBackDistancePoints = CGFloat(speedPointsPerSecond * seconds)
        jumpBackToken = UUID()
    }

    func switchPlaybackModeFromOverlayControl() {
        if isRunning || isCountingDown {
            stop()
            manualScrollEnabled = true
            didReachEndInStopMode = false
            hasStartedSession = true
            shouldUseCountdownOnNextStart = false
            return
        }

        manualScrollEnabled = false
        start()
    }

    func handleManualScroll(deltaPoints: CGFloat) {
        guard abs(deltaPoints) > 0.01 else { return }

        if !manualScrollEnabled {
            manualScrollEnabled = true
        }

        if isRunning || isCountingDown {
            stop()
        }

        didReachEndInStopMode = false
        hasStartedSession = true
        shouldUseCountdownOnNextStart = false
        manualScrollDeltaPoints = deltaPoints
        manualScrollToken = UUID()
    }

    func toggleRunning() {
        if isRunning || isCountingDown {
            stop()
        } else {
            start()
        }
    }

    func start() {
        if isRunning || isCountingDown {
            return
        }

        manualScrollEnabled = false

        if scrollMode == .stopAtEnd, didReachEndInStopMode {
            // Keyboard "start" from end should restart from the top without requiring manual reset.
            resetScroll()
        }

        let delay = max(0, countdownSeconds)
        let shouldRunCountdown: Bool
        switch countdownBehavior {
        case .always:
            shouldRunCountdown = delay > 0
        case .freshStartOnly:
            shouldRunCountdown = delay > 0 && shouldUseCountdownOnNextStart
        case .never:
            shouldRunCountdown = false
        }
        
        guard shouldRunCountdown else {
            beginRunningNow()
            return
        }
        
        beginCountdown(seconds: delay)
    }

    func markReachedEndInStopMode() {
        guard scrollMode == .stopAtEnd else { return }
        didReachEndInStopMode = true
        stop()
    }

    func setScrollMode(_ newMode: ScrollMode) {
        // Entire transition is deferred to avoid publishing inside SwiftUI view updates.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let oldMode = self.scrollMode
            guard oldMode != newMode else { return }
            let wasTerminalStopState = (oldMode == .stopAtEnd && self.didReachEndInStopMode)

            self.scrollMode = newMode

            if newMode == .infinite {
                self.didReachEndInStopMode = false
                if wasTerminalStopState {
                    self.hasStartedSession = true
                    self.isCountingDown = false
                    self.countdownRemaining = 0
                    self.countdownTask?.cancel()
                    self.countdownTask = nil
                    self.shouldUseCountdownOnNextStart = false
                    self.isRunning = true
                }
            }
        }
    }

    func stop() {
        countdownTask?.cancel()
        countdownTask = nil
        isCountingDown = false
        countdownRemaining = 0
        isRunning = false
        if voiceFollowEnabled {
            setVoiceFollow(false)
        }
    }

    // MARK: - Voice follow

    func toggleVoiceFollow() {
        setVoiceFollow(!voiceFollowEnabled)
    }

    func clearVoiceStatusMessage() {
        voiceStatusMessage = nil
    }

    func requestOpenSettings() {
        openSettingsToken = UUID()
    }

    func setVoiceFollow(_ enabled: Bool) {
        guard enabled != voiceFollowEnabled else { return }

        if enabled {
            guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                voiceStatusMessage = "Paste a script before starting voice follow."
                return
            }
            voiceFollowEnabled = true
            voiceStatusMessage = nil
            voiceIsTracking = false
            voiceTargetRelativeY = nil
            voiceHighlightRange = nil
            voiceLookAheadRelativeY = nil
            voiceCurrentWordEndsLine = false
            currentWordIndex = 0
            lastConfidentMatch = nil
            voiceLastMatchAt = nil
            voiceRecoveryPace = nil
            paceSamples.removeAll()

            // Voice follow is its own transport: no countdown, and the timed
            // scroll must not fight the control loop for the same phase value.
            manualScrollEnabled = false
            didReachEndInStopMode = false
            hasStartedSession = true
            isRunning = true

            rebuildScriptIndexIfNeeded()
            speechFollower.contextualHints = ScriptHints.extract(from: script)
            observeSpeechFollower()
            Task { await speechFollower.start() }
        } else {
            voiceFollowEnabled = false
            voiceIsTracking = false
            voiceTargetRelativeY = nil
            voiceCancellables.removeAll()
            speechFollower.stop()
        }
    }

    /// The scrolling view reports the width it actually laid text out at, so the
    /// index is built against identical geometry.
    func reportLayoutWidth(_ width: CGFloat) {
        guard width > 1, abs(width - layoutWidth) > 1 else { return }
        layoutWidth = width
        rebuildScriptIndexIfNeeded()
    }

    private func rebuildScriptIndexIfNeeded() {
        guard voiceFollowEnabled, layoutWidth > 1 else { return }
        guard scriptIndex.isStale(script: script, fontSize: fontSize, width: layoutWidth) else { return }

        scriptIndex = ScriptIndex.build(script: script, fontSize: fontSize, width: layoutWidth)
        scriptTokens = scriptIndex.entries.map(\.token)
        speechFollower.contextualHints = ScriptHints.extract(from: script)
        currentWordIndex = min(currentWordIndex, max(0, scriptTokens.count - 1))
    }

    private func observeSpeechFollower() {
        voiceCancellables.removeAll()

        speechFollower.$transcriptTokens
            .receive(on: RunLoop.main)
            .sink { [weak self] tokens in
                self?.handleTranscript(tokens)
            }
            .store(in: &voiceCancellables)

        speechFollower.$status
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                guard let self else { return }
                if case .unavailable(let reason) = status {
                    self.voiceStatusMessage = reason
                    self.setVoiceFollow(false)
                }
            }
            .store(in: &voiceCancellables)
    }

    private func handleTranscript(_ tokens: [String]) {
        guard voiceFollowEnabled, !tokens.isEmpty else { return }
        rebuildScriptIndexIfNeeded()
        guard !scriptTokens.isEmpty else { return }

        guard let match = aligner.match(transcriptTokens: tokens,
                                        scriptTokens: scriptTokens,
                                        currentIndex: currentWordIndex) else {
            attemptResync(with: tokens)
            return
        }

        let isBackward = match.wordIndex < currentWordIndex
        if isBackward && match.confidence < Self.backwardJumpConfidence {
            expireTrackingIfStale()
            return
        }

        apply(matchAt: match.wordIndex)
    }

    /// Vertical position of the first word that sits on a later line than the
    /// word at `index`. Across a paragraph break this is the next paragraph's
    /// opening line, which is exactly the text that would otherwise be stranded
    /// below the fade. Returns nil on the final line.
    static func nextLineRelativeY(after index: Int, in scriptIndex: ScriptIndex) -> CGFloat? {
        guard scriptIndex.entries.indices.contains(index) else { return nil }
        let currentY = scriptIndex.entries[index].relativeY
        let next = index + 1
        guard next < scriptIndex.entries.count else { return nil }

        // Fractions of total height, so the epsilon guards float noise only.
        return scriptIndex.entries[next...].first { $0.relativeY > currentY + 0.0001 }?.relativeY
    }

    /// Whether the next word starts a new line, meaning this word closes one.
    static func wordEndsLine(at index: Int, in scriptIndex: ScriptIndex) -> Bool {
        let entries = scriptIndex.entries
        guard entries.indices.contains(index), index + 1 < entries.count else { return false }
        return entries[index + 1].relativeY > entries[index].relativeY + 0.0001
    }

    /// Pace over the recent window, ignoring samples too close together to be
    /// meaningful. Clamped so one bad match cannot imply a wild reading speed.
    private func recordPaceSample(at date: Date, relativeY: CGFloat) {
        paceSamples.append((date, relativeY))
        if paceSamples.count > 8 { paceSamples.removeFirst(paceSamples.count - 8) }

        guard let first = paceSamples.first, let last = paceSamples.last else { return }
        let elapsed = last.at.timeIntervalSince(first.at)
        let advanced = last.relativeY - first.relativeY
        guard elapsed > 1.0, advanced > 0 else { return }

        let pace = advanced / CGFloat(elapsed)
        voiceRecoveryPace = min(pace, Self.maximumRecoveryPace)
    }

    /// The windowed search only ever looks near the last known position, so
    /// jumping elsewhere -- skipping ahead, answering questions out of order,
    /// starting over -- leaves it permanently unable to find the reader. After a
    /// quiet spell, search the whole script instead.
    private func attemptResync(with tokens: [String]) {
        guard let last = lastConfidentMatch,
              Date().timeIntervalSince(last) > Self.resyncDelay,
              let resync = aligner.matchAnywhere(transcriptTokens: tokens,
                                                 scriptTokens: scriptTokens) else {
            expireTrackingIfStale()
            return
        }

        // A re-sync is deliberately allowed to move backwards; restarting from
        // the top is one of the cases this exists to handle.
        apply(matchAt: resync.wordIndex)
    }

    private func apply(matchAt index: Int) {
        guard scriptIndex.entries.indices.contains(index) else { return }
        let entry = scriptIndex.entries[index]

        currentWordIndex = index
        let now = Date()
        lastConfidentMatch = now
        voiceLastMatchAt = now
        recordPaceSample(at: now, relativeY: entry.relativeY)
        voiceIsTracking = true
        voiceTargetRelativeY = entry.relativeY
        voiceHighlightRange = entry.range
        voiceLookAheadRelativeY = Self.nextLineRelativeY(after: index, in: scriptIndex)
        voiceCurrentWordEndsLine = Self.wordEndsLine(at: index, in: scriptIndex)
    }

    private func expireTrackingIfStale() {
        guard let last = lastConfidentMatch else { return }
        if Date().timeIntervalSince(last) > Self.trackingTimeout {
            voiceIsTracking = false
        }
    }

    func setSpeed(_ value: Double) {
        speedPointsPerSecond = clampedSpeed(value)
    }

    func adjustSpeed(delta: Double) {
        let newValue = speedPointsPerSecond + delta
        setSpeed(newValue)
    }

    func applySpeedPreset(_ preset: Double) {
        setSpeed(preset)
    }

    var estimatedReadDuration: TimeInterval {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        let words = max(1, trimmed.split(whereSeparator: \.isWhitespace).count)
        // Approximation: 160 words/minute baseline adjusted by current speed.
        let baselineWPM = 160.0
        let speedFactor = speedPointsPerSecond / Self.speedPresetNormal
        let adjustedWPM = max(60, baselineWPM * speedFactor)
        let minutes = Double(words) / adjustedWPM
        return minutes * 60
    }

    func formattedEstimatedReadDuration() -> String {
        let duration = Int(round(estimatedReadDuration))
        guard duration > 0 else { return "~0s" }
        if duration < 60 {
            return "~\(duration)s"
        }
        let minutes = duration / 60
        let seconds = duration % 60
        return String(format: "~%dm %02ds", minutes, seconds)
    }

    func loadFromDefaults() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: DefaultsKey.hasSavedSession) else {
            return
        }

        if let savedScript = defaults.string(forKey: DefaultsKey.script) {
            script = savedScript
        }

        privacyModeEnabled = defaults.object(forKey: DefaultsKey.privacyModeEnabled) as? Bool ?? privacyModeEnabled
        isOverlayVisible = defaults.object(forKey: DefaultsKey.isOverlayVisible) as? Bool ?? true
        // Never auto-start on launch; require explicit user start each session.
        isRunning = false
        isCountingDown = false
        countdownRemaining = 0
        hasStartedSession = false
        shouldUseCountdownOnNextStart = true
        speedPointsPerSecond = clampedSpeed(defaults.object(forKey: DefaultsKey.speed) as? Double ?? speedPointsPerSecond)
        fontSize = clamp(defaults.object(forKey: DefaultsKey.fontSize) as? Double ?? fontSize, lower: 12, upper: 40)
        overlayWidth = clamp(defaults.object(forKey: DefaultsKey.overlayWidth) as? Double ?? overlayWidth, lower: 400, upper: 1200)
        overlayHeight = clamp(defaults.object(forKey: DefaultsKey.overlayHeight) as? Double ?? overlayHeight, lower: 120, upper: 300)
        // Opacity UI has been removed; always render fully opaque by default.
        backgroundOpacity = 1.0
        defaults.removeObject(forKey: "backgroundOpacity")
        countdownSeconds = Int(clamp(Double(defaults.object(forKey: DefaultsKey.countdownSeconds) as? Int ?? countdownSeconds), lower: 0, upper: 10))
        if let rawValue = defaults.string(forKey: DefaultsKey.countdownBehavior),
           let savedBehavior = CountdownBehavior(rawValue: rawValue) {
            countdownBehavior = savedBehavior
        } else {
            countdownBehavior = .freshStartOnly
        }
        if let rawValue = defaults.string(forKey: DefaultsKey.scrollMode),
           let savedMode = ScrollMode(rawValue: rawValue) {
            scrollMode = savedMode
        } else {
            scrollMode = .stopAtEnd
        }

        // One-time migration: looping was the old default and reads as a bug
        // ("my script repeats forever"), so move existing sessions to one pass.
        if !defaults.bool(forKey: DefaultsKey.didMigrateToSinglePass) {
            scrollMode = .stopAtEnd
            defaults.set(true, forKey: DefaultsKey.didMigrateToSinglePass)
        }
        selectedScreenID = CGDirectDisplayID(defaults.object(forKey: DefaultsKey.selectedScreenID) as? UInt32 ?? 0)
        captureArrowKeys = defaults.object(forKey: DefaultsKey.captureArrowKeys) as? Bool ?? true
    }

    func saveToDefaults() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: DefaultsKey.hasSavedSession)
        defaults.set(script, forKey: DefaultsKey.script)
        defaults.set(isRunning, forKey: DefaultsKey.isRunning)
        defaults.set(isOverlayVisible, forKey: DefaultsKey.isOverlayVisible)
        defaults.set(privacyModeEnabled, forKey: DefaultsKey.privacyModeEnabled)
        defaults.set(speedPointsPerSecond, forKey: DefaultsKey.speed)
        defaults.set(fontSize, forKey: DefaultsKey.fontSize)
        defaults.set(overlayWidth, forKey: DefaultsKey.overlayWidth)
        defaults.set(overlayHeight, forKey: DefaultsKey.overlayHeight)
        defaults.set(countdownSeconds, forKey: DefaultsKey.countdownSeconds)
        defaults.set(countdownBehavior.rawValue, forKey: DefaultsKey.countdownBehavior)
        defaults.set(scrollMode.rawValue, forKey: DefaultsKey.scrollMode)
        defaults.set(selectedScreenID, forKey: DefaultsKey.selectedScreenID)
        defaults.set(captureArrowKeys, forKey: DefaultsKey.captureArrowKeys)
    }

    private func beginCountdown(seconds: Int) {
        countdownTask?.cancel()
        isCountingDown = true
        countdownRemaining = seconds

        countdownTask = Task { @MainActor in
            var remaining = seconds
            while remaining > 0 {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    isCountingDown = false
                    countdownRemaining = 0
                    countdownTask = nil
                    return
                }
                remaining -= 1
                countdownRemaining = remaining
            }

            guard !Task.isCancelled else { return }
            beginRunningNow()
            countdownTask = nil
        }
    }
    
    private func beginRunningNow() {
        isCountingDown = false
        countdownRemaining = 0
        hasStartedSession = true
        shouldUseCountdownOnNextStart = false
        isRunning = true
    }

    private func clampedSpeed(_ value: Double) -> Double {
        let clamped = clamp(value, lower: Self.speedRange.lowerBound, upper: Self.speedRange.upperBound)
        let step = Self.speedStep
        return (clamped / step).rounded() * step
    }

    private func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        min(max(value, lower), upper)
    }
}
