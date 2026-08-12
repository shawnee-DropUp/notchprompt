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
