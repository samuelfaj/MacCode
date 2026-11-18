import Foundation

/// Detects when an autonomous agent run finished while the agent was still
/// *waiting on a background job it launched* — e.g. it ended its turn narrating
/// "Standing by for the demo recording to complete." — rather than because the
/// task was actually done, and decides whether the host should auto-nudge the
/// agent to resume.
///
/// WHY: a long full-access run can spawn a background process (a Playwright
/// recording, a build) and then END ITS TURN narrating that it is "awaiting" the
/// result. The provider SDK emits its terminal `result` → the run is marked
/// `.completed`, but the work is not finished and nothing ever wakes the agent
/// back up. The app has NO visibility into background shells (the provider SDK
/// manages them opaquely), so it cannot observe the job's true completion;
/// instead it re-invokes the agent with a bounded "check the background task and
/// continue" nudge, and the agent polls the job itself.
///
/// The detector is intentionally CONSERVATIVE: it requires an explicit
/// "awaiting / standing by" phrase AND a background-work noun, so a normal final
/// answer that merely mentions "background" (e.g. "I ran the tests in the
/// background earlier; all pass.") or that ends "standing by for your next
/// instruction." does not trip it. False positives only cost one bounded,
/// autonomous-only nudge; false negatives leave the run flagged for the user.
public enum BackgroundAwaitContinuation {
    /// Max consecutive auto-nudges per thread before the host stops and leaves the
    /// run flagged as awaiting for the user to drive manually. Bounds runaway token
    /// spend when the agent keeps standing by.
    public static let maxAutoContinuations = 5

    /// Machine marker the Claude agent is instructed — via `systemPromptDirective`,
    /// injected into its system prompt on every run — to put at the START of any
    /// final message where it ENDS A TURN still waiting on background/async work.
    ///
    /// WHY: free-text stall detection has a hard ceiling (the phrase lists below
    /// catch only a fraction of the ways an agent can narrate "I'm waiting"). The
    /// marker makes the agent *self-declare* the stall, so the host recovers it
    /// regardless of phrasing. The phrase lists remain only as a backstop for turns
    /// that omit the marker. The marker is stripped from user-facing text at the
    /// render layer (`strippingAwaitingMarker`) so it never shows in the transcript.
    public static let awaitingMarker = "[[RC_AWAITING]]"

    /// System-prompt rule injected for the Claude provider on every run so the
    /// agent self-declares an unavoidable background-await
    /// with `awaitingMarker`. Behaviour-narrow on purpose: it governs only how the
    /// agent *signals* a wait it cannot avoid. It does not tell the agent to
    /// busy-poll, and it explicitly excludes "task is done" and "waiting on the
    /// user" so the host never auto-nudges those (auto-nudging a user-wait in
    /// full-access mode could make the agent act without the approval it awaits).
    public static let systemPromptDirective = """
    Background-await protocol: if you end your turn while still waiting on background or asynchronous work to finish — a deploy, build, CI job, poller, recording, download, a background shell process you started with &/nohup, other agent/CLI workers or subprocesses you spawned whose results you intend to collect or poll later, or anything that completes later and is expected to resume you — you MUST begin that final message with the exact marker \(awaitingMarker) on its own first line. On the next line, name the work you are waiting for and include its task ID or remote job reference if known. Never invent an identifier. The marker is required whenever you END YOUR TURN while such work you launched is still running, EVEN IF you intend to keep polling or believe you are still working — ending the turn is what stops you. Emit the marker ONLY when you are genuinely blocked waiting on such external work; never when the task is actually finished, never when you are waiting on the user, and never for multi-phase skill handoffs (e.g. "Proceeding to Phase N", "Next: Phase N", "PHASE N RESULT"). Prefer to keep working across phases in one turn, or to poll external work to completion within this turn, rather than stopping — use the marker only when stopping on external async work is truly unavoidable.
    """

    /// System-prompt rule injected for the Claude provider on every run so the agent
    /// does not PREEMPTIVELY refuse a connected MCP tool in a non-interactive run.
    ///
    /// WHY: in `--print` / autonomous mode the model tends to *assume* that an OAuth
    /// MCP server (Linear, Slack, etc.) needs an interactive browser auth it "cannot
    /// do here" and return BLOCKED — WITHOUT ever calling the tool. Observed live: a
    /// run loaded `mcp__linear__get_issue` via ToolSearch (twice) yet never invoked
    /// it and declared "Linear requires authentication unavailable in this
    /// non-interactive session," while the same tool succeeds headlessly (the OAuth
    /// token is cached in the login Keychain the CLI already reads). The failure is a
    /// false model assumption, not missing auth — so the fix is a prompt rule, not an
    /// infra change. Deliberately CONDITIONAL: it does not claim every server is
    /// authenticated (a token can genuinely be expired/absent); it only forbids
    /// declaring an MCP auth block *before* an actual tool call returned an auth error.
    public static let mcpToolAvailabilityDirective = """
    MCP tool availability: connected MCP servers in this session use credentials already cached by the CLI and work in non-interactive and autonomous runs. Do NOT assume an MCP tool needs interactive authentication, and do NOT report a server as unauthenticated or return BLOCKED for MCP authentication, merely because this session is non-interactive. When a relevant MCP tool is available, call it directly. Only treat an MCP server as needing authentication AFTER you have actually invoked one of its tools and received an explicit authentication/authorization error, and then include that exact error.
    """

    /// System-prompt rule injected for the Claude provider on every run so the agent
    /// WAITS for a remote MCP server that is still finishing its asynchronous connect
    /// instead of reporting it as perpetually "connecting".
    ///
    /// WHY: remote/OAuth MCP servers (Linear, the claude.ai connectors) connect
    /// LAZILY and asynchronously — the handshake begins only once the first turn is
    /// submitted and completes ~10-20s later. A quick first turn races ahead of it:
    /// the tools are not loaded yet and the CLI injects a "still connecting … will
    /// appear shortly" reminder, which the model repeats as a final answer ("it's
    /// connecting, try later") — the exact symptom users hit asking "is Linear
    /// active?". The tools DO arrive within the same session; `RefreshMcpTools`
    /// (exposed via `CLAUDE_CODE_ENABLE_REFRESH_MCP_TOOLS=1`, set for Claude turns in
    /// CodexRunner.processEnvironment) re-queries connected servers and loads their
    /// tools mid-turn. So the fix is to wait-and-refresh, matching what a human does
    /// in an already-warm terminal. Reproduced + verified on claude 2.1.218.
    public static let mcpConnectWaitDirective = """
    MCP connection timing: remote MCP servers finish connecting a few seconds into a session, so early on their tools may not be loaded yet and a reminder may say a server is "still connecting". When your task needs such a tool — or the user asks whether an MCP server or its tools are active — do NOT answer that it is unavailable or still connecting. Wait for it: call the RefreshMcpTools tool (after a brief shell `sleep` of a few seconds if its tools are not loaded yet) and retry until the server's tools appear, which normally happens within ~20 seconds, then use them. Report a server as unavailable only after its tools stay absent despite waiting and refreshing.
    """

    /// The always-on Claude system-prompt rules, injected on every Claude run via
    /// both live routes (CLI `buildStreamingArgs` and the SDK `claudeSystemPrompt`).
    /// Single source of truth so the two routes never drift: edit the directives
    /// above, not the call sites.
    public static let alwaysOnClaudeDirectives = systemPromptDirective
        + "\n\n" + mcpToolAvailabilityDirective
        + "\n\n" + mcpConnectWaitDirective
        + "\n\n" + BotPeerDelegation.providerDirective

    /// The nudge sent to re-invoke a stalled agent. Provider-agnostic and explicit
    /// about both branches (done vs still-running) so the agent does the right
    /// thing without re-launching duplicate work, and forbids another bare
    /// "standing by" stop.
    public static let continuationPrompt = """
    The background task you launched may now be finished. Check its output (for example with BashOutput on the background shell you started) and continue the original task to completion. If it is still running, wait briefly and check again. Do not stop until the task is actually done — do not just say you are standing by.
    """

    /// Phrases the agent uses to narrate that it is *waiting* on something. Includes
    /// the first-person future/present forms ("I'll wait", "I'm waiting") the Claude
    /// provider favours — e.g. "I'll wait for the deploy poller to complete …" — not
    /// just the present-continuous / "standing by" forms seen in the first incident.
    private static let awaitingPhrases = [
        "standing by", "stand by for", "awaiting", "await the", "waiting for", "waiting on",
        "i'll wait", "i will wait", "i'm waiting", "i am waiting",
        // pt-BR narration (matched against lowercased text; accents preserved)
        "aguardando", "aguardo", "vou aguardar", "esperando", "vou esperar", "no aguardo"
    ]

    /// Nouns that mark the thing being waited on as a *background job* (not a user
    /// hand-off). Kept tight to the demonstrated background-work vocabulary to
    /// avoid tripping on normal final answers.
    ///
    /// Deliberately precise rather than exhaustive: an adversarial corpus showed
    /// that generic completion phrases (" to complete", " to finish") and a bare
    /// "notif" stem misfire on *user-waits* — "I'll wait for your review … to
    /// complete the rollout", "I'll wait for you to confirm … before I notify the
    /// team" — where auto-nudging a full-access run would make it act WITHOUT the
    /// approval it is waiting for. So the job signal is "notifies me" (a job pinging
    /// the agent), never bare "notify" (an action the agent will take); recall on
    /// the long tail of stall phrasings is intentionally traded away to keep that
    /// false-positive class out.
    private static let backgroundNouns = [
        "background", "completion notification", "demo recording", "the recording", "vite rebuild", "rebuild",
        "poll", "notifies me", "notify me"
    ]

    /// True iff `finalMessage` reads like the agent stopped while waiting on a
    /// background job rather than because it finished the task.
    ///
    /// Two-tier: the deterministic `awaitingMarker` (the agent self-declaring the
    /// stall, works for ANY phrasing) is checked first; the heuristic phrase lists
    /// are only a backstop for turns that omit the marker.
    public static func isAwaitingBackgroundWork(_ finalMessage: String?) -> Bool {
        guard let lowered = finalMessage?.lowercased() else { return false }
        let text = lowered.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if text.contains(awaitingMarker.lowercased()) { return true }
        guard awaitingPhrases.contains(where: { text.contains($0) }) else { return false }
        return backgroundNouns.contains(where: { text.contains($0) })
    }

    // PERF: compile once — strippingAwaitingMarker runs on every rendered
    // assistant message; range(of:options:.regularExpression) recompiled.
    private static let awaitingMarkerRegex = try! NSRegularExpression(
        pattern: NSRegularExpression.escapedPattern(for: awaitingMarker),
        options: [.caseInsensitive]
    )
    private static let trailingSpacesBeforeNewlineRegex = try! NSRegularExpression(
        pattern: #"[ \t]+\n"#
    )
    private static let multiNewlineCollapseRegex = try! NSRegularExpression(
        pattern: #"\n{3,}"#
    )

    /// Removes host-internal incomplete-turn markers from user-facing text.
    /// Detection keys on the markers, but the transcript must never show them —
    /// mirrors `RetrieveHandleSanitizer`.
    ///
    /// Strips `awaitingMarker` and `AssistantToolMarkupSanitizer.uncalledToolMarker`
    /// (the durable signal left after raw tool-invocation markup is removed).
    ///
    /// A true no-op when neither marker is present, so it never reflows normal
    /// assistant prose (it runs on every rendered message).
    public static func strippingAwaitingMarker(_ text: String) -> String {
        let hasAwaiting = text.range(of: awaitingMarker, options: .caseInsensitive) != nil
        let hasUncalled = text.range(
            of: AssistantToolMarkupSanitizer.uncalledToolMarker,
            options: .caseInsensitive
        ) != nil
        guard hasAwaiting || hasUncalled else { return text }
        var stripped = text
        if hasAwaiting {
            let range = NSRange(stripped.startIndex..<stripped.endIndex, in: stripped)
            stripped = awaitingMarkerRegex.stringByReplacingMatches(
                in: stripped,
                options: [],
                range: range,
                withTemplate: ""
            )
        }
        if hasUncalled {
            stripped = AssistantToolMarkupSanitizer.strippingUncalledToolMarker(stripped)
            // strippingUncalledToolMarker already tidies; avoid double-trim path below
            // only when awaiting was absent.
            if !hasAwaiting { return stripped }
        }
        return tidyWhitespace(stripped)
    }

    private static func tidyWhitespace(_ text: String) -> String {
        var result = text
        for (regex, template) in [
            (trailingSpacesBeforeNewlineRegex, "\n"),
            (multiNewlineCollapseRegex, "\n\n")
        ] {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: template
            )
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the host should auto-nudge a just-finished run to resume.
    ///
    /// Only `.completed` autonomous (full-access) runs that trip the detector and
    /// are under the per-thread bound qualify — so supervised runs and runs that
    /// genuinely finished are never auto-nudged.
    public static func shouldAutoContinue(
        status: AgentRunStatus,
        finalMessage: String?,
        isAutonomous: Bool,
        priorAutoContinuations: Int,
        maxAutoContinuations: Int = maxAutoContinuations
    ) -> Bool {
        guard status == .completed, isAutonomous else { return false }
        guard priorAutoContinuations < maxAutoContinuations else { return false }
        return isAwaitingBackgroundWork(finalMessage)
    }

    // MARK: - Shell-detach classifier (shared by Claude / Codex / Grok adapters)

    /// Idempotent prefix of `awaitingMarker` + newline onto a turn's final message.
    ///
    /// No-op when the marker is already present (case-insensitive). Returns the bare
    /// marker when the message is empty or nil so a host-stamped stall still reaches
    /// the four UI surfaces that key on final-message text.
    public static func prefixingAwaitingMarker(_ finalMessage: String?) -> String? {
        let body = finalMessage ?? ""
        if body.range(of: awaitingMarker, options: .caseInsensitive) != nil {
            return finalMessage
        }
        if body.isEmpty { return awaitingMarker }
        return awaitingMarker + "\n" + body
    }

    /// Pure classifier: true when a shell `command` detaches work from the turn.
    ///
    /// Detaching: a line-ending background `&` (not `&&` / `||` / `&>` / `>&` /
    /// bare `2>&1`), or a word-boundary `nohup` / `setsid` / `disown`. Not detaching
    /// when the command also invokes the `wait` builtin (shell blocked on children).
    /// Allocation-cheap for per-stream-line use: regexes are static, no per-call compile.
    public static func commandDetachesShellWork(_ command: String) -> Bool {
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        // Precision: `wait` means the shell blocked until children finished.
        if waitBuiltinRegex.firstMatch(in: command, options: [], range: range) != nil {
            return false
        }
        if detachWordRegex.firstMatch(in: command, options: [], range: range) != nil {
            return true
        }
        for line in command.split(separator: "\n", omittingEmptySubsequences: false) {
            if lineHasTrailingBackgroundAmpersand(String(line)) { return true }
        }
        return false
    }

    private static let waitBuiltinRegex: NSRegularExpression = {
        // Word-boundary so `waiting` / `await` do not match.
        try! NSRegularExpression(pattern: #"\bwait\b"#)
    }()

    private static let detachWordRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"\b(?:nohup|setsid|disown)\b"#)
    }()

    /// True when `line` backgrounds a command: last non-whitespace (post-comment)
    /// character is a bare `&` that is not part of `&&`, `||`, `&>`, or `>&`.
    private static func lineHasTrailingBackgroundAmpersand(_ line: String) -> Bool {
        let stripped = stripTrailingShellCommentAndWhitespace(line)
        guard !stripped.isEmpty, stripped.last == "&" else { return false }
        if stripped.count >= 2 {
            let prev = stripped[stripped.index(stripped.endIndex, offsetBy: -2)]
            // `&&`, `||`, `&>` / `>&` are redirections or boolean ops, not background.
            if prev == "&" || prev == "|" || prev == ">" { return false }
        }
        return true
    }

    /// Strips a trailing `# ...` comment when `#` is outside single/double quotes,
    /// then trims whitespace. Cheap quote tracking only (no escapes beyond `\'`/`\"`).
    private static func stripTrailingShellCommentAndWhitespace(_ line: String) -> String {
        var inSingle = false
        var inDouble = false
        var commentStart: String.Index?
        var i = line.startIndex
        while i < line.endIndex {
            let ch = line[i]
            if ch == "\\" && (inSingle || inDouble) {
                // Skip escaped character inside quotes.
                i = line.index(after: i)
                if i < line.endIndex { i = line.index(after: i) }
                continue
            }
            if ch == "'" && !inDouble {
                inSingle.toggle()
            } else if ch == "\"" && !inSingle {
                inDouble.toggle()
            } else if ch == "#" && !inSingle && !inDouble {
                commentStart = i
                break
            }
            i = line.index(after: i)
        }
        let withoutComment = commentStart.map { String(line[..<$0]) } ?? line
        return withoutComment.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
