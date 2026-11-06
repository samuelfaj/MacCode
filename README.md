![MacCode in action](https://remotecode.io/videos/video-3x.gif)

# MacCode

MacCode is a native macOS development cockpit. It keeps agents, terminals, browsers, files, and git in one workspace, and lets you control that workspace from the Mac or from an iPhone.

The Mac is the source of truth. Agents, shells, git, browsers, and files run on the Mac. Remote clients mirror and control that host state instead of running their own copies.

## Download

[Download the latest release for Apple Silicon (DMG)](https://github.com/samuelfaj/MacCode/releases/latest/download/stable-macos-arm64-RemoteCode.dmg)

## Features

- **Agent App:** run agent threads from Codex, Claude Code, Grok, and Distill. Choose provider, model, reasoning effort, permissions, and execution mode before a run. Run in local mode or an isolated worktree. Queue follow-ups, attach files, approve or deny provider actions, and answer provider questions. Threads restore after restart.
- **Terminal:** real macOS terminal tabs (Ghostty) scoped to each workspace, with ANSI styling and persistent scrollback.
- **SSH:** saved host profiles scoped to a workspace, with reconnect and file transfer while connected.
- **Browser:** embedded browser surfaces with a local address field. Open the current URL in the default browser.
- **Files:** browse workspace files and preview supported file types. Hidden previews unload.
- **Git:** git and diff surfaces, changed-file review, and git context in the Agent composer.
- **Workspaces and panes:** multiple workspaces, each with its own working directory. Tabs can be split, dragged between panes, and minimized. Layout, tabs, and workspace state persist across launches.
- **Bots and Schedule Tasks:** run agents as Bots and schedule Bot and workspace tasks.
- **iPhone remote control:** pair an iPhone over the local network or VPN. The phone mirrors workspaces, threads, terminals, browser surfaces, and git state, and can send prompts, answer provider requests, and stop runs. The iPhone companion app is closed source.

## Requirements

- macOS 14 or later (`Package.swift`: `.macOS(.v14)`).
- Xcode with the macOS SDK. Releases are built with Xcode 27.
- Git and Git LFS. `Vendor/GhosttyKit.xcframework` is stored in Git LFS.
- The release DMG is built for Apple Silicon (arm64). `GhosttyKit.xcframework` also contains an x86_64 slice, but Intel builds are not part of the release process.

## Build From Source

```bash
git lfs install
git clone https://github.com/samuelfaj/MacCode.git
cd MacCode
git lfs pull
scripts/bootstrap.sh
swift build --product RemoteCode
```

If `xcode-select` points at the Command Line Tools, set the developer directory first:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

### Tests

```bash
scripts/test-unit.sh
```

`scripts/test-unit.sh` runs `swift test` and selects the Xcode developer directory when XCTest is available there. Set `RC2_COVERAGE=1` to produce a coverage report. Focused runs can use `swift test --filter <TestName>`.

### Run the App

Run the debug app inside the isolated sandbox from a linked git worktree:

```bash
cd "$(scripts/isolated-sandbox.sh ensure)"
scripts/isolated-sandbox.sh run
```

The sandbox builds and launches `io.remotecode.desktop.debug` with its own Application Support directory, SQLite store, and HTTP port (18218 by default). An installed MacCode app (`io.remotecode.desktop`) is not affected. Use `scripts/isolated-sandbox.sh stop` to stop the sandbox app. `script/build_and_run.sh` runs the same sandbox flow.

`scripts/isolated-sandbox.sh test` runs the test suite in the sandbox worktree.

### Local Package

`scripts/package-app.sh` builds a local `MacCode.app` into `dist/`. The output is not a release artifact. `scripts/package-dmg.sh` builds the signed DMG and requires a Developer ID Application identity in `RC2_CODESIGN_IDENTITY`.

## Project Layout

Modules under `Sources/`:

| Module | Purpose |
| --- | --- |
| `AppShell` | macOS app shell: workspaces, tabs, panes, settings, command routing, lifecycle |
| `Surfaces` | Native surfaces: Agent App, Terminal, Browser, Files, Git/Diff, previews |
| `AgentRuntime` | Provider adapters (Codex, Claude Code, Grok, Distill), streaming, approvals, session recovery |
| `SocketServer` | Local HTTP, RPC, and WebSocket API, pairing, event streams, remote dispatch |
| `CoreModel` | Shared workspace, surface, agent, provider, and event models |
| `Persistence` | SQLite storage for settings, workspaces, threads, messages, queues, and trusted devices |
| `DesignSystemKit` | Shared design tokens and native UI components |
| `AppLifecycleSupport` | App lifecycle helpers |
| `RemoteCodeTreaty` | Host RPC contract types shared with remote clients |
| `RemoteCodeDistillService` | Helper executable: provider proxy, Agent App middleware, subagent telemetry, Chrome host, bot and computer-use MCP servers |
| `RemoteCodeScheduledTaskAgent` | Executable that runs scheduled tasks |
| `RemoteCodeRunAsUserHelper` | Executable for the privileged run-as-user helper |
| `RC2CLI` | `rc2` command-line tool |
| `CSystem` | C system bridge used by the Swift modules |

Tests live in `Tests/`, one target per module. Build and helper scripts live in `scripts/` and `script/`.

## Releases

Releases are for maintainers only. Pushing a `vX.Y.Z` tag to GitHub starts `.github/workflows/release.yml` on a GitHub-hosted Xcode 27 runner. The workflow runs `scripts/release-stable.sh`, which signs and notarizes the DMG, and publishes it with the Sparkle appcast as assets of the GitHub release.

## Contributing

1. Branch from `main`.
2. Open a pull request against `main`.
3. Read [AGENTS.md](AGENTS.md) and [DESIGN.md](DESIGN.md) before changing behavior or UI. Both are binding for this repository.
4. Keep macOS and iOS in sync. Browser state, workspace state, and remote-control behavior must match on both sides. The iOS companion app is closed source, so iOS changes cannot be tested from this repository.
5. Run `scripts/test-unit.sh` and verify UI changes in the isolated sandbox app.

## Security

Do not report vulnerabilities in public issues. Email samuelfajreldines@gmail.com with the details. Include steps to reproduce if you can.

## License

MIT. See [LICENSE](LICENSE). Third-party notices are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Ghostty and Sparkle are MIT-licensed.
