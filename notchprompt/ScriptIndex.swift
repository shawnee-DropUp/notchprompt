//
//  ScriptIndex.swift
//  notchprompt
//
//  Maps word positions in the script to vertical scroll offsets, so voice
//  following can translate "you are reading word N" into "scroll to phase Y".
//

import AppKit

/// A precomputed map from word index -> vertical position within the script.
///
/// Positions are stored as a *fraction* of total laid-out height rather than
/// absolute points. The scrolling view measures its own content height through
/// SwiftUI, and SwiftUI's text layout can differ slightly from TextKit's. Storing
/// fractions lets the caller rescale against whatever height SwiftUI actually
/// produced, so small layout disagreements cannot accumulate into drift.
struct ScriptIndex {
    struct Entry {
        /// Normalized token used for transcript matching.
        let token: String
        /// Vertical position of this word's line, as a fraction of total height.
        let relativeY: CGFloat
        /// Character range in the source script, for live highlighting.
        let range: NSRange
    }

    let entries: [Entry]
    /// Layout inputs this index was built for, used to detect staleness.
    let fontSize: CGFloat
    let width: CGFloat
    let scriptHash: Int

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }

    static let empty = ScriptIndex(entries: [], fontSize: 0, width: 0, scriptHash: 0)

    /// Absolute scroll phase for a word, rescaled to the caller's measured height.
    func phase(forWordAt index: Int, contentHeight: CGFloat) -> CGFloat? {
        guard entries.indices.contains(index) else { return nil }
        return entries[index].relativeY * contentHeight
    }

    func isStale(script: String, fontSize: CGFloat, width: CGFloat) -> Bool {
        scriptHash != script.hashValue
            || abs(self.fontSize - fontSize) > 0.5
            || abs(self.width - width) > 1.0
    }

    // MARK: - Building

    static func build(script: String, fontSize: CGFloat, width: CGFloat) -> ScriptIndex {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, width > 1, fontSize > 1 else { return .empty }

        // Must mirror ScrollingTextView.scrollingContent exactly.
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let attributed = NSAttributedString(string: script, attributes: [.font: font])

        let storage = NSTextStorage(attributedString: attributed)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)

        let totalHeight = layout.usedRect(for: container).height
        guard totalHeight > 1 else { return .empty }

        let nsScript = script as NSString
        var entries: [Entry] = []
        entries.reserveCapacity(script.count / 5)

        // Cache line tops so we do one layout query per line, not per word.
        var cachedLineRange = NSRange(location: NSNotFound, length: 0)
        var cachedLineTop: CGFloat = 0

        script.enumerateSubstrings(in: script.startIndex..., options: [.byWords, .localized]) { substring, range, _, _ in
            guard let substring, let token = normalize(substring) else { return }

            let nsRange = NSRange(range, in: script)
            guard nsRange.location < nsScript.length else { return }

            let glyphRange = layout.glyphRange(forCharacterRange: nsRange, actualCharacterRange: nil)
            guard glyphRange.location != NSNotFound else { return }

            let lineTop: CGFloat
            if cachedLineRange.location != NSNotFound,
               NSLocationInRange(glyphRange.location, cachedLineRange) {
                lineTop = cachedLineTop
            } else {
                var effectiveRange = NSRange(location: 0, length: 0)
                let fragment = layout.lineFragmentRect(forGlyphAt: glyphRange.location,
                                                       effectiveRange: &effectiveRange)
                cachedLineRange = effectiveRange
                cachedLineTop = fragment.minY
                lineTop = fragment.minY
            }

            entries.append(Entry(token: token, relativeY: lineTop / totalHeight, range: nsRange))
        }

        return ScriptIndex(entries: entries,
                           fontSize: fontSize,
                           width: width,
                           scriptHash: script.hashValue)
    }

    // MARK: - Token normalization

    private static let spellOutFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .spellOut
        return f
    }()

    /// Lowercases, strips punctuation, and spells out numerals so that "2026"
    /// in the script can match "twenty twenty six" from the recognizer.
    /// Returns nil for tokens that carry no matchable content.
    static func normalize(_ raw: some StringProtocol) -> String? {
        let stripped = raw.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }

        guard !stripped.isEmpty else { return nil }

        if let number = Int(stripped),
           let spelled = spellOutFormatter.string(from: NSNumber(value: number)) {
            return spelled.replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: " ", with: "")
        }
        return stripped
    }

    /// Normalized tokens from recognizer output, in order.
    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .localized]) { substring, _, _, _ in
            if let substring, let token = normalize(substring) {
                tokens.append(token)
            }
        }
        return tokens
    }
}
