//
//  ScriptHints.swift
//  notchprompt
//
//  Picks the words worth telling the speech recogniser about in advance.
//

import Foundation

/// A teleprompter knows every word before it is spoken, which is an advantage
/// almost no speech app has. Feeding the recogniser the script's distinctive
/// terms biases it toward them, and those are precisely the words that break
/// the position lock when they are misheard: names, jargon, product names.
///
/// Common words are left out deliberately — the recogniser already handles them,
/// and the hint list is a limited budget better spent on the unusual ones.
enum ScriptHints {
    /// Apple treats this list as a hint, not a rule, and long lists dilute it.
    static let limit = 100

    private static let commonWords: Set<String> = [
        "about", "after", "again", "against", "already", "also", "always", "another",
        "because", "been", "before", "being", "below", "between", "both", "came",
        "come", "could", "does", "doing", "done", "down", "during", "each", "even",
        "every", "first", "from", "gets", "getting", "give", "going", "gone", "good",
        "have", "having", "here", "into", "just", "keep", "know", "last", "like",
        "little", "made", "make", "many", "more", "most", "much", "must", "need",
        "never", "next", "only", "other", "over", "part", "people", "place", "put",
        "really", "right", "said", "same", "should", "since", "some", "still",
        "such", "take", "than", "that", "their", "them", "then", "there", "these",
        "they", "thing", "think", "this", "those", "through", "time", "under",
        "until", "very", "want", "well", "went", "were", "what", "when", "where",
        "which", "while", "will", "with", "work", "would", "your",
        "anything", "everything", "nothing", "something", "someone", "anyone"
    ]

    /// Distinctive terms from the script, in order of first appearance.
    static func extract(from script: String, limit: Int = ScriptHints.limit) -> [String] {
        var seen = Set<String>()
        var hints: [String] = []

        script.enumerateSubstrings(in: script.startIndex..., options: [.byWords, .localized]) { substring, _, _, stop in
            // Numbers are short but survive recognition badly ("013"), so they
            // are held to a lower bar than words.
            guard let word = substring else { return }
            let hasDigits = word.contains(where: \.isNumber)
            guard word.count >= (hasDigits ? 2 : 4) else { return }

            let key = word.lowercased()
            guard !commonWords.contains(key), !seen.contains(key) else { return }
            guard isDistinctive(word) else { return }

            seen.insert(key)
            hints.append(word)
            if hints.count >= limit { stop = true }
        }
        return hints
    }

    /// Worth a hint when the recogniser is unlikely to guess it unaided.
    private static func isDistinctive(_ word: some StringProtocol) -> Bool {
        // Digits rarely survive recognition intact ("013", "2026").
        if word.contains(where: \.isNumber) { return true }
        // Internal capitals mark brands and identifiers ("DropUp", "PostHog").
        if word.dropFirst().contains(where: \.isUppercase) { return true }
        // A leading capital is usually a proper noun; sentence-initial words slip
        // through, but they are harmless and few.
        if word.first?.isUppercase == true { return true }
        // Long words are specialised often enough to be worth the slot. Seven
        // catches domain terms like "webhook" that eight would miss.
        return word.count >= 7
    }
}
