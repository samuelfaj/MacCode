import Foundation

/// One text replacement plus the selection to restore afterwards.
struct EditorEdit: Equatable {
    var range: NSRange
    var replacement: String
    var selection: NSRange
}

/// Pure editing commands. They only compute edits, so they test without a view and the text
/// view applies each result as a single undo step.
enum EditorCommands {
    static let indentUnit = String(repeating: " ", count: EditorMetrics.tabWidth)

    // MARK: Comments

    /// vscode: language-configuration.json `comments` for each bundled language.
    static func commentTokens(for language: String?) -> (open: String, close: String?) {
        switch (language ?? "").lowercased() {
        case "python", "shell script", "shellscript", "shell", "bash", "zsh", "sh", "yaml", "yml", "ruby", "toml", "makefile", "dockerfile":
            return ("#", nil)
        case "html", "markdown", "xml":
            return ("<!--", "-->")
        case "css", "scss", "less":
            return ("/*", "*/")
        default:
            return ("//", nil)
        }
    }

    /// Toggles line comments on the lines touched by `selection`. Adds at the smallest common
    /// indent; removes when every non-blank line is already commented (vscode: lineCommentCommand.ts).
    static func toggleComment(text: NSString, selection: NSRange, language: String?) -> EditorEdit? {
        let tokens = commentTokens(for: language)
        var block = selection
        // A selection ending at a line start does not include that line.
        if selection.length > 0, NSMaxRange(selection) > 0, text.character(at: NSMaxRange(selection) - 1) == 0x0A {
            block.length -= 1
        }
        let region = text.lineRange(for: block)
        var lines: [NSRange] = []
        text.enumerateSubstrings(in: region, options: [.byLines, .substringNotRequired]) { _, range, _, _ in lines.append(range) }
        if lines.isEmpty { lines = [NSRange(location: region.location, length: 0)] }
        let nonBlank = lines.filter { text.substring(with: $0).trimmingCharacters(in: .whitespaces).isEmpty == false }
        let open = tokens.open
        func isCommented(_ line: NSRange) -> Bool {
            let s = text.substring(with: line).drop(while: { $0 == " " || $0 == "\t" })
            return s.hasPrefix(open)
        }
        let uncomment = !nonBlank.isEmpty && nonBlank.allSatisfy(isCommented)
        let targets = nonBlank.isEmpty ? lines : nonBlank
        let minIndent = targets.map { line -> Int in
            let s = text.substring(with: line)
            return s.prefix(while: { $0 == " " || $0 == "\t" }).utf16.count
        }.min() ?? 0

        var out = ""
        var cursor = region.location
        var newSelection = selection
        var delta = 0
        for line in lines {
            out += text.substring(with: NSRange(location: cursor, length: line.location - cursor))
            var content = text.substring(with: line)
            let isTarget = targets.contains(line)
            if isTarget {
                let before = content.utf16.count
                if uncomment {
                    let lead = content.prefix(while: { $0 == " " || $0 == "\t" })
                    var rest = content.dropFirst(lead.count)
                    rest = rest.dropFirst(open.count)
                    if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                    if let close = tokens.close {
                        var trimmed = String(rest)
                        while trimmed.hasSuffix(" ") { trimmed.removeLast() }
                        if trimmed.hasSuffix(close) { trimmed.removeLast(close.count) }
                        while trimmed.hasSuffix(" ") { trimmed.removeLast() }
                        rest = Substring(trimmed)
                    }
                    content = String(lead) + rest
                } else {
                    let idx = content.index(content.startIndex, offsetBy: min(minIndent, content.count))
                    var body = String(content[idx...])
                    if let close = tokens.close { body += " " + close }
                    content = String(content[..<idx]) + open + (body.isEmpty ? "" : " ") + body
                }
                let change = content.utf16.count - before
                if line.location + line.length <= selection.location {
                    newSelection.location += change
                } else if line.location < NSMaxRange(selection) || selection.length == 0 {
                    delta += change
                }
            }
            out += content
            cursor = NSMaxRange(line)
        }
        newSelection.length = max(0, newSelection.length + delta)
        let replaced = NSRange(location: region.location, length: cursor - region.location)
        return EditorEdit(range: replaced, replacement: out, selection: newSelection)
    }

    // MARK: Return

    private static let pairs: [unichar: unichar] = [0x28: 0x29, 0x5B: 0x5D, 0x7B: 0x7D]

    /// Auto-indent: copy the line's indent, add a level after an opener (or `:` in Python), and
    /// split `{|}` into a block with the caret on the indented middle line.
    static func newline(text: NSString, selection: NSRange, language: String?) -> EditorEdit {
        let lineStart = text.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let head = text.substring(with: NSRange(location: lineStart, length: selection.location - lineStart))
        let lead = String(head.prefix(while: { $0 == " " || $0 == "\t" }))
        let trimmedHead = head.trimmingCharacters(in: .whitespaces)
        let isPython = (language ?? "").lowercased() == "python"
        let last = trimmedHead.utf16.last
        let opens = last.map { pairs[$0] != nil } ?? false
        let extra = opens || (isPython && trimmedHead.hasSuffix(":")) ? indentUnit : ""
        let afterIndex = NSMaxRange(selection)
        if opens, let last, let close = pairs[last], afterIndex < text.length, text.character(at: afterIndex) == close {
            let middle = "\n" + lead + extra
            let replacement = middle + "\n" + lead
            return EditorEdit(range: selection, replacement: replacement,
                              selection: NSRange(location: selection.location + middle.utf16.count, length: 0))
        }
        let replacement = "\n" + lead + extra
        return EditorEdit(range: selection, replacement: replacement,
                          selection: NSRange(location: selection.location + replacement.utf16.count, length: 0))
    }

    // MARK: Typing

    private static func isWord(_ c: unichar) -> Bool {
        c == 0x5F || (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c > 0x7F
    }

    /// Auto-close and skip-over for one typed character; nil means "insert normally".
    static func typed(_ s: String, text: NSString, selection: NSRange) -> EditorEdit? {
        guard s.utf16.count == 1, let c = s.utf16.first else { return nil }
        let next: unichar? = NSMaxRange(selection) < text.length ? text.character(at: NSMaxRange(selection)) : nil
        let prev: unichar? = selection.location > 0 ? text.character(at: selection.location - 1) : nil
        let closers = Set(pairs.values)
        let quotes: Set<unichar> = [0x22, 0x27, 0x60]
        if selection.length == 0, let next, next == c, closers.contains(c) || quotes.contains(c) {
            return EditorEdit(range: NSRange(location: selection.location, length: 0), replacement: "",
                              selection: NSRange(location: selection.location + 1, length: 0))
        }
        let close: unichar?
        if let closer = pairs[c] { close = closer } else if quotes.contains(c) { close = c } else { close = nil }
        guard let close else { return nil }
        if selection.length > 0 {
            let inner = text.substring(with: selection)
            return EditorEdit(range: selection, replacement: s + inner + String(utf16CodeUnits: [close], count: 1),
                              selection: NSRange(location: selection.location + 1, length: selection.length))
        }
        if quotes.contains(c), let prev, isWord(prev) { return nil }
        if let next, isWord(next) || (quotes.contains(next)) { return nil }
        return EditorEdit(range: selection, replacement: s + String(utf16CodeUnits: [close], count: 1),
                          selection: NSRange(location: selection.location + 1, length: 0))
    }

    /// Backspace between an auto-closed pair removes both characters.
    static func backspace(text: NSString, selection: NSRange) -> EditorEdit? {
        guard selection.length == 0, selection.location > 0, selection.location < text.length else { return nil }
        let prev = text.character(at: selection.location - 1)
        let next = text.character(at: selection.location)
        let quotes: Set<unichar> = [0x22, 0x27, 0x60]
        guard pairs[prev] == next || (prev == next && quotes.contains(prev)) else { return nil }
        let range = NSRange(location: selection.location - 1, length: 2)
        return EditorEdit(range: range, replacement: "", selection: NSRange(location: range.location, length: 0))
    }

    // MARK: Indent

    /// Tab: indent selected lines, or insert spaces up to the next tab stop.
    static func tab(text: NSString, selection: NSRange) -> EditorEdit {
        let spansLines = selection.length > 0 && text.substring(with: selection).contains("\n")
        if !spansLines {
            let lineStart = text.lineRange(for: NSRange(location: selection.location, length: 0)).location
            let column = selection.location - lineStart
            let spaces = String(repeating: " ", count: EditorMetrics.tabWidth - column % EditorMetrics.tabWidth)
            return EditorEdit(range: selection, replacement: spaces,
                              selection: NSRange(location: selection.location + spaces.utf16.count, length: 0))
        }
        return reindent(text: text, selection: selection, outdent: false)
    }

    /// Shift-Tab: remove up to one indent level from the selected lines.
    static func backtab(text: NSString, selection: NSRange) -> EditorEdit {
        reindent(text: text, selection: selection, outdent: true)
    }

    private static func reindent(text: NSString, selection: NSRange, outdent: Bool) -> EditorEdit {
        var block = selection
        if selection.length > 0, text.character(at: NSMaxRange(selection) - 1) == 0x0A { block.length -= 1 }
        let region = text.lineRange(for: block)
        var out = ""
        var firstDelta = 0, total = 0
        var isFirst = true
        text.enumerateSubstrings(in: region, options: [.byLines, .substringNotRequired, .substringNotRequired]) { _, line, _, _ in
            var content = text.substring(with: line)
            let before = content.utf16.count
            if outdent {
                if content.hasPrefix("\t") { content.removeFirst() } else {
                    let n = min(EditorMetrics.tabWidth, content.prefix(while: { $0 == " " }).count)
                    content.removeFirst(n)
                }
            } else if !content.isEmpty {
                content = indentUnit + content
            }
            let change = content.utf16.count - before
            if isFirst { firstDelta = change; isFirst = false }
            total += change
            out += content + "\n"
        }
        if !region.length.isMultiple(of: 1) { out = "" }
        // enumerateSubstrings drops the final terminator; restore it only if the region had one.
        let hadTerminator = region.length > 0 && text.character(at: NSMaxRange(region) - 1) == 0x0A
        if !hadTerminator, out.hasSuffix("\n") { out.removeLast() }
        let start = max(region.location, selection.location + (firstDelta < 0 ? max(firstDelta, region.location - selection.location) : firstDelta))
        let newSel = NSRange(location: start, length: max(0, selection.length + total - firstDelta))
        return EditorEdit(range: region, replacement: out, selection: newSel)
    }

    // MARK: Go to line

    /// UTF-16 location of the start of 1-based `line`, clamped to the document.
    static func lineStart(of line: Int, in text: NSString) -> Int {
        var location = 0
        var current = 1
        while current < line, location < text.length {
            let next = NSMaxRange(text.lineRange(for: NSRange(location: location, length: 0)))
            // The last line has no terminator; there is no line after it to jump to.
            if next >= text.length, text.character(at: text.length - 1) != 0x0A { break }
            location = next
            current += 1
        }
        return min(location, text.length)
    }
}
