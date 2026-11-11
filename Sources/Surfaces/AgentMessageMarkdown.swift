import CoreModel
import Foundation
import SwiftUI
import AppKit
import DesignSystemKit

struct AgentMessageMarkdownBlock: Hashable {
    enum TableAlignment: Hashable { case none, left, center, right }

    enum Kind: Hashable {
        case paragraph
        case heading(Int)
        case bullet(indent: Int)
        case numbered(number: Int, indent: Int)
        /// GFM task item `- [ ]` / `- [x]`.
        case task(checked: Bool, indent: Int)
        /// A later paragraph of the list item at `indent` (after a blank line).
        case listContinuation(indent: Int)
        /// `language` is "" when the fence has no info string (or for indented code).
        case code(language: String)
        case table(headers: [String], rows: [[String]], alignments: [TableAlignment])
        /// Paragraph text inside a block quote (`quoteDepth` ≥ 1).
        case blockquote
        /// Thematic break (`---`, `***`, `___`, `* * *`).
        case rule
    }

    let kind: Kind
    let text: String
    /// Number of enclosing `>` quotes (0 outside quotes). Lists, headings and
    /// code inside a quote keep their own kind and carry the depth here.
    var quoteDepth: Int = 0
}

/// Quote nesting of a prose paragraph, read by `AgentMarkdownLayoutManager`
/// to draw the quote bars. (TextKit 1 NSTextBlock quotes lose their layout
/// as soon as the paragraph has line spacing, so bars are drawn by hand.)
enum AgentMarkdownQuoteDepthAttribute: AttributedStringKey {
    typealias Value = Int
    static let name = "RCQuoteDepth"
}

extension AttributeScopes {
    /// AppKit attributes plus the transcript's own keys, used when the prose
    /// AttributedString is handed to the NSTextView.
    struct AgentMarkdownAttributes: AttributeScope {
        let quoteDepth: AgentMarkdownQuoteDepthAttribute
        let appKit: AttributeScopes.AppKitAttributes
    }

    var agentMarkdown: AgentMarkdownAttributes.Type { AgentMarkdownAttributes.self }
}

enum AgentMessageMarkdown {
    // F3: cache parsed blocks + attributed inline output keyed on the source text.
    // The markdown view re-evaluates `body` on every keystroke / streaming delta /
    // hover / window resize, and SwiftUI does NOT cache the AttributedString handed
    // to Text(...), so a custom tokenizer + Foundation `AttributedString(markdown:)`
    // ran for every visible block (and every table cell) on every pass. Persisted
    // message bodies are immutable, so after the first parse every re-render of
    // stable history is a cache hit; only the live streaming row (changing text)
    // reparses.
    //
    // R4-B: countLimit alone still retains every unique partial length during a
    // stream (each growing prefix is a distinct key). Bound occupancy with
    // totalCostLimit (UTF-8 cost) and allow callers to pass `cache: false` for
    // live rows so intermediate partials are never stored. NSCache is thread-safe;
    // these run on the main actor.
    private final class BlocksBox { let blocks: [AgentMessageMarkdownBlock]; init(_ b: [AgentMessageMarkdownBlock]) { blocks = b } }
    private final class AttributedBox { let value: AttributedString; init(_ v: AttributedString) { value = v } }

    /// Soft byte budget for cached markdown parse results (blocks + inline +
    /// prose share independent budgets). Finished 60 KiB replies still cache
    /// (~34 large replies per 2 MiB). Streaming partials still skip store
    /// via `cache: false`.
    static let blocksCacheCostLimit = 2 * 1_024 * 1_024
    static let inlineCacheCostLimit = 2 * 1_024 * 1_024
    /// Peak block-parse results retained process-wide (NSCache countLimit).
    static let blocksCacheCountLimit = 256
    /// Peak inline AttributedString results retained process-wide.
    static let inlineCacheCountLimit = 256

    private static let blocksCache: NSCache<NSString, BlocksBox> = {
        let cache = NSCache<NSString, BlocksBox>()
        cache.countLimit = blocksCacheCountLimit
        cache.totalCostLimit = blocksCacheCostLimit
        return cache
    }()
    private static let inlineCache: NSCache<NSString, AttributedBox> = {
        let cache = NSCache<NSString, AttributedBox>()
        cache.countLimit = inlineCacheCountLimit
        cache.totalCostLimit = inlineCacheCostLimit
        return cache
    }()

    #if DEBUG
    // Test-only observability: how many times the uncached parse actually ran, so a
    // unit test can prove repeated renders of identical content hit the cache.
    nonisolated(unsafe) static var blocksComputeCountForTesting = 0
    /// Test-only: UTF-8 bytes tokenized by `computeBlocks` (live-tail proof).
    nonisolated(unsafe) static var blocksParsedUTF8BytesForTesting = 0
    nonisolated(unsafe) static var inlineComputeCountForTesting = 0
    /// Test-only: every `blocks(from:)` entry, including cache hits. Hover isolation
    /// must not increment this after the first parent body evaluation.
    nonisolated(unsafe) static var blocksLookupCountForTesting = 0
    /// Test-only: successful setObject admissions (not lookups).
    nonisolated(unsafe) static var blocksCacheStoreCountForTesting = 0
    nonisolated(unsafe) static var inlineCacheStoreCountForTesting = 0
    #endif

    /// Whether a source string is eligible to occupy NSCache.
    /// `cache: false` is live-only: never store, even under 48 KiB.
    static func shouldStoreMarkdownCache(textUTF8Count: Int, cache: Bool) -> Bool {
        cache && textUTF8Count > 0
    }

    /// CH-08: key by utf8 count + 64-bit hash so SwiftUI body does not rehash
    /// the full NSString on every pass.
    /// AA-28: one UTF-8 hash of the source text, handed down to the NSTextView
    /// wrapper as the row's content identity (see `AgentLinkedAttributedText`).
    static func sourceFingerprint(for text: String) -> Int {
        var hasher = Hasher()
        hasher.combine(text.utf8.count)
        hasher.combine(text)
        return hasher.finalize()
    }

    static func cacheKey(for text: String) -> NSString {
        cacheKey(for: text, fingerprint: sourceFingerprint(for: text))
    }

    /// AA-32: the cache key IS the source fingerprint prefixed by the byte
    /// count. Callers that already computed `sourceFingerprint(for:)` for the
    /// text-view identity pass it here instead of hashing the text again.
    static func cacheKey(for text: String, fingerprint: Int) -> NSString {
        "\(text.utf8.count):\(fingerprint)" as NSString
    }

    static func blocks(from text: String, cache: Bool = true) -> [AgentMessageMarkdownBlock] {
        #if DEBUG
        blocksLookupCountForTesting &+= 1
        #endif
        // Live streaming rows grow every paint tick. Re-tokenizing the whole
        // body each tick made a long reply O(n²); the prefix before the last
        // block-level reset point is final, so parse (and cache) it once and
        // re-parse only the growing tail.
        if !cache {
            let chunks = stableLiveChunks(text)
            if chunks.count > 1 {
                var result: [AgentMessageMarkdownBlock] = []
                for (index, chunk) in chunks.enumerated() {
                    let isTail = index == chunks.count - 1
                    if isTail, !chunk.contains(where: { !$0.isWhitespace }) { break }
                    result += blocks(from: String(chunk), cache: !isTail)
                }
                return result
            }
        }
        let key = cacheKey(for: text)
        // Perf CH-04: `cache: false` (live streaming rows) must only skip the
        // STORE — the read still hits, so a body that was parsed while finished
        // (or by a sibling surface) is never re-parsed.
        if let cached = blocksCache.object(forKey: key) { return cached.blocks }
        let result = computeBlocks(from: text)
        let cost = text.utf8.count
        if shouldStoreMarkdownCache(textUTF8Count: cost, cache: cache) {
            blocksCache.setObject(BlocksBox(result), forKey: key, cost: cost)
            #if DEBUG
            blocksCacheStoreCountForTesting &+= 1
            #endif
        }
        return result
    }

    /// Splits where the block parser fully resets: one or more blank lines
    /// (outside a ``` / ~~~ fence) followed by a line that starts at column 0.
    /// An indented line after a blank can still continue a list item or an
    /// indented code block, so it never starts a chunk. The concatenated
    /// per-chunk parses therefore equal the full parse; all chunks but the
    /// last are final and cache, and only the growing last chunk re-parses.
    static func stableLiveChunks(_ text: String) -> [Substring] {
        let utf8 = text.utf8
        let newline = UInt8(ascii: "\n")
        let space = UInt8(ascii: " ")
        let tab = UInt8(ascii: "\t")
        var fence: (char: UInt8, length: Int)?
        var lineStart = utf8.startIndex
        var chunkStart = utf8.startIndex
        var blankRunStart: String.Index?
        var sawContent = false
        var chunks: [Substring] = []
        var index = utf8.startIndex
        while index < utf8.endIndex {
            if utf8[index] == newline {
                var cursor = lineStart
                while cursor < index, utf8[cursor] == space || utf8[cursor] == tab { cursor = utf8.index(after: cursor) }
                let indented = cursor != lineStart
                let blank = cursor == index || text[cursor..<index].allSatisfy(\.isWhitespace)
                let next = utf8.index(after: index)
                if let open = fence {
                    var run = 0
                    var probe = cursor
                    while probe < index, utf8[probe] == open.char { run += 1; probe = utf8.index(after: probe) }
                    if run >= open.length, text[probe..<index].allSatisfy(\.isWhitespace) { fence = nil }
                } else if blank {
                    if sawContent, blankRunStart == nil { blankRunStart = lineStart }
                } else {
                    if let blankStart = blankRunStart, !indented {
                        chunks.append(text[chunkStart..<blankStart])
                        chunkStart = lineStart
                    }
                    blankRunStart = nil
                    sawContent = true
                    if let opener = fenceOpener(text[cursor..<index]) {
                        fence = (opener.char == "`" ? UInt8(ascii: "`") : UInt8(ascii: "~"), opener.length)
                    }
                }
                lineStart = next
            }
            index = utf8.index(after: index)
        }
        chunks.append(text[chunkStart...])
        return chunks
    }

    static func selectionGroups(from blocks: [AgentMessageMarkdownBlock]) -> [[AgentMessageMarkdownBlock]] {
        var groups: [[AgentMessageMarkdownBlock]] = []
        var prose: [AgentMessageMarkdownBlock] = []

        func flushProse() {
            guard !prose.isEmpty else { return }
            groups.append(prose)
            prose.removeAll(keepingCapacity: true)
        }

        for block in blocks {
            switch block.kind {
            case .code, .table, .rule:
                flushProse()
                groups.append([block])
            default:
                prose.append(block)
            }
        }
        flushProse()
        return groups
    }

    private static let proseCache: NSCache<NSString, AttributedBox> = {
        let cache = NSCache<NSString, AttributedBox>()
        cache.countLimit = inlineCacheCountLimit
        cache.totalCostLimit = inlineCacheCostLimit
        return cache
    }()

    // MARK: Prose typography (AppKit attributes)
    //
    // The prose group is drawn by an NSTextView (`AgentLinkedAttributedText`),
    // which only understands AppKit attribute keys. SwiftUI `.font` /
    // `.foregroundColor` runs are stored under "SwiftUI.*" keys that AppKit
    // ignores, so every typographic decision here is an NSFont / NSColor /
    // NSParagraphStyle. Inline intents (bold, italic, code, strikethrough) are
    // resolved against each run's font in `makeNSAttributedString`.

    static let bodyFontSize: CGFloat = 13
    static let listIndentStep: CGFloat = 18
    static let listMarkerWidth: CGFloat = 18
    /// Indent per quote level; the bar sits in the first 3 pt of it.
    static let quoteIndentStep: CGFloat = 14

    static func headingFontSize(_ level: Int, compact: Bool) -> CGFloat {
        if compact { return level <= 2 ? 15 : 13 }
        switch level {
        case 1: return 20
        case 2: return 17
        case 3: return 15
        case 6: return 12
        default: return 13
        }
    }

    static func headingFont(_ level: Int, compact: Bool) -> NSFont {
        NSFont.systemFont(ofSize: headingFontSize(level, compact: compact), weight: level <= 2 ? .bold : .semibold)
    }

    static func selectableProse(from blocks: [AgentMessageMarkdownBlock], compact: Bool, cache: Bool = true) -> AttributedString {
        let proseKey: NSString = {
            var hasher = Hasher()
            hasher.combine(compact)
            hasher.combine(blocks.count)
            for block in blocks {
                hasher.combine(block.kind)
                hasher.combine(block.quoteDepth)
                hasher.combine(block.text.utf8.count)
                hasher.combine(block.text)
            }
            return "prose:\(hasher.finalize())" as NSString
        }()
        if cache, let cached = proseCache.object(forKey: proseKey) {
            return cached.value
        }
        var result = AttributedString()
        var previous: AgentMessageMarkdownBlock?
        var previousParagraph = AttributeContainer()
        var appended = 0
        for (index, block) in blocks.enumerated() {
            // Perf CH-04: in a live streaming group only the LAST block can
            // still grow; stable earlier blocks are cached and read like
            // finished content so a token does not re-parse them.
            var line = attributedInline(block.text, cache: cache || index < blocks.count - 1)
            // An image-only paragraph renders in the gallery, not as an empty line.
            if case .paragraph = block.kind, !line.characters.contains(where: { !$0.isWhitespace }) { continue }
            if case .blockquote = block.kind, !line.characters.contains(where: { !$0.isWhitespace }) { continue }

            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = appended == 0 ? 0 : spacingBefore(block, previous: previous, compact: compact)

            var font = NSFont.systemFont(ofSize: bodyFontSize)
            var color = DS.NS.text
            var marker: AttributedString?
            switch block.kind {
            case .paragraph, .code, .table, .rule:
                break
            case .heading(let level):
                font = headingFont(level, compact: compact)
                if level == 6 { color = DS.NS.textSecondary }
                style.paragraphSpacing = compact ? 0 : 2
            case .blockquote:
                color = DS.NS.textSecondary
            case .bullet(let indent):
                marker = listMarker(["•", "◦", "▪"][indent % 3], color: DS.NS.textTertiary, font: NSFont.systemFont(ofSize: bodyFontSize, weight: .bold))
                applyListIndent(style, indent: indent, markerWidth: listMarkerWidth)
            case .numbered(let number, let indent):
                let label = "\(number)."
                let markerFont = NSFont.monospacedDigitSystemFont(ofSize: bodyFontSize, weight: .regular)
                let width = max(listMarkerWidth, ceil((label as NSString).size(withAttributes: [.font: markerFont]).width) + 6)
                marker = listMarker(label, color: DS.NS.textSecondary, font: markerFont)
                applyListIndent(style, indent: indent, markerWidth: width)
            case .task(let checked, let indent):
                marker = listMarker(
                    checked ? "☑" : "☐",
                    color: checked ? DS.NS.accent : DS.NS.textTertiary,
                    font: NSFont.systemFont(ofSize: bodyFontSize + 1)
                )
                applyListIndent(style, indent: indent, markerWidth: listMarkerWidth + 2)
                if checked { color = DS.NS.textSecondary }
            case .listContinuation(let indent):
                let head = CGFloat(indent) * listIndentStep + listMarkerWidth
                style.firstLineHeadIndent = head
                style.headIndent = head
            }

            // Quotes: indent past the bars `AgentMarkdownLayoutManager` draws.
            if block.quoteDepth > 0 {
                let offset = CGFloat(block.quoteDepth) * quoteIndentStep
                style.firstLineHeadIndent += offset
                style.headIndent += offset
                style.tabStops = style.tabStops.map { NSTextTab(textAlignment: $0.alignment, location: $0.location + offset) }
            }

            var base = AttributeContainer()
            base[AttributeScopes.AppKitAttributes.FontAttribute.self] = font
            base[AttributeScopes.AppKitAttributes.ForegroundColorAttribute.self] = color
            line.mergeAttributes(base, mergePolicy: .keepNew)
            if let marker {
                var full = marker
                full.append(line)
                line = full
            }
            var paragraph = AttributeContainer()
            paragraph[AttributeScopes.AppKitAttributes.ParagraphStyleAttribute.self] = style
            if block.quoteDepth > 0 {
                paragraph[AgentMarkdownQuoteDepthAttribute.self] = block.quoteDepth
            }
            if appended > 0 {
                // The newline ends the PREVIOUS paragraph and must carry its
                // style: TextKit lays text blocks (quote bars) out per whole
                // paragraph, and a terminator with another paragraph's blocks
                // drops the bar.
                var separator = AttributedString("\n")
                separator.mergeAttributes(previousParagraph)
                result.append(separator)
            }
            line.mergeAttributes(paragraph, mergePolicy: .keepNew)
            result.append(line)
            previousParagraph = paragraph
            previous = block
            appended += 1
        }
        if cache {
            let cost = blocks.reduce(0) { $0 + $1.text.utf8.count }
            proseCache.setObject(AttributedBox(result), forKey: proseKey, cost: max(1, cost))
        }
        return result
    }

    private static func listMarker(_ glyph: String, color: NSColor, font: NSFont) -> AttributedString {
        var marker = AttributedString(glyph + "\t")
        var container = AttributeContainer()
        container[AttributeScopes.AppKitAttributes.FontAttribute.self] = font
        container[AttributeScopes.AppKitAttributes.ForegroundColorAttribute.self] = color
        marker.mergeAttributes(container)
        return marker
    }

    /// Hanging indent: the marker sits at the item's indent, wrapped lines
    /// align with the text after it (not with the marker).
    private static func applyListIndent(_ style: NSMutableParagraphStyle, indent: Int, markerWidth: CGFloat) {
        let start = CGFloat(indent) * listIndentStep
        style.firstLineHeadIndent = start
        style.headIndent = start + markerWidth
        style.tabStops = [NSTextTab(textAlignment: .left, location: start + markerWidth)]
        style.defaultTabInterval = listIndentStep
    }

    private static func isListItem(_ kind: AgentMessageMarkdownBlock.Kind) -> Bool {
        switch kind {
        case .bullet, .numbered, .task, .listContinuation: return true
        default: return false
        }
    }

    private static func spacingBefore(
        _ block: AgentMessageMarkdownBlock,
        previous: AgentMessageMarkdownBlock?,
        compact: Bool
    ) -> CGFloat {
        let gap: CGFloat = compact ? 6 : 10
        if case .heading = block.kind { return compact ? 8 : 14 }
        if let previous, isListItem(block.kind), isListItem(previous.kind) { return 4 }
        if let previous, block.quoteDepth > 0, previous.quoteDepth > 0 { return 6 }
        if let previous, case .heading = previous.kind { return compact ? 4 : 6 }
        return gap
    }

    // MARK: Block parser

    private static func computeBlocks(from text: String) -> [AgentMessageMarkdownBlock] {
        #if DEBUG
        blocksComputeCountForTesting &+= 1
        blocksParsedUTF8BytesForTesting &+= text.utf8.count
        #endif
        let blocks = parseBlocks(text.components(separatedBy: "\n"))
        return blocks.isEmpty ? [AgentMessageMarkdownBlock(kind: .paragraph, text: text)] : blocks
    }

    /// Columns of leading whitespace (a tab advances to the next multiple of
    /// 4) and the remaining content.
    static func measure(_ line: String) -> (indent: Int, content: Substring) {
        var columns = 0
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == " " {
                columns += 1
            } else if character == "\t" {
                columns += 4 - columns % 4
            } else {
                break
            }
            index = line.index(after: index)
        }
        return (columns, line[index...])
    }

    /// Removes up to `count` columns of leading whitespace.
    static func dropColumns(_ line: String, _ count: Int) -> String {
        var columns = 0
        var index = line.startIndex
        while index < line.endIndex, columns < count {
            let character = line[index]
            if character == " " {
                columns += 1
            } else if character == "\t" {
                let next = columns + 4 - columns % 4
                if next > count {
                    // A tab straddling the cut keeps its overshoot as spaces.
                    return String(repeating: " ", count: next - count) + line[line.index(after: index)...]
                }
                columns = next
            } else {
                break
            }
            index = line.index(after: index)
        }
        return String(line[index...])
    }

    /// ``` or ~~~ (3+); a backtick fence's info string may not contain a backtick.
    static func fenceOpener<S: StringProtocol>(_ content: S) -> (char: Character, length: Int, info: String)? {
        guard let first = content.first, first == "`" || first == "~" else { return nil }
        let run = content.prefix(while: { $0 == first }).count
        guard run >= 3 else { return nil }
        let info = content.dropFirst(run)
        if first == "`", info.contains("`") { return nil }
        let language = info.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
        return (first, run, language)
    }

    private static func isFenceClose<S: StringProtocol>(_ content: S, char: Character, length: Int) -> Bool {
        let run = content.prefix(while: { $0 == char }).count
        return run >= length && content.dropFirst(run).allSatisfy(\.isWhitespace)
    }

    static func isThematicBreak<S: StringProtocol>(_ content: S) -> Bool {
        guard let first = content.first, first == "-" || first == "*" || first == "_" else { return false }
        var count = 0
        for character in content {
            if character == first {
                count += 1
            } else if character != " " && character != "\t" {
                return false
            }
        }
        return count >= 3
    }

    private static func setextLevel<S: StringProtocol>(_ content: S) -> Int? {
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return nil }
        if trimmed.allSatisfy({ $0 == "=" }) { return 1 }
        if trimmed.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    private static func heading<S: StringProtocol>(from content: S) -> (level: Int, text: String)? {
        let level = content.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let rest = content.dropFirst(level)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // Optional closing sequence: "## Title ##".
        if let hashes = text.lastIndex(where: { $0 != "#" }), hashes < text.index(before: text.endIndex),
           text[hashes] == " " || text[hashes] == "\t" {
            text = String(text[...hashes]).trimmingCharacters(in: .whitespaces)
        } else if text.allSatisfy({ $0 == "#" }) {
            text = ""
        }
        return text.isEmpty ? nil : (level, text)
    }

    enum ListMarker: Equatable { case bullet, numbered(Int) }

    /// Detect bullet (`- ` / `* ` / `+ `) or ordered (`1. ` / `1) `) list items.
    /// `indent` is the marker column, `content` the column where item text starts.
    static func listItem(from rawLine: String) -> (indent: Int, content: Int, marker: ListMarker, text: String)? {
        let (indent, line) = measure(rawLine)
        guard let first = line.first else { return nil }
        let marker: ListMarker
        let markerLength: Int
        if first == "-" || first == "*" || first == "+" {
            marker = .bullet
            markerLength = 1
        } else {
            let digits = line.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, digits.count <= 9, let number = Int(digits) else { return nil }
            let separator = line.dropFirst(digits.count).first
            guard separator == "." || separator == ")" else { return nil }
            marker = .numbered(number)
            markerLength = digits.count + 1
        }
        let afterMarker = line.dropFirst(markerLength)
        guard let gap = afterMarker.first, gap == " " || gap == "\t" else { return nil }
        let spaces = afterMarker.prefix { $0 == " " || $0 == "\t" }.count
        let text = afterMarker.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        let content = indent + markerLength + (spaces > 4 ? 1 : spaces)
        return (indent, content, marker, text)
    }

    /// Splits a GFM table row into cells: outer pipes are optional, `\|` is a
    /// literal pipe, and a pipe inside an inline code span does not split.
    static func tableCells(from line: String) -> [String] {
        var content = Substring(line.trimmingCharacters(in: .whitespaces))
        if content.hasPrefix("|") { content = content.dropFirst() }
        var cells: [String] = []
        var current = ""
        var codeRun = 0
        var index = content.startIndex
        while index < content.endIndex {
            let character = content[index]
            if character == "\\", content.index(after: index) < content.endIndex,
               content[content.index(after: index)] == "|" {
                current.append("|")
                index = content.index(index, offsetBy: 2)
                continue
            }
            if character == "`" {
                let run = content[index...].prefix { $0 == "`" }.count
                if codeRun == 0 {
                    // Open only when a closing run of the same length follows.
                    let rest = content[content.index(index, offsetBy: run)...]
                    if hasBacktickRun(rest, length: run) { codeRun = run }
                } else if run == codeRun {
                    codeRun = 0
                }
                current += String(repeating: "`", count: run)
                index = content.index(index, offsetBy: run)
                continue
            }
            if character == "|", codeRun == 0 {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
            index = content.index(after: index)
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty || cells.isEmpty { cells.append(last) }
        return cells
    }

    private static func hasBacktickRun(_ text: Substring, length: Int) -> Bool {
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "`" else { index = text.index(after: index); continue }
            let run = text[index...].prefix { $0 == "`" }.count
            if run == length { return true }
            index = text.index(index, offsetBy: run)
        }
        return false
    }

    /// A GFM delimiter row: every cell is `:?-+:?`.
    static func tableAlignments(fromSeparator line: String) -> [AgentMessageMarkdownBlock.TableAlignment]? {
        guard line.contains("-") else { return nil }
        let cells = tableCells(from: line)
        var alignments: [AgentMessageMarkdownBlock.TableAlignment] = []
        for cell in cells {
            let left = cell.hasPrefix(":")
            let right = cell.hasSuffix(":") && cell.count > 1
            let dashes = cell.dropFirst(left ? 1 : 0).dropLast(right ? 1 : 0)
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            alignments.append(left && right ? .center : right ? .right : left ? .left : .none)
        }
        return alignments.isEmpty ? nil : alignments
    }

    /// Header row + delimiter row with the same column count.
    private static func tableStart(_ lines: [String], at index: Int) -> (headers: [String], alignments: [AgentMessageMarkdownBlock.TableAlignment])? {
        guard index + 1 < lines.count else { return nil }
        let (indent, content) = measure(lines[index])
        guard indent < 4, content.contains("|"), !content.hasPrefix(">") else { return nil }
        guard let alignments = tableAlignments(fromSeparator: lines[index + 1]),
              lines[index + 1].contains("|") || alignments.count == 1 else { return nil }
        let headers = tableCells(from: lines[index])
        guard headers.count == alignments.count else { return nil }
        return (headers, alignments)
    }

    /// Whether `lines[index]` opens a block that interrupts a paragraph or a
    /// lazily continued list item / quote.
    private static func startsBlock(_ lines: [String], at index: Int, paragraphOpen: Bool) -> Bool {
        let (indent, content) = measure(lines[index])
        if fenceOpener(content) != nil { return true }
        guard indent < 4 else { return false }
        if content.hasPrefix(">") || isThematicBreak(content) || heading(from: content) != nil { return true }
        if let item = listItem(from: lines[index]) {
            if paragraphOpen, case .numbered(let number) = item.marker, number != 1 { return false }
            return true
        }
        return tableStart(lines, at: index) != nil
    }

    /// Line-oriented CommonMark/GFM block parser tuned for chat replies.
    /// Quotes recurse on their de-quoted lines, so lists, code and nested
    /// quotes inside a quote parse like top-level content.
    static func parseBlocks(_ lines: [String]) -> [AgentMessageMarkdownBlock] {
        var blocks: [AgentMessageMarkdownBlock] = []
        var paragraph: [String] = []
        // Open list items: marker column and content column.
        var listStack: [(marker: Int, content: Int)] = []
        // Block whose text takes lazy continuation lines (a list item).
        var openItemIndex: Int?
        var previousBlank = false
        var i = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(AgentMessageMarkdownBlock(kind: .paragraph, text: paragraph.joined(separator: "\n")))
            paragraph.removeAll()
        }
        func closeLists() {
            listStack.removeAll()
            openItemIndex = nil
        }

        while i < lines.count {
            let line = lines[i]
            let (indent, content) = measure(line)
            if content.allSatisfy(\.isWhitespace) {
                flushParagraph()
                openItemIndex = nil
                previousBlank = true
                i += 1
                continue
            }
            let afterBlank = previousBlank
            previousBlank = false

            // Fenced code (any indentation; content loses the fence's indent).
            if let opener = fenceOpener(content) {
                flushParagraph()
                openItemIndex = nil
                if listStack.first.map({ indent < $0.content }) ?? false { listStack.removeAll() }
                var body: [String] = []
                i += 1
                while i < lines.count {
                    let (_, closing) = measure(lines[i])
                    if isFenceClose(closing, char: opener.char, length: opener.length) { i += 1; break }
                    body.append(dropColumns(lines[i], indent))
                    i += 1
                }
                blocks.append(AgentMessageMarkdownBlock(kind: .code(language: opener.info), text: body.joined(separator: "\n")))
                continue
            }

            if indent < 4 || !listStack.isEmpty {
                // Setext heading underline (only under a plain paragraph).
                if !paragraph.isEmpty, indent < 4, let level = setextLevel(content) {
                    blocks.append(AgentMessageMarkdownBlock(kind: .heading(level), text: paragraph.joined(separator: "\n")))
                    paragraph.removeAll()
                    i += 1
                    continue
                }
                if isThematicBreak(content), indent < 4 {
                    flushParagraph()
                    closeLists()
                    blocks.append(AgentMessageMarkdownBlock(kind: .rule, text: ""))
                    i += 1
                    continue
                }
                if indent < 4, let heading = heading(from: content) {
                    flushParagraph()
                    closeLists()
                    blocks.append(AgentMessageMarkdownBlock(kind: .heading(heading.level), text: heading.text))
                    i += 1
                    continue
                }
                if indent < 4, content.hasPrefix(">") {
                    flushParagraph()
                    closeLists()
                    var inner: [String] = []
                    var lastInnerBlank = false
                    while i < lines.count {
                        let (quoteIndent, quoteContent) = measure(lines[i])
                        if quoteIndent < 4, quoteContent.hasPrefix(">") {
                            var stripped = quoteContent.dropFirst()
                            if stripped.first == " " { stripped = stripped.dropFirst() }
                            inner.append(String(stripped))
                            lastInnerBlank = stripped.allSatisfy(\.isWhitespace)
                        } else if !quoteContent.allSatisfy(\.isWhitespace), !lastInnerBlank,
                                  !startsBlock(lines, at: i, paragraphOpen: true) {
                            inner.append(String(quoteContent))  // lazy continuation
                        } else {
                            break
                        }
                        i += 1
                    }
                    for var block in parseBlocks(inner) {
                        block.quoteDepth += 1
                        if case .paragraph = block.kind {
                            block = AgentMessageMarkdownBlock(kind: .blockquote, text: block.text, quoteDepth: block.quoteDepth)
                        }
                        blocks.append(block)
                    }
                    continue
                }
                if let table = tableStart(lines, at: i) {
                    flushParagraph()
                    closeLists()
                    var rows: [[String]] = []
                    i += 2
                    while i < lines.count {
                        let (rowIndent, rowContent) = measure(lines[i])
                        guard rowIndent < 4, rowContent.contains("|"), !rowContent.allSatisfy(\.isWhitespace) else { break }
                        var cells = tableCells(from: lines[i])
                        if cells.count < table.headers.count {
                            cells += Array(repeating: "", count: table.headers.count - cells.count)
                        } else if cells.count > table.headers.count {
                            cells = Array(cells.prefix(table.headers.count))
                        }
                        rows.append(cells)
                        i += 1
                    }
                    blocks.append(AgentMessageMarkdownBlock(
                        kind: .table(headers: table.headers, rows: rows, alignments: table.alignments),
                        text: ""
                    ))
                    continue
                }
                if let item = listItem(from: line),
                   indent < 4 || !listStack.isEmpty,
                   !(paragraph.isEmpty == false && { if case .numbered(let n) = item.marker { return n != 1 }; return false }()) {
                    flushParagraph()
                    while let last = listStack.last, item.indent < last.content { listStack.removeLast() }
                    let depth = listStack.count
                    listStack.append((item.indent, item.content))
                    let kind: AgentMessageMarkdownBlock.Kind
                    var text = item.text
                    switch item.marker {
                    case .numbered(let number):
                        kind = .numbered(number: number, indent: depth)
                    case .bullet:
                        if let checked = taskState(text) {
                            kind = .task(checked: checked, indent: depth)
                            text = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                        } else {
                            kind = .bullet(indent: depth)
                        }
                    }
                    blocks.append(AgentMessageMarkdownBlock(kind: kind, text: text))
                    openItemIndex = blocks.count - 1
                    i += 1
                    continue
                }
            }

            // Continuation of the open list item (indented or lazy).
            if let open = openItemIndex, !afterBlank, !startsBlock(lines, at: i, paragraphOpen: true) {
                let item = blocks[open]
                blocks[open] = AgentMessageMarkdownBlock(
                    kind: item.kind,
                    text: item.text + "\n" + content,
                    quoteDepth: item.quoteDepth
                )
                i += 1
                continue
            }

            // A later paragraph of a list item: indented to an open item's content.
            if paragraph.isEmpty, let outer = listStack.first {
                if indent >= outer.content {
                    while let last = listStack.last, indent < last.content { listStack.removeLast() }
                    blocks.append(AgentMessageMarkdownBlock(
                        kind: .listContinuation(indent: max(0, listStack.count - 1)),
                        text: String(content)
                    ))
                    openItemIndex = blocks.count - 1
                    i += 1
                    continue
                }
                listStack.removeAll()
            }

            // Indented code: 4+ columns where a new block may start.
            if indent >= 4, paragraph.isEmpty {
                var body: [String] = []
                while i < lines.count {
                    let (codeIndent, codeContent) = measure(lines[i])
                    let blank = codeContent.allSatisfy(\.isWhitespace)
                    guard blank || codeIndent >= 4 else { break }
                    body.append(blank ? "" : dropColumns(lines[i], 4))
                    i += 1
                }
                while body.last?.isEmpty == true { body.removeLast() }
                previousBlank = true
                blocks.append(AgentMessageMarkdownBlock(kind: .code(language: ""), text: body.joined(separator: "\n")))
                continue
            }

            paragraph.append(String(content))
            i += 1
        }
        flushParagraph()
        return blocks
    }

    /// `[ ] ` / `[x] ` / `[X] ` at the start of a bullet's text.
    private static func taskState(_ text: String) -> Bool? {
        guard text.count >= 4 else { return nil }
        let prefix = text.prefix(4)
        switch prefix {
        case "[ ] ": return false
        case "[x] ", "[X] ": return true
        default: return nil
        }
    }

    // MARK: Inline

    static func attributedInline(_ text: String, cache: Bool = true, fingerprint: Int? = nil) -> AttributedString {
        let key = fingerprint.map { cacheKey(for: text, fingerprint: $0) } ?? cacheKey(for: text)
        // Perf CH-04: `cache: false` skips only the store; the read still hits.
        if let cached = inlineCache.object(forKey: key) { return cached.value }
        let result = computeAttributedInline(text)
        let cost = text.utf8.count
        if shouldStoreMarkdownCache(textUTF8Count: cost, cache: cache) {
            inlineCache.setObject(AttributedBox(result), forKey: key, cost: cost)
            #if DEBUG
            inlineCacheStoreCountForTesting &+= 1
            #endif
        }
        return result
    }

    private static let lineBreakTag = try! NSRegularExpression(pattern: #"^<br\s*/?>$"#, options: [.caseInsensitive])

    /// Foundation's inline parser (GFM emphasis, strikethrough, code, links,
    /// autolinks) plus chat fixes: images leave the prose (they render in the
    /// gallery), `<br>` is a line break, other raw HTML stays literal text.
    /// Fonts for bold/italic/code are resolved later from the run intents, so
    /// headings, table cells and body text each get the right family and size.
    private static func computeAttributedInline(_ text: String) -> AttributedString {
        #if DEBUG
        inlineComputeCountForTesting &+= 1
        #endif
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var attributed = try? AttributedString(markdown: text, options: options) else {
            return AttributedString(text)
        }
        var removals: [Range<AttributedString.Index>] = []
        var breaks: [Range<AttributedString.Index>] = []
        for run in attributed.runs {
            if run.imageURL != nil {
                removals.append(run.range)
            } else if run.inlinePresentationIntent?.contains(.inlineHTML) == true {
                let tag = String(attributed.characters[run.range])
                let ns = tag as NSString
                if lineBreakTag.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)) != nil {
                    breaks.append(run.range)
                }
            }
        }
        for range in (removals + breaks).sorted(by: { $0.lowerBound > $1.lowerBound }) {
            if breaks.contains(range) {
                // U+2028: a line break that stays inside the paragraph (and
                // inside a table cell, where "\n" would end the cell).
                attributed.replaceSubrange(range, with: AttributedString("\u{2028}"))
            } else {
                attributed.removeSubrange(range)
            }
        }
        return keepingLineBreaksInParagraph(applyingDetectedLinks(to: attributed))
    }

    /// Soft and hard line breaks become U+2028 so they stay inside one
    /// paragraph: wrapped and continued lines keep a list item's hanging
    /// indent, block spacing applies once per block, and a `<br>` in a table
    /// cell does not end the cell.
    static func keepingLineBreaksInParagraph(_ source: AttributedString) -> AttributedString {
        guard source.characters.contains("\n") else { return source }
        // One pass over the runs (index arithmetic per break would be O(n·k)).
        var result = AttributedString()
        for run in source.runs {
            let slice = source[run.range]
            let text = String(slice.characters)
            if text.contains("\n") {
                result.append(AttributedString(text.replacingOccurrences(of: "\n", with: "\u{2028}"), attributes: run.attributes))
            } else {
                result.append(slice)
            }
        }
        return result
    }

    // MARK: Clickable mentions (UX-MAC_AGENT-OPEN-SPLIT)
    // Bare URLs and file-path mentions in transcript prose become tappable `.link`
    // runs so a click can open a Browser / Files split panel. File mentions use a
    // custom scheme carrying the raw token; the click handler resolves it against
    // the thread's working directory (detection stays a pure function of the text,
    // keeping the NSCache text-keyed).

    static let fileLinkScheme = "remotecode-file"

    static func fileLinkURL(for rawPath: String) -> URL? {
        var comps = URLComponents()
        comps.scheme = fileLinkScheme
        comps.host = "open"
        comps.queryItems = [URLQueryItem(name: "path", value: rawPath)]
        return comps.url
    }

    static func filePath(fromFileLink url: URL) -> String? {
        guard url.scheme == fileLinkScheme else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "path" })?.value
    }

    // Explicit-scheme / www. / localhost URLs only — no bare-domain detection, so
    // file names like "Reducer.swift" or "config.dev" never false-positive as web links.
    // Parentheses are allowed inside the URL (`wiki/Foo_(bar)`); an unbalanced
    // closing one is trimmed afterwards by `trimmingTrailingPunctuation`.
    private static let urlRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(?:https?://|file:///|www\.)[^\s<>"'\]\}]+|(?<![\w.])localhost:\d+[^\s<>"'\]\}]*"#
    )
    // Two shapes: rooted paths (`/abs`, `~/x`, `./x`, `../x`) and relative paths that
    // contain a slash AND end in a file extension (so "and/or" or "I/O" never match).
    // Both accept a trailing `:line(:col)` suffix.
    private static let pathRegex = try! NSRegularExpression(
        pattern: #"(?<![\w@.\-/])(?:~|\.{1,2})?/(?:[\w.\-+@]+/)*[\w.\-+@]+(?::\d+(?::\d+)?)?|(?<![\w@.\-/~])(?:[\w.\-+@]+/)+[\w.\-+@]+\.[A-Za-z]\w{0,7}(?::\d+(?::\d+)?)?"#
    )

    // Bare filenames ("Package.swift", "foo.test.ts") are only linked inside inline
    // code spans, where a file mention is unambiguous.
    private static let bareFilenameRegex = try! NSRegularExpression(
        pattern: #"(?<![\w.\-/~])[\w\-]+(?:\.[\w\-]+)*\.[A-Za-z]\w{0,7}(?::\d+(?::\d+)?)?(?![\w/])"#
    )

    static func applyingDetectedLinks(to source: AttributedString) -> AttributedString {
        var hasSlashOrDot = false
        for character in source.characters {
            if character == "/" || character == "." {
                hasSlashOrDot = true
                break
            }
        }
        guard hasSlashOrDot else { return source }

        // NSRange is native on NSAttributedString, so each match is O(1) instead of
        // `String.distance` + `AttributedString.Index` offset from startIndex.
        let ns = NSMutableAttributedString(attributedString: NSAttributedString(source))
        let nsText = ns.string as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let sourceHasLinks = source.runs.contains { $0.link != nil }

        func rangesOverlap(_ a: NSRange, _ b: NSRange) -> Bool {
            a.location < b.location + b.length && b.location < a.location + a.length
        }
        func hasExistingLink(_ range: NSRange) -> Bool {
            guard sourceHasLinks else { return false }
            guard range.length > 0, NSMaxRange(range) <= ns.length else { return true }
            var found = false
            ns.enumerateAttribute(.link, in: range, options: []) { value, _, stop in
                if value != nil {
                    found = true
                    stop.pointee = true
                }
            }
            return found
        }
        func markLink(_ range: NSRange, url: URL) {
            ns.addAttribute(.link, value: url, range: range)
            ns.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            ns.addAttribute(.foregroundColor, value: DS.NS.accent, range: range)
        }
        func mappedTrimmed(_ range: NSRange) -> NSRange? {
            let trimmed = trimmingTrailingPunctuation(nsText, range)
            return trimmed.length > 0 ? trimmed : nil
        }

        // Raw HTML stays literal text: `</span>` is not a file path.
        var claimed: [NSRange] = source.runs.compactMap { run in
            guard run.inlinePresentationIntent?.contains(.inlineHTML) == true else { return nil }
            return NSRange(run.range, in: source)
        }

        for match in urlRegex.matches(in: ns.string, range: fullRange) {
            guard let range = mappedTrimmed(match.range),
                  !claimed.contains(where: { rangesOverlap($0, range) }),
                  !hasExistingLink(range) else { continue }
            let token = nsText.substring(with: range)
            guard let url = normalizedWebURL(token) else { continue }
            if url.isFileURL {
                guard let fileLink = fileLinkURL(for: url.path) else { continue }
                markLink(range, url: fileLink)
            } else {
                markLink(range, url: url)
            }
            claimed.append(range)
        }

        for match in pathRegex.matches(in: ns.string, range: fullRange) {
            guard let range = mappedTrimmed(match.range),
                  !claimed.contains(where: { rangesOverlap($0, range) }),
                  !hasExistingLink(range) else { continue }
            guard let fileLink = fileLinkURL(for: nsText.substring(with: range)) else { continue }
            markLink(range, url: fileLink)
            claimed.append(range)
        }

        // Bare filenames: restricted to inline-code runs. Collect UTF-16 ranges
        // from the source runs before mutation (few spans; not the 50-match path).
        let codeNSRanges: [NSRange] = source.runs.compactMap { run in
            guard run.inlinePresentationIntent?.contains(.code) == true else { return nil }
            return NSRange(run.range, in: source)
        }
        for nsRange in codeNSRanges {
            for match in bareFilenameRegex.matches(in: ns.string, range: nsRange) {
                guard let range = mappedTrimmed(match.range),
                      !claimed.contains(where: { rangesOverlap($0, range) }),
                      !hasExistingLink(range) else { continue }
                guard let fileLink = fileLinkURL(for: nsText.substring(with: range)) else { continue }
                markLink(range, url: fileLink)
                claimed.append(range)
            }
        }

        // NSAttributedString keeps AppKit keys (link, underline, NSColor).
        // SwiftUI font/background/intent would otherwise drop on the way back.
        var result = AttributedString(ns)
        for run in source.runs {
            let nsRange = NSRange(run.range, in: source)
            guard nsRange.length > 0, let range = Range(nsRange, in: result) else { continue }
            if let font = run.font {
                result[range].font = font
            }
            if let backgroundColor = run.backgroundColor {
                result[range].backgroundColor = backgroundColor
            }
            if let intent = run.inlinePresentationIntent {
                result[range].inlinePresentationIntent = intent
            }
            let addedLink = run.link == nil && result[range].link != nil
            if addedLink { continue }
            if let foregroundColor = run.foregroundColor {
                result[range].foregroundColor = foregroundColor
            }
        }
        return result
    }

    /// "https://x", "file:///x" parse directly; "www.x" and "localhost:3000" get a
    /// scheme prepended so the resulting `.link` URL is loadable.
    static func normalizedWebURL(_ token: String) -> URL? {
        let lower = token.lowercased()
        if lower.hasPrefix("www.") { return URL(string: "https://\(token)") }
        if lower.hasPrefix("localhost:") { return URL(string: "http://\(token)") }
        return URL(string: token)
    }

    /// Sentence punctuation glued to a match ("see /a/b.swift.") is not part of the
    /// token. A trailing ")" is kept only while the token's parentheses balance
    /// (`wiki/Foo_(bar)` keeps it, `(see https://x/y)` drops it).
    private static func trimmingTrailingPunctuation(_ text: NSString, _ range: NSRange) -> NSRange {
        var length = range.length
        while length > 0 {
            let last = text.substring(with: NSRange(location: range.location + length - 1, length: 1))
            if ".,;:!?\"'".contains(last) {
                length -= 1
            } else if last == ")" {
                let token = text.substring(with: NSRange(location: range.location, length: length))
                let opens = token.reduce(0) { $0 + ($1 == "(" ? 1 : 0) }
                let closes = token.reduce(0) { $0 + ($1 == ")" ? 1 : 0) }
                guard closes > opens else { break }
                length -= 1
            } else {
                break
            }
        }
        return NSRange(location: range.location, length: length)
    }

    /// IMP-010: Copies `text` to the system general pasteboard.
    /// Extracted as a static helper so it can be unit-tested independently of the SwiftUI view.
    @MainActor
    static func copyCodeToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

/// Copy-button chrome for a fenced code block. Hover/copied @State is local so
/// `AgentMessageMarkdownView` stays equatable on `text` and does not re-run
/// `blocks(from:)` when the pointer enters or leaves Copy.
struct CodeBlockCopyChrome: View {
    let text: String
    /// Fence info string ("swift"); empty hides the label.
    var language: String = ""
    @State private var hovered = false
    @State private var copied = false
    @FocusState private var copyFocused: Bool

    /// Copy stays mounted so keyboard and VoiceOver reach it without a
    /// pointer; hover or keyboard focus only decides whether it is painted.
    nonisolated static func copyOpacity(hovered: Bool, focused: Bool) -> Double {
        hovered || focused ? 1 : 0
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                if !language.isEmpty {
                    Text(language.lowercased())
                        .font(DS.Font.caption2.monospaced())
                        .foregroundColor(DS.Palette.textTertiary)
                        .lineLimit(1)
                        .accessibilityLabel(L("%1$@ code", language))
                }
                AgentSelectablePlainText(
                    text: text.isEmpty ? " " : text,
                    fontSize: 11,
                    monospaced: true,
                    textColor: DS.NS.text
                )
            }
            .padding(DS.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))

            Button(action: {
                AgentMessageMarkdown.copyCodeToPasteboard(text)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    copied = false
                }
            }) {
                Text(copied ? L("Copied") : L("Copy"))
                    .font(DS.Font.caption2)
                    .foregroundColor(DS.Palette.textSecondary)
                    .padding(.horizontal, DS.Space.sm)
                    .padding(.vertical, DS.Space.xxs)
                    .background(DS.Palette.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
                    // Fade the label, not the Button: a zero-opacity control
                    // can drop out of the accessibility tree.
                    .opacity(Self.copyOpacity(hovered: hovered, focused: copyFocused))
            }
            .buttonStyle(.plain)
            .focused($copyFocused)
            .accessibilityLabel(copied ? L("Copied") : L("Copy code"))
            .accessibilityIdentifier("agent.codeBlock.copy")
            .help(L("Copy code to clipboard"))
            .padding(DS.Space.sm)
        }
        .onHover { inside in
            withAnimation(.easeInOut(duration: 0.12)) {
                hovered = inside
            }
        }
    }
}

public struct AgentMessageMarkdownView: View, Equatable {
    let text: String
    var compact: Bool = false
    /// When false (live streaming rows), parse results are not inserted into NSCache
    /// so growing partial bodies cannot thrash occupancy (R4-B).
    var cacheResults: Bool = true

    public init(text: String, compact: Bool = false, cacheResults: Bool = true) {
        self.text = text
        self.compact = compact
        self.cacheResults = cacheResults
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.compact == rhs.compact && lhs.cacheResults == rhs.cacheResults
    }

    public var body: some View {
        let groups = AgentMessageMarkdown.selectionGroups(
            from: AgentMessageMarkdown.blocks(from: text, cache: cacheResults)
        )
        VStack(alignment: .leading, spacing: compact ? DS.Space.sm : DS.Space.md) {
            // Iterate the existing collection's indices instead of allocating an
            // enumerated Array on every SwiftUI body pass. Positional ids stay
            // because content-hash ids remount the live streaming group on every token.
            ForEach(groups.indices, id: \.self) { index in
                let group = groups[index]
                // Unary ForEach child (AvdLee list-patterns).
                Group {
                    if group.count == 1, let block = group.first, isIsolatedBlock(block) {
                        blockView(block)
                    } else {
                        // Perf CH-04: only the last group of a live row can still
                        // grow; earlier groups parse (and cache) like finished
                        // content so tokens do not re-parse stable paragraphs.
                        let prose = AgentMessageMarkdown.selectableProse(
                            from: group,
                            compact: compact,
                            cache: cacheResults || index < groups.count - 1
                        )
                        // An image-only paragraph shows in the gallery; an
                        // empty text view would still reserve a blank line.
                        if !prose.characters.isEmpty {
                            AgentLinkedAttributedText(
                                attributed: prose,
                                font: .systemFont(ofSize: AgentMessageMarkdown.bodyFontSize),
                                textColor: DS.NS.text,
                                lineFragmentPadding: 0,
                                lineSpacing: compact ? 3 : 5
                            )
                        }
                    }
                }
            }
        }
        // Selection lives inside AgentLinkedInlineText (NSTextView). Applying
        // SwiftUI `.textSelection` here would put an I-beam over the whole block
        // and hide the pointing-hand cursor on split-opening links.
    }

    private func isIsolatedBlock(_ block: AgentMessageMarkdownBlock) -> Bool {
        switch block.kind {
        case .code, .table, .rule: return true
        default: return false
        }
    }

    /// Blocks that are not prose: everything else shares one NSTextView per
    /// group (`selectableProse`).
    @ViewBuilder
    private func blockView(_ block: AgentMessageMarkdownBlock) -> some View {
        switch block.kind {
        case .code(let language):
            CodeBlockCopyChrome(text: block.text, language: language)
        case .table(let headers, let rows, let alignments):
            AgentMarkdownTableView(headers: headers, rows: rows, alignments: alignments)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
                .frame(maxWidth: .infinity, alignment: .leading)
        case .rule:
            Rectangle()
                .fill(DS.Palette.line)
                .frame(height: DS.Border.hairline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, compact ? DS.Space.xxs : DS.Space.xs)
                .accessibilityHidden(true)
        default:
            EmptyView()
        }
    }
}

// MARK: - Tables

/// Builds the attributed text of a GFM table: one NSTextTable whose cells are
/// sized to their content (capped) so the table can be wider than the column
/// and scroll horizontally instead of crushing its columns.
enum AgentMarkdownTableLayout {
    static let maxColumnWidth: CGFloat = 320
    static let minColumnWidth: CGFloat = 28
    static let cellPaddingX: CGFloat = 10
    static let cellPaddingY: CGFloat = 5
    static let fontSize: CGFloat = 12.5

    final class Built {
        let text: NSAttributedString
        let width: CGFloat
        init(text: NSAttributedString, width: CGFloat) {
            self.text = text
            self.width = width
        }
    }

    private static let cache: NSCache<NSString, Built> = {
        let cache = NSCache<NSString, Built>()
        cache.countLimit = 64
        return cache
    }()

    static func build(
        headers: [String],
        rows: [[String]],
        alignments: [AgentMessageMarkdownBlock.TableAlignment]
    ) -> Built {
        var hasher = Hasher()
        hasher.combine(headers)
        hasher.combine(rows)
        hasher.combine(alignments)
        let key = "table:\(hasher.finalize())" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let columns = max(1, headers.count)
        let headerFont = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let bodyFont = NSFont.systemFont(ofSize: fontSize)
        let grid: [[NSAttributedString]] = ([headers] + rows).enumerated().map { rowIndex, row in
            (0..<columns).map { column in
                let source = column < row.count ? row[column] : ""
                return AgentLinkedInlineTextRepresentable.makeNSAttributedString(
                    attributed: AgentMessageMarkdown.attributedInline(source),
                    font: rowIndex == 0 ? headerFont : bodyFont,
                    textColor: DS.NS.text,
                    lineSpacing: 2
                )
            }
        }
        var widths = [CGFloat](repeating: minColumnWidth, count: columns)
        for row in grid {
            for (column, cell) in row.enumerated() {
                let natural = ceil(cell.boundingRect(
                    with: NSSize(width: 10_000, height: 10_000),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                ).width) + 1
                widths[column] = min(maxColumnWidth, max(widths[column], natural))
            }
        }

        let table = NSTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        let output = NSMutableAttributedString()
        for (rowIndex, row) in grid.enumerated() {
            for (column, cell) in row.enumerated() {
                let block = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
                block.setValue(widths[column], type: .absoluteValueType, for: .width)
                block.setWidth(cellPaddingX, type: .absoluteValueType, for: .padding, edge: .minX)
                block.setWidth(cellPaddingX, type: .absoluteValueType, for: .padding, edge: .maxX)
                block.setWidth(cellPaddingY, type: .absoluteValueType, for: .padding, edge: .minY)
                block.setWidth(cellPaddingY, type: .absoluteValueType, for: .padding, edge: .maxY)
                block.setWidth(DS.Border.hairline, type: .absoluteValueType, for: .border)
                block.setBorderColor(DS.NS.line)
                if rowIndex == 0 {
                    block.backgroundColor = DS.NS.surface
                } else if rowIndex % 2 == 0 {
                    block.backgroundColor = DS.NS.surface.withAlphaComponent(0.45)
                }
                let style = NSMutableParagraphStyle()
                style.textBlocks = [block]
                style.lineSpacing = 2
                switch column < alignments.count ? alignments[column] : .none {
                case .center: style.alignment = .center
                case .right: style.alignment = .right
                case .left, .none: style.alignment = .left
                }
                let paragraph = NSMutableAttributedString(attributedString: cell)
                paragraph.append(NSAttributedString(string: "\n", attributes: [.font: rowIndex == 0 ? headerFont : bodyFont]))
                paragraph.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: paragraph.length))
                output.append(paragraph)
            }
        }
        let width = widths.reduce(0) { $0 + $1 + cellPaddingX * 2 } + CGFloat(columns + 1) * DS.Border.hairline
        let built = Built(text: output, width: ceil(width))
        cache.setObject(built, forKey: key)
        return built
    }
}

/// Horizontal-only scroll view that hands vertical wheel gestures to the
/// transcript, so a wide table never traps the page scroll.
final class AgentHorizontalScrollView: NSScrollView {
    private var gestureIsHorizontal = false

    override func scrollWheel(with event: NSEvent) {
        if event.phase == .began || (event.phase.isEmpty && event.momentumPhase.isEmpty) {
            gestureIsHorizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        }
        let fits = (documentView?.frame.width ?? 0) <= contentView.bounds.width + 0.5
        if gestureIsHorizontal, !fits {
            super.scrollWheel(with: event)
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }
}

/// GFM table: one selectable TextKit 1 NSTextView (NSTextTable) inside an
/// AppKit horizontal scroller. AppKit on purpose: a SwiftUI ScrollView nested
/// in the transcript ScrollView reads the parent's scroll environment and
/// crashes on macOS 26 (see `AgentTranscriptImageThumbStrip`).
struct AgentMarkdownTableView: NSViewRepresentable {
    let headers: [String]
    let rows: [[String]]
    let alignments: [AgentMessageMarkdownBlock.TableAlignment]

    final class Coordinator: NSObject, NSTextViewDelegate {
        var openURL: OpenURLAction?
        weak var textView: NSTextView?
        var built: AgentMarkdownTableLayout.Built?
        var textHeight: CGFloat = 0

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard let url, let openURL else { return false }
            openURL(url)
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AgentHorizontalScrollView {
        let scroll = AgentHorizontalScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .automatic
        scroll.borderType = .noBorder

        let textView = NSTextView(usingTextLayoutManager: false)
        textView.textContainer?.replaceLayoutManager(AgentMarkdownLayoutManager())
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.allowsUndo = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.linkTextAttributes = [
            .foregroundColor: DS.NS.accent,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        scroll.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.openURL = context.environment.openURL
        apply(context: context)
        return scroll
    }

    func updateNSView(_ scroll: AgentHorizontalScrollView, context: Context) {
        context.coordinator.openURL = context.environment.openURL
        apply(context: context)
    }

    /// `CGSize?` on purpose: a non-optional return does not witness the
    /// protocol requirement, and SwiftUI would size the scroll view to zero.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AgentHorizontalScrollView, context: Context) -> CGSize? {
        apply(context: context)
        let tableWidth = context.coordinator.built?.width ?? 0
        var available = tableWidth
        if let width = proposal.width, width.isFinite, width > 0 { available = width }
        var height = context.coordinator.textHeight
        if tableWidth > available + 0.5, nsView.scrollerStyle == .legacy {
            height += NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        }
        return CGSize(width: min(available, tableWidth), height: height)
    }

    private func apply(context: Context) {
        let built = AgentMarkdownTableLayout.build(headers: headers, rows: rows, alignments: alignments)
        let coordinator = context.coordinator
        guard coordinator.built !== built, let textView = coordinator.textView,
              let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        coordinator.built = built
        container.containerSize = NSSize(width: built.width + 2, height: CGFloat.greatestFiniteMagnitude)
        textView.textStorage?.setAttributedString(built.text)
        layoutManager.ensureLayout(for: container)
        // The last cell's terminator leaves an empty extra line fragment
        // under the table; it is not part of the table.
        var used = layoutManager.usedRect(for: container).height
        if layoutManager.extraLineFragmentTextContainer != nil {
            used -= layoutManager.extraLineFragmentUsedRect.height
        }
        let height = ceil(max(0, used))
        coordinator.textHeight = height
        textView.frame = NSRect(x: 0, y: 0, width: built.width + 2, height: height)
    }
}

/// UX-MAC_AGENT-006: monospace diff preview for approval requests, colorizing
/// +/-/@@/header lines. Caps rendered lines so a large patch can't dominate.
struct DiffPreviewText: View {
    private let attributed: AttributedString

    init(_ diff: String, maxLines: Int = 200) {
        self.attributed = Self.render(diff, maxLines: maxLines)
    }

    var body: some View {
        AgentLinkedAttributedText(
            attributed: attributed,
            font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            textColor: DS.NS.text,
            lineFragmentPadding: 0,
            lineSpacing: 0
        )
    }

    private static func render(_ diff: String, maxLines: Int) -> AttributedString {
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false)
        let shown = lines.prefix(maxLines)
        var out = AttributedString()
        for line in shown {
            var seg = AttributedString(String(line) + "\n")
            if line.hasPrefix("+") && !line.hasPrefix("+++") {
                seg.foregroundColor = DS.Palette.success
                seg.backgroundColor = DS.Palette.success.opacity(0.08)
            } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                seg.foregroundColor = DS.Palette.danger
                seg.backgroundColor = DS.Palette.danger.opacity(0.08)
            } else if line.hasPrefix("@@") {
                seg.foregroundColor = DS.Palette.accent
            } else if line.hasPrefix("diff --git") || line.hasPrefix("+++") || line.hasPrefix("---") {
                seg.foregroundColor = DS.Palette.warning
            } else {
                seg.foregroundColor = DS.Palette.textSecondary
            }
            out.append(seg)
        }
        if lines.count > maxLines {
            var more = AttributedString(L("… %1$@ more lines", lines.count - maxLines))
            more.foregroundColor = DS.Palette.textSecondary
            out.append(more)
        }
        return out
    }
}

/// Cursor-style "Edit path" card with line numbers and red/green hunks.
struct AgentFileEditDiffCard: View {
    let model: AgentFileEditDiffPresentation.Model
    var initiallyExpanded: Bool = false
    @State private var expanded: Bool
    @State private var showAllLines = false

    init(
        model: AgentFileEditDiffPresentation.Model,
        initiallyExpanded: Bool = AgentWorkDisclosureLayout.diffDefaultExpanded
    ) {
        self.model = model
        self.initiallyExpanded = initiallyExpanded
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        let visible = AgentWorkDisclosureLayout.visibleDiffLines(
            model.lines,
            isMeta: { $0.kind == .meta },
            showAll: showAllLines
        )
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.14)) { expanded.toggle() }
            } label: {
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: "diamond.fill")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(DS.Palette.textTertiary)
                    Text(L("Edit"))
                        .font(DS.Font.caption.weight(.semibold))
                        .foregroundColor(DS.Palette.textSecondary)
                    if let path = model.path, !path.isEmpty {
                        AgentSelectablePlainText(
                            text: path,
                            fontSize: 11,
                            textColor: DS.NS.warning,
                            maximumNumberOfLines: 1
                        )
                    }
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(DS.Palette.textTertiary)
                }
                .padding(.horizontal, DS.Space.sm)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? L("Hide file edit diff") : L("Show file edit diff"))
            .accessibilityIdentifier("agent.fileEdit.header")

            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(visible.rows) { line in
                        diffLineRow(line)
                    }
                    if visible.hiddenCount > 0 {
                        Button {
                            showAllLines = true
                        } label: {
                            Text(L("Show %1$@ more lines", visible.hiddenCount))
                                .font(DS.Font.caption2)
                                .foregroundColor(DS.Palette.accent)
                                .padding(.horizontal, DS.Space.sm)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("agent.fileEdit.showMore")
                    } else if model.hiddenLineCount > 0 {
                        Text(L("… %1$@ more lines truncated", model.hiddenLineCount))
                            .font(DS.Font.caption2)
                            .foregroundColor(DS.Palette.textSecondary)
                            .padding(.horizontal, DS.Space.sm)
                            .padding(.vertical, 4)
                    }
                }
                .background(DS.Palette.surface)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.surfaceRaised.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
        )
        .accessibilityIdentifier("agent.fileEdit.diff")
    }

    @ViewBuilder
    private func diffLineRow(_ line: AgentFileEditDiffPresentation.Line) -> some View {
        let bg: Color = {
            switch line.kind {
            case .addition: return DS.Palette.success.opacity(0.14)
            case .deletion: return DS.Palette.danger.opacity(0.16)
            case .hunk: return DS.Palette.accent.opacity(0.06)
            default: return Color.clear
            }
        }()
        let fg: Color = {
            switch line.kind {
            case .addition: return DS.Palette.success
            case .deletion: return DS.Palette.danger
            case .hunk: return DS.Palette.accent
            case .context: return DS.Palette.textSecondary
            case .meta: return DS.Palette.textTertiary
            }
        }()
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(line.displayLineNumber.map(String.init) ?? " ")
                .font(DS.Font.monoSmall.monospacedDigit())
                .foregroundColor(DS.Palette.textTertiary)
                .frame(width: 36, alignment: .trailing)
                .padding(.trailing, 8)
            Text(displayText(for: line))
                .font(DS.Font.monoSmall)
                .foregroundColor(fg)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
        .padding(.trailing, DS.Space.sm)
        .background(bg)
    }

    private func displayText(for line: AgentFileEditDiffPresentation.Line) -> String {
        switch line.kind {
        case .addition: return line.text.isEmpty ? " " : line.text
        case .deletion: return line.text.isEmpty ? " " : line.text
        case .hunk: return line.text
        case .context, .meta: return line.text.isEmpty ? " " : line.text
        }
    }
}
