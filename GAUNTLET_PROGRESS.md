# Gauntlet progress: Files section to native VS Code Explorer and editor

Spec: `PROMPT.md`. Branch: `feat/files-vscode-native` (linked worktree under `.sandbox-worktrees/`), base `3448dc648`.

## Iterations

1. **Audit and baseline.** The Files section was one SwiftUI file: a `List(selection:)` tree with a permanent filter field, a raw path field, a `root` breadcrumb row, row separators and a generic icon for every file. The editor was a TextKit 1 `NSTextView` whose `NSRulerView` drew line numbers below the text. Six tests already failed on the base commit (five `BotsWindowTests` Docker/Studio-files tests and `HostScopedSessionBackupCLITests.testPackagedCLIRestoreAndCreateRefuseHeldAppInstanceLockWithoutBackupFiles`); they are unrelated to Files and still fail the same way.
2. **Editor engine** (commits `02ec46316`..`86e208c32`):
   - TextKit 2 with no `layoutManager` access.
   - Gutter numbers are computed from the layout fragments.
   - Diagnostics are drawn by the editor.
   - Dark Modern look: current-line box, indent guides, bracket match.
   - Incremental highlighter.
   - Editing commands: Cmd+/, Ctrl+G, auto-indent, auto-close, Tab/Shift-Tab.
   - CRLF and UTF-16 BOM are kept on save.
   - 35 pt tabs with a right-side action group, one breadcrumb row, and real line-ending and encoding values in the status bar.
3. **Explorer** (commits `ffc11c5d1`..`0f5e98554`):
   - `NSOutlineView` (`Sources/AppShell/Files/FileExplorerOutlineView.swift`) with custom row and cell views. Rows are 22 pt with an 8 pt indent and indent guides, and highlight edge to edge.
   - Colors: hover, focused selection with an outline, and unfocused selection.
   - Lazy children, a context menu, inline rename, delete with confirmation, and drag and drop (internal move, drag out, and copy-in from Finder without overwriting).
   - Git decorations (M/U/A/D plus a dot on parent folders) and FSEvents refresh.
   - Expansion state is persisted in `expanded_dirs`.
   - The tree stays rooted at the workspace and expands to the selected or revealed file.

## Values traced to microsoft/vscode (clone at `/tmp/vscode-src`, commit `86db3b6`)

| Value | Source |
| --- | --- |
| Sidebar `#181818`, foreground `#CCCCCC`, editor `#1F1F1F`, tabs `#181818`/`#1F1F1F`, active tab top border `#0078D4`, line numbers `#6E7681` / active `#CCCCCC` | `extensions/theme-defaults/themes/dark_modern.json` |
| Indent guides `#404040` / active `#707070`, inactive selection `#3A3D41` | `extensions/theme-defaults/themes/dark_vs.json` |
| List hover `#2A2D2E`, active selection `#04395E`, inactive selection `#37373D`, focus outline `#0078D4`, drop `#062F4A`, tree guides `#585858` | `src/vs/platform/theme/common/colors/listColors.ts` |
| Current line border `#282828`, caret `#AEAFAD`, bracket match `#0064001a` / `#888` | `src/vs/editor/common/core/editorColorRegistry.ts` |
| Git colors M `#E2C08D`, U `#73C991`, A `#81b88b`, D `#c74e39` | `extensions/git/package.json` |
| Row height 22 | `src/vs/workbench/contrib/files/browser/media/explorerviewlet.css` |
| Twistie width 16, indent guides | `src/vs/base/browser/ui/tree/media/tree.css` |
| Tree indent 8 | `src/vs/platform/list/browser/listService.ts` (`workbench.tree.indent`) |
| Tab height 35, padding 10, min width 80 | `src/vs/workbench/browser/parts/editor/media/multieditortabscontrol.css` |
| Menlo 12, line height 1.5× | `src/vs/editor/common/config/fontInfo.ts` |
| `lineNumbersMinChars` 5, `lineDecorationsWidth` 10 | `src/vs/editor/common/config/editorOptions.ts` |

## Test results

`scripts/isolated-sandbox.sh test --filter 'FileExplorerOutline|Files|FileTree|FileExtensionIcon|WorkspaceFileService'` reported 350 passed and 6 failed. The 6 failures are exactly the base-commit failures listed above.

New tests:
- `FileExplorerOutlineTests` (7): native outline and lazy listing, create/rename/move on disk keeping expansion, expansion persist/restore, FSEvents picking up an external file, git parsing on a real repository, rename records, copy-in without overwrite.
- `FilesEditorGutterTests`, `FilesEditorCommandsTests`, `FilesEditorBracketTests`, the highlight performance tests, and the CRLF/UTF-16 save test in `WorkspaceFileServiceTests`.

## End-to-end checks in the isolated debug app (`io.remotecode.desktop.debug`, mac-use under `scripts/macos-ui-lease.sh`)

All of these were observed in the running app:
- The tree, git badges and folder dots render.
- Clicking a folder expands it, and clicking a file opens it in a tab with the focused selection style.
- A file created outside MacCode appears with a green `U`.
- Expansion and open tabs come back after a relaunch.
- The editor gutter is aligned.
- The Agent App tab still renders normally.

Screenshots are in the goal scratch directory: `files-after-*.png`, `vscode-ref.png`, `regression-agentapp.png`.

## Unverified / outstanding

- These were not driven in the GUI: inline rename by keyboard, the context menu, drag and drop, and delete confirmation. They are covered only at the model level by the tests.
- The Bots home files mount was not opened in the GUI. Its `BotsWindowTests` keep the same pass/fail set as the base commit.
- No blind visual A/B against the critic was run. Remaining gaps against the VS Code capture:
  - SF Symbols are used instead of Seti glyphs.
  - There is no sticky scroll.
  - Tab icons and labels are not pixel-matched.
- The VS Code reference capture was taken in Restricted Mode, so it shows no git colors.
- Hover-only header actions and the narrow/wide window check were not exercised by input.
