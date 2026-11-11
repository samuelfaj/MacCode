import Foundation
import AppKit
import WebKit
import CoreModel

@MainActor
public final class MarkdownSurface: NSObject, Surface, WKNavigationDelegate {
    private nonisolated static let maxMarkdownBytes = 512 * 1024

    public private(set) var descriptor: SurfaceDescriptor
    public let view: NSView
    private let webView: WKWebView
    public private(set) var filePath: String?
    private var isVisible = true
    /// Last known scroll offset, captured before hide / blanking so a long
    /// README returns to the same place instead of jumping to top (UX-016).
    private var savedScrollY: Double = 0
    /// Generation token so a slow background render can't overwrite a newer
    /// load (e.g. file changed via `load(filePath:)` mid-render) (PERF-012).
    private var renderGeneration = 0

    public init(workspaceID: WorkspaceID, filePath: String?, title: String = "markdown") {
        self.descriptor = SurfaceDescriptor(
            type: .markdown,
            title: title,
            iconName: "doc.text",
            metadata: ["workspace": workspaceID.value.uuidString, "path": filePath ?? ""]
        )
        self.filePath = filePath
        let cfg = WKWebViewConfiguration()
        cfg.suppressesIncrementalRendering = false
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.translatesAutoresizingMaskIntoConstraints = false
        wv.setValue(false, forKey: "drawsBackground")
        self.webView = wv

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(wv)
        NSLayoutConstraint.activate([
            wv.topAnchor.constraint(equalTo: container.topAnchor),
            wv.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            wv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        self.view = container

        super.init()
        // UX-017: intercept the rc-action: links (open / reveal in Finder).
        wv.navigationDelegate = self
        loadAndRender()
    }

    public func load(filePath: String) {
        self.filePath = filePath
        descriptor.metadata["path"] = filePath
        savedScrollY = 0
        loadAndRender()
    }

    private func loadAndRender() {
        guard isVisible else { return }
        // PERF-012: read disk + render HTML off the main actor so creating
        // / revealing the surface doesn't block layout on I/O for big files;
        // hop back to main only to load the string into the webview.
        renderGeneration &+= 1
        let gen = renderGeneration
        let path = filePath
        let restoreY = savedScrollY
        Task.detached(priority: .userInitiated) {
            let body = Self.loadMarkdownBody(filePath: path)
            let html = Self.renderHTML(markdown: body, scrollY: restoreY)
            await MainActor.run { [weak self] in
                guard let self, gen == self.renderGeneration, self.isVisible else { return }
                self.webView.loadHTMLString(html, baseURL: path.flatMap { URL(fileURLWithPath: $0).deletingLastPathComponent() })
            }
        }
    }

    nonisolated static func loadMarkdownBody(filePath: String?, maxBytes: Int = MarkdownSurface.maxMarkdownBytes) -> String {
        guard let path = filePath,
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return L("# Markdown Preview\n\nNo file loaded.")
        }
        defer { try? handle.close() }
        let limit = max(1, maxBytes)
        let data = (try? handle.read(upToCount: limit + 1)) ?? Data()
        let clipped = Data(data.prefix(limit))
        guard var body = String(data: clipped, encoding: .utf8) else {
            return L("# Markdown Preview\n\nUnable to render this file as UTF-8 markdown.")
        }
        if data.count > limit {
            // UX-017: a truncated preview is a dead-end without an escape
            // hatch; offer Open / Reveal links handled by the nav delegate.
            body += L("\n\n---\n\n_Preview truncated after %1$@ bytes._", limit)
            body += L("\n\n[Open full file in default app](rc-action:open) · [Reveal in Finder](rc-action:reveal)")
        }
        return body
    }

    /// Minimal Markdown -> HTML translator. Handles headings, code fences,
    /// inline code, bold, italic, lists, paragraphs, links, hr. Good
    /// enough for in-app preview of READMEs; not CommonMark-complete.
    public nonisolated static func renderHTML(markdown: String, scrollY: Double = 0) -> String {
        // PERF-011: accumulate fragments and join once instead of repeated
        // `body += …` on a Swift String (avoids O(n²) reallocation).
        var frags: [String] = []
        var inFence = false
        var fenceLang = ""
        var fenceBuf: [String] = []
        var inList = false

        func closeList() {
            if inList { frags.append("</ul>\n"); inList = false }
        }

        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine
            if inFence {
                if line.hasPrefix("```") {
                    frags.append("<pre><code class=\"lang-\(fenceLang)\">" + escape(fenceBuf.joined(separator: "\n")) + "</code></pre>\n")
                    inFence = false; fenceBuf.removeAll(); fenceLang = ""
                } else {
                    fenceBuf.append(line)
                }
                continue
            }
            if line.hasPrefix("```") {
                closeList()
                inFence = true
                fenceLang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { closeList(); continue }
            if trimmed == "---" || trimmed == "***" { closeList(); frags.append("<hr/>\n"); continue }
            if let h = headingLevel(line) {
                closeList()
                let content = inlineMD(String(line.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces))
                frags.append("<h\(h)>\(content)</h\(h)>\n")
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                if !inList { frags.append("<ul>\n"); inList = true }
                let item = inlineMD(String(line.dropFirst(2)))
                frags.append("<li>\(item)</li>\n")
                continue
            }
            closeList()
            frags.append("<p>\(inlineMD(line))</p>\n")
        }
        if inFence {
            frags.append("<pre><code class=\"lang-\(fenceLang)\">" + escape(fenceBuf.joined(separator: "\n")) + "</code></pre>\n")
        }
        closeList()
        let body = frags.joined()

        // UX-016: honor system appearance via prefers-color-scheme instead
        // of a forced dark page; ship both palettes and let the OS pick.
        let css = """
        :root { color-scheme: light dark; }
        body { font: 14px -apple-system, system-ui; color: #1c2530; background: #ffffff; padding: 24px; max-width: 820px; margin: 0 auto; }
        h1 { font-size: 28px; border-bottom: 1px solid #d6dde4; padding-bottom: 8px; }
        h2 { font-size: 22px; border-bottom: 1px solid #d6dde4; padding-bottom: 4px; }
        h3 { font-size: 18px; }
        pre { position: relative; background: #f4f6f8; border: 1px solid #d6dde4; border-radius: 6px; padding: 12px; overflow: auto; }
        code { background: #eef1f4; padding: 1px 5px; border-radius: 4px; font-family: ui-monospace, "SF Mono", Menlo, monospace; }
        /* IMP-010: per-fence copy button, revealed on hover. */
        pre code { background: none; padding: 0; }
        .rc-copy { position: absolute; top: 6px; right: 6px; opacity: 0; transition: opacity .12s; cursor: pointer; font: 11px -apple-system, system-ui; color: #1c2530; background: #ffffff; border: 1px solid #d6dde4; border-radius: 4px; padding: 2px 7px; }
        pre:hover .rc-copy { opacity: 1; }
        .rc-copy:hover { background: #eef1f4; }
        a { color: #1769c9; text-decoration: none; }
        a:hover { text-decoration: underline; }
        ul { padding-left: 22px; }
        hr { border: 0; border-top: 1px solid #d6dde4; margin: 22px 0; }
        @media (prefers-color-scheme: dark) {
          body { color: #e7edf3; background: #0f1419; }
          h1, h2 { border-bottom-color: #2a3440; }
          pre { background: #0a0e13; border-color: #2a3440; }
          code { background: #1a1f26; }
          a { color: #7cc7ff; }
          hr { border-top-color: #2a3440; }
          .rc-copy { color: #e7edf3; background: #1a1f26; border-color: #2a3440; }
          .rc-copy:hover { background: #222831; }
        }
        """
        // UX-016: restore the saved scroll offset after the body lays out.
        let scrollJS = scrollY > 0 ? "window.scrollTo(0,\(Int(scrollY)));" : ""
        // IMP-010: inject a "Copy" button into every <pre> that copies the
        // raw fenced code to the clipboard; self-contained, no parser change.
        let copyJS = """
        function rcCopy(t,b){
          function ok(){b.textContent='Copied';setTimeout(function(){b.textContent='Copy';},1200);}
          if(navigator.clipboard&&navigator.clipboard.writeText){navigator.clipboard.writeText(t).then(ok,function(){rcExec(t,ok);});}
          else{rcExec(t,ok);}
        }
        function rcExec(t,ok){
          var ta=document.createElement('textarea');ta.value=t;ta.style.position='fixed';ta.style.opacity='0';
          document.body.appendChild(ta);ta.select();try{document.execCommand('copy');ok();}catch(e){}document.body.removeChild(ta);
        }
        document.querySelectorAll('pre').forEach(function(pre){
          var b=document.createElement('button');b.className='rc-copy';b.textContent='Copy';
          b.addEventListener('click',function(){var c=pre.querySelector('code');rcCopy(c?c.innerText:pre.innerText,b);});
          pre.appendChild(b);
        });
        """
        let script = "<script>window.addEventListener('load',function(){\(copyJS)\(scrollJS)});</script>"
        return "<!doctype html><html><head><meta charset=\"utf-8\"><style>\(css)</style></head><body>\(body)\(script)</body></html>"
    }

    private nonisolated static func headingLevel(_ line: String) -> Int? {
        var n = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == "#" {
            n += 1
            idx = line.index(after: idx)
        }
        // SEP-3: CommonMark requires a space/tab (or EOL) after the run —
        // "#hashtag" and "####### x" are paragraphs, not headings.
        guard (1...6).contains(n) else { return nil }
        guard idx == line.endIndex || line[idx] == " " || line[idx] == "\t" else { return nil }
        return n
    }

    private nonisolated static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    private nonisolated static func inlineMD(_ s: String) -> String {
        var t = escape(s)
        func apply(_ regex: NSRegularExpression?, _ template: String) {
            guard let regex else { return }
            let nsRange = NSRange(t.startIndex..<t.endIndex, in: t)
            t = regex.stringByReplacingMatches(in: t, range: nsRange, withTemplate: template)
        }
        // links [text](url) then bold **x**, italic *x*, inline code `x`.
        apply(mdLinkRegex, "<a href=\"$2\">$1</a>")
        apply(mdBoldRegex, "<strong>$1</strong>")
        apply(mdItalicRegex, "<em>$1</em>")
        apply(mdCodeRegex, "<code>$1</code>")
        return t
    }

    public func focus() { view.window?.makeFirstResponder(webView) }
    public func unfocus() {}
    public func didBecomeVisible() {
        guard !isVisible else { return }
        isVisible = true
        loadAndRender()
    }
    public func didBecomeHidden() {
        guard isVisible else { return }
        isVisible = false
        // UX-016: remember scroll position before blanking so returning to
        // the surface restores it instead of snapping to the top.
        // Blanking is deferred into the completion handler so the offset is
        // captured BEFORE the webview is cleared (fixes scroll-offset race).
        webView.evaluateJavaScript("window.scrollY") { [weak self] value, _ in
            guard let self else { return }
            if let y = Self.scrollYFromJS(value) { self.savedScrollY = y }
            self.webView.stopLoading()
            self.webView.loadHTMLString("", baseURL: nil)
        }
    }

    /// Decode the `Any?` value returned by WKWebView evaluateJavaScript("window.scrollY").
    /// WKWebView may return the JS Number as Double or NSNumber depending on platform/version.
    /// Returns nil when the value is missing or an unexpected type (offset is left unchanged).
    nonisolated static func scrollYFromJS(_ value: Any?) -> Double? {
        if let y = value as? Double { return y }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    // MARK: UX-017 escape-hatch links

    public func webView(_ webView: WKWebView,
                        decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
        if url.scheme == "rc-action" {
            // host carries the verb for rc-action:open / rc-action:reveal.
            handleAction(url.host ?? "")
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    private func handleAction(_ verb: String) {
        guard let path = filePath else { return }
        let fileURL = URL(fileURLWithPath: path)
        switch verb {
        case "open": NSWorkspace.shared.open(fileURL)
        case "reveal": NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        default: break
        }
    }

    public func close() {}
    public func sendText(_ text: String) {}
    public func readText() -> String { filePath ?? "" }
    public func snapshot() -> [String: String] { ["path": filePath ?? ""] }
}

// PERF-010: compile the four inline-markdown regexes once at file scope and
// reuse them, rather than building four `NSRegularExpression`s per line of
// the document. File-level lets are not actor-isolated so the nonisolated
// renderer can read them. NSRegularExpression is thread-safe for matching.
private let mdLinkRegex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^)]+)\)"#)
private let mdBoldRegex = try? NSRegularExpression(pattern: #"\*\*([^*]+)\*\*"#)
private let mdItalicRegex = try? NSRegularExpression(pattern: #"\*([^*]+)\*"#)
private let mdCodeRegex = try? NSRegularExpression(pattern: "`([^`]+)`")
