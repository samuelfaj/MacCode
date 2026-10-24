# GAUNTLET LOOP — MacCode Files section → native VS Code Explorer + Editor

## HOW TO RUN (paste this into a fresh session)

```text
Build Rebuild only the MacCode Files section (NSOutlineView Explorer + TextKit 2 editor, SwiftUI shell) to match VS Code, as specified in /Users/samuelfajreldines/dev/remote-code/macos-app/PROMPT.md; read and obey it fully. Base every decision on the microsoft/vscode source. Test everything end to end only in the isolated MacCode copy with mac-use.. The bar is VS Code Dark Modern Explorer + editor, same window size, workspace and open file (github.com/microsoft/vscode + /Applications/Visual Studio Code.app; /tmp/gauntlet-files/vscode-reference.jpg). Get the real thing first. Screenshot it at the same viewport and compare against those captures directly, not against a description of them. Break this into the smallest pieces that can be improved and judged on their own. For each piece, fan out a builder and a separate critic with fresh context. The critic inspects the actual output, puts it next to the bar blind with the labels stripped, says which one is better, and names the single biggest remaining gap. Then it goes back to the builder. The critic should be a harsh critic. Praise is not useful. If ours does not win, it keeps going. Keep looping until the critic picks ours blind, or I stop the run. Launch a workflow that owns the loop with agent and parallel. Children do not spawn children. Never resume the critic from the builder. Watch /workflows.
```

Everything below is the binding spec the loop reads.

---

## 0. MISSION

Rebuild ONLY the existing Files section of MacCode (Explorer on the left, code editor on the right) so it looks and behaves nearly indistinguishable from Visual Studio Code's Explorer and editor (Dark Modern theme), and fix the bugs the current version has. Use a native hybrid SwiftUI + AppKit architecture. Do not rebuild VS Code. Do not change unrelated sections.

Done means production-ready, responsive, functional, maintainable — verified in the running isolated app, not just compiled.

## 0a. ALWAYS-ON RULES (apply to every builder and critic, every iteration)

### Source of truth: `https://github.com/microsoft/vscode`

Every visual and behavioral decision must be based on the real VS Code source, not on memory or guesses.

- Clone once, shallow, outside the repo: `git clone --depth 1 https://github.com/microsoft/vscode /tmp/vscode-src` (reuse it if it exists; `git -C /tmp/vscode-src pull --depth 1` to refresh). Never vendor VS Code code or assets into MacCode; read it and reimplement in Swift. VS Code is MIT-licensed; if any asset (e.g. codicon glyph data) is copied, add the attribution to `THIRD_PARTY_NOTICES.md` in the same change.
- Take exact values from the source, and cite file + line in the code comment or in `GAUNTLET_PROGRESS.md` for each one:
  - Colors: `extensions/theme-defaults/themes/dark_modern.json` (+ `dark_plus.json`, `dark_vs.json` it inherits) for workbench colors and token colors.
  - Explorer tree: `src/vs/base/browser/ui/tree/` (`abstractTree.ts`, `media/tree.css`: row height 22, indent 8, twistie, indent guides), `src/vs/workbench/contrib/files/browser/views/explorerView.ts`, `explorerViewer.ts`, `media/explorerviewlet.css`, `src/vs/base/browser/ui/list/` (list styles, focus/selection/hover).
  - Tabs and breadcrumbs: `src/vs/workbench/browser/parts/editor/` (`multiEditorTabsControl.ts`, `media/multieditortabscontrol.css`, `breadcrumbsControl.ts`, `media/breadcrumbscontrol.css`, `editorGroupView.ts`).
  - Editor: `src/vs/editor/common/config/editorOptions.ts` (font size, line height, padding, gutter widths, defaults), `src/vs/editor/browser/viewParts/` (`lineNumbers`, `currentLineHighlight`, `indentGuides`, `rulers`, `viewCursors`, `selections`), `src/vs/editor/contrib/stickyScroll/`, `src/vs/editor/contrib/bracketMatching/`, `suggest/browser/media/suggest.css` (completion popup geometry), `find/browser/findWidget.css`.
  - Keybindings and behaviors: the `KeybindingsRegistry` / `registerAction2` entries next to each feature (explorer, editor, find, comment, go to line) — map them to macOS equivalents VS Code uses on darwin.
  - Icons: `src/vs/base/browser/ui/codicons/` (codicons) and the Seti file icon theme in `extensions/theme-seti/` (`icons/vs-seti-icon-theme.json`) for per-extension glyphs and colors.
- When MacCode and the source disagree, the source wins. When the live app and the source disagree (e.g. user settings), use default settings in the live app so they match the source.
- Critics must cite the VS Code source location behind every reported discrepancy.

### Testing: always the isolated MacCode copy, always end to end with mac-use

- All edits, builds, tests and launches happen in the isolated sandbox worktree: `cd "$(scripts/isolated-sandbox.sh ensure)"`, `scripts/isolated-sandbox.sh test [--filter …]`, `scripts/isolated-sandbox.sh run`, `scripts/isolated-sandbox.sh stop`. Read `.grok/skills/isolated-sandbox/SKILL.md` first.
- Never test against the user's running MacCode (`io.remotecode.desktop`). Never `pkill -x RemoteCode`, never `osascript` quit it, never `scripts/run-app.sh`. Keep `RC2_DISABLE_MANAGED_DISTILL_RECONCILE=1`.
- Every change, however small, is exercised end to end in the running debug app `io.remotecode.desktop.debug` with the mac-use MCP before it counts: read the mac-use skill, `list_windows` → exact `target_pid` + `target_window_id`, observe with `get_ui_tree` / `screenshot`, act with `click_element` / `set_value` / `menu_shortcut` using the latest state token.
- Run every mac-use session through `scripts/macos-ui-lease.sh -- …` (read-only by default; `--allow-input` only for one bounded, reversible E2E that must click/type/press keys/drag). If the lease is held by someone else, wait or stop the UI step; never compete for input.
- Each E2E pass covers the user flow, not just a render: open fixture workspace → expand folders → open files in tabs → edit → undo/redo → save → close/reopen app (state restored) → create/rename/delete/move in the tree → external change → find/replace → go to line → toggle comment; then check the Bots home files mount and one unrelated surface for regressions; narrow and wide window.
- VS Code screenshots for comparison come from `/Applications/Visual Studio Code.app` with the same fixture workspace and window size (mac-use read-only observation of that window is allowed).
- Clean up: stop the sandbox app you launched, release mac-use sessions/recordings. Anything that could not be exercised (native file picker, forbidden input) is reported as **unverified**, never as tested.

## 1. THE BAR (visual reference)

- **Reference:** `/tmp/gauntlet-files/vscode-reference.jpg` (VS Code, Dark Modern, `theme.js` open, Explorer showing `DEMO-TRAVEL-BLOG`).
- **Source bar:** `https://github.com/microsoft/vscode` (see §0a) — exact values come from here.
- **Live bar:** `/Applications/Visual Studio Code.app` (`com.microsoft.VSCode`). Open the same fixture workspace in it, same window size, same expanded folders, same file and scroll position, Dark Modern theme, and screenshot it. Compare against that live capture, not against a description.
- **Current broken state:** `/tmp/gauntlet-files/maccode-files-before.jpg`.

If `/tmp/gauntlet-files/` is gone, ask the user to re-supply the screenshots; the live VS Code app is still the bar.

### Gaps already visible in the "before" screenshot (fix all)

| Area | MacCode today | VS Code target |
| --- | --- | --- |
| Editor gutter | Line numbers `1–4` render **below** the text, misaligned with the lines they label | Gutter numbers aligned on each line's baseline, right-aligned, active line number brighter |
| Explorer rows | Every row has a horizontal separator line; tall rows; large font | No separators, 22 pt rows, 13 pt UI font, 8 pt indent step + twistie |
| Explorer header | `EXPLORER` + `E1` root + always-visible action icons + raw absolute path line + extra `root` row | `EXPLORER  ···` header, collapsible bold uppercase root (`DEMO-TRAVEL-BLOG`), action icons only on hover, no path line, no duplicate root |
| Filter field | Big always-visible `Filter files…` text field | VS Code filters by typing in the tree (find widget) — no permanent field |
| Selection | Thick blue bordered rectangle | Flat `#37373D`-style inactive / `#04395E` + `#0078D4` focus outline when focused; hover `#2A2D2E` |
| Icons | Same generic doc glyph for every file | Per-language file icons (Seti-like: `JS`, `#`, `<>`, `{}`, gear, image…) and folder chevrons only (no folder glyphs in default theme) |
| Tabs | Tall tabs, mismatched widths, wrong active indicator | 35 pt tabs, active tab top border/background, inactive dimmed, dirty dot ↔ close `×` swap, `1, M` decorations |
| Breadcrumbs | One-line filename bar mixed with `Up to date / Source / Preview / Split / Save / Discard` buttons that overlap ("Up to dat") | `src › lib › stores › JS theme.js › createThemeStore › toggle` breadcrumb row; actions live in the tab bar's right-side icon group; nothing truncates or overlaps |
| Editor text | Code starts far from gutter, no indent guides, no current-line highlight | Indent guides, current line highlight, bracket pair colors/matching, sticky scroll header line (as in reference line 16), minimap-free is acceptable |
| Git | No git decorations | Modified files/folders in orange/yellow with `M`/`U`/count badges and folder dots, gutter change bars |

## 2. REPOSITORY FACTS (audited — re-verify before relying on them)

- Swift Package, `Package.swift` platform `.macOS(.v14)` → **TextKit 2 is available** (`NSTextLayoutManager`, `NSTextContentStorage`, `NSTextViewportLayoutController`). Verify behavior on 14 before relying on 15+ APIs; gate any newer API with `#available`.
- Current implementation is one 4 975-line file: `Sources/AppShell/FilesSurface.swift`
  - `FilesSurface` (Surface host), `FilesViewModel` (state), `FilesSurfaceRoot` (SwiftUI view, line ~1954)
  - Explorer is a SwiftUI `List(selection:)` (~line 2206) fed by `FileTreeStore` / `FileTreeNode` (~lines 239–517) → replace with `NSOutlineView`.
  - Editor: `CodeEditorTextView: NSTextView` (~line 4116) + `CodeLineNumberRulerView: NSRulerView` (~line 4572) — the gutter misalignment bug lives here.
  - `EditorColorPalette` (~line 760); `TextField("Filter files…")` (~line 2177).
  - Markdown Preview / Split uses `WKWebView` (~lines 3434–3528).
- Existing pieces to **reuse, not duplicate**: `FilesEditorIntelligence.swift`, `FilesLanguageServer.swift` (already a Swift LSP client with `LSPFrameReader`), `FilesSuggestWidget.swift` (completion popup), `HostFileAccessPermissions.swift`, `BotHomeFilesRouter.swift`.
- Files data comes through a router (`fsWorkspaceList(workspace:path:)` etc.), not direct `FileManager` calls from the view — keep that seam so remote/bot workspaces keep working.
- `FilesSurfaceRoot` is mounted in **two places**: the workspace Files surface and Bots (`BotsWindow.swift` ~line 15443, via `BotHomeFilesRouter`). Both must work after the change.
- Existing tests to keep green and extend (`Tests/AppShellTests/`): `FileTreeStoreTests`, `FilesOpenTabsTests`, `FilesSurfaceAuxSeamsTests`, `FilesEditorIntelligenceTests`, `FilesEditorLSPIntegrationTests`, `FilesVSCodeChromeTests`, `FilesEditorPersistenceTests`, `FilesViewModelRoutingTests`, `FileExtensionIconTests`, `AppResponsiveMinimumWidthTests`, `BotsWindowTests`; `Tests/SocketServerTests/WorkspaceFileServiceTests.swift`, `DispatcherTests.swift`.

## 3. MANDATORY HYBRID ARCHITECTURE

**SwiftUI shell** owns: integration with the existing surface, Files layout, Explorer/editor split, resizable sidebar, tab bar, breadcrumbs, theme tokens, observable state.

**Explorer = AppKit `NSOutlineView`** in `NSViewRepresentable`: hierarchical tree, lazy enumeration, virtualization, expand/collapse, selection, full keyboard navigation (arrows, ←/→ collapse/expand, Return rename, ⌘↓ open, type-to-find), context menus, drag and drop (move/copy inside tree, drop from Finder, drag out), file decorations, git indicators, tree indent guides, filesystem change updates. Custom row views to match VS Code exactly. No SwiftUI `List`.

**Editor = AppKit `NSTextView` on TextKit 2** in `NSViewRepresentable`: `NSTextLayoutManager`, `NSTextContentStorage`, viewport layout, `NSScrollView`, native gutter (`NSRulerView` or custom view synced to viewport fragments). Native editing, caret, selection, line numbers, current-line highlight, syntax coloring, indent guides, bracket matching, undo/redo, both-axis scrolling, find/replace (`NSTextFinder`), shortcuts, multi-document state, diagnostics decorations.

Rules:
- Never replace the whole attributed string while typing. Highlight incrementally via rendering attributes / `NSTextContentStorage` edits scoped to the changed range.
- Highlighting must never break selection, caret, scroll position, undo history, or marked text (IME).
- Stay responsive on large files (≥ 50 k lines / 5 MB): highlight visible range first, rest off the main thread, apply latest-wins.
- Document state (text, dirty flag, undo, selection, scroll) lives in a model outside view lifecycles so SwiftUI re-creation never loses edits.

## 4. TECHNOLOGY CONSTRAINTS

Allowed: Swift, SwiftUI, AppKit, Foundation, TextKit 2, Core Text, Apple frameworks, SwiftPM, native Swift LSP client.

Prohibited for the Explorer and editor: Electron, Monaco, CodeMirror, `WKWebView`, browser editing, HTML/CSS/JS UI, other frameworks, fake editing components, screenshot simulations.

- No non-Swift parser dependency (e.g. Tree-sitter, C core) without explicit owner approval — ask, document, wait.
- Highlighting engine: isolated, incremental, pure Swift lexer service behind a small protocol so it can be swapped later.
- The existing Markdown **Preview** (`WKWebView` render of `.md`) is not the editor. Keep it working as-is unless the owner says otherwise; do not extend web usage.

## 5. EXPLORER REQUIREMENTS

Visual fidelity to the bar: Dark Modern colors, `EXPLORER` header with `···`, collapsible root header with hover-only actions (New File, New Folder, Refresh, Collapse All), typography, Seti-style file icons, chevron twisties, row height, indentation, padding, selection/focus/hover colors, indent guides, git colors and badges, sidebar divider, scroll behavior.

Functionality (real, not mocked): open workspace, expand/collapse, open file (single click = preview tab, double click = pinned), create file/folder inline, inline rename, delete to Trash with confirm, drag and drop move, Reveal in Finder, Copy Path / Copy Relative Path, keyboard navigation, filesystem change detection (FSEvents / existing observation service), persisted expansion + selection per workspace across app restarts, efficient large trees, lazy enumeration.

Respect security-scoped bookmarks and file coordination where required. On any error, surface it; never silently lose or change files.

## 6. EDITOR REQUIREMENTS

UI: VS Code tabs (preview italic tab, dirty dot, close `×`, git/diagnostic decorations, overflow scroll), tab-bar right action group (Preview/Split for Markdown, Save, Discard, more), breadcrumbs with symbol segments (from LSP document symbols when available), syntax colors, line numbers, gutter, active line, selection, matching brackets, indent guides, completion popup (reuse `FilesSuggestWidget`), native scrolling, VS Code padding, monospaced font (Menlo/SF Mono 13–14 pt, line height ≈ 1.5), Dark Modern palette.

Editing (each verified before claimed): open/save/save as, multiple tabs, dirty tracking, undo/redo, find/replace, go to line (⌃G), auto-indent, toggle comment (⌘/), bracket/quote auto-close and matching, configurable tab width, word navigation, multi-line selection, standard macOS shortcuts, external-change detection (reload if clean, conflict prompt if dirty), encoding preservation, line-ending preservation, safe close with unsaved changes.

Syntax priority: Swift, JavaScript, TypeScript, JSON, HTML, CSS, Python, Markdown.

IntelliSense only through the existing Swift LSP client (`FilesLanguageServer.swift`): diagnostics, completion, hover, go to definition, document symbols. SourceKit-LSP first; other servers only when installed/configured. Never fake completions; syntax highlighting is not IntelliSense.

## 7. STRUCTURE

Split `FilesSurface.swift` into focused files under `Sources/AppShell/Files/` (adapt names to what exists; no needless abstractions):

```text
Files/Views/     FilesWorkspaceView, FileExplorerRepresentable, EditorRepresentable, EditorTabBar, EditorBreadcrumbs
Files/Explorer/  FileOutlineView, FileTreeDataSource, FileTreeDelegate, FileTreeItem (reuse FileTreeStore logic)
Files/Editor/    NativeCodeTextView, CodeEditorCoordinator, LineNumberGutterView, EditorDocument, EditorState, EditorTheme
Files/Services/  SyntaxHighlightingService (+ per-language lexers), reuse existing LSP/intelligence/router services
```

Keep public types used by tests and by `BotsWindow` / `AppCommandRouter` compiling, or update their callers in the same change.

## 8. REPO RULES THAT ALWAYS APPLY (from `Agents.md` / `DESIGN.md`)

- **Isolated sandbox only.** `cd "$(scripts/isolated-sandbox.sh ensure)"`; build/test with `scripts/isolated-sandbox.sh test [--filter …]`; launch with `scripts/isolated-sandbox.sh run`; stop with `scripts/isolated-sandbox.sh stop`. Never touch the user's running `io.remotecode.desktop`, never `pkill -x RemoteCode`, never `scripts/run-app.sh`, keep `RC2_DISABLE_MANAGED_DISTILL_RECONCILE=1`.
- **Verify in the running debug app** `io.remotecode.desktop.debug` with mac-use (exact `target_pid` / `target_window_id`), through `scripts/macos-ui-lease.sh` (read-only by default; `--allow-input` only for one bounded reversible E2E). Release mac-use sessions you create.
- Read `DESIGN.md` before any UI change; if the VS Code look needs new tokens/patterns, update `DESIGN.md` in the same change. Check a narrow and a wide window (§7b).
- Persist workspace, open tabs, selected tab, expansion state, scroll/caret across MacCode close/reopen.
- Loading rules: open file/tab acknowledges within 100 ms with cached content or layout-stable placeholder; freshness work latest-wins, cancellable, never shows another workspace's data.
- Shared components: the same control in Files and Bots home files stays one component.
- Keep existing `fs.*` / socket RPC contracts that iOS uses intact; do not add a macOS-only behavior that breaks the iOS mirror.

## 9. GAUNTLET ROUNDS

1. **Audit + baseline.** Re-verify §2. Build and launch the sandbox app before editing. Screenshot the current Files section and the live VS Code bar on the same fixture workspace (create one under `/tmp`, shaped like `DEMO-TRAVEL-BLOG`: `.github`, `.vscode`, `node_modules`, `src/lib/stores/theme.js`, `src/app.css`, `src/app.html`, `static/favicon.png`, `.editorconfig`, `.gitignore`, `.prettierrc`, `jsconfig.json`, `package.json`, a git repo with modified files). Never use personal project files.
2. **Build pieces (one owner per file per batch):** A Explorer (NSOutlineView + rows + FS ops), B Editor engine (TextKit 2 view, gutter, highlighting service), C Editor UI (tabs, breadcrumbs, theme, popup placement), D Integration (wire into `FilesSurfaceRoot`, Bots mount, persistence, tests).
3. **Critics (fresh context, harsh, blind A/B vs the bar):** Visual (alignment, type, margins, row height, gutter, syntax colors, icons, tab geometry, breadcrumbs, selection/hover), Functional (real edit/FS workflows, lost edits, keyboard), Native Swift (AppKit/SwiftUI lifecycle, main thread, concurrency, retain cycles, TextKit perf, FS safety, accessibility/VoiceOver labels), Regression (Bots home files, other surfaces unchanged).
4. **Screenshot verification:** same window size, theme, sidebar width, expansion, file, scroll. Use overlays/diffs where tooling allows. Concrete reproducible discrepancy lists; no invented scores.
5. **Iterate:** IMPLEMENT → BUILD → RUN → SCREENSHOT → COMPARE → CRITIQUE → FIX → RETEST. Priority: data loss/broken function → major layout → typography/editor rendering → tree fidelity → tabs/breadcrumbs/popup → fine detail → performance.

Stop only when the critic picks ours blind and §11 holds, a real blocker is hit (report it), or the user stops the run. Compiling is not a stop condition.

## 10. AUTOMATED VERIFICATION

XCTest (and XCUITest where the harness supports it), always on temp workspaces: open workspace, recursive navigation, edit, save + reopen, unsaved-change prompt, undo/redo, multiple tabs, highlighting stays correct after edits (incl. marked text), find/replace, caret/selection, shortcuts, external file change (clean and dirty), create/rename/delete/move, encoding + CRLF preservation, window resize, large-file responsiveness (time budget assert), Bots files mount still works.

## 11. DEFINITION OF DONE

- Explorer is `NSOutlineView`; editor is `NSTextView` on TextKit 2; SwiftUI integrates both.
- Running app closely matches the VS Code bar side by side; the critic picks ours (or calls it indistinguishable) blind.
- Filesystem operations, editing, saving work reliably with no data loss.
- Syntax highlighting works for the priority languages; LSP features work where a server exists.
- Keyboard feels native; large real repos stay responsive.
- All relevant tests pass (`scripts/isolated-sandbox.sh test`), and unrelated sections are unchanged.
- Every visual value traces to a cited `microsoft/vscode` source location.
- Every change was exercised end to end in the isolated debug app with mac-use; every claim is backed by a sandbox screenshot, test output, or mac-use observation; anything not exercised is listed as unverified.

## 12. PROGRESS REPORT

Maintain `GAUNTLET_PROGRESS.md` in the sandbox worktree: completed components, current iteration, architecture decisions, visual discrepancies (ranked), screenshot paths, test results with exit codes, critic findings, outstanding issues, blockers. Each iteration ends in a working, verifiable app state.

No mockups. No WebViews in the explorer/editor. No fake functionality. No unnecessary rewrites. No unsupported claims of completion.
