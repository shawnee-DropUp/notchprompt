//
//  TranscriptAligner.swift
//  notchprompt
//
//  Locates where in the script the speaker currently is, by matching the tail
//  of the live transcript against a window of script tokens.
//

import Foundation

struct TranscriptAligner {
    struct Match {
        /// Index into the script's token list of the most recently spoken word.
        let wordIndex: Int
        /// 0...1. Below `acceptanceThreshold` the caller should ignore this.
        let confidence: Double
    }

    /// How many trailing transcript words to match on. Long enough to be
    /// distinctive, short enough to stay responsive.
    var probeLength: Int = 5
    /// How far behind the current position to search (repeats, restarts).
    var lookBehind: Int = 12
    /// How far ahead to search (skipped lines, fast reading).
    var lookAhead: Int = 60
    /// Minimum confidence before a match is trusted at all.
    var acceptanceThreshold: Double = 0.55

    /// Confidence required to jump anywhere in the script, well above the
    /// ordinary bar: a re-sync can move the reader a long way, so it must be
    /// near-certain before it fires.
    var resyncThreshold: Double = 0.78
    /// How far the best whole-script candidate must beat any distant rival.
    /// Scripts repeat phrases ("thanks for coming in today"), and jumping to the
    /// wrong copy is worse than not jumping at all.
    var resyncMargin: Double = 0.12

    /// Searches the whole script, for when the reader has moved outside the
    /// local window entirely: skipping a section, answering out of order, or
    /// starting again from the top. Without this the position can never be
    /// recovered, because the windowed search can only ever look nearby.
    func matchAnywhere(transcriptTokens: [String], scriptTokens: [String]) -> Match? {
        guard !scriptTokens.isEmpty else { return nil }

        let probe = Array(transcriptTokens.suffix(probeLength))
        // A short probe is not distinctive enough to justify a long jump.
        guard probe.count >= probeLength else { return nil }

        var best: (index: Int, score: Double)?
        var runnerUp: Double = 0

        for end in scriptTokens.indices {
            let score = alignmentScore(probe: probe, scriptTokens: scriptTokens, endingAt: end)
            if score > (best?.score ?? 0) {
                // The previous best becomes the rival, unless it overlaps the new
                // one -- neighbouring positions score similarly and are not rivals.
                if let previous = best, abs(previous.index - end) > probe.count {
                    runnerUp = max(runnerUp, previous.score)
                }
                best = (end, score)
            } else if let current = best, abs(current.index - end) > probe.count {
                runnerUp = max(runnerUp, score)
            }
        }

        guard let best, best.score >= resyncThreshold,
              best.score - runnerUp >= resyncMargin else { return nil }
        return Match(wordIndex: best.index, confidence: best.score)
    }

    /// Finds the speaker's most likely position in `scriptTokens`.
    ///
    /// - Parameters:
    ///   - transcriptTokens: normalized tokens of what has been heard so far.
    ///   - scriptTokens: normalized tokens of the full script.
    ///   - currentIndex: last known position, used to centre the search window.
    /// - Returns: nil when nothing clears `acceptanceThreshold`.
    func match(transcriptTokens: [String],
               scriptTokens: [String],
               currentIndex: Int) -> Match? {
        guard !transcriptTokens.isEmpty, !scriptTokens.isEmpty else { return nil }

        let probe = Array(transcriptTokens.suffix(probeLength))
        guard !probe.isEmpty else { return nil }

        let lower = max(0, currentIndex - lookBehind)
        let upper = min(scriptTokens.count - 1, currentIndex + lookAhead)
        guard lower <= upper else { return nil }

        var best: Match?

        // `end` is the candidate script index the last probe word lands on.
        for end in lower...upper {
            let score = alignmentScore(probe: probe, scriptTokens: scriptTokens, endingAt: end)
            if score > (best?.confidence ?? 0) {
                best = Match(wordIndex: end, confidence: score)
            }
        }

        guard let best, best.confidence >= acceptanceThreshold else { return nil }
        return best
    }

    /// Weighted similarity of `probe` against the script slice ending at `end`.
    /// Recent words weigh more, so a stale word at the front cannot outvote the
    /// word actually being spoken right now.
    private func alignmentScore(probe: [String], scriptTokens: [String], endingAt end: Int) -> Double {
        var weighted = 0.0
        var totalWeight = 0.0

        for (offset, probeToken) in probe.enumerated().reversed() {
            // distance back from the newest probe word
            let stepsBack = probe.count - 1 - offset
            let scriptIndex = end - stepsBack
            let weight = Double(offset + 1)
            totalWeight += weight

            guard scriptIndex >= 0, scriptIndex < scriptTokens.count else { continue }
            weighted += weight * Self.similarity(probeToken, scriptTokens[scriptIndex])
        }

        guard totalWeight > 0 else { return 0 }
        return weighted / totalWeight
    }

    /// 1.0 exact, partial credit for near-misses, 0 for unrelated words.
    /// Speech recognizers routinely return "their" for "there" or drop plurals,
    /// so exact-only matching loses the position constantly.
    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1.0 }
        if a.isEmpty || b.isEmpty { return 0 }

        let maxLen = max(a.count, b.count)
        // Cheap reject: very different lengths are not recognizer confusions.
        if abs(a.count - b.count) > maxLen / 2 { return 0 }

        let distance = levenshtein(Array(a), Array(b))
        let ratio = 1.0 - (Double(distance) / Double(maxLen))
        // Only near-matches earn credit; loose matches are noise.
        return ratio >= 0.7 ? ratio : 0
    }

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1,        // deletion
                                 current[j - 1] + 1,     // insertion
                                 previous[j - 1] + cost) // substitution
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
