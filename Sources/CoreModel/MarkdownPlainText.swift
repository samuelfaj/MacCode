import Foundation

/// Plain-text previews of Markdown (roster subtitles, `titio_inbox.last_preview`,
/// banners, the pet bubble). A preview is one line of what the reader would
/// see: no `**`, backticks, link targets, heading or list markers.
public enum MarkdownPlainText {
    /// The first visible line of `text` with its Markdown removed, collapsed
    /// to single spaces. Skips blank lines, fence markers, rules, table
    /// separators and any ```choices card. `maxCharacters` clips with "…".
    /// Host-internal markers such as `[[RC_AWAITING]]` are never visible.
    public static func firstLine(_ text: String, maxCharacters: Int? = nil) -> String {
        var fence: (marker: Character, length: Int, hidden: Bool)?
        var found = ""
        // Stops at the first visible line: a long message is never split whole.
        BackgroundAwaitContinuation.strippingAwaitingMarker(text).enumerateLines { raw, stop in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if isFenceClose(line, marker: open.marker, length: open.length) {
                    fence = nil
                } else if !open.hidden, !line.isEmpty {
                    found = collapse(line)
                    stop = true
                }
                return
            }
            if let opened = fenceOpen(line) {
                fence = opened
                return
            }
            guard !line.isEmpty, !isRule(line), !isTableSeparator(line) else { return }
            let plain = self.plain(line)
            if !plain.isEmpty {
                found = plain
                stop = true
            }
        }
        return clip(found, max: maxCharacters)
    }

    /// One line of Markdown as plain text (inline markup and leading block
    /// markers removed). Inline code keeps its text verbatim.
    public static func plain(_ line: String) -> String {
        var text = stripBlockMarkers(line.trimmingCharacters(in: .whitespaces))
        if text.hasPrefix("|") || text.hasSuffix("|") {
            text = tableCells(text)
        }
        // Code spans first: their text is shown as is, never re-parsed.
        var spans: [String] = []
        text = replace(#"(`+)(.+?)\1"#, in: text) { groups in
            spans.append(groups[2].trimmingCharacters(in: .whitespaces))
            return "\u{0}\(spans.count - 1)\u{0}"
        }
        text = replace(#"!\[([^\]]*)\]\((?:[^()\s]|\([^()]*\))*(?:\s+"[^"]*")?\)"#, in: text) { $0[1] }
        text = replace(#"\[([^\]]+)\]\((?:[^()\s]|\([^()]*\))*(?:\s+"[^"]*")?\)"#, in: text) { $0[1] }
        text = replace(#"<((?:https?|mailto):[^>\s]+)>"#, in: text) { $0[1] }
        text = replace(#"<br\s*/?>"#, in: text) { _ in " " }
        text = replace(#"</?[A-Za-z][A-Za-z0-9-]*(?:\s[^<>]*)?/?>"#, in: text) { _ in "" }
        text = text.replacingOccurrences(of: "***", with: "")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "~~", with: "")
        text = replace(#"(?<![A-Za-z0-9_])__(?=\S)(.+?)(?<=\S)__(?![A-Za-z0-9_])"#, in: text) { $0[1] }
        text = replace(#"(?<![\\*A-Za-z0-9])\*(?=\S)(.+?)(?<=\S)\*(?![*A-Za-z0-9])"#, in: text) { $0[1] }
        text = replace(#"(?<![\\A-Za-z0-9_])_(?=\S)(.+?)(?<=\S)_(?![A-Za-z0-9_])"#, in: text) { $0[1] }
        text = replace(#"\\([\\`*_{}\[\]()#+\-.!|>~<])"#, in: text) { $0[1] }
        text = replace("\u{0}([0-9]+)\u{0}", in: text) { groups in
            Int(groups[1]).flatMap { spans.indices.contains($0) ? spans[$0] : nil } ?? ""
        }
        text = text.replacingOccurrences(of: "`", with: "")
        return collapse(text)
    }

    // MARK: Blocks

    private static func stripBlockMarkers(_ line: String) -> String {
        var text = line
        // Quotes (any depth), then one heading or list marker, then a task box.
        while text.hasPrefix(">") {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        text = replace(#"^#{1,6}(?:\s+|$)"#, in: text) { _ in "" }
        text = replace(#"\s+#+\s*$"#, in: text) { _ in "" }
        text = replace(#"^(?:[-*+]|[0-9]{1,9}[.)])\s+"#, in: text) { _ in "" }
        text = replace(#"^\[[ xX]\]\s+"#, in: text) { _ in "" }
        return text
    }

    private static func tableCells(_ line: String) -> String {
        var body = line
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|"), !body.hasSuffix("\\|") { body.removeLast() }
        // Split on unescaped pipes outside code spans.
        var cells: [String] = []
        var current = ""
        var inCode = false
        var previous: Character?
        for character in body {
            if character == "`" { inCode.toggle() }
            if character == "|", !inCode, previous != "\\" {
                cells.append(current)
                current = ""
            } else {
                current.append(character)
            }
            previous = character
        }
        cells.append(current)
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func fenceOpen(_ line: String) -> (marker: Character, length: Int, hidden: Bool)? {
        guard let marker = line.first, marker == "`" || marker == "~" else { return nil }
        let length = line.prefix { $0 == marker }.count
        guard length >= 3 else { return nil }
        let info = line.dropFirst(length).trimmingCharacters(in: .whitespaces)
        if marker == "`", info.contains("`") { return nil }
        return (marker, length, info.lowercased().hasPrefix("choices"))
    }

    private static func isFenceClose(_ line: String, marker: Character, length: Int) -> Bool {
        let run = line.prefix { $0 == marker }.count
        return run >= length && line.dropFirst(run).trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let first = compact.first, "-*_=".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        guard line.contains("-") else { return false }
        return line.allSatisfy { "|:- \t".contains($0) } && line.contains("|")
    }

    // MARK: Helpers

    private static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func clip(_ text: String, max: Int?) -> String {
        guard let max, max > 1, text.count > max else { return text }
        return String(text.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static var regexCache: [String: NSRegularExpression] = [:]
    private static let regexLock = NSLock()

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        regexLock.lock()
        defer { regexLock.unlock() }
        if let cached = regexCache[pattern] { return cached }
        let made = try? NSRegularExpression(pattern: pattern)
        regexCache[pattern] = made
        return made
    }

    /// Replaces every match of `pattern`; `transform` gets the match and its groups.
    private static func replace(_ pattern: String, in text: String, _ transform: ([String]) -> String) -> String {
        guard let regex = regex(pattern) else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var result = ""
        var cursor = 0
        for match in matches {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
            result += transform(groups)
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }
}
