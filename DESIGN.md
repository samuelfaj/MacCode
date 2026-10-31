# MacCode Design Standard

This is the binding design standard for MacCode on macOS. Every new or changed UI must follow it. It is derived from what the app already ships (audited 2026-10-21 against `production` `1e60e8179`); where the code and this file disagree, fix the code toward this file or update this file in the same change.

- Tokens and primitives live in `Sources/DesignSystemKit/` (`Tokens.swift`, `Components.swift`).
- Shared product controls live in `Sources/Surfaces/` (`AgentChoiceSheet.swift`, `AgentComposerChrome.swift`, `AgentModelPopover.swift`, `AgentAutoGuide.swift`).
- This is the only design document for macOS. iOS keeps its own in `../ios-app/docs/design-system.md` and shares the parity rules in §7.

## 1. Principles

1. **Dense, dark, developer-grade.** Maximize signal, minimize chrome. No marketing layouts, no decorative gradients on content, no drop shadows on content.
2. **One system.** Use `DS.*` tokens and the shared components below. Never paint a lookalike. If two surfaces show the same control, extract one component and mount it from both (see `AGENTS.md` → Shared components).
3. **Acknowledge instantly.** A tap shows its destination at once; freshness work happens after the first frame (see `AGENTS.md` → Loading and perceived performance).
4. **Honest states.** Never fake progress, never show another object's data, never hide errors. Loading, empty and error states are designed, not afterthoughts.
5. **Parity.** Agent App, Bot Desk and Schedule Tasks share controls and options; iOS mirrors host capabilities (see `AGENTS.md`).
6. **Simple first.** Prefer the native control (`Toggle`, `Picker`, `.sheet`, `.popover`) styled with tokens over custom machinery.

## 2. Appearance

- **Dark only.** The app forces `.darkAqua` (`AppShell/RemoteCodeAppearance.swift`) and SwiftUI roots use `.preferredColorScheme(.dark)`. Do not add light variants. Code editors may keep their own syntax palettes.

## 3. Color

Use `DS.Palette` (SwiftUI) or `DS.NS` (AppKit). No `Color(hex:)`, `Color.blue`/`.red`/…, or `NSColor(red:)` in views. The only allowed literal colors are user-chosen identity colors (workspace color, Bot blobatar) and third-party brand marks.

| Token | Value | Use |
|---|---|---|
| `bg` | `#0F1419` | Window/canvas, sheet footers at 0.35 |
| `surface` | `#171D24` | Bars, sidebar, sheets, code blocks |
| `surfaceRaised` | `#1B222B` | Cards, inputs, chips, secondary buttons |
| `surfaceOverlay` | `#212A34` | Hovered cards, neutral pills, popover fill |
| `line` | `#2A3440` | 1 pt hairline borders and dividers |
| `lineStrong` | `#394654` | Emphasized dividers, dashed "add" borders, grips |
| `text` | `#E7EDF3` | Primary text |
| `textSecondary` | `#9DA9B5` | Secondary text, subtitles |
| `textTertiary` | `#6B7785` | Meta, timestamps, section headers |
| `accent` | `#7CC7FF` | Selection, primary action, focus, links, unread |
| `onAccent` | `#0A0E13` | Text/icons on accent fills |
| `success` | `#8EE6A8` | Done, connected, additions, running-good |
| `warning` | `#FFD37A` | Needs attention, recoverable error, Auto-edit permission |
| `danger` | `#FF8F8F` | Failure, destructive, Full access |
| `ultracode` / `ultracodeDeep` | `#C084FC` / `#818CF8` | Auto and Ultracode identity (purple) |
| `hover` / `pressed` | white 5% / 9% | Interaction layers |
| `selection` | accent 16% | Selected row background |
| `focusRing` | accent 65% | Keyboard focus ring |

**Semantic rules**

- Tinted fills use the tone color at low opacity: callouts and selected cards 0.10, pills and badges 0.12–0.16, icon tiles 0.14 with 0.22 stroke.
- **Unread / count badges are `accent`**, never `Color.blue`.
- **Auto is purple** (`ultracode`) everywhere: Auto model, Auto profile, Auto effort, the Ultracode mode, new-conversation icon. Do not introduce a second Auto color.
- **Danger is for risk**, not for "on". A toggle being enabled is not dangerous; use `accent` or `success` unless the state is actually risky (Full access).
- **Permission tones:** Supervised `textSecondary`, Auto-edit `warning`, Full access `danger`.
- **Effort scale:** levels come from the model's `supportedReasoningEfforts`, ordered lightest→heaviest; tint runs blue→red by position (`Color(hue: 0.6 * (1 - t), saturation: 0.75, brightness: 0.95)`), Auto is `ultracode`. Never hard-code effort levels in UI.

## 4. Typography

SF system font only, via `DS.Font`. Monospace only for code, commands, paths, branch names, IDs and numeric counters (`.monospacedDigit()`).

| Token | Spec | Use |
|---|---|---|
| `title` | 22 bold | Window/page titles (rare) |
| `title2` | 18 semibold | Settings hero, detail page titles |
| `title3` | 15 semibold | Sheet titles, empty-state titles |
| `body` / `bodyStrong` | 13 / 13 semibold | Default text, card titles |
| `bodyDense` | 12 | Subtitles, dense lists |
| `caption` / `captionStrong` | 11 / 11 semibold | Chips, menu rows, meta |
| `caption2` | 10 | Section headers, badges, prefixes ("Main", "Worker") |
| `mono` / `monoSmall` / `monoStrong` | 12 / 11 / 12 semibold monospaced | Code and command text |

- Section headers: `caption2` semibold, UPPERCASE, tracking 0.6, `textTertiary` (`DSSectionHeaderG`, `AgentChoiceSectionHeader`).
- New code must not add `.font(.system(size:))`. Icon glyph sizes inside a component are the only exception and should be expressed relative to the tile (`size * 0.42`).

## 5. Spacing, radius, borders

- `DS.Space`: xxs 2, xs 4, sm 6, md 8, lg 12, xl 16, xxl 20, xxxl 24, huge 32. Use only these.
- `DS.Radius`: control 5 (buttons, inputs, sidebar rows, code blocks), card 7 (panels, settings nav rows), panel 9 (callouts, search fields, option cards, segmented track), bubble 10 (user message), modal 12 (sheets, choice cards, settings hero), pill 999. Always `style: .continuous`.
- Borders are `DS.Border.hairline` (1 pt) `line`. Selected cards use the tint at 0.75 and 1.5 pt.
- Shadows only on transient floating controls (scroll-to-bottom, FAB).

## 6. Iconography

- SF Symbols only. Decorative icons are `.accessibilityHidden(true)`.
- Fixed meanings: `sparkles` = Auto / new conversation; `speedometer` = effort; `wand.and.stars` = Ultracode mode, `bolt.fill` = Ultrafast, `leaf.fill` = Ultrasave, `circle.dotted` = Normal; `lock.shield` / `exclamationmark.shield.fill` = permission / Full access; `arrow.triangle.branch` = git branch; `plus` / `plus.circle.fill` = create; `xmark` = close; `chevron.left` = back.
- **Icon tiles** (`AgentChoiceIconTile`): rounded square, radius `size * 0.28`, tint fill 0.14, stroke 0.22. Sizes: 24 (settings nav, menu rows), 30 (cards), 34 (sheet header), 40 (empty state), 56 (settings hero).

## 7. Layout

- **Window:** sidebar + content. Sidebar visibility follows `AdaptiveSidebarPolicy` (hysteresis 120 pt, 2 s resize cooldown); never hide content to show the sidebar.
- **Headers:** compact, full width, 44 pt high, `dsBar(edge: .bottom)`. Title left, icon buttons right.
- **Surfaces:** a task that becomes the user's main task replaces the body; it does not float over it. Sidebars and drawers must not cover the primary terminal or editor content.
- **Apple surface parity (shared with iOS):** SSH and Agent App are the visual baseline (compact header, dense dark content, direct controls). Terminal UI appears only for real usable sessions; empty or disconnected states use a clear empty state with a recovery action. iOS may adapt layout for touch but must keep every host capability macOS exposes.
- **Settings:** two columns at ≥ 640 pt (nav list + page), a menu below that. Page = hero (56 tile, `title2`, subtitle, `surfaceRaised`, radius modal) then `DSSectionHeaderG` sections of rows.
- **Grids:** choice grids are 2 columns, spacing `md`. Wide editors may place cards side by side and stack them when narrow.
- **Max widths:** user bubble 420; empty-state subtitle 360–420; inline editors 880; sheet bodies scroll at 560 max height.

## 7b. Responsive (mandatory)

Every screen must work at any window width, from the narrowest the window allows to full screen. Cap content with `maxWidth` and center it; never fix widths that can exceed the container. Rows with a label and a control use `ViewThatFits` (side by side, then stacked). Wrapping text uses `fixedSize(horizontal: false, vertical: true)`. Two-column layouts collapse to one below about 640 pt (as Settings does). Verify narrow and wide in the running app.

## 8. Components (use these; do not fork)

**Primitives (`DesignSystemKit`)**

- `DSPrimaryButtonStyle` / `DSSecondaryButtonStyle`, or native `.borderedProminent` / `.bordered` for sheet footers.
- `DSIconButton` — 26×22 visual, 44×44 hit target, `.help` and label required.
- `DSPill(text, tone:)` — status pills (neutral, accent, success, warning, danger). One mapping from a status to a tone per domain.
- `DSSectionHeaderG`, `DSEmptyState`, `DSBusySpinner`, `DSResizeDivider`, `dsPanel`, `dsBar`, `dsHoverFill`, `dsFocusRing`.

**Choice UI (`Surfaces/AgentChoiceSheet.swift`)**

- `AgentChoiceSheet` — the only modal for choosing something. Header: 34 icon tile + `title3` + `caption` subtitle + round close (Esc). Body scrolls (max 560). Optional footer on `bg` 0.35: secondary action left ("Back to models"), primary right ("Done", default action). Widths: 460 (permission), 520 (default), 540 (run as), 600 (model).
- `AgentChoiceCard` — min height 52, radius modal, `surfaceRaised`; hover `surfaceOverlay`; selected tint 0.10 fill + tint border + filled check circle; disabled shows the reason in `warning`. Press scale 0.985.
- `AgentChoiceSearchField` (shown when a list has more than 6 items), `AgentChoiceSegmented`, `AgentChoiceCallout`, `AgentChoiceBadge`, `AgentChoiceSectionHeader`.
- **Multi-step choices** stay in one sheet: step 1 picks the object, step 2 picks its options, then the sheet closes. Example: model → effort. Provide "Back" in the footer.

**Composer (`Surfaces/AgentComposerChrome.swift`, `AgentModelPopover.swift`)**

- Chip order, left to right: Run as → Source/account → Main pill → Worker pill → Mode → Permission → Execution (Local/Worktree).
- `AgentComposerCapsule` (`.raised` or `.tinted`), `AgentModelPillLabel` ("Main"/"Worker" prefix in `caption2`, model in `caption` medium, effort after ` · `), `AgentExecutionModeCapsule`.
- Compact menus (popovers): `AgentCompactMenuRow`, `AgentCompactMenuSection`, `AgentCompactMenuDivider`. The checkmark column is always reserved so selection does not shift text.

**Execution mode** — Distill has one exclusive mode per session: Normal, Ultrafast, Ultracode, Ultrasave (`DistillExecutionMode`, wire values `normal|ultrafast|ultracode|ultrasave`). It is one capsule, `AgentExecutionModeCapsule` ("Mode · Normal"), that opens an `AgentChoiceSheet` with one card per mode. Never add a per-mode toggle or chip. Tints: Normal `textSecondary`, Ultrafast `warning`, Ultracode purple (gradient when active), Ultrasave `success`. Mount it wherever a message can set it: Agent App, Bot Desk and both Schedule Tasks editors.

**Grouping and dividers**

- Lists that mix scopes are grouped: **scope-specific first, then general**, separated by an `AgentCompactMenuDivider` / hairline and a section header. Example: Workspace bots, then General bots.
- Creation actions ("New bot…", "Add option") come last in a list, after a divider, styled as a dashed `lineStrong` card or a `plus` row.
- Menus are ordered: selection → actions on the current object → destructive (separated) → creation.

**New conversation** — `AgentNewConversationEmptyState` (Agent App and Bot Desk): 40 purple sparkles tile, title, subtitle, and the inline Accounts & Auto editor when available. The editor is a disclosure card (`DistillAccountsInlineDisclosure`): 28 icon tile, `bodyStrong` title, summary line (2 lines max), chevron rotating 90° with "Show"/"Hide", `micro` motion, open until Auto routing is set up; the choice persists in `agent.emptyState.accountsExpanded`.

## 9. States

- **Empty:** `DSEmptyState` or `AgentNewConversationEmptyState`; one clear next action; reserve height (`minHeight: 280` in chat) so the layout does not jump.
- **Loading:** acknowledge at once; show cached data if it is honest, otherwise a layout-stable placeholder or `DSBusySpinner` with a label. Live strips reserve their height.
- **Errors:** inline first — `AgentChoiceCallout` (warning when recoverable, danger otherwise) or an error strip in place. Use alerts only for blocking confirmations. Text says what happened and what to do.
- **Banners:** a full-width strip under the header for persistent risk (e.g. "Full access is on" with a "Switch to supervised" action).
- **Disabled:** opacity 0.38 (`DS.Alpha.disabled`) and a visible reason.
- **Destructive:** `role: .destructive`, confirmation for irreversible actions, never the default button.

## 10. Motion

- Use `DS.Motion`: `micro` (easeOut 0.16 s) for disclosures, hovers and toggles; `standard` (easeOut 0.22 s) for layout changes; `emphasized` (spring 0.34/0.86) for selection moves (`matchedGeometryEffect` in segmented controls).
- No new ad-hoc durations. No animation in front of the first useful frame of a navigation.
- Every animation and continuous loop checks `@Environment(\.accessibilityReduceMotion)` and falls back to an opacity change or no animation.

## 11. Accessibility

- Every interactive element has a stable dotted `accessibilityIdentifier`: `<area>.<object>.<action>` in lowerCamel segments (`agent.composer.stop`, `bots.desk.model.menu`, `sidebar.newConversation.newBot`). Tests and mac-use verification depend on them.
- Icon-only buttons have `.accessibilityLabel` and `.help`. Decorative images are hidden.
- Hit targets are at least 44×44 pt (use `contentShape` when the visual is smaller).
- Text meets contrast on its surface: `text` for content, `textSecondary` for supporting copy; never put `textTertiary` on interactive labels.
- Keyboard: Esc closes sheets (`.cancelAction`), Return confirms (`.defaultAction`), ⌘S saves editors, focus rings via `dsFocusRing`.

## 12. Copy

- UI language is English.
- **Titles and buttons use Title Case** for commands ("Run Now", "New Workspace", "Back to models" is the accepted exception for navigation). Subtitles, descriptions and errors use sentence case and end with a period.
- Use `…` when an action opens another step ("New bot…", "Edit Group…") or for progress ("Loading…").
- Use ` · ` to join metadata ("Claude · Empath", "2 running · 1 needs you").
- Be direct and specific; no blame, no jargon the user did not introduce. Product names: MacCode, Bot(s), Agent App, Desk, Studio, Schedule Tasks, Auto, Ultracode.

## 13. Verification (required for every UI change)

1. Build and run the isolated app: `scripts/isolated-sandbox.sh run` (never the user's `io.remotecode.desktop`).
2. Exercise the change with mac-use on `io.remotecode.desktop.debug`, then check every surface that shares the component (Agent App, Bot Desk, Schedule Tasks, Settings).
3. Check narrow and wide window sizes, keyboard use, and reduced motion.
4. Report what was observed; mark anything not exercised as unverified.

## 14. Known debt (fix when touching these files)

- About 270 raw `.font(.system(size:))` calls outside `DesignSystemKit` (largest in `AgentAppSurface.swift`, `SidebarView.swift`, `FilesSurface.swift`, `DiffPanelSurface.swift`).
- `Color.blue` badges in `ActiveThreadsWindow.swift` and `SidebarView.swift` → `DS.Palette.accent`.
- `AgentModelAutoRoutingCard` uses a green/accent Auto identity → should be `ultracode` purple.
- Insomnia "on" toggle uses `danger` → should not signal risk.
- Ad-hoc animation durations (0.08–0.2 s) and unguarded animations in `AgentChatChoicesCard`, `DiffPanelSurface`, `ActivityWindow`, `AgentMessageMarkdown`, `SidebarView`, `ScheduledTasksWindow`.
- Duplicate lookalikes to merge: settings `settingRow` vs keybindings `settingRow` vs scheduled `formRow`; `statusPill` (Activity) vs `runStatusPill` (Scheduled); `DistillAccountsPanel` add/rename sheets do not use `AgentChoiceSheet`.
- Error surfaces differ (inline strip in Bots, alerts in Activity and Scheduled) → prefer inline.
- `DS.NS` lacks `surfaceOverlay`, `hover`, `pressed`, `selection`, `focusRing`, `ultracode`.


## Bot parallel-task links

A Bot can start independent work in separate conversations through the existing host send tools. Persist one compact capsule in the originating transcript for each accepted new run. The capsule shows the task title, the exact run's honest state, and a trailing chevron. A running task uses the native small progress indicator; terminal failure remains distinct from success. Status lookup failure must read as unavailable, never completed.

Clicking a capsule opens that exact conversation in a trailing, resizable pane without selecting another main chat, stopping either run, or touching either draft. Keep the originating chat usable. The task pane is an observing surface with a labeled close action and a note that the Bot manages the task. Reuse the shared Agent App transcript with no composer or draft ownership. Remember the selected task per originating thread and restore it when that chat reopens. Validate the persisted source link, destination identity, and current context read grants before displaying it; revoke the preview if context access is withdrawn. Closing the pane only closes the preview, not the conversation or run.
