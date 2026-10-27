import AppKit

/// Incremental, pure-Swift syntax highlighter. Works on a range of an attributed string and only
/// touches attributes, so it never changes text, selection or the undo stack.
enum SyntaxHighlighter {
    /// UTF-16 length scanned by the last `highlight` calls; lets tests prove keystrokes stay local.
    nonisolated(unsafe) static var scannedLengthForTests = 0
    /// Block comments and bracket depth look this far outside the edited paragraphs.
    static let contextLimit = 20_000
    private static let bracketColors = [editorHex(0xFFD700), editorHex(0xDA70D6), editorHex(0x179FFF)]

    /// Re-colors the paragraphs touching `range`. `resetBase` clears previous colors first.
    @discardableResult
    static func highlight(
        _ storage: NSMutableAttributedString,
        range: NSRange,
        language: String?,
        palette: EditorColorPalette,
        resetBase: Bool = false
    ) -> NSRange {
        let ns = storage.string as NSString
        guard ns.length > 0 else { return NSRange(location: 0, length: 0) }
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: ns.length))
        let paragraphs = ns.paragraphRange(for: clamped)
        scannedLengthForTests += paragraphs.length
        let lang = (language ?? "").lowercased()
        if resetBase { storage.setAttributes(codeBaseAttributes(for: palette), range: paragraphs) }
        let isMarkdown = lang == "markdown"

        var inFence = false
        if isMarkdown { inFence = fenceOpen(before: paragraphs.location, in: ns) }
        ns.enumerateSubstrings(in: paragraphs, options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            let line = ns.substring(with: lineRange)
            if isMarkdown {
                markdownLine(line, at: lineRange, inFence: &inFence, storage: storage)
            } else {
                applyHighlightSpans(highlightCodeLine(line, language: language), lineRange: lineRange, to: storage)
            }
        }
        if !isMarkdown {
            for comment in blockComments(in: ns, around: paragraphs, language: lang) {
                let hit = NSIntersectionRange(comment, paragraphs)
                if hit.length > 0, let color = codeColor(for: "comment") {
                    storage.addAttribute(.foregroundColor, value: color, range: hit)
                }
            }
            colorizeBrackets(storage, ns, paragraphs: paragraphs)
        }
        return paragraphs
    }

    // MARK: Block comments

    /// `/* */` (or `<!-- -->`) ranges that overlap `paragraphs`, scanned within `contextLimit`.
    static func blockComments(in ns: NSString, around paragraphs: NSRange, language: String) -> [NSRange] {
        let open: String, close: String
        switch language {
        case "python", "shell script", "shellscript", "shell", "bash", "zsh", "sh", "yaml", "yml", "json", "markdown": return []
        case "html": (open, close) = ("<!--", "-->")
        default: (open, close) = ("/*", "*/")
        }
        let lo = max(0, paragraphs.location - contextLimit)
        let hi = min(ns.length, NSMaxRange(paragraphs) + contextLimit)
        guard hi > lo else { return [] }
        let window = NSRange(location: lo, length: hi - lo)
        // Cheap exit: no opener in the window means no block comments to color.
        if ns.range(of: open, options: [], range: window).location == NSNotFound { return [] }
        var result: [NSRange] = []
        var i = lo
        var quote: unichar = 0
        let o = Array(open.utf16), c = Array(close.utf16)
        func matches(_ token: [unichar], at pos: Int) -> Bool {
            guard pos + token.count <= hi else { return false }
            for k in 0..<token.count where ns.character(at: pos + k) != token[k] { return false }
            return true
        }
        while i < hi {
            let ch = ns.character(at: i)
            if quote != 0 {
                if ch == 0x5C { i += 2; continue }
                if ch == quote || (ch == 0x0A && quote != 0x60) { quote = 0 }
                i += 1
            } else if matches(o, at: i) {
                var end = i + o.count
                while end < hi, !matches(c, at: end) { end += 1 }
                let stop = end < hi ? end + c.count : hi
                result.append(NSRange(location: i, length: stop - i))
                i = stop
            } else if (ch == 0x22 || ch == 0x27 || ch == 0x60), language != "html" {
                quote = ch
                i += 1
            } else if language != "html", ch == 0x2F, i + 1 < hi, ns.character(at: i + 1) == 0x2F {
                while i < hi, ns.character(at: i) != 0x0A { i += 1 }
            } else {
                i += 1
            }
        }
        return result.filter { NSIntersectionRange($0, paragraphs).length > 0 }
    }

    // MARK: Brackets

    /// vscode: editorColorRegistry.ts editorBracketHighlight.foreground1…3. Strings and comments keep their color.
    private static func colorizeBrackets(_ storage: NSMutableAttributedString, _ ns: NSString, paragraphs: NSRange) {
        var depth = 0
        let start = max(0, paragraphs.location - contextLimit)
        let stringColor = codeColor(for: "str"), commentColor = codeColor(for: "comment")
        func isCode(_ index: Int) -> Bool {
            guard let color = storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor else { return true }
            return !(color.isEqual(stringColor) || color.isEqual(commentColor))
        }
        var i = start
        let end = NSMaxRange(paragraphs)
        while i < end {
            let c = ns.character(at: i)
            if c == 0x28 || c == 0x5B || c == 0x7B {
                if isCode(i) {
                    if i >= paragraphs.location {
                        storage.addAttribute(.foregroundColor, value: bracketColors[depth % 3], range: NSRange(location: i, length: 1))
                    }
                    depth += 1
                }
            } else if c == 0x29 || c == 0x5D || c == 0x7D {
                if isCode(i) {
                    depth = max(0, depth - 1)
                    if i >= paragraphs.location {
                        storage.addAttribute(.foregroundColor, value: bracketColors[depth % 3], range: NSRange(location: i, length: 1))
                    }
                }
            }
            i += 1
        }
    }

    // MARK: Markdown

    private static func fenceOpen(before location: Int, in ns: NSString) -> Bool {
        let lo = max(0, location - contextLimit)
        var count = 0
        var search = NSRange(location: lo, length: location - lo)
        while search.length > 0 {
            let found = ns.range(of: "```", options: [], range: search)
            if found.location == NSNotFound { break }
            // Only fences at line start count.
            if found.location == 0 || ns.character(at: found.location - 1) == 0x0A { count += 1 }
            let next = NSMaxRange(found)
            search = NSRange(location: next, length: location - next)
        }
        return count % 2 == 1
    }

    /// vscode: dark_plus.json markup.heading (#569CD6, bold); inline code uses the string color.
    private static func markdownLine(_ line: String, at range: NSRange, inFence: inout Bool, storage: NSMutableAttributedString) {
        let trimmed = line.drop(while: { $0 == " " })
        if trimmed.hasPrefix("```") {
            inFence.toggle()
            storage.addAttribute(.foregroundColor, value: codeColor(for: "str") as Any, range: range)
            return
        }
        if inFence {
            storage.addAttribute(.foregroundColor, value: codeColor(for: "str") as Any, range: range)
            return
        }
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        if (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " || trimmed.count == hashes {
            storage.addAttribute(.foregroundColor, value: codeColor(for: "heading") as Any, range: range)
            if let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont {
                let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                storage.addAttribute(.font, value: bold, range: range)
            }
            return
        }
        let ns = line as NSString
        var i = 0
        while i < ns.length {
            if ns.character(at: i) == 0x60 {
                let rest = NSRange(location: i + 1, length: ns.length - i - 1)
                let close = ns.range(of: "`", options: [], range: rest)
                if close.location != NSNotFound {
                    let span = NSRange(location: range.location + i, length: close.location - i + 1)
                    storage.addAttribute(.foregroundColor, value: codeColor(for: "str") as Any, range: span)
                    i = NSMaxRange(close)
                    continue
                }
            }
            i += 1
        }
    }
}
