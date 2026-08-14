//
//  TranscriptAlignerSelfTests.swift
//  notchprompt
//

import Foundation

enum TranscriptAlignerSelfTests {
    private static let scriptTokens: [String] = """
    welcome everybody to the quarterly product review today we are going to walk
    through three things first the growth numbers second the roadmap for next
    quarter and third the hiring plan let us start with growth we closed the
    quarter at four million in recurring revenue which is up thirty percent
    """.split(whereSeparator: { $0.isWhitespace }).map(String.init)

    @MainActor
    static func runLayoutChecks() {
        assertLookAheadCrossesParagraphBreak()
        assertLineEndDetection()
    }

    /// The scroll may only jump a spoken word out of view once that word ends
    /// its line; doing it mid-line would pull text away from the reader.
    @MainActor
    private static func assertLineEndDetection() {
        // Wide enough that each paragraph occupies exactly one line.
        let script = "alpha bravo charlie\n\ndelta echo foxtrot"
        let index = ScriptIndex.build(script: script, fontSize: 20, width: 4000)
        guard index.count == 6 else {
            assertionFailure("Expected 6 indexed words, got \(index.count)")
            return
        }

        assert(!PrompterModel.wordEndsLine(at: 0, in: index), "First word does not end its line")
        assert(!PrompterModel.wordEndsLine(at: 1, in: index), "Middle word does not end its line")
        assert(PrompterModel.wordEndsLine(at: 2, in: index), "'charlie' ends the first line")
        assert(!PrompterModel.wordEndsLine(at: 3, in: index), "'delta' does not end its line")
        assert(!PrompterModel.wordEndsLine(at: 5, in: index), "The final word has no following line")
    }

    /// The look-ahead must land on the next *line*, not the next word, or a
    /// paragraph break leaves the following text stranded below the fade.
    @MainActor
    private static func assertLookAheadCrossesParagraphBreak() {
        let script = "alpha bravo charlie\n\ndelta echo foxtrot"
        let index = ScriptIndex.build(script: script, fontSize: 20, width: 400)
        guard index.count >= 4 else {
            assertionFailure("Expected the sample script to index its words")
            return
        }

        let first = index.entries[0].relativeY
        let lookAhead = PrompterModel.nextLineRelativeY(after: 0, in: index)
        assert(lookAhead != nil, "Expected a next line to exist after the first word")
        assert((lookAhead ?? 0) > first, "Look-ahead must point past the current line")

        // Words sharing the first line must all resolve to the same next line.
        assert(PrompterModel.nextLineRelativeY(after: 1, in: index) == lookAhead,
               "Words on one line should share a look-ahead target")

        // The final word has nothing after it.
        assert(PrompterModel.nextLineRelativeY(after: index.count - 1, in: index) == nil,
               "The last word must report no look-ahead")
    }

    static func run() {
        assertExactTailMatches()
        assertToleratesMisrecognition()
        assertRejectsOffScriptSpeech()
        assertFindsForwardSkip()
        assertTracksFullReadMonotonically()
        assertSimilarityBounds()
    }

    private static func aligner() -> TranscriptAligner { TranscriptAligner() }

    private static func assertExactTailMatches() {
        let probe = ["walk", "through", "three", "things", "first"]
        let match = aligner().match(transcriptTokens: probe, scriptTokens: scriptTokens, currentIndex: 5)
        assert(match?.wordIndex == scriptTokens.firstIndex(of: "first"),
               "Expected an exact tail match to land on the last spoken word")
    }

    private static func assertToleratesMisrecognition() {
        // "tree" for "three" is a single-edit slip; the lock must survive it.
        let probe = ["walk", "through", "tree", "things", "first"]
        let match = aligner().match(transcriptTokens: probe, scriptTokens: scriptTokens, currentIndex: 5)
        assert(match?.wordIndex == scriptTokens.firstIndex(of: "first"),
               "Expected a single misrecognized word to be tolerated")
    }

    private static func assertRejectsOffScriptSpeech() {
        let probe = ["banana", "helicopter", "purple", "monday", "asparagus"]
        let match = aligner().match(transcriptTokens: probe, scriptTokens: scriptTokens, currentIndex: 10)
        assert(match == nil, "Expected off-script speech to produce no confident match")
    }

    private static func assertFindsForwardSkip() {
        let probe = ["recurring", "revenue", "which", "is", "up"]
        let match = aligner().match(transcriptTokens: probe, scriptTokens: scriptTokens, currentIndex: 3)
        assert(match?.wordIndex == scriptTokens.firstIndex(of: "up"),
               "Expected a forward skip within the look-ahead window to be found")
    }

    private static func assertTracksFullReadMonotonically() {
        let engine = aligner()
        var index = 0
        for end in 6..<scriptTokens.count {
            let probe = Array(scriptTokens[max(0, end - 4)...end])
            guard let match = engine.match(transcriptTokens: probe,
                                           scriptTokens: scriptTokens,
                                           currentIndex: index) else {
                assertionFailure("Lost the lock partway through a clean read at word \(end)")
                return
            }
            assert(match.wordIndex >= index, "Position went backwards during a clean forward read")
            index = match.wordIndex
        }
        assert(index == scriptTokens.count - 1, "Expected a clean read to reach the final word")
    }

    private static func assertSimilarityBounds() {
        assert(TranscriptAligner.similarity("growth", "growth") == 1.0,
               "Identical tokens must score 1.0")
        assert(TranscriptAligner.similarity("three", "tree") > 0.7,
               "Single-edit near-misses must earn partial credit")
        assert(TranscriptAligner.similarity("growth", "banana") == 0,
               "Unrelated tokens must score zero")
    }
}
