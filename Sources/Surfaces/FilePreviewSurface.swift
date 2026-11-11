import Foundation
import AppKit
import ImageIO
import Quartz
import CoreModel

/// Immutable UTF-16 line-start index for the read-only preview ruler.
/// Build once with the loaded text, then resolve the first visible line in O(log lines).
struct FilePreviewLineIndex: Sendable, Equatable {
    // Preview text is capped at 512 KiB, so UInt32 covers every UTF-16 offset
    // while halving the index storage versus native-width Int on macOS.
    private let lineStartOffsets: [UInt32]

    init(text: String) {
        var offsets: [UInt32] = [0]
        var utf16Offset: UInt32 = 0
        for codeUnit in text.utf16 {
            utf16Offset += 1
            if codeUnit == 0x0A { offsets.append(utf16Offset) }
        }
        lineStartOffsets = offsets
    }

    var lineCount: Int { lineStartOffsets.count }
    var storageBytesForTesting: Int { lineStartOffsets.count * MemoryLayout<UInt32>.stride }

    /// Returns the 1-based line containing `charOffset`.
    /// Exact line starts belong to the new line; a newline itself stays on the prior line.
    func lineNumber(forCharacterOffset charOffset: Int) -> Int {
        guard charOffset > 0, !lineStartOffsets.isEmpty else { return 1 }
        let boundedOffset = UInt32(clamping: charOffset)
        var low = 0
        var high = lineStartOffsets.count
        while low < high {
            let middle = low + (high - low) / 2
            if lineStartOffsets[middle] <= boundedOffset {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return max(1, low)
    }
}

// Pure text-content cache -- no AppKit deps; safe to test without a display.
// Caches the UTF-8 string and its UTF-16 line index together so visibility reloads
// avoid both the 512KB FileHandle read and rebuilding the gutter index.
public struct FilePreviewTextCache {
    private struct Entry {
        let text: String
        let lineIndex: FilePreviewLineIndex
    }

    private var store: [String: Entry] = [:]

    public init() {}

    public mutating func store(path: String, text: String) {
        store(path: path, text: text, lineIndex: FilePreviewLineIndex(text: text))
    }

    mutating func store(path: String, text: String, lineIndex: FilePreviewLineIndex) {
        store[path] = Entry(text: text, lineIndex: lineIndex)
    }

    public func text(for path: String) -> String? {
        store[path]?.text
    }

    func cachedEntry(for path: String) -> (text: String, lineIndex: FilePreviewLineIndex)? {
        guard let entry = store[path] else { return nil }
        return (entry.text, entry.lineIndex)
    }

    public mutating func evict(path: String) {
        store.removeValue(forKey: path)
    }

    public mutating func removeAll() {
        store.removeAll(keepingCapacity: false)
    }

    var entryCountForTesting: Int { store.count }
    var retainedPayloadBytesForTesting: Int {
        store.values.reduce(into: 0) {
            $0 += $1.text.utf8.count + $1.lineIndex.storageBytesForTesting
        }
    }

    /// Pure helper: returns true when cachedPath differs from newPath (reload required).
    /// Nonisolated -- touches no AppKit state; callable from any context.
    public nonisolated static func shouldReload(cachedPath: String?, newPath: String) -> Bool {
        cachedPath != newPath
    }
}

// PDF-document cache -- keyed by absolute file path.
// PDFDocument is a reference type and not Equatable; stored separately from the text cache.
// Avoids re-running PDFDocument(url:) (synchronous disk parse) on every didBecomeVisible.
public final class FilePreviewPDFCache {
    private var store: [String: PDFDocument] = [:]

    public init() {}

    public func store(path: String, document: PDFDocument) {
        store[path] = document
    }

    public func document(for path: String) -> PDFDocument? {
        store[path]
    }

    public func evict(path: String) {
        store.removeValue(forKey: path)
    }

    public func removeAll() {
        store.removeAll(keepingCapacity: false)
    }

    var entryCountForTesting: Int { store.count }
}

// Pure scroll/page cache -- no AppKit deps; safe to test without a display.
// Keyed by absolute file path. Scroll offset is a Y-axis CGFloat (points from top).
// PDF page is a zero-based Int. Unknown key returns (offset: 0, page: 0).
public struct FilePreviewScrollCache {
    public struct Entry: Equatable {
        public var scrollOffsetY: CGFloat
        public var pdfPageIndex: Int
        public init(scrollOffsetY: CGFloat = 0, pdfPageIndex: Int = 0) {
            self.scrollOffsetY = scrollOffsetY
            self.pdfPageIndex = pdfPageIndex
        }
    }

    private var store: [String: Entry] = [:]

    public init() {}

    public mutating func store(path: String, entry: Entry) {
        store[path] = entry
    }

    public func entry(for path: String) -> Entry {
        store[path] ?? Entry()
    }
}

// Render strategy for a given file extension.
// .native  - handled by a first-class renderer (image / PDF / text).
// .quicklook - no native renderer; fall back to QLPreviewView.
public enum FileRenderStrategy: Equatable {
    case native
    case quicklook
}

@MainActor
public final class FilePreviewSurface: NSObject, Surface {
    private nonisolated static let maxTextPreviewBytes = 512 * 1024

    /// Pure helper: decide render strategy from a lowercased file extension.
    /// Never touches AppKit state; safe to call from any isolation context.
    public nonisolated static func renderStrategy(for ext: String) -> FileRenderStrategy {
        let lowered = ext.lowercased()
        let nativeExts: Set<String> = [
            "png", "jpg", "jpeg", "gif", "bmp", "tiff", "heic", "webp",
            "pdf",
            "txt", "md", "swift", "py", "js", "ts", "json", "yaml", "yml",
            "sh", "bash", "zsh", "rb", "go", "rs", "c", "cpp", "h", "hpp",
            "java", "kt", "cs", "html", "css", "xml", "toml", "ini", "cfg",
            "log", "gitignore", "env"
        ]
        return nativeExts.contains(lowered) ? .native : .quicklook
    }

    public private(set) var descriptor: SurfaceDescriptor
    public let view: NSView
    public private(set) var filePath: String?
    private let containerStack: NSView
    private var isVisible = true
    private var renderGeneration: UInt64 = 0
    var scrollCache = FilePreviewScrollCache()
    var textCache = FilePreviewTextCache()
    let pdfCache = FilePreviewPDFCache()
    var previewTextLoaderForTesting: (@Sendable (String) -> String)?
    var previewTextPublicationProbeForTesting: (@MainActor @Sendable (String, Bool) -> Void)?

    public init(workspaceID: WorkspaceID, filePath: String?, title: String = "preview") {
        self.descriptor = SurfaceDescriptor(
            type: .filePreview,
            title: title,
            iconName: "doc",
            metadata: ["workspace": workspaceID.value.uuidString, "path": filePath ?? ""]
        )
        self.filePath = filePath
        let stack = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        self.containerStack = stack
        self.view = stack
        super.init()
        renderForFile(filePath)
    }

    public func load(filePath: String) {
        if self.filePath != filePath {
            releaseHeavyContent()
        }
        renderGeneration &+= 1
        self.filePath = filePath
        descriptor.metadata["path"] = filePath
        renderForFile(filePath)
    }

    private func renderForFile(_ path: String?) {
        guard isVisible else { return }
        for sub in containerStack.subviews { sub.removeFromSuperview() }
        guard let p = path else {
            let label = NSTextField(labelWithString: "No file selected")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.textColor = .secondaryLabelColor
            // a11y identifier so UI automation and VoiceOver can locate the
            // placeholder (P3 empty-state a11y).
            label.setAccessibilityIdentifier("filePreview.empty")
            label.setAccessibilityLabel("No file selected")
            containerStack.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: containerStack.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: containerStack.centerYAnchor)
            ])
            return
        }
        let ext = (p as NSString).pathExtension.lowercased()
        switch Self.renderStrategy(for: ext) {
        case .quicklook:
            renderQuickLook(path: p)
        case .native:
            if ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "heic", "webp"].contains(ext) {
                renderImage(path: p)
            } else if ext == "pdf" {
                renderPDF(path: p)
            } else {
                renderText(path: p)
            }
        }
    }

    private func renderImage(path: String) {
        let generation = renderGeneration
        let iv = NSImageView()
        iv.imageScaling = .scaleProportionallyDown
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.setAccessibilityIdentifier("filePreview.image")
        containerStack.addSubview(iv)
        pin(iv)
        // Decode off the main thread into a downsampled image rather than synchronously
        // decoding the full-resolution NSImage on the RPC/main path (PERF-MAC_FILES-005).
        // kCGImageSourceShouldCacheImmediately decodes on this detached task so
        // first paint does not pay ImageIO on the main thread.
        let url = URL(fileURLWithPath: path)
        Task { [weak self, weak iv] in
            let image = await Task.detached(priority: .userInitiated) {
                Self.decodeDownsampled(url: url)
            }.value
            guard let self,
                  self.isVisible,
                  self.filePath == path,
                  self.renderGeneration == generation else { return }
            iv?.image = image
        }
    }

    /// Longest decoded edge for Files / File Preview thumbs. 4096² RGBA is
    /// ~64 MiB per image; 2048² is ~16 MiB and still covers Retina preview.
    nonisolated static let thumbnailMaxPixelSize = 2048

    nonisolated static func decodeDownsampled(url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixelSize
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private func renderPDF(path: String) {
        let generation = renderGeneration
        let pdf = PDFView()
        pdf.autoScales = true
        pdf.translatesAutoresizingMaskIntoConstraints = false
        pdf.setAccessibilityIdentifier("filePreview.pdf")
        containerStack.addSubview(pdf)
        pin(pdf)
        let saved = scrollCache.entry(for: path)
        let url = URL(fileURLWithPath: path)

        // Load PDFDocument off the main thread to avoid blocking the render path
        // (PERF: PDFDocument(url:) reads/parses the PDF file synchronously).
        // Re-use cached result if this path was already loaded.
        if let cached = pdfCache.document(for: path) {
            // Cache hit -- apply document immediately on main (no I/O).
            pdf.document = cached
            Self.applyPDFScrollRestore(pdf: pdf, doc: cached, saved: saved)
        } else {
            Task { [weak self, weak pdf] in
                let doc = await Task.detached(priority: .userInitiated) {
                    PDFDocument(url: url)
                }.value
                guard let self,
                      self.isVisible,
                      self.filePath == path,
                      self.renderGeneration == generation,
                      let pdf else { return }
                if let doc {
                    self.pdfCache.store(path: path, document: doc)
                    pdf.document = doc
                    Self.applyPDFScrollRestore(pdf: pdf, doc: doc, saved: saved)
                } else {
                    // PDFDocument(url:) returned nil — show an error state instead
                    // of leaving a silently blank pane (P2 PDF-nil error state).
                    self.showPDFError(over: pdf)
                }
            }
        }
    }

    /// Overlay a simple error label on `pdfView` when the PDF fails to load.
    private func showPDFError(over pdfView: NSView) {
        let label = NSTextField(labelWithString: "Unable to load PDF")
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityIdentifier("filePreview.pdfError")
        pdfView.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: pdfView.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: pdfView.centerYAnchor)
        ])
    }

    @MainActor
    private static func applyPDFScrollRestore(pdf: PDFView, doc: PDFDocument?, saved: FilePreviewScrollCache.Entry) {
        guard saved.pdfPageIndex > 0,
              let doc,
              saved.pdfPageIndex < doc.pageCount,
              let page = doc.page(at: saved.pdfPageIndex) else { return }
        pdf.go(to: page)
    }

    private func renderText(path: String) {
        let generation = renderGeneration
        let previewTextLoader = previewTextLoaderForTesting ?? { path in
            Self.previewText(path: path)
        }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let tv = NSTextView()
        tv.isEditable = false
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.textContainerInset = .init(width: 8, height: 8)
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        // Native Cmd+F find within the preview text via NSTextView's built-in find bar
        // (IMP-MAC_FILES-001). Selectable read-only text still supports find/search.
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.setAccessibilityIdentifier("filePreview.text")
        scroll.documentView = tv
        // Line-number ruler: mirrors the Files editor gutter pattern.
        // PreviewLineNumberRulerView is a read-only NSRulerView subclass defined below.
        let ruler = PreviewLineNumberRulerView(textView: tv)
        scroll.hasVerticalRuler = true
        scroll.verticalRulerView = ruler
        scroll.rulersVisible = true
        containerStack.addSubview(scroll)
        pin(scroll)
        let saved = scrollCache.entry(for: path)

        // Load text bytes off the main thread to avoid blocking the render path
        // (PERF: previewText reads up to 512KB synchronously via FileHandle).
        // Re-use cached result if this path was already loaded.
        if let cached = textCache.cachedEntry(for: path) {
            // Cache hit -- apply text immediately on main (no I/O).
            ruler.replaceLineIndex(cached.lineIndex)
            tv.string = cached.text
            Self.applyTextScrollRestore(scroll: scroll, saved: saved)
        } else {
            Task { [weak self, weak tv, weak scroll, weak ruler] in
                let loaded = await Task.detached(priority: .userInitiated) {
                    let text = previewTextLoader(path)
                    return (text, FilePreviewLineIndex(text: text))
                }.value
                guard let self else { return }
                let shouldPublish = self.isVisible
                    && self.filePath == path
                    && self.renderGeneration == generation
                    && tv != nil
                    && scroll != nil
                    && ruler != nil
                self.previewTextPublicationProbeForTesting?(loaded.0, shouldPublish)
                guard shouldPublish, let tv, let scroll, let ruler else { return }
                self.textCache.store(path: path, text: loaded.0, lineIndex: loaded.1)
                ruler.replaceLineIndex(loaded.1)
                tv.string = loaded.0
                Self.applyTextScrollRestore(scroll: scroll, saved: saved)
            }
        }
    }

    @MainActor
    private static func applyTextScrollRestore(scroll: NSScrollView, saved: FilePreviewScrollCache.Entry) {
        guard saved.scrollOffsetY != 0 else { return }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: saved.scrollOffsetY))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Pure helper: count 1-based lines in `text`.
    /// A completely empty string has 1 line. A trailing newline adds one phantom empty line.
    /// Nonisolated -- no AppKit; callable from any isolation context or test.
    public nonisolated static func lineCount(for text: String) -> Int {
        if text.isEmpty { return 1 }
        var n = 1
        for c in text.utf16 where c == 0x0A { n += 1 }
        return n
    }

    /// Pure helper: return the 1-based line number that contains `charOffset` (UTF-16 offset).
    /// Scans the UTF-16 code units up to `charOffset` and counts newlines.
    /// Returns 1 for any offset in an empty string or when offset <= 0.
    /// Retained as the reference implementation for correctness and A/B performance proof;
    /// the production ruler uses the precomputed `FilePreviewLineIndex` instead.
    public nonisolated static func lineNumber(forCharacterOffset charOffset: Int, in text: String) -> Int {
        guard charOffset > 0 else { return 1 }
        let ns = text as NSString
        let length = min(charOffset, ns.length)
        var line = 1
        var i = 0
        while i < length {
            if ns.character(at: i) == 0x0A { line += 1 }
            i += 1
        }
        return line
    }

    nonisolated static func previewText(path: String, maxBytes: Int = FilePreviewSurface.maxTextPreviewBytes) -> String {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return "[unable to read file]"
        }
        defer { try? handle.close() }
        let limit = max(1, maxBytes)
        let data = (try? handle.read(upToCount: limit + 1)) ?? Data()
        let clipped = Data(data.prefix(limit))
        if var content = String(data: clipped, encoding: .utf8) {
            if data.count > limit {
                content += "\n\n" + L("[preview truncated after %1$@ bytes]", limit)
            }
            return content
        }
        let suffix = data.count > limit ? "at least " : ""
        return L("[binary file, %1$@%2$@ bytes]", suffix, data.count)
    }

    private func renderQuickLook(path: String) {
        let ql = QLPreviewView()
        ql.previewItem = URL(fileURLWithPath: path) as QLPreviewItem
        ql.autostarts = true
        ql.translatesAutoresizingMaskIntoConstraints = false
        ql.setAccessibilityIdentifier("filePreview.quicklook")
        containerStack.addSubview(ql)
        pin(ql)
    }

    private func pin(_ v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: containerStack.topAnchor),
            v.bottomAnchor.constraint(equalTo: containerStack.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: containerStack.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: containerStack.trailingAnchor)
        ])
    }

    public func focus() { view.window?.makeFirstResponder(view) }
    public func unfocus() {}
    public func didBecomeVisible() {
        guard !isVisible else { return }
        isVisible = true
        renderForFile(filePath)
    }
    public func didBecomeHidden() {
        guard isVisible else { return }
        isVisible = false
        renderGeneration &+= 1
        if let path = filePath {
            var entry = FilePreviewScrollCache.Entry()
            for sub in containerStack.subviews {
                if let scroll = sub as? NSScrollView {
                    entry.scrollOffsetY = scroll.contentView.bounds.origin.y
                } else if let pdf = sub as? PDFView {
                    entry.pdfPageIndex = pdf.currentPage.flatMap { pdf.document?.index(for: $0) } ?? 0
                }
            }
            scrollCache.store(path: path, entry: entry)
        }
        for sub in containerStack.subviews { sub.removeFromSuperview() }
        releaseHeavyContent()
    }
    public func close() {
        didBecomeHidden()
        releaseHeavyContent()
    }

    private func releaseHeavyContent() {
        textCache.removeAll()
        pdfCache.removeAll()
    }
    public func sendText(_ text: String) {}
    public func readText() -> String { filePath ?? "" }
    public func snapshot() -> [String: String] { ["path": filePath ?? ""] }
}

// MARK: - Line-number ruler for read-only text preview

/// Minimal NSRulerView subclass that draws 1-based line numbers aligned to the
/// NSTextView's line-fragment rects. Follows the same AppKit pattern as
/// CodeLineNumberRulerView in FilesSurface (AppShell), adapted for the read-only
/// preview context where the palette and edit callbacks are not needed.
///
/// Redraws only when the visible glyph range changes (coalesced via boundsChanged).
private final class PreviewLineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private var lastVisibleGlyphRange = NSRange(location: NSNotFound, length: 0)
    private var lineIndex = FilePreviewLineIndex(text: "")

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 46
        if let clip = textView.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(boundsChanged),
                name: NSView.boundsDidChangeNotification,
                object: clip
            )
        }
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func replaceLineIndex(_ index: FilePreviewLineIndex) {
        lineIndex = index
        lastVisibleGlyphRange = NSRange(location: NSNotFound, length: 0)
        needsDisplay = true
    }

    // Redraw only when the set of visible lines actually changes (not on every
    // scroll tick / horizontal scroll / sub-pixel jitter).
    @objc private func boundsChanged() {
        guard let textView,
              let lm = textView.layoutManager,
              let tc = textView.textContainer,
              let clip = textView.enclosingScrollView?.contentView else {
            needsDisplay = true
            return
        }
        let gr = lm.glyphRange(forBoundingRect: clip.bounds, in: tc)
        guard !NSEqualRanges(gr, lastVisibleGlyphRange) else { return }
        lastVisibleGlyphRange = gr
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let lm = textView.layoutManager,
              let tc = textView.textContainer,
              let clip = textView.enclosingScrollView?.contentView else { return }

        // Background
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let bgColor: NSColor = isDark
            ? NSColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1)
            : NSColor(red: 0.91, green: 0.91, blue: 0.91, alpha: 1)
        let fgColor: NSColor = isDark
            ? NSColor(red: 0.45, green: 0.47, blue: 0.50, alpha: 1)
            : NSColor(red: 0.42, green: 0.44, blue: 0.47, alpha: 1)
        bgColor.setFill()
        bounds.fill()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: fgColor
        ]
        let visibleRect = clip.bounds
        let glyphRange = lm.glyphRange(forBoundingRect: visibleRect, in: tc)
        guard glyphRange.location < lm.numberOfGlyphs else { return }

        // O(log lines): resolve the first visible line from the immutable UTF-16 index.
        let firstCharIndex = lm.characterIndexForGlyph(at: glyphRange.location)
        var lineNumber = lineIndex.lineNumber(forCharacterOffset: firstCharIndex)

        var glyphIndex = glyphRange.location
        while glyphIndex < NSMaxRange(glyphRange) {
            var lineRange = NSRange()
            let lineRect = lm.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: &lineRange,
                withoutAdditionalLayout: true
            )
            let y = lineRect.minY + textView.textContainerOrigin.y - visibleRect.minY
            let label = "\(lineNumber)" as NSString
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y + 1), withAttributes: attrs)
            glyphIndex = NSMaxRange(lineRange)
            lineNumber += 1
        }
    }
}
