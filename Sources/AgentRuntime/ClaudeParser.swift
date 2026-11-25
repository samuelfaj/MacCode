import Foundation
import CoreModel

/// Inbound CLI `control_response` for a host `control_request` (interrupt receipt).
struct ClaudeControlResponseReceipt: Equatable, Sendable {
    let requestId: String
    let success: Bool
    let cancelled: [String]
    let stillQueued: [String]
}

/// Parser for Anthropic Claude CLI streaming output.
/// Maps stream events into the same normalized AssistantEvent model.
/// Supported events:
/// - system { subtype: "init", session_id }
/// - message_start { message: { id } }
/// - content_block_start { index, content_block: { type, id?, name? } }
/// - content_block_delta { index, delta: { type: "text_delta" | "thinking_delta" | "input_json_delta", text/thinking/partial_json } }
/// - content_block_stop { index }
/// - message_delta { delta }
/// - message_stop {}
/// - result { type: "result", subtype?, error? }
/// - sdk_error { message } — Agent SDK bridge query failure; terminal for the turn
public final class ClaudeParser {
    public init() {}

    private var sessionId: String?
    private var threadEmitted = false
    private var currentTurnId: String?
    private var indexToItemId: [Int: String] = [:]
    private var indexToType: [Int: AssistantItemType] = [:]
    private var indexToToolName: [Int: String] = [:]
    private var indexToToolInputJSON: [Int: String] = [:]
    private var exitPlanToolIds = Set<String>()
    private var emittedStructuredUserInputRequestIds = Set<String>()
    private var indexToAssistantBody: [Int: String] = [:]
    private var assembledAssistantBody: String = ""
    // PERF: whole-message assistant-text dedup (parseLine case "assistant") used to
    // compare each new block against the ENTIRE growing `assembledAssistantBody` and
    // linearly scan `emittedAssistantBodies` — re-running the `\s+` normalize regex
    // each time. In --output-format stream-json the CLI never sends message_start, so
    // these reset only at `result`/finalize and grew for the whole run => O(n^2) CPU
    // ramp. The normalized/compact forms of the assembled body are now maintained
    // incrementally, and emitted bodies are deduped via Sets, so per-block cost is
    // O(block length), not O(accumulated assistant text). Semantics are unchanged:
    // a block is suppressed iff its whitespace-normalized OR whitespace-stripped form
    // matches the assembled body or any prior emitted body.
    private var assembledAssistantBodyNormalized: String = ""
    private var assembledAssistantBodyCompact: String = ""
    private var emittedAssistantBodyNormalizedKeys: Set<String> = []
    private var emittedAssistantBodyCompactKeys: Set<String> = []
    // CLAUDE-PARTIAL-REPLAY: with --include-partial-messages every API message
    // arrives twice — streamed (message_start → content_block_*) AND replayed as
    // whole `assistant` events carrying the SAME message.id, one event per
    // completed block, emitted BEFORE that block's content_block_stop. Message ids
    // seen via message_start are recorded here so the replay's text/thinking
    // blocks are not opened as a second transcript item (the body-equality dedup
    // below cannot catch them: it records emitted bodies only at
    // content_block_stop, which has not arrived yet).
    private var streamedMessageIds: Set<String> = []
    /// CLAUDE-AUTH-002: AUTH-001 completes the turn on the synthetic assistant
    /// envelope. Live 2.1.270 still emits a follow-on `result` (`api_error`).
    /// Remember that so the result path does not hard-error or `ensureTurn` a
    /// second empty turn.
    private var completedTurnAsAuthFailure = false

    public func parseLine(_ line: String) -> [AssistantEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let data = trimmed.data(using: .utf8) else { return [] }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return parseObject(obj)
    }

    /// Dispatch on an already-decoded SDK/CLI JSON object.
    /// The Claude SDK bridge decodes each line once and reuses this so
    /// `sdk_error` / user-input / runtime / parser do not JSONSerialization again.
    public func parseObject(
        _ obj: [String: Any],
        now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> [AssistantEvent] {
        guard let type = obj["type"] as? String else { return [] }

        // Every line (incl. the cmux shim's hook_started/hook_response
        // lines that arrive BEFORE init) carries session_id — capture it
        // so the resume id is never lost.
        if let sid = obj["session_id"] as? String, !sid.isEmpty { sessionId = sid }

        if type == "stream_event", var event = obj["event"] as? [String: Any] {
            // Inject session_id if the nested event omits it, then dispatch
            // directly on the already-decoded dict — avoids the re-serialize +
            // re-parse round trip that was costing 1-2 extra JSON parses per line.
            if event["session_id"] == nil, let sid = obj["session_id"] {
                event["session_id"] = sid
            }
            // CLAUDE-CLI-011: --forward-subagent-text sets parent_tool_use_id on
            // the stream_event envelope. Nested message_start / content_block_*
            // omit it; copy so nested text does not join the parent assembled body.
            let nestedParent = event["parent_tool_use_id"]
            let nestedMissing = nestedParent == nil
                || nestedParent is NSNull
                || ((nestedParent as? String)?.isEmpty ?? false)
            if nestedMissing, let parent = obj["parent_tool_use_id"] {
                event["parent_tool_use_id"] = parent
            }
            guard let eventType = event["type"] as? String else { return [] }
            return parseDecodedObject(event, type: eventType, now: now)
        }

        return parseDecodedObject(obj, type: type, now: now)
    }

    /// Core dispatch on an already-decoded JSON object.  Called both from
    /// `parseLine` (after the initial `JSONSerialization` decode) and from the
    /// `stream_event` fast-path (with the nested `event` dict that was already
    /// decoded as part of the outer object).  This eliminates the previous
    /// re-serialize + recursive-parseLine round trip for `stream_event` lines.
    private func parseDecodedObject(_ obj: [String: Any], type: String, now: Int64) -> [AssistantEvent] {
        var out: [AssistantEvent] = []

        // Capture session_id from inner events too (stream_event path).
        if let sid = obj["session_id"] as? String, !sid.isEmpty { sessionId = sid }

        if type == "system" {
            // Emit threadStarted only on init (the shim's hook_* lines must
            // NOT trip the fallback before the real session id is known).
            if (obj["subtype"] as? String) == "init", !threadEmitted {
                threadEmitted = true
                out.append(.threadStarted(threadId: sessionId ?? UUID().uuidString,
                                          providerThreadId: sessionId))
            }
            out.append(contentsOf: systemEvents(from: obj, now: now))
            return out
        }

        if !threadEmitted {
            threadEmitted = true
            out.append(.threadStarted(threadId: sessionId ?? UUID().uuidString, providerThreadId: sessionId))
        }

        switch type {
        case "message_start":
            let messageId = (obj["message"] as? [String: Any])?["id"] as? String
            if currentTurnId == nil {
                let id = messageId ?? UUID().uuidString
                currentTurnId = id
                resetAssistantBodyDedupState()
                indexToAssistantBody = [:]
                out.append(.turnStarted(turnId: id))
            }
            // CLAUDE-PARTIAL-REPLAY: recorded after the reset above so the first
            // message's id survives it.
            if let messageId, !messageId.isEmpty {
                streamedMessageIds.insert(messageId)
            }
        case "content_block_start":
            let index = obj["index"] as? Int ?? 0
            let block = obj["content_block"] as? [String: Any] ?? [:]
            let bt = (block["type"] as? String) ?? "text"
            let itemType: AssistantItemType
            switch bt {
            case "thinking": itemType = .reasoning
            case "tool_use": itemType = .tool
            default: itemType = .assistantMessage
            }
            let rawItemId = (block["id"] as? String) ?? UUID().uuidString
            let parentToolUseId = nestedParentToolUseId(from: obj)
            let itemId = itemType == .tool ? rawItemId : namespacedItemId(rawItemId, parentToolUseId: parentToolUseId)
            indexToItemId[index] = itemId
            indexToType[index] = itemType
            let turnId = currentTurnId ?? ""
            let summary: String?
            if itemType == .tool {
                summary = block["name"] as? String
            } else if let parentToolUseId {
                summary = "subagent \(parentToolUseId)"
            } else {
                summary = nil
            }
            if itemType == .tool {
                indexToToolName[index] = summary
                if Self.isExitPlanMode(summary) { exitPlanToolIds.insert(itemId) }
                if let input = block["input"],
                   let data = try? JSONSerialization.data(withJSONObject: input),
                   let inputString = String(data: data, encoding: .utf8) {
                    indexToToolInputJSON[index] = inputString
                }
            }
            out.append(.itemStarted(item: AssistantItem(id: itemId, turnId: turnId, type: itemType, state: .streaming, summary: summary, body: "", progress: Self.progressValue(block) ?? Self.progressValue(obj), startedAtMs: now)))
        case "content_block_delta":
            let index = obj["index"] as? Int ?? 0
            guard let itemId = indexToItemId[index] else { break }
            let delta = obj["delta"] as? [String: Any] ?? [:]
            let dtype = delta["type"] as? String
            switch dtype {
            case "text_delta":
                let text = delta["text"] as? String
                // API-delta path only; the assembled normalized/compact dedup forms
                // are intentionally NOT updated here — they are read solely by the
                // whole-message `assistant` path (assembledAssistantBodyMatches).
                // When both shapes arrive (--include-partial-messages), the whole-
                // message replay of a streamed message is skipped upstream via
                // streamedMessageIds (CLAUDE-PARTIAL-REPLAY) and never consults them.
                // Nested forwarded text (parent_tool_use_id) must not join the
                // parent assembled body — empty `result` falls back to it.
                if let text, nestedParentToolUseId(from: obj) == nil {
                    assembledAssistantBody += text
                }
                if let text, indexToType[index] == .assistantMessage {
                    indexToAssistantBody[index, default: ""] += text
                }
                out.append(.itemDelta(itemId: itemId, bodyAppend: text, outputAppend: nil, summary: nil))
            case "thinking_delta":
                let text = delta["thinking"] as? String
                out.append(.itemDelta(itemId: itemId, bodyAppend: text, outputAppend: nil, summary: nil))
            case "input_json_delta":
                let text = delta["partial_json"] as? String
                if let text {
                    indexToToolInputJSON[index, default: ""] += text
                }
                out.append(.itemDelta(itemId: itemId, bodyAppend: nil, outputAppend: text, summary: nil))
            default:
                break
            }
            if let progress = Self.progressValue(delta) ?? Self.progressValue(obj) {
                out.append(.itemProgress(itemId: itemId, progress: progress))
            }
        case "content_block_stop":
            let index = obj["index"] as? Int ?? 0
            if let itemId = indexToItemId[index] {
                if indexToType[index] == .assistantMessage,
                   let emitted = indexToAssistantBody[index],
                   !emitted.isEmpty,
                   !hasEmittedAssistantBody(emitted) {
                    recordEmittedAssistantBody(emitted)
                }
                out.append(.itemCompleted(itemId: itemId, finalState: .completed))
                if indexToType[index] == .tool {
                    out.append(contentsOf: structuredClaudeToolEvents(
                        toolId: itemId,
                        name: indexToToolName[index],
                        input: parseToolInput(indexToToolInputJSON[index]),
                        turnId: currentTurnId ?? "",
                        now: now
                    ))
                    // content_block_start seeds "{}" and the deltas append the real object after it.
                    out.append(contentsOf: fileTouchEvents(
                        toolId: itemId,
                        name: indexToToolName[index],
                        input: parseToolInput(indexToToolInputJSON[index].map { $0.hasPrefix("{}{") ? String($0.dropFirst(2)) : $0 }),
                        now: now
                    ))
                }
                indexToItemId.removeValue(forKey: index)
                indexToType.removeValue(forKey: index)
                indexToToolName.removeValue(forKey: index)
                indexToToolInputJSON.removeValue(forKey: index)
                indexToAssistantBody.removeValue(forKey: index)
            }
        case "message_delta", "message_stop":
            break
        case "assistant", "user":
            // `claude --print --output-format stream-json` emits whole
            // messages, NOT Anthropic-API deltas: {type:"assistant",
            // message:{content:[{type:"text",text:…}|{type:"tool_use",…}]}}.
            // CLAUDE-AUTH-001: unauthenticated CLI 2.1.x emits a synthetic
            // assistant envelope (`error: authentication_failed`) instead of
            // `auth_status`. Treat it as recoverable failure, not assistant text.
            // Complete the turn here so `inFlightRunId` can clear even if no
            // `result` follows. CLAUDE-AUTH-002: 2.1.270 always emits a follow-on
            // result (`terminal_reason=api_error`); that path must not hard-error
            // or open a second turn.
            if type == "assistant", Self.isAuthenticationFailedAssistantEnvelope(obj) {
                ensureTurn(&out)
                out.append(contentsOf: authenticationFailedAssistantEvents(from: obj, now: now))
                if let tid = currentTurnId {
                    out.append(.turnCompleted(turnId: tid, finalMessage: nil))
                    currentTurnId = nil
                    resetAssistantBodyDedupState()
                    indexToAssistantBody = [:]
                    exitPlanToolIds.removeAll()
                    completedTurnAsAuthFailure = true
                }
                break
            }
            completedTurnAsAuthFailure = false
            ensureTurn(&out)
            let msg = obj["message"] as? [String: Any] ?? [:]
            // `--replay-user-messages` echoes the host's own prompt back as a
            // `user` message. Its text/thinking blocks are the USER's words, not
            // assistant prose: rendering them duplicated every prompt into the
            // turn, and feeding them into the assembled-body state made
            // finalize() persist the prompt as an interrupted run's final
            // assistant answer. Only tool_result blocks (which ride on
            // user-role messages) may be processed for user messages.
            let isUserMessage = type == "user" || (msg["role"] as? String) == "user"
            // CLAUDE-PARTIAL-REPLAY: a whole `assistant` event whose message.id was
            // already seen via a streamed message_start is a per-block replay of
            // content the content_block_* path is rendering live. Its text/thinking
            // blocks must not open a second item. Tool blocks still flow through:
            // they are keyed by the provider tool id, so both paths converge on one
            // item, and the usage extraction below must keep running either way.
            let isStreamedMessageReplay = (msg["id"] as? String)
                .map { streamedMessageIds.contains($0) } ?? false
            let content = msg["content"] as? [[String: Any]] ?? []
            for block in content {
                let bt = (block["type"] as? String) ?? "text"
                let itemId = (block["id"] as? String) ?? UUID().uuidString
                let turnId = currentTurnId ?? ""
                switch bt {
                case "text":
                    if isUserMessage || isStreamedMessageReplay { break }
                    let text = block["text"] as? String ?? ""
                    if text.isEmpty { break }
                    if assembledAssistantBodyMatches(text) || hasEmittedAssistantBody(text) { break }
                    let parentToolUseId = nestedParentToolUseId(from: obj)
                    let nestedItemId = namespacedItemId(itemId, parentToolUseId: parentToolUseId)
                    if parentToolUseId == nil {
                        recordEmittedAssistantBody(text)
                        appendAssembledAssistantBody(text)
                    }
                    let summary = parentToolUseId.map { "subagent \($0)" }
                    out.append(.itemStarted(item: AssistantItem(id: nestedItemId, turnId: turnId, type: .assistantMessage, state: .streaming, summary: summary, body: "", startedAtMs: now)))
                    out.append(.itemDelta(itemId: nestedItemId, bodyAppend: text, outputAppend: nil, summary: nil))
                    out.append(.itemCompleted(itemId: nestedItemId, finalState: .completed))
                case "thinking":
                    if isUserMessage || isStreamedMessageReplay { break }
                    let text = block["thinking"] as? String ?? ""
                    let parentToolUseId = nestedParentToolUseId(from: obj)
                    let nestedItemId = namespacedItemId(itemId, parentToolUseId: parentToolUseId)
                    let summary = parentToolUseId.map { "subagent \($0)" }
                    out.append(.itemStarted(item: AssistantItem(id: nestedItemId, turnId: turnId, type: .reasoning, state: .streaming, summary: summary, body: "", startedAtMs: now)))
                    out.append(.itemDelta(itemId: nestedItemId, bodyAppend: text, outputAppend: nil, summary: nil))
                    out.append(.itemCompleted(itemId: nestedItemId, finalState: .completed))
                case "tool_use":
                    let name = block["name"] as? String
                    if Self.isExitPlanMode(name) { exitPlanToolIds.insert(itemId) }
                    let input = (try? JSONSerialization.data(withJSONObject: block["input"] ?? [:]))
                        .flatMap { String(data: $0, encoding: .utf8) }
                    let structuredEvents = structuredClaudeToolEvents(
                        toolId: itemId,
                        name: name,
                        input: block["input"] as? [String: Any],
                        turnId: turnId,
                        now: now
                    )
                    out.append(.itemStarted(item: AssistantItem(id: itemId, turnId: turnId, type: .tool, state: .streaming, summary: name, body: input ?? "", startedAtMs: now)))
                    out.append(.itemCompleted(itemId: itemId, finalState: .completed))
                    out.append(contentsOf: structuredEvents)
                    out.append(contentsOf: fileTouchEvents(toolId: itemId, name: name, input: block["input"] as? [String: Any], now: now))
                case "tool_result":
                    let payload = block["content"]
                    let s = (payload as? String) ?? ((try? JSONSerialization.data(withJSONObject: payload ?? [:])).flatMap { String(data: $0, encoding: .utf8) }) ?? ""
                    let toolUseId = stringValue(block["tool_use_id"]) ?? itemId
                    out.append(.itemStarted(item: AssistantItem(id: toolUseId, turnId: turnId, type: .tool, state: .completed, summary: "result", body: "", output: s, startedAtMs: now)))
                    out.append(.itemCompleted(itemId: toolUseId, finalState: .completed))
                    if exitPlanToolIds.remove(toolUseId) != nil,
                       let markdown = planMarkdown(from: obj["tool_use_result"] ?? payload),
                       !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        out.append(.proposedPlan(AssistantProposedPlan(id: toolUseId, turnId: turnId, markdown: markdown)))
                    }
                default:
                    break
                }
            }
            // Per-request occupancy lives on assistant → message.usage (Anthropic
            // API shape). The later CLI `result` modelUsage is session-cumulative
            // billing only — do not treat it as context occupancy.
            if !isUserMessage {
                if let msgUsage = msg["usage"] as? [String: Any],
                   let usage = tokenUsage(from: ["usage": msgUsage]) {
                    out.append(.tokenUsage(usage))
                }
            }
        case "result":
            // Authoritative final answer is the top-level `result` string.
            let isError = (obj["is_error"] as? Bool) ?? ((obj["subtype"] as? String).map { $0 != "success" } ?? false)
            let resultText = obj["result"] as? String
            if let usage = tokenUsage(from: obj) {
                out.append(.tokenUsage(usage))
            }
            out.append(contentsOf: permissionDenialResultEvents(from: obj, now: now))
            // CLAUDE-AMBIENT-TASK-RESULT: on resume the CLI dumps orphaned
            // background-task notifications and may emit a success result with
            // origin.kind == "task-notification", num_turns == 0, and an empty
            // body — without processing the user prompt. Completing a turn for
            // that ambient result finishes the host run empty ("without producing
            // an assistant response"). Keep usage accounting; do not own lifecycle.
            if !isError,
               Self.isAmbientTaskNotificationResult(
                obj,
                resultText: resultText,
                hasAssistantBody: !assembledAssistantBody.isEmpty
               ) {
                break
            }
            // CLAUDE-AUTH-002: after AUTH-001, live 2.1.270 still emits
            // `subtype=success is_error=true terminal_reason=api_error`.
            // Do not append recoverable:false or ensureTurn a second empty turn.
            let alreadyCompletedAsAuthFailure = completedTurnAsAuthFailure
            completedTurnAsAuthFailure = false
            let isAuthFailedResult = alreadyCompletedAsAuthFailure
                || Self.isAuthenticationFailedResult(obj)
            if isAuthFailedResult {
                if !alreadyCompletedAsAuthFailure {
                    let msg = resultText.flatMap { $0.isEmpty ? nil : $0 }
                        ?? "Claude authentication failed"
                    out.append(.error(message: msg, recoverable: true))
                    out.append(contentsOf: completedRuntimeItem(
                        id: stringValue(obj["uuid"]) ?? "claude-auth-failed-result-\(now)",
                        type: .error,
                        summary: "Claude auth",
                        body: msg,
                        now: now
                    ))
                }
                if alreadyCompletedAsAuthFailure, currentTurnId == nil {
                    break
                }
                if currentTurnId == nil {
                    ensureTurn(&out)
                }
                let final = (resultText?.isEmpty == false ? resultText : nil)
                    ?? (assembledAssistantBody.isEmpty ? nil : assembledAssistantBody)
                if let tid = currentTurnId {
                    out.append(.turnCompleted(turnId: tid, finalMessage: final))
                    currentTurnId = nil
                    resetAssistantBodyDedupState()
                    indexToAssistantBody = [:]
                    exitPlanToolIds.removeAll()
                }
                break
            }
            if isError, !Self.isHostInterruptResult(obj) {
                let msg = resultText
                    ?? (obj["error"] as? [String: Any])?["message"] as? String
                    ?? "claude run failed"
                out.append(.error(message: msg, recoverable: false))
            }
            ensureTurn(&out)
            let final = (resultText?.isEmpty == false ? resultText : nil)
                ?? (assembledAssistantBody.isEmpty ? nil : assembledAssistantBody)
            if let tid = currentTurnId {
                out.append(.turnCompleted(turnId: tid, finalMessage: final))
                currentTurnId = nil
                resetAssistantBodyDedupState()
                indexToAssistantBody = [:]
                exitPlanToolIds.removeAll()
            }
        case "error":
            let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? "claude error"
            out.append(.error(message: msg, recoverable: false))
        case "sdk_error":
            // Sole failure signal of the Agent SDK bridge's query loop
            // (ClaudeAgentSDKBridge.mjs): the query died mid-run and no `result`
            // will ever follow, so the turn must be completed here — otherwise
            // the adapter never emits .finished and the run hangs in 'running'.
            out.append(.error(message: stringValue(obj["message"]) ?? "Claude Agent SDK error", recoverable: true))
            ensureTurn(&out)
            if let tid = currentTurnId {
                out.append(.turnCompleted(turnId: tid, finalMessage: nil))
                currentTurnId = nil
                resetAssistantBodyDedupState()
                indexToAssistantBody = [:]
                exitPlanToolIds.removeAll()
            }
        case "plan_update", "update_plan":
            if let plan = activePlan(from: obj, now: now) {
                out.append(.activePlanUpdated(plan))
            }
        case "tool_progress":
            if let event = progressItem(from: obj, defaultSummary: "Claude tool progress", now: now) {
                out.append(contentsOf: event)
            }
        case "tool_use_summary":
            out.append(contentsOf: completedRuntimeItem(
                id: stringValue(obj["id"]) ?? stringValue(obj["tool_use_id"]) ?? UUID().uuidString,
                type: .tool,
                summary: stringValue(obj["name"]) ?? stringValue(obj["tool_name"]) ?? "Claude tool summary",
                body: stringValue(obj["summary"]) ?? jsonString(obj["input"]) ?? jsonString(obj),
                now: now
            ))
        case "auth_status":
            out.append(contentsOf: authStatusEvents(from: obj, now: now))
        case "rate_limit_event":
            out.append(contentsOf: rateLimitEvents(from: obj, now: now))
        case "usage", "token_usage":
            if let usage = tokenUsage(from: obj) {
                out.append(.tokenUsage(usage))
            }
        case "compact_boundary", "context_compaction":
            out.append(contentsOf: compactionEvents(from: obj, now: now))
        case "control_request":
            // CLI stream-json control channel (Agent SDK 0.3.x / claude CLI):
            // {"type":"control_request","request_id":"…","request":{"subtype":"can_use_tool"|…}}
            // Host replies key on the envelope request_id (not tool_use_id).
            if let inner = obj["request"] as? [String: Any] {
                let subtype = stringValue(inner["subtype"])
                let envelopeId = stringValue(obj["request_id"]) ?? stringValue(obj["requestId"])
                if subtype == "can_use_tool" {
                    var flattened = inner
                    if let rid = envelopeId {
                        flattened["request_id"] = rid
                    }
                    let toolName = stringValue(inner["tool_name"])
                        ?? stringValue(inner["toolName"])
                        ?? stringValue(inner["name"])
                    // CLAUDE-CLI-004: AskUserQuestion arrives as can_use_tool; answers must
                    // ride control_response updatedInput, not a freeform user turn. Open a
                    // structured user-input card keyed by envelope request_id.
                    if Self.isAskUserQuestion(toolName) {
                        let input = (inner["input"] as? [String: Any]) ?? [:]
                        let requestId = envelopeId
                            ?? stringValue(inner["tool_use_id"])
                            ?? UUID().uuidString
                        // Prefer control request_id: if tool_use already opened a card for
                        // the same tool_use_id, resolve that card so the UI is not dual-pending.
                        if let toolUseId = stringValue(inner["tool_use_id"]),
                           toolUseId != requestId,
                           emittedStructuredUserInputRequestIds.contains(toolUseId) {
                            out.append(.userInputResolved(requestId: toolUseId, answer: nil))
                        }
                        let request = askUserQuestionRequest(
                            toolId: requestId,
                            input: input,
                            turnId: currentTurnId ?? requestId,
                            now: now
                        )
                        out.append(contentsOf: deduplicatedStructuredUserInputRequest(request))
                    } else if let request = permissionRequest(from: flattened, now: now) {
                        out.append(.requestOpened(request))
                    }
                } else if subtype == "elicitation" {
                    // CLAUDE-CLI-005: MCP elicitation/create on the control channel.
                    var flattened = inner
                    if let rid = envelopeId {
                        flattened["request_id"] = rid
                    }
                    if let request = userInputRequest(from: flattened, now: now) {
                        out.append(.userInputRequested(request))
                    }
                } else if subtype == "request_user_dialog" {
                    // CLAUDE-CLI-013: tool-driven blocking dialogs (e.g. computer_use_approval).
                    // Surface as user-input so the host can answer; never drop silently
                    // (CLI parks the turn until control_response or timeout).
                    var flattened = inner
                    if let rid = envelopeId {
                        flattened["request_id"] = rid
                    }
                    let kind = stringValue(inner["dialog_kind"]) ?? stringValue(inner["dialogKind"]) ?? "dialog"
                    if flattened["prompt"] == nil && flattened["message"] == nil && flattened["title"] == nil {
                        flattened["prompt"] = "Claude requested dialog: \(kind)"
                    }
                    if let request = userInputRequest(from: flattened, now: now) {
                        out.append(.userInputRequested(request))
                    }
                }
            }
        case "control_response":
            // Inbound receipts (interrupt_receipt_v1, permission answers echoed
            // on stdout). Adapter matches pending interrupt request_id. Do not
            // emit a hard error or a new AssistantEvent case.
            break
        case "control_cancel_request":
            // CLAUDE-CLI-008: CLI cancelled an in-flight control request — drop both
            // approval and user-input pending UI for that request_id.
            if let id = stringValue(obj["request_id"]) ?? stringValue(obj["requestId"]), !id.isEmpty {
                out.append(.requestResolved(requestId: id, state: .cancelled))
                out.append(.userInputResolved(requestId: id, answer: nil))
            }
        case "permission_request", "request.opened", "canUseTool/request":
            if let request = permissionRequest(from: obj, now: now) {
                out.append(.requestOpened(request))
            }
        case "permission_decision", "request.resolved", "canUseTool/decision":
            if let resolved = permissionResolution(from: obj) {
                out.append(.requestResolved(requestId: resolved.id, state: resolved.state))
            }
        case "user_input_request", "elicitation":
            if let request = userInputRequest(from: obj, now: now) {
                out.append(.userInputRequested(request))
            }
        case "user_input_response", "user_input_resolved":
            if let id = stringValue(obj["request_id"]) ?? stringValue(obj["id"]) ?? stringValue(obj["elicitation_id"]) {
                out.append(.userInputResolved(requestId: id, answer: stringValue(obj["text"]) ?? stringValue(obj["answer"])))
            }
        default:
            break
        }
        return out
    }

    private func systemEvents(from obj: [String: Any], now: Int64) -> [AssistantEvent] {
        let subtype = obj["subtype"] as? String ?? ""
        switch subtype {
        case "init":
            var out: [AssistantEvent] = []
            if let usage = tokenUsage(from: obj) {
                out.append(.tokenUsage(usage))
            }
            out.append(contentsOf: initLoadErrorEvents(from: obj, now: now))
            return out
        case "rc_bridge_ready":
            return [.providerRuntime(ProviderRuntimeEvent(
                provider: .claude,
                source: "claude.agent-sdk",
                method: "runtime.handshake",
                payloadJSON: jsonString(obj) ?? "{}",
                receivedAtMs: now
            ))]
        case "status":
            return completedRuntimeItem(
                id: stringValue(obj["id"]) ?? "claude-status-\(now)",
                type: .tool,
                summary: "Claude status: \(stringValue(obj["status"]) ?? stringValue(obj["state"]) ?? "updated")",
                body: stringValue(obj["message"]) ?? jsonString(obj),
                now: now
            )
        case "compact_boundary":
            return compactionEvents(from: obj, now: now)
        case "hook_started", "hook_progress", "hook_response":
            let hook = stringValue(obj["hook_name"]) ?? stringValue(obj["name"]) ?? "hook"
            var out = completedRuntimeItem(
                id: stringValue(obj["id"]) ?? "\(subtype)-\(hook)-\(now)",
                type: .tool,
                summary: "Claude hook: \(hook)",
                body: stringValue(obj["output"]) ?? stringValue(obj["message"]) ?? jsonString(obj),
                now: now
            )
            if let progress = Self.progressValue(obj), let id = firstStartedItemId(in: out) {
                out.append(.itemProgress(itemId: id, progress: progress))
            }
            return out
        case "task_started", "task_progress", "task_notification":
            return taskEvents(from: obj, subtype: subtype, now: now)
        case "files_persisted":
            let files = obj["files"] as? [String] ?? []
            return completedRuntimeItem(
                id: stringValue(obj["id"]) ?? "files-persisted-\(now)",
                type: .fileChange,
                summary: "Claude files persisted",
                body: files.isEmpty ? (stringValue(obj["message"]) ?? jsonString(obj)) : files.joined(separator: "\n"),
                now: now
            )
        case "auth_status":
            return authStatusEvents(from: obj, now: now)
        case "rate_limit_event":
            return rateLimitEvents(from: obj, now: now)
        case "api_retry":
            // Claude Code headless stream-json emits system/api_retry before a
            // retriable API call. Surface it so long retries do not look hung.
            return apiRetryEvents(from: obj, now: now)
        case "permission_denied":
            // CLAUDE-PERM-DENIED-001: denials the CLI decides without calling
            // the host (deny rule / mode / classifier). Interactive asks still
            // arrive as control_request can_use_tool.
            return permissionDeniedEvents(from: obj, now: now)
        default:
            if let usage = tokenUsage(from: obj) {
                return [.tokenUsage(usage)]
            }
            return []
        }
    }

    private func taskEvents(from obj: [String: Any], subtype: String, now: Int64) -> [AssistantEvent] {
        var out = completedRuntimeItem(
            id: stringValue(obj["id"]) ?? stringValue(obj["task_id"]) ?? "\(subtype)-\(now)",
            type: .tool,
            summary: taskSummaryLabel(from: obj),
            body: taskBody(from: obj, subtype: subtype),
            now: now
        )
        if let progress = Self.progressValue(obj), let id = firstStartedItemId(in: out) {
            out.append(.itemProgress(itemId: id, progress: progress))
        }
        return out
    }

    /// Human label for background task rows. Prefer an explicit title/task when
    /// present; otherwise map known `task_type` values from the live CLI.
    private func taskSummaryLabel(from obj: [String: Any]) -> String {
        if let titled = stringValue(obj["title"]) ?? stringValue(obj["task"]), !titled.isEmpty {
            return titled
        }
        switch stringValue(obj["task_type"]) {
        case "local_bash":
            return "Background shell"
        case "local_agent":
            return "Background agent"
        default:
            return "Claude task"
        }
    }

    /// Prefer human-readable fields already on the wire (`description`, notification
    /// `status` / non-empty `output_file`). Raw JSON is last-resort only so unknown
    /// future payloads still render something.
    private func taskBody(from obj: [String: Any], subtype: String) -> String? {
        if let description = stringValue(obj["description"]), !description.isEmpty {
            return description
        }
        if subtype == "task_notification" {
            var parts: [String] = []
            if let status = stringValue(obj["status"]), !status.isEmpty {
                parts.append(status)
            }
            if let outputFile = stringValue(obj["output_file"]), !outputFile.isEmpty {
                parts.append(outputFile)
            }
            if !parts.isEmpty {
                return parts.joined(separator: " · ")
            }
        }
        if let message = stringValue(obj["message"]), !message.isEmpty {
            return message
        }
        if let notification = stringValue(obj["notification"]), !notification.isEmpty {
            return notification
        }
        return jsonString(obj)
    }

    private func progressItem(from obj: [String: Any], defaultSummary: String, now: Int64) -> [AssistantEvent]? {
        let id = stringValue(obj["id"]) ?? stringValue(obj["tool_use_id"]) ?? stringValue(obj["item_id"]) ?? "tool-progress-\(now)"
        let body: String?
        if boolValue(obj["heartbeat"]) == true {
            if let elapsed = intValue(obj["elapsed_time_seconds"]) {
                body = "Running · \(elapsed)s elapsed"
            } else {
                body = "Running"
            }
        } else {
            body = stringValue(obj["message"]) ?? stringValue(obj["summary"]) ?? jsonString(obj)
        }
        var out = completedRuntimeItem(
            id: id,
            type: .tool,
            summary: stringValue(obj["name"]) ?? stringValue(obj["tool_name"]) ?? defaultSummary,
            body: body,
            now: now
        )
        if let progress = Self.progressValue(obj) {
            out.append(.itemProgress(itemId: id, progress: progress))
        }
        return out
    }

    private func compactionEvents(from obj: [String: Any], now: Int64) -> [AssistantEvent] {
        let summary = stringValue(obj["summary"])
            ?? stringValue(obj["message"])
            ?? "Claude context compacted"
        var out = completedRuntimeItem(
            id: stringValue(obj["id"]) ?? "claude-compaction-\(now)",
            type: .contextCompaction,
            summary: summary,
            body: summary,
            now: now
        )
        out.append(.contextCompaction(summary: summary))
        return out
    }

    private func authStatusEvents(from obj: [String: Any], now: Int64) -> [AssistantEvent] {
        let status = stringValue(obj["status"]) ?? stringValue(obj["state"]) ?? "updated"
        let message = stringValue(obj["message"]) ?? "Claude auth \(status)"
        if boolValue(obj["authenticated"]) == false || status.range(of: "fail", options: .caseInsensitive) != nil {
            return [
                .error(message: message, recoverable: true)
            ] + completedRuntimeItem(id: stringValue(obj["id"]) ?? "claude-auth-\(now)", type: .error, summary: "Claude auth", body: message, now: now)
        }
        return completedRuntimeItem(
            id: stringValue(obj["id"]) ?? "claude-auth-\(now)",
            type: .tool,
            summary: "Claude auth: \(status)",
            body: message,
            now: now
        )
    }

    private func authenticationFailedAssistantEvents(from obj: [String: Any], now: Int64) -> [AssistantEvent] {
        let msg = obj["message"] as? [String: Any] ?? [:]
        let content = msg["content"] as? [[String: Any]] ?? []
        let bodyText = content.compactMap { block -> String? in
            guard (block["type"] as? String) == "text" else { return nil }
            let text = block["text"] as? String ?? ""
            return text.isEmpty ? nil : text
        }.joined(separator: "\n")
        let message = bodyText.isEmpty
            ? (stringValue(obj["error"]) ?? "Claude authentication failed")
            : bodyText
        let id = stringValue(obj["uuid"])
            ?? stringValue(msg["id"])
            ?? "claude-auth-failed-\(now)"
        return [
            .error(message: message, recoverable: true)
        ] + completedRuntimeItem(id: id, type: .error, summary: "Claude auth", body: message, now: now)
    }

    private func rateLimitEvents(from obj: [String: Any], now: Int64) -> [AssistantEvent] {
        let info = obj["rate_limit_info"] as? [String: Any]
            ?? obj["rateLimitInfo"] as? [String: Any]
        let reset = stringValue(obj["reset_at"]) ?? stringValue(obj["resetAt"])
            ?? (info.flatMap { stringValue($0["resetsAt"] ?? $0["resets_at"]) })
        let limitType = stringValue(obj["limit_type"])
            ?? stringValue(obj["limitType"])
            ?? (info.flatMap { stringValue($0["rateLimitType"] ?? $0["rate_limit_type"]) })
            ?? "rate limit"
        let status = info.flatMap { stringValue($0["status"]) }
        let message = stringValue(obj["message"])
            ?? [limitType, status.map { "status \($0)" }, reset.map { "reset \($0)" }]
                .compactMap { $0 }
                .joined(separator: " ")
        var events = completedRuntimeItem(
            id: stringValue(obj["id"]) ?? stringValue(obj["uuid"]) ?? "claude-rate-limit-\(now)",
            type: .tool,
            summary: "Claude rate limit",
            body: message,
            now: now
        )
        if let usage = accountUsage(from: obj) {
            events.append(.accountUsage(usage))
        }
        return events
    }

    private func apiRetryEvents(from obj: [String: Any], now: Int64) -> [AssistantEvent] {
        let attempt = intValue(obj["attempt"])
        let maxRetries = intValue(obj["max_retries"]) ?? intValue(obj["maxRetries"])
        let delayMs = intValue(obj["retry_delay_ms"]) ?? intValue(obj["retryDelayMs"])
        let error = stringValue(obj["error"]) ?? stringValue(obj["error_status"]).map { "HTTP \($0)" }
        var parts: [String] = ["API retry"]
        if let attempt {
            if let maxRetries {
                parts.append("\(attempt)/\(maxRetries)")
            } else {
                parts.append("#\(attempt)")
            }
        }
        if let error, !error.isEmpty {
            parts.append(error)
        }
        if let delayMs, delayMs > 0 {
            parts.append("in \(delayMs)ms")
        }
        return completedRuntimeItem(
            id: stringValue(obj["uuid"]) ?? stringValue(obj["id"]) ?? "claude-api-retry-\(now)",
            type: .tool,
            summary: "Claude API retry",
            body: parts.joined(separator: " · "),
            now: now
        )
    }

    private func accountUsage(from obj: [String: Any]) -> AssistantAccountUsage? {
        AssistantAccountUsageParser.claude(from: obj)
    }

    private func tokenUsage(from obj: [String: Any]) -> AssistantTokenUsage? {
        if let modelUsage = obj["modelUsage"] as? [String: Any] ?? obj["model_usage"] as? [String: Any] {
            var uncached = 0
            var creation = 0
            var read = 0
            var output = 0
            var window: Int?
            var modelCostUSD = 0.0
            var modelCostComplete = true
            var modelCount = 0
            for value in modelUsage.values {
                guard let usage = value as? [String: Any] else { continue }
                modelCount += 1
                // Record the three cache buckets SEPARATELY (G3): folding them into one
                // number made net dollars uncomputable (a cache read is ~0.1x an uncached
                // token). inputTokens below stays the billed total for back-compat.
                uncached += intValue(usage["inputTokens"]) ?? intValue(usage["input_tokens"]) ?? 0
                creation += intValue(usage["cacheCreationInputTokens"]) ?? intValue(usage["cache_creation_input_tokens"]) ?? 0
                read += intValue(usage["cacheReadInputTokens"]) ?? intValue(usage["cache_read_input_tokens"]) ?? 0
                output += intValue(usage["outputTokens"]) ?? intValue(usage["output_tokens"]) ?? 0
                if let cost = doubleValue(usage["costUSD"] ?? usage["cost_usd"]) {
                    modelCostUSD += cost
                } else {
                    modelCostComplete = false
                }
                if let contextWindow = intValue(usage["contextWindow"]) ?? intValue(usage["context_window"]) {
                    window = max(window ?? 0, contextWindow)
                }
            }
            let input = uncached + creation + read
            let total = input + output
            guard total > 0 || window != nil else { return nil }
            let reportedCostMicros = costMicros(
                fromUSD: doubleValue(obj["total_cost_usd"] ?? obj["totalCostUSD"])
                    ?? (modelCount > 0 && modelCostComplete ? modelCostUSD : nil)
            )
            // modelUsage on CLI `result` is session-cumulative (cache re-reads sum
            // across the whole session). Do NOT set contextTokens — that would
            // inflate the context gauge (e.g. 2.8M / 200k → 999%).
            return AssistantTokenUsage(
                inputTokens: input,
                outputTokens: output,
                totalTokens: total,
                contextWindow: window,
                compactsAutomatically: nil,
                uncachedInputTokens: uncached,
                cacheCreationInputTokens: creation,
                cacheReadInputTokens: read,
                reportedCostMicros: reportedCostMicros,
                contextTokens: nil,
                semantics: .cumulative
            )
        }
        let usage = obj["usage"] as? [String: Any] ?? obj["token_usage"] as? [String: Any] ?? obj
        let uncached = intValue(usage["input_tokens"]) ?? intValue(usage["inputTokens"]) ?? 0
        let output = intValue(usage["output_tokens"]) ?? intValue(usage["outputTokens"]) ?? 0
        let creation = intValue(usage["cache_creation_input_tokens"])
            ?? intValue(usage["cacheCreationInputTokens"])
            ?? 0
        let read = intValue(usage["cache_read_input_tokens"])
            ?? intValue(usage["cacheReadInputTokens"])
            ?? 0
        let input = uncached + creation + read
        let providerTotal = intValue(usage["total_tokens"])
            ?? intValue(usage["totalTokens"])
            ?? 0
        let total = max(providerTotal, input + output)
        let window = intValue(usage["context_window"]) ?? intValue(usage["contextWindow"])
        guard input > 0 || output > 0 || total > 0 || window != nil else { return nil }
        let compactsAutomatically = usage["compacts_automatically"] as? Bool ?? usage["compactsAutomatically"] as? Bool
        let reportedCostMicros = costMicros(
            fromUSD: doubleValue(obj["total_cost_usd"] ?? obj["totalCostUSD"])
                ?? doubleValue(usage["costUSD"] ?? usage["cost_usd"])
        )
        // Per-request occupancy: uncached + cache write + cache read + output
        // for this single request (not session-cumulative modelUsage).
        let contextTokens = input + output
        return AssistantTokenUsage(
            inputTokens: input,
            outputTokens: output,
            totalTokens: total,
            contextWindow: window,
            compactsAutomatically: compactsAutomatically,
            uncachedInputTokens: uncached,
            cacheCreationInputTokens: creation,
            cacheReadInputTokens: read,
            reportedCostMicros: reportedCostMicros,
            contextTokens: contextTokens > 0 ? contextTokens : nil,
            // Assistant/usage payloads are independent API requests. A result
            // payload without modelUsage is a final snapshot for the run.
            semantics: stringValue(obj["type"]) == "result" ? .cumulative : .incremental
        )
    }

    private func costMicros(fromUSD value: Double?) -> Int? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        let micros = (value * 1_000_000).rounded()
        guard micros <= Double(Int.max) else { return nil }
        return Int(micros)
    }

    private func permissionRequest(from obj: [String: Any], now: Int64) -> AssistantPendingRequest? {
        let request = obj["request"] as? [String: Any] ?? obj
        let id = stringValue(request["request_id"])
            ?? stringValue(request["requestId"])
            ?? stringValue(request["id"])
            ?? stringValue(request["tool_use_id"])
        guard let id, !id.isEmpty else { return nil }
        let toolName = stringValue(request["tool_name"])
            ?? stringValue(request["toolName"])
            ?? stringValue(request["name"])
            ?? "Claude tool"
        let detail = stringValue(request["detail"])
            ?? stringValue(request["message"])
            ?? jsonString(request["input"])
            ?? jsonString(request)
        return AssistantPendingRequest(
            id: id,
            turnId: currentTurnId,
            kind: requestKind(from: toolName, request: request),
            title: toolName,
            detail: detail,
            createdAtMs: now
        )
    }

    private func permissionResolution(from obj: [String: Any]) -> (id: String, state: AssistantRequestState)? {
        let request = obj["request"] as? [String: Any] ?? obj
        let id = stringValue(request["request_id"])
            ?? stringValue(request["requestId"])
            ?? stringValue(request["id"])
            ?? stringValue(request["tool_use_id"])
        guard let id, !id.isEmpty else { return nil }
        let raw = (stringValue(request["state"]) ?? stringValue(request["decision"]) ?? stringValue(request["behavior"]) ?? "resolved").lowercased()
        let state: AssistantRequestState
        switch raw {
        case "allow", "allowed", "approve", "approved", "accept", "accepted":
            state = .approved
        case "deny", "denied", "decline", "declined", "reject", "rejected":
            state = .declined
        case "cancel", "cancelled", "canceled":
            state = .cancelled
        default:
            state = .resolved
        }
        return (id, state)
    }

    private func userInputRequest(from obj: [String: Any], now: Int64) -> AssistantUserInputRequest? {
        guard let id = stringValue(obj["request_id"]) ?? stringValue(obj["id"]) ?? stringValue(obj["elicitation_id"]) else {
            return nil
        }
        // Claude AskUserQuestion routed through the SDK bridge canUseTool path:
        // a structured `questions` array. Render it as a multi-question card rather
        // than a permission/approval row.
        let structuredQuestions = userInputQuestions(obj["questions"])
        if !structuredQuestions.isEmpty {
            return structuredUserInputRequest(
                id: id,
                turnId: stringValue(obj["turn_id"]) ?? currentTurnId ?? id,
                questions: structuredQuestions,
                now: now
            )
        }
        let schema = obj["requested_schema"] as? [String: Any]
        let prompt = stringValue(obj["prompt"])
            ?? stringValue(obj["question"])
            ?? stringValue(obj["message"])
            ?? stringValue(obj["title"])
            ?? stringValue(obj["description"])
            ?? "Input required"
        let schemaQuestions = schemaUserInputQuestions(schema)
        if !schemaQuestions.isEmpty {
            return AssistantUserInputRequest(
                id: id,
                turnId: stringValue(obj["turn_id"]) ?? currentTurnId ?? id,
                prompt: prompt,
                options: schemaQuestions.count == 1 ? schemaQuestions[0].options.map(\.label) : [],
                allowsMultipleSelection: schemaQuestions.count == 1
                    ? schemaQuestions[0].allowsMultipleSelection
                    : false,
                isSecret: schemaContainsSecret(schema),
                questions: schemaQuestions,
                createdAtMs: now
            )
        }
        let options = optionValues(obj["options"] ?? obj["choices"] ?? schema?["enum"])
        return AssistantUserInputRequest(
            id: id,
            turnId: stringValue(obj["turn_id"]) ?? currentTurnId ?? id,
            prompt: prompt,
            options: options,
            allowsMultipleSelection: boolValue(obj["allows_multiple_selection"])
                ?? boolValue(obj["allowsMultipleSelection"])
                ?? boolValue(schema?["uniqueItems"])
                ?? false,
            createdAtMs: now
        )
    }

    private func requestKind(from toolName: String, request: [String: Any]) -> AssistantRequestKind {
        if let raw = stringValue(request["kind"]) ?? stringValue(request["request_type"]) ?? stringValue(request["requestType"]),
           let kind = AssistantRequestKind(rawValue: raw) {
            return kind
        }
        let lowered = toolName.lowercased()
        if lowered.contains("bash") || lowered.contains("shell") || lowered.contains("exec") {
            return .commandExecution
        }
        if lowered.contains("read") {
            return .fileRead
        }
        if lowered.contains("edit") || lowered.contains("write") || lowered.contains("patch") {
            return .fileChange
        }
        return .dynamic
    }

    private func completedRuntimeItem(id: String, type: AssistantItemType, summary: String, body: String?, now: Int64) -> [AssistantEvent] {
        let turnId = currentTurnId ?? ""
        return [
            .itemStarted(item: AssistantItem(id: id, turnId: turnId, type: type, state: .completed, summary: summary, body: body ?? "", startedAtMs: now, finishedAtMs: now)),
            .itemCompleted(itemId: id, finalState: type == .error ? .failed : .completed)
        ]
    }

    private func firstStartedItemId(in events: [AssistantEvent]) -> String? {
        for event in events {
            if case .itemStarted(let item) = event { return item.id }
        }
        return nil
    }

    private func structuredClaudeToolEvents(toolId: String, name: String?, input: [String: Any]?, turnId: String, now: Int64) -> [AssistantEvent] {
        guard let tool = name?.lowercased() else { return [] }
        let input = input ?? [:]
        if tool == "askuserquestion" || tool == "ask_user_question" || tool == "ask_user" {
            return deduplicatedStructuredUserInputRequest(
                askUserQuestionRequest(toolId: toolId, input: input, turnId: turnId, now: now)
            )
        }
        if tool == "exitplanmode" || tool == "exit_plan_mode" {
            return []
        }
        return []
    }

    private func fileTouchEvents(toolId: String, name: String?, input: [String: Any]?, now: Int64) -> [AssistantEvent] {
        ProviderFileTouchParser.runtimeEvent(
            provider: .claude,
            touches: ProviderFileTouchParser.claude(toolName: name, input: input),
            itemId: toolId,
            receivedAtMs: now
        ).map { [$0] } ?? []
    }

    private static func isExitPlanMode(_ name: String?) -> Bool {
        normalizedToolName(name) == "exitplanmode"
    }

    /// Strip `_`/`-` and lowercase — matches Agent SDK / CLI tool-name normalization.
    private static func normalizedToolName(_ name: String?) -> String {
        (name ?? "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }

    /// AskUserQuestion (and legacy aliases) on the can_use_tool control path.
    private static func isAskUserQuestion(_ name: String?) -> Bool {
        let normalized = normalizedToolName(name)
        return normalized == "askuserquestion" || normalized == "askuser"
    }

    /// True when a CLI `result` is only the ambient dump of orphaned background
    /// task notifications (not a user-turn terminal).
    ///
    /// Wire shape observed on resume after a previous Claude process exit:
    /// `{type:"result", subtype:"success", is_error:false, result:"", num_turns:0,
    ///  origin:{kind:"task-notification"}, …}`.
    /// Pure — no I/O. Exposed via tests through parseLine behavior.
    static func isAmbientTaskNotificationResult(
        _ obj: [String: Any],
        resultText: String?,
        hasAssistantBody: Bool
    ) -> Bool {
        // Real model output always owns the lifecycle, even if origin is set.
        if hasAssistantBody { return false }
        if let text = resultText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        if (obj["is_error"] as? Bool) == true { return false }
        guard let origin = obj["origin"] as? [String: Any] else { return false }
        let kind = (origin["kind"] as? String)
            ?? (origin["type"] as? String)
            ?? ""
        return kind == "task-notification"
    }

    /// Host-driven interrupt completion. CLI 2.1.x returns `is_error: true` with
    /// `terminal_reason: aborted_streaming` after a control interrupt; that is a
    /// cancelled turn, not a hard provider failure.
    static func isHostInterruptResult(_ obj: [String: Any]) -> Bool {
        (obj["terminal_reason"] as? String) == "aborted_streaming"
    }

    /// Unauthenticated stream-json paints a synthetic assistant with
    /// `error: authentication_failed` / `is_api_error_message` instead of `auth_status`.
    static func isAuthenticationFailedAssistantEnvelope(_ obj: [String: Any]) -> Bool {
        guard (obj["type"] as? String) == "assistant" else { return false }
        // Require the authentication discriminator. Bare is_api_error_message is
        // also used for rate limits / invalid_request / server errors and must
        // not complete the turn as "Claude auth".
        if let error = obj["error"] as? String, error == "authentication_failed" { return true }
        return false
    }

    /// CLI 2.1.270 logged-out `result`: `subtype=success`, `is_error=true`,
    /// `terminal_reason=api_error`, body like "Not logged in · Please run /login".
    /// Other `api_error` failures (rate limit, billing, 5xx) must stay loud.
    static func isAuthenticationFailedResult(_ obj: [String: Any]) -> Bool {
        guard (obj["terminal_reason"] as? String) == "api_error" else { return false }
        let isError = (obj["is_error"] as? Bool)
            ?? ((obj["subtype"] as? String).map { $0 != "success" } ?? false)
        guard isError else { return false }
        let text = ((obj["result"] as? String) ?? "").lowercased()
        return text.contains("not logged in") || text.contains("please run /login")
    }

    /// Parse an inbound stdout `control_response` (interrupt receipt).
    static func controlResponseReceipt(from obj: [String: Any]) -> ClaudeControlResponseReceipt? {
        guard (obj["type"] as? String) == "control_response" else { return nil }
        let envelope = obj["response"] as? [String: Any] ?? [:]
        let requestId = textValue(envelope["request_id"])
            ?? textValue(obj["request_id"])
            ?? textValue(obj["requestId"])
        guard let requestId, !requestId.isEmpty else { return nil }
        let subtype = textValue(envelope["subtype"]) ?? ""
        let inner = envelope["response"] as? [String: Any] ?? [:]
        let cancelled = stringArray(inner["cancelled"])
        let stillQueued = stringArray(inner["still_queued"])
        return ClaudeControlResponseReceipt(
            requestId: requestId,
            success: subtype == "success",
            cancelled: cancelled,
            stillQueued: stillQueued
        )
    }

    private static func textValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private static func stringArray(_ value: Any?) -> [String] {
        (value as? [Any])?.compactMap { textValue($0) } ?? []
    }

    private func planMarkdown(from payload: Any?) -> String? {
        if let object = payload as? [String: Any] {
            return stringValue(object["plan"])
                ?? stringValue(object["markdown"])
                ?? stringValue(object["planMarkdown"])
        }
        if let blocks = payload as? [[String: Any]] {
            for block in blocks {
                if let plan = planMarkdown(from: block) { return plan }
                if let nested = planMarkdown(from: block["content"]) { return nested }
                if let text = block["text"] as? String, let plan = planMarkdown(from: text) { return plan }
            }
            return nil
        }
        guard let text = payload as? String else { return nil }
        guard let data = text.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return planMarkdown(from: decoded)
    }

    private func parseToolInput(_ raw: String?) -> [String: Any] {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    private func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let string as String:
            switch string.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        case let number as NSNumber:
            return number.boolValue
        default:
            return nil
        }
    }

    private func intValue(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let double as Double:
            return double
        case let int as Int:
            return Double(int)
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    // PERF: ISO8601DateFormatter init is expensive; parsing runs on every stream
    // timestamp fallback. Share one formatter under a short lock (not thread-safe).
    private static let isoFallbackLock = NSLock()
    private static let isoFallbackFormatter = ISO8601DateFormatter()

    private func resetMilliseconds(from value: Any?) -> Int64? {
        if let int = intValue(value) {
            return Int64(int)
        }
        guard let string = stringValue(value) else { return nil }
        if let int = Int64(string) {
            return int
        }
        Self.isoFallbackLock.lock()
        defer { Self.isoFallbackLock.unlock() }
        return Self.isoFallbackFormatter.date(from: string).map { Int64($0.timeIntervalSince1970 * 1000) }
    }

    private func jsonString(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func nestedParentToolUseId(from obj: [String: Any]) -> String? {
        guard let value = stringValue(obj["parent_tool_use_id"]), !value.isEmpty else { return nil }
        return value
    }

    private func namespacedItemId(_ itemId: String, parentToolUseId: String?) -> String {
        guard let parentToolUseId else { return itemId }
        return "\(parentToolUseId):\(itemId)"
    }

    /// CLAUDE-CLI-010: captured stderr hides CLI skip warnings; stream-json
    /// init carries mcp_server_errors / plugin_errors instead.
    private func initLoadErrorEvents(from obj: [String: Any], now: Int64) -> [AssistantEvent] {
        func rows(forKey key: String) -> [[String: Any]] {
            if let dicts = obj[key] as? [[String: Any]] { return dicts }
            if let strings = obj[key] as? [String] {
                return strings.map { ["message": $0] }
            }
            return []
        }
        var out: [AssistantEvent] = []
        for row in rows(forKey: "mcp_server_errors") {
            out.append(.providerRuntime(ProviderRuntimeEvent(
                provider: .claude,
                source: "claude.stream-json.init",
                method: "claude.init.mcp_server_error",
                payloadJSON: jsonString(row) ?? "{}",
                receivedAtMs: now
            )))
        }
        for row in rows(forKey: "plugin_errors") {
            out.append(.providerRuntime(ProviderRuntimeEvent(
                provider: .claude,
                source: "claude.stream-json.init",
                method: "claude.init.plugin_error",
                payloadJSON: jsonString(row) ?? "{}",
                receivedAtMs: now
            )))
        }
        // CLAUDE-INIT-MCP-001: runtime connect failures live on
        // `mcp_servers[].status=failed`. `mcp_server_errors` is only
        // config-validation skips.
        if let servers = obj["mcp_servers"] as? [[String: Any]] {
            for server in servers {
                guard stringValue(server["status"]) == "failed" else { continue }
                out.append(.providerRuntime(ProviderRuntimeEvent(
                    provider: .claude,
                    source: "claude.stream-json.init",
                    method: "claude.init.mcp_server_error",
                    payloadJSON: jsonString(server) ?? "{}",
                    receivedAtMs: now
                )))
            }
        }
        return out
    }

    /// CLAUDE-PERM-DENIED-001: `system/permission_denied` is best-effort; the
    /// host still needs a denial card when the CLI refuses without `can_use_tool`.
    private func permissionDeniedEvents(from obj: [String: Any], now: Int64) -> [AssistantEvent] {
        let tool = stringValue(obj["tool_name"])
            ?? stringValue(obj["toolName"])
            ?? stringValue(obj["name"])
        let id = stringValue(obj["tool_use_id"])
            ?? stringValue(obj["uuid"])
            ?? stringValue(obj["request_id"])
            ?? "claude-permission-denied-\(now)"
        let summary = tool.map { "Permission denied: \($0)" } ?? "Permission denied"
        var out: [AssistantEvent] = [
            .providerRuntime(ProviderRuntimeEvent(
                provider: .claude,
                source: "claude.stream-json",
                method: "claude.permission_denied",
                payloadJSON: jsonString(obj) ?? "{}",
                receivedAtMs: now
            ))
        ]
        out.append(contentsOf: completedRuntimeItem(
            id: id,
            type: .error,
            summary: summary,
            body: stringValue(obj["reason"]) ?? stringValue(obj["message"]) ?? jsonString(obj),
            now: now
        ))
        return out
    }

    /// Authoritative permission-denial record on `result.permission_denials`
    /// (complete for path-scoped Read/Edit/Write as of CLI 2.1.269). Empty
    /// arrays are silent.
    private func permissionDenialResultEvents(from obj: [String: Any], now: Int64) -> [AssistantEvent] {
        let rows: [[String: Any]]
        if let dicts = obj["permission_denials"] as? [[String: Any]] {
            rows = dicts
        } else if let strings = obj["permission_denials"] as? [String] {
            rows = strings.map { ["message": $0] }
        } else {
            return []
        }
        var out: [AssistantEvent] = []
        for (index, row) in rows.enumerated() {
            let tool = stringValue(row["tool_name"])
                ?? stringValue(row["toolName"])
                ?? stringValue(row["name"])
            let id = stringValue(row["tool_use_id"])
                ?? stringValue(row["uuid"])
                ?? "claude-permission-denial-\(index)-\(now)"
            let summary = tool.map { "Permission denied: \($0)" } ?? "Permission denied"
            out.append(.providerRuntime(ProviderRuntimeEvent(
                provider: .claude,
                source: "claude.stream-json.result",
                method: "claude.result.permission_denial",
                payloadJSON: jsonString(row) ?? "{}",
                receivedAtMs: now
            )))
            out.append(contentsOf: completedRuntimeItem(
                id: id,
                type: .error,
                summary: summary,
                body: stringValue(row["reason"]) ?? stringValue(row["message"]) ?? jsonString(row),
                now: now
            ))
        }
        return out
    }

    /// True iff `text` duplicates an already-emitted assistant body, by
    /// whitespace-normalized OR whitespace-stripped equality. O(1): membership in
    /// the pre-normalized key sets, equivalent to the old linear scan of
    /// `emittedAssistantBodies` with per-element `assistantText` comparison.
    private func hasEmittedAssistantBody(_ text: String) -> Bool {
        let normalized = normalizedAssistantText(text)
        guard !normalized.isEmpty else { return false }
        if emittedAssistantBodyNormalizedKeys.contains(normalized) { return true }
        let compact = compactAssistantText(text)
        return !compact.isEmpty && emittedAssistantBodyCompactKeys.contains(compact)
    }

    /// Records an emitted assistant body for future dedup, keyed by its normalized
    /// and compact forms (computed once at record time instead of re-normalized on
    /// every later comparison). Mirrors the old `emittedAssistantBodies.append`,
    /// which only mattered for bodies with a non-empty normalized form.
    private func recordEmittedAssistantBody(_ text: String) {
        let normalized = normalizedAssistantText(text)
        guard !normalized.isEmpty else { return }
        emittedAssistantBodyNormalizedKeys.insert(normalized)
        let compact = compactAssistantText(text)
        if !compact.isEmpty { emittedAssistantBodyCompactKeys.insert(compact) }
    }

    /// True iff `text` duplicates the whole accumulated assembled body (normalized OR
    /// compact equality). Uses the incrementally-maintained forms, so it does not
    /// re-normalize the growing body on every block. Equivalent to the old
    /// `assistantText(assembledAssistantBody, equals: text)`.
    private func assembledAssistantBodyMatches(_ text: String) -> Bool {
        guard !assembledAssistantBodyNormalized.isEmpty else { return false }
        let normalized = normalizedAssistantText(text)
        guard !normalized.isEmpty else { return false }
        if assembledAssistantBodyNormalized == normalized { return true }
        return assembledAssistantBodyCompact == compactAssistantText(text)
    }

    /// Appends a whole-message assistant text block to the assembled body and keeps
    /// the normalized/compact projections in sync. Blocks are joined by "\n", so the
    /// normalized form equals each block's normalized text joined by a single space
    /// (empty-normalized blocks contribute nothing, matching a trim of the raw body),
    /// and the compact form is the concatenation of each block's compact text.
    private func appendAssembledAssistantBody(_ text: String) {
        assembledAssistantBody += (assembledAssistantBody.isEmpty ? "" : "\n") + text
        let normalized = normalizedAssistantText(text)
        if !normalized.isEmpty {
            assembledAssistantBodyNormalized += assembledAssistantBodyNormalized.isEmpty ? normalized : " " + normalized
        }
        assembledAssistantBodyCompact += compactAssistantText(text)
    }

    /// Clears the per-run assistant-text dedup accumulators. Called at every reset
    /// point (message_start, result, finalize) so a new turn starts from scratch.
    private func resetAssistantBodyDedupState() {
        assembledAssistantBody = ""
        assembledAssistantBodyNormalized = ""
        assembledAssistantBodyCompact = ""
        emittedAssistantBodyNormalizedKeys = []
        emittedAssistantBodyCompactKeys = []
        emittedStructuredUserInputRequestIds = []
        streamedMessageIds = []
    }

    private func deduplicatedStructuredUserInputRequest(_ request: AssistantUserInputRequest) -> [AssistantEvent] {
        guard emittedStructuredUserInputRequestIds.insert(request.id).inserted else { return [] }
        return [.userInputRequested(request)]
    }

    #if DEBUG
    /// Test-only observability: counts `\s+` normalization passes run by the
    /// whole-message assistant-text dedup. A perf test asserts this stays O(blocks)
    /// across a long run instead of O(blocks^2) — the regression where dedup
    /// re-normalized the entire growing assembled body and every prior emitted body
    /// on each block, ramping CPU on long Claude runs. DEBUG-only so release builds
    /// carry no shared-mutable write on the parse path. Never read by production.
    nonisolated(unsafe) static var assistantTextNormalizationsForTesting = 0
    #endif

    // PERF: compile once — normalized/compact forms run on every assistant block
    // for stream-json dedup; replacingOccurrences(options: .regularExpression) recompiled.
    private static let whitespaceRegex = try! NSRegularExpression(pattern: #"\s+"#)

    private func normalizedAssistantText(_ text: String) -> String {
        #if DEBUG
        Self.assistantTextNormalizationsForTesting &+= 1
        #endif
        return Self.replaceAll(Self.whitespaceRegex, in: text, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func compactAssistantText(_ text: String) -> String {
        #if DEBUG
        Self.assistantTextNormalizationsForTesting &+= 1
        #endif
        return Self.replaceAll(Self.whitespaceRegex, in: text, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replaceAll(
        _ regex: NSRegularExpression,
        in text: String,
        with template: String
    ) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: template
        )
    }

    // Claude's AskUserQuestion tool sends a `questions` array, each entry with its
    // own `question`, `header`, structured `options` (label + description), and
    // `multiSelect`. Parse that real shape into the structured user-input model so
    // the card renders human-readable choices instead of raw JSON / an empty
    // "Input required" box. Falls back to the legacy singular `question`/`options`
    // shape so older synthetic payloads keep working.
    private func askUserQuestionRequest(toolId: String, input: [String: Any], turnId: String, now: Int64) -> AssistantUserInputRequest {
        let questions = userInputQuestions(input["questions"])
        if !questions.isEmpty {
            return structuredUserInputRequest(id: toolId, turnId: turnId, questions: questions, now: now)
        }
        let prompt = stringValue(input["question"])
            ?? stringValue(input["prompt"])
            ?? stringValue(input["message"])
            ?? "Input required"
        return AssistantUserInputRequest(
            id: toolId,
            turnId: turnId,
            prompt: prompt,
            options: optionValues(input["options"] ?? input["choices"]),
            allowsMultipleSelection: boolValue(input["allows_multiple_selection"])
                ?? boolValue(input["allowsMultipleSelection"])
                ?? boolValue(input["multi_select"])
                ?? false,
            createdAtMs: now
        )
    }

    private func structuredUserInputRequest(id: String, turnId: String, questions: [AssistantUserInputQuestion], now: Int64) -> AssistantUserInputRequest {
        // `prompt` is a plain-text summary used by the work log / accessibility; the
        // UI renders the structured `questions`. Mirror a single question's flat
        // options/multi-select so legacy single-list consumers keep working.
        let prompt: String
        if questions.count == 1 {
            prompt = questions[0].prompt
        } else {
            prompt = questions.map { question in
                if let header = question.header, !header.isEmpty { return "\(header): \(question.prompt)" }
                return question.prompt
            }.joined(separator: "\n")
        }
        return AssistantUserInputRequest(
            id: id,
            turnId: turnId,
            prompt: prompt,
            options: questions.count == 1 ? questions[0].options.map(\.label) : [],
            allowsMultipleSelection: questions.count == 1 ? questions[0].allowsMultipleSelection : false,
            questions: questions,
            createdAtMs: now
        )
    }

    private func userInputQuestions(_ value: Any?) -> [AssistantUserInputQuestion] {
        guard let array = value as? [[String: Any]] else { return [] }
        // Position-stable ids: AskUserQuestion may (rarely) repeat prompt text, and
        // an id == prompt would collide in SwiftUI identity / per-question UI state.
        return array.enumerated().compactMap { (index, raw) -> AssistantUserInputQuestion? in
            guard let prompt = (stringValue(raw["question"])
                ?? stringValue(raw["prompt"])
                ?? stringValue(raw["text"])
                ?? stringValue(raw["title"])),
                  !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return AssistantUserInputQuestion(
                id: "\(index)",
                prompt: prompt,
                header: stringValue(raw["header"]).flatMap { $0.isEmpty ? nil : $0 },
                options: userInputOptions(raw["options"] ?? raw["choices"]),
                allowsMultipleSelection: boolValue(raw["multiSelect"])
                    ?? boolValue(raw["multi_select"])
                    ?? boolValue(raw["allows_multiple_selection"])
                    ?? boolValue(raw["allowsMultipleSelection"])
                    ?? false
            )
        }
    }

    private func schemaUserInputQuestions(_ schema: [String: Any]?) -> [AssistantUserInputQuestion] {
        guard let properties = schema?["properties"] as? [String: Any] else { return [] }
        return properties.keys.sorted().compactMap { name in
            guard let property = properties[name] as? [String: Any] else { return nil }
            let title = stringValue(property["title"]) ?? name
            let prompt = stringValue(property["description"]) ?? title
            let options: [AssistantUserInputOption]
            if let values = property["enum"] as? [Any] {
                options = values.map { AssistantUserInputOption(label: String(describing: $0)) }
            } else if stringValue(property["type"]) == "boolean" {
                options = [
                    AssistantUserInputOption(label: "true", detail: "Yes"),
                    AssistantUserInputOption(label: "false", detail: "No")
                ]
            } else {
                options = []
            }
            return AssistantUserInputQuestion(
                id: name,
                prompt: prompt,
                header: title == prompt ? nil : title,
                options: options,
                allowsMultipleSelection: stringValue(property["type"]) == "array"
            )
        }
    }

    private func schemaContainsSecret(_ schema: [String: Any]?) -> Bool {
        guard let properties = schema?["properties"] as? [String: Any] else { return false }
        return properties.values.contains { value in
            guard let property = value as? [String: Any] else { return false }
            let format = stringValue(property["format"])?.lowercased() ?? ""
            return format.contains("password") || format.contains("secret") || format.contains("token")
        }
    }

    private func userInputOptions(_ value: Any?) -> [AssistantUserInputOption] {
        if let strings = value as? [String] {
            return strings.map { AssistantUserInputOption(label: $0) }
        }
        if let raw = value as? [[String: Any]] {
            return raw.compactMap { option in
                guard let label = stringValue(option["label"])
                    ?? stringValue(option["value"])
                    ?? stringValue(option["text"])
                    ?? stringValue(option["title"]) else { return nil }
                return AssistantUserInputOption(
                    label: label,
                    detail: stringValue(option["description"]).flatMap { $0.isEmpty ? nil : $0 }
                )
            }
        }
        return []
    }

    private func optionValues(_ value: Any?) -> [String] {
        if let strings = value as? [String] {
            return strings
        }
        if let raw = value as? [[String: Any]] {
            return raw.compactMap {
                stringValue($0["label"])
                    ?? stringValue($0["value"])
                    ?? stringValue($0["text"])
                    ?? stringValue($0["title"])
            }
        }
        return []
    }

    private func activePlan(from obj: [String: Any], now: Int64) -> AssistantActivePlan? {
        let rawSteps = obj["plan"] as? [[String: Any]]
            ?? obj["steps"] as? [[String: Any]]
            ?? (obj["update"] as? [String: Any])?["plan"] as? [[String: Any]]
        guard let rawSteps, !rawSteps.isEmpty else { return nil }
        let steps = rawSteps.enumerated().compactMap { index, raw -> AssistantPlanStep? in
            let title = raw["step"] as? String
                ?? raw["title"] as? String
                ?? raw["text"] as? String
                ?? raw["content"] as? String
                ?? ""
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let statusRaw = raw["status"] as? String ?? "pending"
            let status = AssistantPlanStepStatus(rawValue: statusRaw)
                ?? (statusRaw == "inProgress" ? .inProgress : .pending)
            let id = raw["id"] as? String ?? "\(index)-\(trimmed)"
            return AssistantPlanStep(id: id, title: trimmed, status: status)
        }
        guard !steps.isEmpty else { return nil }
        return AssistantActivePlan(explanation: obj["explanation"] as? String, steps: steps, updatedAtMs: now)
    }

    /// The CLI never sends `message_start`, so synthesize a turn the
    /// first time any assistant/result content appears.
    private func ensureTurn(_ out: inout [AssistantEvent]) {
        if currentTurnId == nil {
            let tid = UUID().uuidString
            currentTurnId = tid
            out.append(.turnStarted(turnId: tid))
        }
    }

    public func finalize() -> [AssistantEvent] {
        guard let tid = currentTurnId else { return [] }
        let final = assembledAssistantBody.isEmpty ? nil : assembledAssistantBody
        currentTurnId = nil
        resetAssistantBodyDedupState()
        indexToAssistantBody = [:]
        exitPlanToolIds.removeAll()
        return [.turnCompleted(turnId: tid, finalMessage: final)]
    }

    // PERF: progressValue trims string percent payloads on streaming item
    // events; share one CharacterSet instead of allocating per string parse.
    private static let progressPercentTrimSet = CharacterSet(charactersIn: "% ")

    private static func progressValue(_ obj: [String: Any]) -> Double? {
        for key in ["progress", "percentage", "percent"] {
            if let value = obj[key] as? Double { return AssistantTimelineState.normalizedProgress(value) }
            if let value = obj[key] as? Int { return AssistantTimelineState.normalizedProgress(Double(value)) }
            if let value = obj[key] as? String,
               let parsed = Double(value.trimmingCharacters(in: progressPercentTrimSet)) {
                return AssistantTimelineState.normalizedProgress(parsed)
            }
        }
        return nil
    }
}
