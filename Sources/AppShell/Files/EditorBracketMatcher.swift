import Foundation

/// Bracket pairing for the editor. Pure so it can be tested without a view.
enum EditorBracketMatcher {
    /// vscode: src/vs/editor/contrib/bracketMatching — scans are bounded so huge files stay responsive.
    static let scanLimit = 20_000
    private static let openers: [unichar: unichar] = [0x28: 0x29, 0x7B: 0x7D, 0x5B: 0x5D]
    private static let closers: [unichar: unichar] = [0x29: 0x28, 0x7D: 0x7B, 0x5D: 0x5B]

    static func isBracket(_ c: unichar) -> Bool { openers[c] != nil || closers[c] != nil }

    /// Pair for the bracket just before or at `caret`, as two single-character ranges.
    static func pair(in text: NSString, caret: Int) -> (NSRange, NSRange)? {
        let length = text.length
        for index in [caret - 1, caret] where index >= 0 && index < length {
            let c = text.character(at: index)
            guard isBracket(c) else { continue }
            if let other = match(in: text, at: index) {
                return (NSRange(location: index, length: 1), NSRange(location: other, length: 1))
            }
        }
        return nil
    }

    /// Index of the partner of the bracket at `index`, or nil when unmatched or out of reach.
    static func match(in text: NSString, at index: Int) -> Int? {
        let c = text.character(at: index)
        let lo = max(0, index - scanLimit)
        let hi = min(text.length, index + scanLimit)
        let mask = literalMask(in: text, from: lo, to: hi)
        if mask[index - lo] { return nil }
        if let close = openers[c] {
            var depth = 0
            var i = index
            while i < hi {
                if !mask[i - lo] {
                    let ch = text.character(at: i)
                    if ch == c { depth += 1 } else if ch == close {
                        depth -= 1
                        if depth == 0 { return i }
                    }
                }
                i += 1
            }
        } else if let open = closers[c] {
            var depth = 0
            var i = index
            while i >= lo {
                if !mask[i - lo] {
                    let ch = text.character(at: i)
                    if ch == c { depth += 1 } else if ch == open {
                        depth -= 1
                        if depth == 0 { return i }
                    }
                }
                i -= 1
            }
        }
        return nil
    }

    /// True for characters inside string literals or comments (best effort, language agnostic).
    static func literalMask(in text: NSString, from lo: Int, to hi: Int) -> [Bool] {
        var mask = [Bool](repeating: false, count: max(0, hi - lo))
        var i = lo
        var quote: unichar = 0
        var inLineComment = false
        var inBlockComment = false
        while i < hi {
            let c = text.character(at: i)
            let next: unichar = i + 1 < text.length ? text.character(at: i + 1) : 0
            if c == 0x0A {
                inLineComment = false
                if quote != 0x60 { quote = 0 }
                i += 1
                continue
            }
            if inBlockComment {
                mask[i - lo] = true
                if c == 0x2A, next == 0x2F, i + 1 < hi { mask[i + 1 - lo] = true; inBlockComment = false; i += 1 }
            } else if inLineComment {
                mask[i - lo] = true
            } else if quote != 0 {
                mask[i - lo] = true
                if c == 0x5C, i + 1 < hi { mask[i + 1 - lo] = true; i += 1 } else if c == quote { quote = 0 }
            } else if c == 0x22 || c == 0x27 || c == 0x60 {
                quote = c
                mask[i - lo] = true
            } else if c == 0x2F, next == 0x2F {
                inLineComment = true
                mask[i - lo] = true
            } else if c == 0x2F, next == 0x2A {
                inBlockComment = true
                mask[i - lo] = true
            }
            i += 1
        }
        return mask
    }
}
