# MacCode macOS Rules

- Browser parity is mandatory: every macOS browser URL change must emit host state so iOS mirrors the same target.
- External URLs, localhost/dev-server URLs, and macOS file URLs must stay synchronized between macOS and iOS.
- Browser target changes on either side must propagate to the paired side, or the control must stay host-driven/read-only.
- Do not add browser behavior that only works on one side without updating the other side in the same change.
- User workflow state must survive closing and reopening MacCode. Persist the user's active workspace, panes, selected tabs, browser URLs/titles, surface metadata, agent thread state, and other explicit user choices unless the user intentionally closes/deletes them.

## Privilege escalation (mandatory)

- Use the single installed root-owned helper at `/Library/PrivilegedHelperTools/io.remotecode.RunAsUserHelper`. Its first install may show one administrator dialog; it remains available after MacCode closes and reopens.
- The password is never persisted or stored. Provider run-as-user, Insomnia `pmset`, scheduled tasks, and provider teardown are the four consumers; all privilege escalation for them must call `RunAsUserProcessBootstrap`.
- Do not use direct `sudo`, AppleScript administrator authorization, sudoers edits, or password files. The bootstrap installer is the only in-app `sudo` exception, and it must verify the helper owner, mode, and version before reuse.

## Loading and perceived performance (mandatory)

Apply these rules to every user-visible load on macOS: navigation, tabs, rows, lists, details, search, reconnect, hydration, refresh, restore, and provider-backed content.

- Acknowledge the user's intent immediately. Publish the selected destination, identity, and safe cached/local state before database, network, Docker, provider, transcript, inspector, or other freshness work. Target first feedback within 100 ms and zero unacknowledged dead time.
- Mount the destination on the interaction turn. Do not put navigation-boundary animations, blocking overlays, or duplicate synchronous reloads in front of the first useful frame. Preserve local motion only when it does not delay acknowledgement, and respect reduced motion.
- Run freshness after the initial state commit, in one coalesced asynchronous pass. `Task.yield()` is only a next-executor-turn boundary, not proof that a frame painted; use an actual render/frame barrier when correctness requires post-paint work.
- Make deferred work latest-wins and destination-safe: use cancellation plus a monotonic generation/request identity, check the current destination/selection before every visible effect, and let only the task that owns a handle clear it. A stale task must never overwrite newer state or clear newer work.
- Cache-first must remain honest. Never show another workspace/bot/thread's data, never present consequential stale data as fresh, never fake progress or success, and never suppress errors. If no safe cache exists, use a layout-stable placeholder or real progress appropriate to the latency.
- Preserve exact behavior while deferring work: persistence, canonical events, read/attention state, routing, queued follow-ups, error surfaces, and other required side effects must still occur exactly once for the winning request.
- Every loading-performance change needs regression coverage for the immediate path, eventual exact completion, rapid A→B races/stale-result rejection, and failure behavior. Performance claims require comparable before/after measurements on the same environment and workload, at least five warmed samples, and no settled-latency regression beyond `max(25 ms, 5%)`.

## Isolated sandbox (mandatory)

The user's running MacCode (`io.remotecode.desktop`) is off-limits. A git worktree isolates files; it does not isolate bundle id, Application Support, SQLite, port `18217`, or `/tmp/RemoteCode.sock`.

- Create/enter a linked worktree, then edit, build, and test only there: `cd "$(scripts/isolated-sandbox.sh ensure)"`
- Prove with `scripts/isolated-sandbox.sh test` (optional `--filter …`). Launch a second GUI only via `scripts/isolated-sandbox.sh run`.
- Never `pkill -x RemoteCode`. Never `osascript` quit `io.remotecode.desktop`. Never `scripts/run-app.sh` (it packages the stable bundle id and quits the host). `script/build_and_run.sh` launches the debug sandbox app via `scripts/isolated-sandbox.sh`.
- Do not touch `~/.remote-code/bin` or `~/.local/bin/distill` from the sandbox; keep `RC2_DISABLE_MANAGED_DISTILL_RECONCILE=1`.
- Identity, ports, and App Support live in `scripts/isolated-sandbox.sh`. Ritual: `.grok/skills/isolated-sandbox/SKILL.md`.

## Verify every change in the running sandbox app with mac-use (mandatory)

Every change, however small, must be exercised in the real isolated debug app before you call it done. A green build or unit test does not count as verification of anything the user sees or does.

- Rebuild and relaunch the isolated build from the linked worktree: `scripts/isolated-sandbox.sh run`. Never test against the user's `io.remotecode.desktop`.
- Drive and observe the app with the mac-use MCP, targeting only the debug bundle `io.remotecode.desktop.debug` (exact `target_pid` and `target_window_id` from `list_windows`). Use `get_ui_tree` / `screenshot` and targeted AX actions (`click_element`); the state token changes after every observation, so act on the token the last call returned.
- Exercise the changed behavior end to end the way a user would, then visit the other surfaces that share the touched state or components (e.g. Agent App and Bot Desk) and look for regressions.
- Follow the macOS UI automation lease rules below: read-only observation by default; input-producing automation only via `scripts/macos-ui-lease.sh --allow-input` for one bounded, reversible E2E.
- Clean up what you start: stop the sandbox app you launched with `scripts/isolated-sandbox.sh stop`, and release mac-use sessions or recordings you created.
- Report what you observed. If a path could not be exercised (for example it needs a native file picker or input that the lease forbids), say so explicitly and mark it unverified; never claim it was tested.

## macOS UI automation lease (mandatory)

- macOS event posting is host-global even when a harness targets an app PID. Run every
  macos-harness or Computer Use session through `scripts/macos-ui-lease.sh -- ...`; its shared
  `/tmp/remotecode-macos-ui-lease.lock` is single-flight across all worktrees.
- This is a cooperative repository guard, not an OS-enforced sandbox: a raw external
  Computer Use client can bypass it. Therefore the default acceptance path uses read-only
  macos-harness only; do not run input-capable Computer Use in parallel with a user's session.
  If another agent cannot honor the lease, stop the UI E2E rather than competing for HID.
- The lease is read-only by default and rejects input-producing snippets. Use `--allow-input`
  only for one bounded, reversible E2E that must click, type, press keys, scroll, drag, or run
  AppleScript. Prefer `see`/`state` and targeted AX actions.
- Target the exact debug bundle ID `io.remotecode.desktop.debug`, then exit the session. Never
  target stable MacCode or leave SkyComputerUseService, `node_repl`, or Computer Use MCP
  daemons running; never use a persistent harness `repl`.

## Design standard (mandatory)

- Before changing anything a user sees, read [`DESIGN.md`](DESIGN.md) and follow it. It is the binding UI standard (tokens, components, states, motion, accessibility, copy, verification).
- If a change needs a new pattern or changes the standard, update `DESIGN.md` in the same change.
- Every screen must be responsive at any window width (see `DESIGN.md` §7b). Check a narrow and a wide window in the running app before calling a UI change done.

## Shared components

- Reusing components is welcome and encouraged when it is done well. If two surfaces already show the same control (composer chips, popovers, bubbles, live-turn chrome, queued header), extract one component and mount it from both. Do not copy a second SwiftUI implementation just because the caller lives in another file.
- "Well done" means the shared type owns the real look, copy, a11y, and behavior — not a lookalike fork, and not a wrapper that still paints its own capsule. Different products stay different (Desk editor placeholder, workspace-less Local execution, bot @mentions). Same control must stay one component.

## Schedule Tasks parity (mandatory)

- Every change to the Agent App or to Bots must also land in Schedule Tasks in the same change. If a new message can set it (run as user/Bot, model, efforts, Auto profile, Ultracode, permission, plan mode, Local/Worktree execution, and anything added later), the scheduled task editor must be able to set it, persist it, and apply it when the run fires — for both workspace tasks and Bot schedules.
- Schedule Tasks has one "New Task" entry point; choosing a Bot in "Run as" turns the draft into a Bot schedule. Do not add a second creation button.
- iOS mirrors it through `scheduled_task.*` (capability `agent.scheduled_tasks_v1`): a new run option needs a `scheduled_task.save` param and the iOS editor field in the same change.

## Token Saver removed (2026-10-06)

- Token Saver was removed on 2026-10-06; do not reintroduce Distill compression, PATH wrappers, dialect injection, Graphify or the librarian without an owner decision.
- The Distill agent provider is not Token Saver. Keep `DistillACP*`, `DistillParser`, `DistillRunner`, `DistillProvisioner`, `DistillAccounts*`, `DistillModelsConfig`, `DistillReasoningPolicy`, `DistillLiveStatus`, the `distill.accounts.*` RPCs, `cli.distill.path`, and the distill effort settings.
- `RemoteCodeDistillService` stays as a product. Its non-Token-Saver modes stay: Chrome host, `subagent` telemetry (including the legacy `distill subagent` / `cli subagent` forms), Agent App middleware, provider proxy, `rc-computer-use-mcp`, the bot MCPs (`rc-bot-self-config`, `rc-bot-browser`, `rc-bot-web`, `rc-bot-computer`), and pass-through for leftover symlinks.
- Provider account usage (quota rings, `agent.account.usage`) is a neutral feature, not Token Saver.

### Legacy compatibility (do not delete)

- `AssistantEvent` cases `.sr1Translation` and `.itemHostMetadata` stay decode-only: stored events are decoded strictly, so removing a case breaks `agent.thread.read` for old threads.
- `ManagedProcessKind` cases `.sidecar` and `.graphify` stay: the process-ownership ledger decodes the whole tag array, and an unknown case blocks provider admission.
- Tables `rc_reversible_content`, `agent_item_host_attestations` and `shared_memory_blocks` stay in use. Never edit historical `SchemaStep`s. Former Token Saver tables stay dormant (no drop migration).
- Treaty cases `.tokenSaverDigest`, `.graphifyThreadRoots` and `.agentSR1Translation` stay (deprecated) until iOS bumps its treaty pin. The `token_saver.digest.get` RPC stays as a stub answering `{"enabled": false}` until then.
- `DistillAppliedReceipt.strip` stays so legacy `[[rcd:…]]` markers never render raw.
- `RC2_DISABLE_MANAGED_DISTILL_RECONCILE` stays: it keeps the sandbox app and the scheduled-task agent away from the user's `~/.remote-code/bin`.
- For one release: the `RC_TOKEN_SAVER_*` fallbacks in the subagent telemetry scope and `RC2CLI`, `"mcp"` in the process sweeper's distill MCP argv modes, and a fail-open `distill hook` no-op for stale Grok hooks.

## macOS crash / long-running terminal diagnostics

- For reports that MacCode closes while a long Claude terminal or Agent run is active, first collect unified logs from the app diagnostics subsystems:
  ```bash
  log stream --style compact --predicate 'subsystem == "io.remotecode.app" || subsystem == "io.remotecode.surfaces" || subsystem == "io.remotecode.agent"'
  ```
- After an unexpected close, capture the recent persisted log window:
  ```bash
  log show --last 30m --style compact --predicate 'process == "RemoteCode" && subsystem BEGINSWITH "io.remotecode"'
  ```
- Check for crash reports before guessing root cause:
  ```bash
  ls -lt ~/Library/Logs/DiagnosticReports/*RemoteCode* | head
  ```
- Also check for stale Claude provider processes. Orphaned `ClaudeAgentSDKBridge.mjs` and Claude SDK child processes can accumulate across app sessions and create memory pressure:
  ```bash
  ps -axo pid,ppid,rss,etime,args | awk '/ClaudeAgentSDKBridge\\.mjs|claude --output-format stream-json|claude --dangerously-skip-permissions/ && !/awk/ {print}'
  ```
- Useful log events added for this class of issue: `app.heartbeat`, `app.will_terminate`, `terminal.spawned`, `terminal.output_health`, `terminal.pty_eof`, `terminal.dead`, and `terminal.close`. These intentionally log IDs, PIDs, counts, RSS, statuses, and byte totals, not terminal contents or secrets.

## Localization

Six languages are supported and always kept complete: English, Portuguese (pt-BR), Spanish, French, Arabic, and Chinese (zh-Hans/zh-Hant). A language without text falls back to English.

**Every task must translate.** Before any task is considered done:

- Every new or edited user-visible string ships with all six translations. No string may be added in English only, and never leave a language falling back to English on purpose.
- While working in a file, translate every user-visible string you find that is still English-only, even when it is unrelated to the task. Add the missing languages instead of reporting them.
- Strings are added through the per-language helpers already in the codebase (e.g. `TitioNoticeCopy.t`, `TitioLanguageSetting.choices`); stay consistent with them rather than inlining one-off dictionaries.
- The default language is the device language (`auto`); the user can override it in Settings (`titio_language`). A fixed unsupported tag falls back to English.
- Formatting is localized too: decimal commas for pt/es/fr, 24-hour clocks everywhere except English, and per-language date patterns.
- Verify with a test or a build that the new strings render in every language, and say which languages you checked.

